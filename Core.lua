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

-- This copy's version (from PriceShare.toc), told to friends so older copies know to update.
local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.VERSION = (getMeta and getMeta("PriceShare", "Version")) or "1.0"
ns.UPDATE_HOW = "double-click Update-PriceShare.bat in Interface\\AddOns\\PriceShare, then /reload"

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
  return math.floor(sec / 86400 + 0.5) .. " days ago"
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

function ns.Norm(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  if not name:find("-", 1, true) then
    return name .. "-" .. MyRealm()
  end
  return name
end

-- "Name" for people on your realm, "Name-Realm" for others.
function ns.Short(name)
  if type(name) ~= "string" then
    return "?"
  end
  local base, realm = name:match("^(.-)%-([^%-]+)$")
  if base and realm == MyRealm() then
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
  if not realm or realm == MyRealm() then
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

events:SetScript("OnUpdate", function()
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
end)

events:SetScript("OnEvent", function(_, event, ...)
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
    if ns.Sync then
      ns.Sync.Start()
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
end)
