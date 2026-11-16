-- PriceShare: a light Auction House price scanner that shares prices with friends.
--
-- * Opening the Auction House starts a Full Scan (every auction at once), at most
--   once every 15 minutes from this client. Full Scans started by other addons
--   (VendorSnipe, Auctionator, ...) count too, and are saved the same way.
-- * For each item it keeps the cheapest price, a sale price (where the cheapest
--   10% of listed units end, at most 20 deep) and how many are listed.
-- * Friends who also run PriceShare are found automatically, and the newest scan
--   anyone has is passed around in the background (Sync.lua).
--
-- Times are server time (GetServerTime), so friends' clocks don't matter.

local _, ns = ...

local SCAN_COOLDOWN = 15 * 60   -- the server allows one Full Scan per 15 minutes
local SCAN_TIMEOUT = 30         -- seconds to wait for the server to send scan data
local AUTO_DELAY = 2            -- seconds after the AH opens before the auto-scan
local AUTO_TRIES = 10           -- ...retried each second while the AH is busy
local FRESH = 48 * 3600         -- older prices aren't shown or handed to other addons
local GONE_KEEP = 7 * 86400     -- how long "no longer listed" is remembered
local LINEAGE_MAX = 20          -- scan times remembered, so friends can get just the changes
local WORK_MS = 6               -- time per frame spent reading a scan
local SALE_SHARE, SALE_MAX = 0.1, 20

ns.FRESH = FRESH

-- This copy's version, told to friends so older copies know to update. Kept here and
-- not read from PriceShare.toc: WoW reads .toc files only when the game starts, so after
-- an update and a /reload the .toc would still report the old version.
-- (Keep "## Version" in PriceShare.toc the same; Update-PriceShare.bat reads that one.)
ns.VERSION = "1.6.2"
ns.UPDATE_HOW = "double-click Update-PriceShare.bat in Interface\\AddOns\\PriceShare, then restart WoW (or /reload, if it says that's enough)"

-- true when version a is newer than b ("1.10" > "1.9")
function ns.VersionNewer(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then
    return false
  end
  local pa, pb = {}, {}
  for n in a:gmatch("%d+") do
    pa[#pa + 1] = tonumber(n)
  end
  for n in b:gmatch("%d+") do
    pb[#pb + 1] = tonumber(n)
  end
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then
      return x > y
    end
  end
  return false
end

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
local function Now()
  return (GetServerTime and GetServerTime()) or time()
end
ns.Now = Now

local function Print(msg)
  print("|cff66ccffPriceShare|r: " .. msg)
end
ns.Print = Print

function ns.Debug(msg)
  if ns.db and ns.db.debug then
    print("|cff6688aaPriceShare debug|r: " .. msg)
  end
end

-- Diagnostic log, kept in the saved data (WTF\...\SavedVariables\PriceShare.lua) so a
-- problem can be looked at after a /reload. Last LOG_MAX lines; nothing is sent anywhere.
local LOG_MAX = 400
function ns.Log(fmt, ...)
  local db = ns.db
  if not db or db.log == false then
    return
  end
  db.logLines = db.logLines or {}
  local ok, text = pcall(string.format, fmt, ...)
  if not ok then
    text = tostring(fmt)
  end
  local lines = db.logLines
  lines[#lines + 1] = date("%m-%d %H:%M:%S ") .. text
  while #lines > LOG_MAX do
    table.remove(lines, 1)
  end
end

-- Runs fn and logs any Lua error instead of losing it (WoW hides errors by default).
local errorsShown = 0
function ns.Guard(where, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      ns.Log("ERROR in %s: %s", where, tostring(err))
      if errorsShown < 3 then
        errorsShown = errorsShown + 1
        print("|cffff4040PriceShare error|r (" .. where .. "): " .. tostring(err))
      end
    end
  end
end

local function Money(c)
  c = math.floor((c or 0) + 0.5)
  local g, s, k = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  local parts = {}
  if g > 0 then
    parts[#parts + 1] = "|cffffd700" .. g .. "g|r"
  end
  if s > 0 then
    parts[#parts + 1] = "|cffc7c7cf" .. s .. "s|r"
  end
  if k > 0 or #parts == 0 then
    parts[#parts + 1] = "|cffeda55f" .. k .. "c|r"
  end
  return table.concat(parts, " ")
end
ns.Money = Money

local function Ago(sec)
  if not sec then
    return "never"
  elseif sec < 90 then
    return "just now"
  elseif sec < 3600 then
    return math.floor(sec / 60 + 0.5) .. " min ago"
  elseif sec < 86400 then
    return math.floor(sec / 3600 + 0.5) .. " h ago"
  end
  local days = math.floor(sec / 86400 + 0.5)
  return days .. (days == 1 and " day ago" or " days ago")
end
ns.Ago = Ago

-- Values the game hides from addons in some situations (instance chat lockdown).
function ns.Unreadable(...)
  local isSecret = _G.issecretvalue
  if not isSecret then
    return false
  end
  for i = 1, select("#", ...) do
    local ok, secret = pcall(isSecret, (select(i, ...)))
    if not ok or secret then
      return true
    end
  end
  return false
end

---------------------------------------------------------------------------
-- Names and realms. Names are kept as "Name-Realm" (on Forever a name can be
-- "First Last"), so the same person always has the same key.
---------------------------------------------------------------------------
local function MyRealm()
  return (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName() or ""):gsub("[%s%-]", "")
end
ns.MyRealm = MyRealm

-- Any spelling of your own realm: "CAMWOWEU4Realm6PvP", the display name, any letter case.
local function Squash(s)
  return (tostring(s or ""):gsub("[%s%-']", ""):lower())
end
-- Realms that share one Auction House. On Forever the clusters share one: checked in game
-- (2026-11-08), CAMWOW EU4 Realm 6, EU4 Realm 8 and EU5 Realm 2 PvP all see the same
-- listings. So "CAMWOWEU4Realm6PvP" and "CAMWOWEU5Realm2PvP" -> "camwoweu|pvp". PvE realms
-- stay apart until someone confirms they share it too. Other names: the realm itself.
function ns.AHGroup(realm)
  local r = Squash(realm)
  local server, kind = r:match("^(%a+)%d*realm%d+(.*)$")
  if server and server ~= "" then
    return server .. "|" .. kind
  end
  return r
end

function ns.IsMyRealm(realm)
  local r = Squash(realm)
  if r == "" then
    return false
  end
  return r == Squash(MyRealm()) or r == Squash(GetRealmName and GetRealmName())
    or ns.AHGroup(r) == ns.AHGroup(MyRealm())
end

-- First word of a name, lower case: "Zakstor Wildroot-Realm" -> "zakstor"
function ns.FirstName(name)
  return type(name) == "string" and (name:match("^(%S+)") or name):gsub("%-.*$", ""):lower() or nil
end

-- "bob", "Bob" and "BOB-Realm" are the same person: names get a capital first
-- letter per word (the game's spelling), realm added when missing.
function ns.Norm(name)
  if type(name) ~= "string" then
    return nil
  end
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then
    return nil
  end
  local base, realm = name:match("^(.-)%-([^%-]+)$")
  if not base or base == "" then
    base, realm = name, MyRealm()
  elseif ns.IsMyRealm(realm) then
    realm = MyRealm()
  end
  base = base:gsub("(%S)(%S*)", function(first, rest)
    return first:upper() .. rest:lower()
  end)
  return base .. "-" .. realm
end

-- Whisper target: plain name on your own realm (how other Forever addons do it).
function ns.WhisperName(name)
  if type(name) ~= "string" then
    return name
  end
  local base, realm = name:match("^(.-)%-([^%-]+)$")
  if base and realm == MyRealm() then
    return base
  end
  return name
end

-- "Name" for people on your realm, "Name-Realm" for others.
function ns.Short(name)
  if type(name) ~= "string" then
    return "?"
  end
  local base, realm = name:match("^(.-)%-([^%-]+)$")
  if base and (realm == MyRealm() or ns.IsMyRealm(realm)) then
    return base
  end
  return name
end

function ns.IsMe(name)
  return name ~= nil and (name == ns.me or name == ns.meShort)
end

-- Your realm or a realm connected to it (same Auction House).
function ns.SameRealmGroup(name)
  local realm = type(name) == "string" and name:match("%-([^%-]+)$")
  if not realm or realm == MyRealm() or ns.IsMyRealm(realm) then
    return true
  end
  local connected = (C_AutoComplete and C_AutoComplete.GetAutoCompleteRealms) or GetAutoCompleteRealms
  if connected then
    for _, r in ipairs(connected() or {}) do
      if r == realm then
        return true
      end
    end
  end
  return false
end

---------------------------------------------------------------------------
-- Markets: your faction's Auction House, or the neutral (goblin) one.
---------------------------------------------------------------------------
-- Stranglethorn Vale (Booty Bay), Tanaris (Gadgetzan), Winterspring (Everlook)
local NEUTRAL_MAPS = { [1434] = true, [1446] = true, [1452] = true }
local NEUTRAL_TOWNS = { ["Booty Bay"] = true, ["Gadgetzan"] = true, ["Everlook"] = true }
ns.MARKET_NAMES = { H = "Horde", A = "Alliance", N = "Neutral (goblin)" }

function ns.HomeMarket()
  return UnitFactionGroup("player") == "Alliance" and "A" or "H"
end

-- Which Auction House you're standing at.
function ns.MarketHere()
  if GetSubZoneText and NEUTRAL_TOWNS[GetSubZoneText() or ""] then
    return "N"
  end
  local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  for _ = 1, 6 do
    if not map then
      break
    end
    if NEUTRAL_MAPS[map] then
      return "N"
    end
    local info = C_Map.GetMapInfo and C_Map.GetMapInfo(map)
    map = info and info.parentMapID
    if map == 0 then
      break
    end
  end
  return ns.HomeMarket()
end

---------------------------------------------------------------------------
-- Saved data
--   PRICESHARE_DB.markets["Realm:H"] = {
--     t = scan time, by = who scanned, n = items,
--     items = { [itemID] = { m = cheapest, s = sale, q = listed, c = when it last changed } },
--     gone = { [itemID] = when it stopped being listed },
--     lin = { scan times this data grew from },
--   }
---------------------------------------------------------------------------
local db

local function InitDB()
  PRICESHARE_DB = PRICESHARE_DB or {}
  db = PRICESHARE_DB
  db.version = 1
  db.markets = db.markets or {}
  db.peers = db.peers or {}
  db.blocked = db.blocked or {}
  db.lastScan = db.lastScan or 0
  if db.autoScan == nil then
    db.autoScan = true
  end
  if db.share == nil then
    db.share = true
  end
  if db.tooltip == nil then
    db.tooltip = true
  end
  if db.chat == nil then
    db.chat = true
  end
  ns.db = db
end

function ns.Store(code, create)
  if not db then
    return nil
  end
  local key = MyRealm() .. ":" .. (code or ns.HomeMarket())
  local store = db.markets[key]
  if not store and create then
    store = { t = 0, n = 0, items = {}, gone = {}, lin = {} }
    db.markets[key] = store
  end
  return store
end

-- Markets on this realm that have data, as codes.
function ns.Markets()
  local out, prefix = {}, MyRealm() .. ":"
  for key, store in pairs(db and db.markets or {}) do
    if key:sub(1, #prefix) == prefix and store.t and store.t > 0 then
      out[#out + 1] = key:sub(#prefix + 1)
    end
  end
  return out
end

-- People who run PriceShare, on this realm: [name] = { seen = time, via = how found }
function ns.Peers()
  local realm = MyRealm()
  db.peers[realm] = db.peers[realm] or {}
  return db.peers[realm]
end

function ns.Lineage(store, t)
  local lin = store.lin
  if lin[#lin] ~= t then
    lin[#lin + 1] = t
  end
  while #lin > LINEAGE_MAX do
    table.remove(lin, 1)
  end
end

function ns.HasLineage(store, t)
  for _, v in ipairs(store.lin) do
    if v == t then
      return true
    end
  end
  return false
end

local callbacks = {}
function ns.Fire(code)
  for _, fn in ipairs(callbacks) do
    pcall(fn, code)
  end
end

local function QtyChanged(a, b)
  a, b = a or 0, b or 0
  return math.abs(a - b) > math.max(2, 0.25 * math.max(a, b))
end

-- Full Scans and search pages round per-item prices a little differently.
local function PriceClose(a, b)
  if not a or not b then
    return a == b
  end
  return math.abs(a - b) <= math.max(1, 0.002 * math.max(a, b))
end

-- A new complete scan. Items whose prices didn't change keep their change time,
-- so friends who already have them only get what changed. kind: "full" or "quick".
function ns.ApplyScan(code, new, t, by, kind)
  local store = ns.Store(code, true)
  local items, gone = store.items, store.gone
  local changed, removed, n = 0, 0, 0
  for id, v in pairs(new) do
    n = n + 1
    local old = items[id]
    if not (old and PriceClose(old.m, v.m) and PriceClose(old.s, v.s) and not QtyChanged(old.q, v.q)) then
      items[id] = { m = v.m, s = v.s, q = v.q, c = t }
      changed = changed + 1
    end
    gone[id] = nil
  end
  for id in pairs(items) do
    if not new[id] then
      items[id] = nil
      gone[id] = t
      removed = removed + 1
    end
  end
  for id, r in pairs(gone) do
    if t - r > GONE_KEEP then
      gone[id] = nil
    end
  end
  store.t, store.by, store.n, store.kind = t, by, n, kind or "full"
  ns.Lineage(store, t)
  ns.Fire(code)
  return changed, removed, n
end

function ns.KindText(store)
  return (store and store.kind == "quick") and "Quick Scan" or "Full Scan"
end

---------------------------------------------------------------------------
-- Reading a Full Scan
---------------------------------------------------------------------------
local scan = { awaiting = false, gen = 0 }
local ahOpen = false
local deadline = 0

local function Checkpoint()
  if debugprofilestop() > deadline then
    coroutine.yield()
  end
end

local function Summarize(list)
  table.sort(list, function(a, b)
    return a[1] < b[1]
  end)
  local total = 0
  for _, l in ipairs(list) do
    total = total + l[2]
  end
  local target = math.max(1, math.min(SALE_MAX, math.ceil(total * SALE_SHARE)))
  local acc, sale = 0, list[#list][1]
  for _, l in ipairs(list) do
    acc = acc + l[2]
    if acc >= target then
      sale = l[1]
      break
    end
  end
  local m = math.max(1, math.floor(list[1][1] + 0.5))
  return m, math.max(m, math.floor(sale + 0.5)), total
end

local function Process(count, gen, code)
  local lists = {}
  for index = 0, count - 1 do
    local _, _, quantity, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID =
      C_AuctionHouse.GetReplicateItemInfo(index)
    if itemID and quantity and quantity > 0 and buyout and buyout > 0 then
      local list = lists[itemID]
      if not list then
        list = {}
        lists[itemID] = list
      end
      list[#list + 1] = { buyout / quantity, quantity }
    end
    if index % 200 == 0 then
      Checkpoint()
      if gen ~= scan.gen then
        return
      end
    end
  end
  local new, i = {}, 0
  for itemID, list in pairs(lists) do
    local m, s, q = Summarize(list)
    new[itemID] = { m = m, s = s, q = q }
    i = i + 1
    if i % 100 == 0 then
      Checkpoint()
      if gen ~= scan.gen then
        return
      end
    end
  end
  if i == 0 then
    Print("The Full Scan came back empty, nothing saved.")
    return
  end
  local changed, removed, n = ns.ApplyScan(code, new, Now(), ns.me, "full")
  if db.chat then
    Print(string.format("Full Scan: %d items at the %s AH (%d changed, %d no longer listed).", n,
      ns.MARKET_NAMES[code] or code, changed, removed))
  end
  if ns.Sync then
    ns.Sync.OnScan(code)
  end
end

local function OnReplicateRequested()
  if not db then
    return
  end
  -- A scan already being read keeps going: another addon asking inside the server's 15 minute
  -- cooldown gets no new data, and dropping ours lost the whole scan. If new data does come,
  -- OnReplicateReady starts over with it. The cooldown clock (db.lastScan) isn't reset either.
  if scan.worker then
    scan.awaiting = true
    scan.market = ahOpen and ns.ahMarket or ns.MarketHere()
    local gen = scan.gen
    C_Timer.After(SCAN_TIMEOUT, function()
      if scan.awaiting and scan.gen == gen then
        scan.awaiting = false
      end
    end)
    return
  end
  db.lastScan = time()
  scan.awaiting = true
  scan.gen = scan.gen + 1
  scan.worker = nil
  scan.market = ahOpen and ns.ahMarket or ns.MarketHere()
  local gen = scan.gen
  C_Timer.After(SCAN_TIMEOUT, function()
    if scan.awaiting and scan.gen == gen then
      scan.awaiting = false
      ns.Debug("no Full Scan data came back (server cooldown still running?)")
    end
  end)
end

local function OnReplicateReady()
  if not scan.awaiting then
    return
  end
  scan.awaiting = false
  local count = C_AuctionHouse.GetNumReplicateItems() or 0
  if count == 0 then
    return
  end
  scan.gen = scan.gen + 1
  local gen, code = scan.gen, scan.market or ns.HomeMarket()
  scan.worker = coroutine.create(function()
    Process(count, gen, code)
  end)
end

local function ScanBusy()
  return scan.awaiting or scan.worker ~= nil
end
ns.FullScanBusy = ScanBusy

function ns.AHOpen()
  return ahOpen
end

-- seconds until this client may Full Scan again (0 = now)
function ns.ScanWait()
  local elapsed = time() - (db and db.lastScan or 0)
  if elapsed < 0 or elapsed >= SCAN_COOLDOWN then
    return 0
  end
  return SCAN_COOLDOWN - elapsed
end

local function StartScan(manual, tries)
  if not ahOpen then
    if manual then
      Print("Open the Auction House first.")
    end
    return
  end
  if ScanBusy() or (ns.Quick and ns.Quick.Busy()) then
    if manual then
      Print("A scan is already running.")
    end
    return
  end
  local wait = ns.ScanWait()
  if wait > 0 then
    if manual then
      Print(string.format("This client did a Full Scan %s. The next one is allowed in ~%d min.",
        Ago(SCAN_COOLDOWN - wait), math.ceil(wait / 60)))
    end
    return
  end
  if not C_AuctionHouse.IsThrottledMessageSystemReady() then
    tries = (tries or 0) + 1
    if tries <= AUTO_TRIES then
      C_Timer.After(1, function()
        StartScan(manual, tries)
      end)
    elseif manual then
      Print("The Auction House is busy, try again in a moment.")
    end
    return
  end
  if db.chat then
    Print("Full Scan started (asking the server for every auction)...")
  end
  C_AuctionHouse.ReplicateItems() -- our hook marks the scan as requested
end
ns.StartFullScan = StartScan

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------
local function FreshStore(code)
  local store = ns.Store(code or ns.HomeMarket())
  if store and store.t and store.t > 0 and Now() - store.t < FRESH then
    return store
  end
end

-- How many you have: bags and bank (the bank only counts once you've opened it), or bags only.
local function ItemCount(id, bagsOnly)
  local get = (C_Item and C_Item.GetItemCount) or GetItemCount
  if not get then
    return 0
  end
  local ok, n = pcall(get, id, not bagsOnly)
  return (ok and tonumber(n)) or 0
end

local function AddTooltip(tooltip, link)
  if not db or not db.tooltip or type(link) ~= "string" then
    return
  end
  local id = tonumber(link:match("item:(%d+)"))
  local store = id and FreshStore()
  if not store then
    return
  end
  local e = store.items[id]
  local label = "AH (PriceShare)"
  if e then
    local text = Money(e.m) .. " each"
    if e.s and e.s > e.m then
      text = text .. " |cffaaaaaa(sells ~" .. Money(e.s) .. ")|r"
    end
    tooltip:AddDoubleLine(label, text, 0.4, 0.8, 1, 1, 1, 1)
    -- what everything you have of it is worth
    local count = ItemCount(id)
    if count > 1 then
      local bags = ItemCount(id, true)
      local where = count > bags and string.format(" (%d in bank)", count - bags) or ""
      tooltip:AddDoubleLine(string.format("   Your %d%s", count, where), Money(e.m * count), 0.6, 0.6, 0.6, 1, 1, 1)
    end
    if IsShiftKeyDown() then
      tooltip:AddLine(string.format("   %d listed. %s %s by %s.", e.q or 0, ns.KindText(store), Ago(Now() - store.t),
        ns.IsMe(store.by) and "you" or ns.Short(store.by)), 0.6, 0.6, 0.6, true)
    end
  elseif store.gone[id] then
    tooltip:AddDoubleLine(label, "none listed", 0.4, 0.8, 1, 0.6, 0.6, 0.6)
  end
end

local function HookTooltips()
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
      if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then
        return
      end
      local _, link = tooltip:GetItem()
      AddTooltip(tooltip, link)
    end)
  elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
      local _, link = tooltip:GetItem()
      AddTooltip(tooltip, link)
    end)
  end
end

---------------------------------------------------------------------------
-- Update reminders: once a friend runs a newer PriceShare, a colored chat reminder
-- every 5 minutes (held back while you're in combat) with a sound, until you update.
-- The sound is picked on the minimap button's right-click menu or with /ps sound.
---------------------------------------------------------------------------
local REMIND_EVERY = 5 * 60
local REMIND_AFTER_LOGIN = 20 -- seconds, for an update already known from earlier sessions

-- Voice lines from Warcraft III that the game ships (file IDs from its file list).
-- One the game doesn't have (the Fel Reaver before The Burning Crusade) falls back to
-- the raid warning sound.
ns.SOUNDS = {
  { key = "workwork", label = "Peon: \"Work work.\"", file = 558147 },
  { key = "busy", label = "Peon: \"Me busy. Leave me alone!\"", file = 558144 },
  { key = "whaaat", label = "Peon: \"Whaaat?\"", file = 558133 },
  { key = "ready", label = "Peon: \"Ready to work.\"", file = 558137 },
  { key = "what", label = "Peasant: \"What?\"", file = 558120 },
  { key = "doh", label = "Peasant: \"D'oh!\"", file = 558122 },
  { key = "felreaver", label = "Fel Reaver roar (if your game has it)", file = 594958 },
  { key = "raidwarning", label = "Raid warning", kit = "RAID_WARNING", kitID = 8959 },
  { key = "off", label = "No sound" },
}
local DEFAULT_SOUND = "workwork"

local function SoundChoice(key)
  for _, s in ipairs(ns.SOUNDS) do
    if s.key == key then
      return s
    end
  end
end

-- Plays a sound from the list (the chosen one by default). Returns false for "No sound".
function ns.PlayReminderSound(key)
  local s = SoundChoice(key or (db and db.remindSound) or DEFAULT_SOUND) or SoundChoice(DEFAULT_SOUND)
  if s.key == "off" then
    return false
  end
  if s.file and PlaySoundFile then
    local ok, willPlay = pcall(PlaySoundFile, s.file, "Master")
    if ok and willPlay then
      return true
    end
  end
  local kit = (SOUNDKIT and SOUNDKIT[s.kit or "RAID_WARNING"]) or s.kitID or 8959
  if PlaySound then
    pcall(PlaySound, kit, "Master")
  end
  return true
end

function ns.SetReminderSound(key)
  local s = SoundChoice(key)
  if not s or not db then
    return false
  end
  db.remindSound = s.key
  ns.PlayReminderSound(s.key) -- so you hear what you picked
  return true
end

function ns.ReminderSoundLabel()
  local s = SoundChoice(db and db.remindSound or DEFAULT_SOUND) or SoundChoice(DEFAULT_SOUND)
  return s.label
end

local newest      -- { version, who }: the newest PriceShare a friend runs, when newer than yours
local remindTicker
local remindWaiting -- a reminder held back until combat ends
local lastReminded = -REMIND_EVERY

local function Remind(preview)
  if not newest and not preview then
    return
  end
  if InCombatLockdown and InCombatLockdown() and not preview then
    remindWaiting = true
    return
  end
  remindWaiting = false
  if not preview then
    lastReminded = GetTime()
  end
  local version = newest and newest.version or "?"
  local who = newest and newest.who and ns.Short(newest.who) or "a friend"
  local news = (newest and newest.relayed)
    and string.format("PriceShare |cff40ff40%s|r is out (word from %s)", version, who)
    or string.format("%s runs PriceShare |cff40ff40%s|r", who, version)
  print(string.format("|cff66ccffPriceShare|r: |cffff8000Update available!|r %s, you have |cffff4040%s|r. " ..
    "Until you update, you may miss your friends' newest prices.", news, ns.VERSION))
  print("   |cffffd040How to update:|r double-click |cffffffffUpdate-PriceShare.bat|r in |cffffffff" ..
    "World of Warcraft\\_forever_\\Interface\\AddOns\\PriceShare|r (it downloads the new version), then |cffffffffrestart WoW|r. " ..
    "|cff999999(Reminds you every 5 minutes. Sound: minimap button, right-click.)|r")
  ns.PlayReminderSound()
end

-- A version number as PriceShare writes them ("1.6", "1.6.1"): anything else is ignored.
function ns.ValidVersion(v)
  return type(v) == "string" and #v <= 12 and v:match("^%d+%.%d+[%.%d]*$") ~= nil and not v:find("%.%.") and
    v:sub(-1) ~= "."
end

-- News of a newer version, passed on in every hello (so it spreads through friends who
-- haven't updated yet), and kept over logins: { v = version, via = who told you,
-- t = when anyone last actually saw someone running it }. Passing the news on doesn't
-- renew t, only seeing it run does, so it's dropped RELAY_KEEP after that (a typo'd or
-- test version can't nag everyone forever), or once you have that version.
local RELAY_KEEP = 14 * 86400

local function Heard()
  local h = db and db.heardVersion
  if type(h) ~= "table" or not ns.ValidVersion(h.v) or not ns.VersionNewer(h.v, ns.VERSION)
      or ns.Now() - (tonumber(h.t) or 0) > RELAY_KEEP then
    if db then
      db.heardVersion = nil
    end
    return nil
  end
  return h
end

-- The newest PriceShare version you've heard of when it's newer than yours, and when
-- someone was last seen running it (server time); nil when there's none.
function ns.NewestHeard()
  local h = Heard()
  if h then
    return h.v, tonumber(h.t)
  end
end
ns.RELAY_KEEP = RELAY_KEEP

-- A friend runs version (relayed: a friend heard of it), seen live or saved earlier.
-- seenAt: when someone was seen running it (now for a friend who runs it).
function ns.NoteNewerVersion(version, who, quietly, relayed, seenAt)
  if not ns.ValidVersion(version) or not ns.VersionNewer(version, ns.VERSION) then
    return
  end
  seenAt = math.min(tonumber(seenAt) or ns.Now(), ns.Now())
  if ns.Now() - seenAt > RELAY_KEEP then
    return -- old news
  end
  local h = Heard()
  if not h or ns.VersionNewer(version, h.v) then
    db.heardVersion = { v = version, via = who, t = seenAt }
  elseif version == h.v and seenAt > (tonumber(h.t) or 0) then
    h.t = seenAt -- seen running more recently
    if not relayed then
      h.via = who
    end
  end
  if newest and not ns.VersionNewer(version, newest.version) then
    if version == newest.version and newest.relayed and not relayed then
      newest.who, newest.relayed = who, nil -- now seen from someone who runs it
    end
    return
  end
  local first = newest == nil
  newest = { version = version, who = who, relayed = relayed or nil }
  ns.Log("newer PriceShare %s %s %s", tostring(version), relayed and "heard of via" or "run by", tostring(who))
  if first then
    if not quietly then
      Remind()
    end
    if not remindTicker then
      -- checked every minute, shown 5 minutes after the last one (a reminder held back
      -- by combat and shown afterwards restarts the 5 minutes)
      remindTicker = C_Timer.NewTicker(60, ns.Guard("update reminder", function()
        if GetTime() - lastReminded >= REMIND_EVERY - 1 then
          Remind()
        end
      end))
    end
  end
end

-- The newest version any linked friend ran last time you saw them, or that you heard of.
local function CheckSavedVersions()
  local best, by, at
  for name, p in pairs(ns.Peers()) do
    if type(p) == "table" and ns.ValidVersion(p.version) and ns.VersionNewer(p.version, ns.VERSION)
        and (not best or ns.VersionNewer(p.version, best)) then
      best, by, at = p.version, name, p.seen
    end
  end
  local h = Heard()
  if h and (not best or ns.VersionNewer(h.v, best)) then
    ns.NoteNewerVersion(h.v, h.via, false, true, h.t)
  elseif best then
    ns.NoteNewerVersion(best, by, false, false, at)
  end
end

---------------------------------------------------------------------------
-- For other addons (VendorSnipe reads this when a friend's scan is newer than yours)
---------------------------------------------------------------------------
PriceShare = {
  -- cheapest, sale price, units listed for an item, or nil (not listed / no fresh scan)
  GetPrices = function(itemID, code)
    local store = FreshStore(code)
    local e = store and store.items[itemID]
    if e then
      return e.m, e.s or e.m, e.q or 0
    end
  end,
  GetMin = function(itemID, code)
    local store = FreshStore(code)
    local e = store and store.items[itemID]
    return e and e.m
  end,
  GetSale = function(itemID, code)
    local store = FreshStore(code)
    local e = store and store.items[itemID]
    return e and (e.s or e.m)
  end,
  -- seconds since the newest scan you have (yours or a friend's), or nil
  GetAge = function(code)
    local store = ns.Store(code)
    if store and store.t and store.t > 0 then
      return Now() - store.t
    end
  end,
  -- scan time (server time), who scanned, items
  GetScanInfo = function(code)
    local store = ns.Store(code)
    if store and store.t and store.t > 0 then
      return store.t, ns.IsMe(store.by) and "you" or ns.Short(store.by), store.n
    end
  end,
  -- fn(marketCode) is called after every new scan, yours or a friend's
  RegisterCallback = function(fn)
    callbacks[#callbacks + 1] = fn
  end,
  HomeMarket = function()
    return ns.HomeMarket()
  end,
}

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function OnOff(arg, current)
  if arg == "on" then
    return true
  elseif arg == "off" then
    return false
  end
  return not current
end

local function Status()
  local any = false
  for _, code in ipairs(ns.Markets()) do
    local store = ns.Store(code)
    any = true
    print(string.format("   %s AH: %d items, %s %s by %s.%s", ns.MARKET_NAMES[code] or code, store.n or 0,
      ns.KindText(store), Ago(Now() - store.t), ns.IsMe(store.by) and "you" or ns.Short(store.by),
      Now() - store.t >= FRESH and " |cffff8040(too old to use)|r" or ""))
  end
  if not any then
    print("   No prices yet. Open the Auction House to scan, or wait for a friend's scan.")
  end
  local wait = ns.ScanWait()
  print(string.format("   Auto-scan when you open the AH: %s. %s", db.autoScan and "on" or "off",
    wait > 0 and string.format("Next Full Scan allowed in ~%d min.", math.ceil(wait / 60)) or "A Full Scan is allowed now."))
  if ns.Sync then
    print("   " .. ns.Sync.StatusLine())
  end
end

local function Help()
  print("|cff66ccffPriceShare|r commands (/ps or /priceshare):")
  print("   /ps - status")
  print("   /ps find [name] - price lookup window (also the minimap button, or a key in Key Bindings)")
  print("   /ps minimap - show or hide the minimap button")
  print("   /ps sound [number] - the update reminder's sound (also on the minimap button, right-click)")
  print("   /ps remind - show the update reminder now")
  print("   /ps scan - Full Scan now (Auction House open, once per 15 min)")
  print("   /ps quick - Quick Scan: goes through every search page, no 15 min wait")
  print("   /ps auto on|off - Full Scan when you open the AH")
  print("   /ps friends - who runs PriceShare")
  print("   /ps sync - ask friends for newer prices now")
  print("   /ps add Name - add someone who isn't in your guild or friends list (both of you)")
  print("   /ps check - why someone isn't linked: what PriceShare sees")
  print("   /ps ping Name - test PriceShare with one online person")
  print("   /ps remove Name / block Name / unblock Name")
  print("   /ps share on|off - send and receive prices")
  print("   /ps tooltip on|off, /ps chat on|off")
end

SLASH_PRICESHARE1 = "/priceshare"
SLASH_PRICESHARE2 = "/ps"
SlashCmdList.PRICESHARE = function(msg)
  if not db then
    return
  end
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  local arg = rest:lower()
  if cmd == "" or cmd == "status" then
    Print("status (version " .. ns.VERSION .. ")")
    Status()
  elseif cmd == "find" or cmd == "lookup" or cmd == "price" then
    if ns.Lookup then
      ns.Lookup.Open(rest ~= "" and rest or nil)
    end
  elseif cmd == "sound" then
    local pick = tonumber(arg) and ns.SOUNDS[tonumber(arg)] or SoundChoice(arg)
    if pick then
      ns.SetReminderSound(pick.key)
      Print("Update reminder sound: " .. pick.label .. ".")
    else
      Print("Update reminder sound: " .. ns.ReminderSoundLabel() .. ". To change it (or the minimap button, right-click):")
      for i, s in ipairs(ns.SOUNDS) do
        print(string.format("   /ps sound %d - %s", i, s.label))
      end
    end
  elseif cmd == "remind" then
    if newest then
      Remind()
    else
      Print("You have the newest PriceShare your friends run (" .. ns.VERSION .. "). This is what the reminder looks like:")
      Remind(true)
    end
  elseif cmd == "minimap" then
    if ns.Lookup then
      ns.Lookup.SetMinimapShown(db.minimapHidden == true)
      Print("Minimap button: " .. (db.minimapHidden and "hidden (/ps minimap brings it back)" or "shown") .. ".")
    end
  elseif cmd == "scan" then
    StartScan(true)
  elseif cmd == "quick" then
    if ns.Quick then
      ns.Quick.Start()
    end
  elseif cmd == "auto" then
    db.autoScan = OnOff(arg, db.autoScan)
    Print("Auto-scan when you open the Auction House: " .. (db.autoScan and "on" or "off") .. ".")
  elseif cmd == "tooltip" then
    db.tooltip = OnOff(arg, db.tooltip)
    Print("Tooltip line: " .. (db.tooltip and "on" or "off") .. ".")
  elseif cmd == "chat" then
    db.chat = OnOff(arg, db.chat)
    Print("Chat messages about scans and syncs: " .. (db.chat and "on" or "off") .. ".")
  elseif cmd == "debug" then
    db.debug = OnOff(arg, db.debug)
    Print("Debug messages: " .. (db.debug and "on" or "off") .. ".")
  elseif cmd == "log" then
    if arg == "clear" then
      db.logLines = {}
      Print("Log cleared.")
    elseif arg == "on" or arg == "off" then
      db.log = arg == "on"
      Print("Diagnostic log: " .. arg .. ".")
    else
      local lines = db.logLines or {}
      Print(string.format("last lines of the diagnostic log (%d kept; saved to the PriceShare file in " ..
        "WTF\\Account\\...\\SavedVariables on /reload or logout):", #lines))
      for i = math.max(1, #lines - 14), #lines do
        print("   " .. lines[i])
      end
    end
  elseif cmd == "share" then
    db.share = OnOff(arg, db.share)
    Print("Sharing prices with friends: " .. (db.share and "on" or "off") .. ".")
    if db.share and ns.Sync then
      ns.Sync.Announce(true, true)
    end
  elseif ns.Sync and ns.Sync.Command(cmd, rest) then
    return
  else
    Help()
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("AUCTION_HOUSE_SHOW")
events:RegisterEvent("AUCTION_HOUSE_CLOSED")
events:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
events:RegisterEvent("PLAYER_REGEN_ENABLED")

events:SetScript("OnUpdate", ns.Guard("scan reading", function()
  if not scan.worker then
    return
  end
  deadline = debugprofilestop() + WORK_MS
  local ok, err = coroutine.resume(scan.worker)
  if not ok then
    scan.worker = nil
    Print("Reading the Full Scan failed: " .. tostring(err))
  elseif coroutine.status(scan.worker) == "dead" then
    scan.worker = nil
  end
end))

events:SetScript("OnEvent", ns.Guard("core events", function(_, event, ...)
  if event == "ADDON_LOADED" then
    if ... == "PriceShare" then
      InitDB()
      hooksecurefunc(C_AuctionHouse, "ReplicateItems", OnReplicateRequested)
      HookTooltips()
    end
  elseif event == "PLAYER_LOGIN" then
    local name = (GetUnitName and GetUnitName("player", true)) or UnitName("player")
    ns.me = ns.Norm(name)
    ns.meShort = ns.Norm(UnitName("player"))
    ns.Log("=== login: PriceShare %s, me=%s (GetUnitName=%s, UnitName=%s), realm=%s (GetRealmName=%s), faction=%s, guild=%s",
      ns.VERSION, tostring(ns.me), tostring(name), tostring(UnitName("player")), MyRealm(), tostring(GetRealmName()),
      tostring(UnitFactionGroup("player")), tostring(IsInGuild and IsInGuild()))
    if ns.Sync then
      ns.Sync.Start()
    end
    C_Timer.After(REMIND_AFTER_LOGIN, ns.Guard("saved versions", CheckSavedVersions))
  elseif event == "PLAYER_REGEN_ENABLED" then
    if remindWaiting then
      C_Timer.After(2, function()
        Remind()
      end)
    end
  elseif event == "AUCTION_HOUSE_SHOW" then
    ahOpen = true
    ns.ahMarket = ns.MarketHere()
    if db.autoScan then
      C_Timer.After(AUTO_DELAY, function()
        StartScan(false)
      end)
    end
    if ns.Sync then
      ns.Sync.OnAHOpen()
    end
  elseif event == "AUCTION_HOUSE_CLOSED" then
    ahOpen = false
    if scan.worker then
      scan.worker = nil
      scan.gen = scan.gen + 1
      Print("Full Scan cancelled: the Auction House closed before it was read.")
    end
    scan.awaiting = false
  elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
    OnReplicateReady()
  end
end))
