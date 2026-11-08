-- PriceShare sync: finds friends who run PriceShare and passes the newest scan around.
--
-- Finding each other (automatic):
--   * a hello goes to your guild, your group, your online friends and Battle.net
--     friends on this realm and faction, and people who ran PriceShare with you before;
--   * whoever answers with PriceShare is added, and tells you about the other
--     PriceShare users they know (friends of friends);
--   * friends who don't run it never see anything (addon messages are invisible).
-- On Forever, addon messages over custom chat channels don't arrive, so everything
-- goes by whisper (or guild/group chat for hellos).
--
-- Sharing: a hello says "I have a scan from time T". Anyone with older data asks
-- one person who has the newest scan; they get only the items that changed since
-- the scan they already have (or everything, the first time). The newest scan wins.
--
-- Messages (fields split by "^", numbers in base 36):
--   H^1^market^scanTime^items^q^scannedBy   hello ("q" = please answer)
--   P^name^name...                          other PriceShare users I know
--   R^market^haveTime                       please send me what's newer than haveTime
--   B^market                                busy, ask someone else
--   S^market^time^d|f^entries^messages^by^f|q   start of data (d = changes only, f = everything;
--                                           last field: from a Full or Quick Scan)
--   D^market^time^seq^entries               data: id,min,sale-min,listed,time-changed;...  ~id,time-gone
--   E^market^time^messages                  end of data
--   M^market^time^seq,seq...                these didn't arrive, please send them again

local _, ns = ...
local Sync = {}
ns.Sync = Sync

local PREFIX = "PriceShare1"
local PROTO = "1"
local MAX_MSG = 250
local LOGIN_DELAY = 10      -- seconds after login before saying hello
local CHOOSE_WAIT = 4       -- seconds to collect hellos before choosing who to ask
local STREAM_TIMEOUT = 45   -- seconds without data before giving up on a transfer
local MAX_STREAMS = 3       -- transfers we send at the same time
local MAX_RESENDS = 3       -- times we ask again for lost messages before starting over
local RESEND_KEEP = 900     -- seconds a sent transfer is kept for re-sending lost messages
local PING_EVERY = 10 * 60  -- hello the same person at most this often
local AH_HELLO_EVERY = 10 * 60
local PEER_KEEP = 30 * 86400
local ERR_WINDOW = 300      -- "No player named X" can arrive ~2 minutes after an addon whisper
local SEND_MIN, SEND_MAX = 0.35, 3
local THROTTLE_PAUSE = 1.5
local LOCKDOWN_PAUSE = 30
local MARKETS = { H = true, A = true, N = true }

local RES = (Enum and Enum.SendAddonMessageResult) or {}
local RES_THROTTLE = RES.AddonMessageThrottle or 3
local RES_LOCKDOWN = RES.AddOnMessageLockdown or 11
local RES_OFFLINE = RES.TargetOffline or 12
local RES_UNSUPPORTED = {
  [RES.InvalidPrefix or -1] = true,
  [RES.InvalidChatType or -2] = true,
  [RES.InvalidChannel or -3] = true,
}

---------------------------------------------------------------------------
-- State (this session only, except ns.Peers())
---------------------------------------------------------------------------
local online = {}      -- [name] = GetTime() last heard from
local offline = {}     -- [name] = true after a whisper to them failed
local known = {}       -- [market][name] = { t = their scan time, n = items }
local pinged = {}      -- [name] = GetTime() of our last hello whisper
local whispered = {}   -- [name] = GetTime() of our last whisper
local replied = {}     -- [name] = GetTime() we last answered their hello
local gossiped = {}    -- [name] = true once we told them who else runs it
local introduced = {}  -- [name] = who told us about them
local failed = {}      -- [name] = GetTime() until which we don't ask them for data
local versionNoted = {}
local social = {}      -- [name] = "friend" / "bnet" / "guild" (last check)
local lastSweep = -100
local lastAHHello = -1000
local req = {}         -- [market] = the transfer we're receiving
local choosing = {}    -- [market] = true while waiting to choose a source
local streams = {}     -- transfers we're sending: { target, msgs, i, market }
local lastBuilt = {}   -- [name] = the last transfer built for them, for re-sending lost parts
local control = {}     -- small messages, sent before transfer data
local nextSend, interval, rr = 0, SEND_MIN, 1
local disabledChat = {}
local stats = { sent = 0, got = 0 }
-- for /ps check
local bnetSeen = {}    -- Battle.net friends in WoW at the last check: { name, why not used }
local heard = {}       -- [name] = { n = messages, last = GetTime(), channel, ignored = true/nil }
local results = {}     -- [send result code] = count
local pingWatch = {}   -- [name] = GetTime() of a /ps ping

local function DB()
  return ns.db
end

---------------------------------------------------------------------------
-- Numbers <-> base 36
---------------------------------------------------------------------------
local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

local function E36(n)
  n = math.floor(n or 0)
  if n <= 0 then
    return "0"
  end
  local t = {}
  while n > 0 do
    local d = n % 36
    t[#t + 1] = DIGITS:sub(d + 1, d + 1)
    n = math.floor(n / 36)
  end
  return string.reverse(table.concat(t))
end

local function D36(s)
  if not s or s == "" then
    return 0
  end
  return tonumber(s, 36) or 0
end

local function Split(text)
  local f = {}
  for part in (text .. "^"):gmatch("([^%^]*)%^") do
    f[#f + 1] = part
  end
  return f
end

---------------------------------------------------------------------------
-- Sending: a small queue, paced so the server's limits aren't hit
---------------------------------------------------------------------------
local function Queue(msg, chat, target)
  if not DB().share or disabledChat[chat] then
    return
  end
  if chat == "WHISPER" and (not target or offline[target]) then
    return
  end
  control[#control + 1] = { msg = msg, chat = chat, target = target }
end

local function DropStreamsTo(name)
  for i = #streams, 1, -1 do
    if streams[i].target == name then
      table.remove(streams, i)
    end
  end
end

function Sync.MarkOffline(name)
  if not name then
    return
  end
  offline[name] = true
  online[name] = nil
  DropStreamsTo(name)
  for i = #control, 1, -1 do
    if control[i].target == name then
      table.remove(control, i)
    end
  end
  for code, r in pairs(req) do
    if r.from == name then
      req[code] = nil
      Sync.Want(code)
    end
  end
end

local function SendNow(item)
  local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, item.msg, item.chat, item.target)
  if not ok then
    ns.Debug("send failed: " .. tostring(res))
    return nil
  end
  if item.chat == "WHISPER" then
    whispered[item.target] = GetTime()
  end
  stats.sent = stats.sent + 1
  return res
end

local function Pump()
  local t = GetTime()
  if t < nextSend then
    return
  end
  local item, stream
  if #control > 0 then
    item = table.remove(control, 1)
  elseif #streams > 0 then
    if rr > #streams then
      rr = 1
    end
    stream = streams[rr]
    item = { msg = stream.msgs[stream.i], chat = "WHISPER", target = stream.target }
  else
    return
  end
  local res = SendNow(item)
  local code = res == nil and "error" or tostring(res)
  results[code] = (results[code] or 0) + 1
  if item.target and pingWatch[item.target] and type(res) == "number" and res ~= (RES.Success or 0) then
    ns.Print(string.format("ping to %s: the game refused it (code %s%s).", ns.Short(item.target), code,
      res == RES_OFFLINE and ", they're offline or the name is wrong" or ""))
  end
  if res == RES_THROTTLE then
    if not stream then
      table.insert(control, 1, item)
    end
    interval = math.min(SEND_MAX, interval * 1.5)
    nextSend = t + THROTTLE_PAUSE
    return
  end
  nextSend = t + interval
  interval = math.max(SEND_MIN, interval * 0.97)
  if res == RES_OFFLINE and item.target then
    Sync.MarkOffline(item.target)
    return
  elseif res == RES_LOCKDOWN then
    nextSend = t + LOCKDOWN_PAUSE -- in an instance: try again later (transfers wait, hellos are dropped)
    return
  elseif RES_UNSUPPORTED[res] and item.chat ~= "WHISPER" then
    disabledChat[item.chat] = true
  end
  if stream then
    stream.i = stream.i + 1
    if stream.i > #stream.msgs then
      for i, s in ipairs(streams) do
        if s == stream then
          table.remove(streams, i)
          break
        end
      end
    else
      rr = rr + 1
    end
  end
end

---------------------------------------------------------------------------
-- Who's who
---------------------------------------------------------------------------
-- Online friends, Battle.net friends on this realm and faction, guild members.
-- Returns the online ones who can be whispered (guild gets one broadcast instead).
local function Sweep()
  lastSweep = GetTime()
  wipe(social)
  local whisper = {}
  if C_FriendList and C_FriendList.GetNumFriends then
    for i = 1, (C_FriendList.GetNumFriends() or 0) do
      local info = C_FriendList.GetFriendInfoByIndex(i)
      local name = info and ns.Norm(info.name)
      if name and not ns.Unreadable(name) then
        social[name] = "friend"
        if info.connected then
          whisper[name] = true
        end
      end
    end
  end
  local numBN = BNGetNumFriends and BNGetNumFriends() or 0
  local getBN = C_BattleNet and C_BattleNet.GetFriendAccountInfo
  wipe(bnetSeen)
  for i = 1, (getBN and numBN or 0) do
    local acc = getBN(i)
    local g = acc and acc.gameAccountInfo
    if g and g.isOnline and g.clientProgram == (BNET_CLIENT_WOW or "WoW") and g.characterName and g.characterName ~= "" then
      local realm = g.realmName and (g.realmName:gsub("[%s%-]", "")) or ""
      local name = ns.Norm(g.characterName:find("-", 1, true) and g.characterName
        or (realm ~= "" and (g.characterName .. "-" .. realm) or g.characterName))
      local why
      if WOW_PROJECT_ID and g.wowProjectID and g.wowProjectID ~= WOW_PROJECT_ID then
        why = "plays another WoW version"
      elseif g.factionName and g.factionName ~= UnitFactionGroup("player") then
        why = "other faction (" .. tostring(g.factionName) .. ")"
      elseif not name or not ns.SameRealmGroup(name) then
        why = "other realm (" .. tostring(g.realmName) .. ")"
      end
      bnetSeen[#bnetSeen + 1] = { name = name or g.characterName, why = why }
      if not why then
        social[name] = "bnet"
        whisper[name] = true
      end
    end
  end
  if IsInGuild and IsInGuild() and GetNumGuildMembers then
    for i = 1, (GetNumGuildMembers() or 0) do
      local name = ns.Norm((GetGuildRosterInfo(i)))
      if name and not ns.Unreadable(name) then
        social[name] = social[name] or "guild"
      end
    end
  end
  return whisper
end

local function InGroupWith(name)
  local short = ns.Short(name)
  return (UnitInParty and UnitInParty(short)) or (UnitInRaid and UnitInRaid(short)) or false
end

local function Trusted(who, channel)
  if DB().blocked[who] then
    return false
  end
  if channel == "GUILD" or channel == "PARTY" or channel == "RAID" or channel == "INSTANCE_CHAT" then
    return true
  end
  if ns.Peers()[who] or introduced[who] then
    return true
  end
  if not social[who] and GetTime() - lastSweep > 5 then
    Sweep() -- they may have come online since the last check
  end
  return social[who] ~= nil or InGroupWith(who)
end

local function Touch(who, channel)
  online[who] = GetTime()
  offline[who] = nil
  local peers = ns.Peers()
  local p = peers[who]
  if not p then
    p = { via = social[who] or (introduced[who] and "friend of " .. ns.Short(introduced[who])) or (channel or ""):lower() }
    peers[who] = p
    if DB().chat then
      ns.Print(ns.Short(who) .. " runs PriceShare too: sharing prices with them.")
    end
  end
  p.seen = ns.Now()
end

local function OnlinePeers(except)
  local out = {}
  for name in pairs(ns.Peers()) do
    if online[name] and not offline[name] and name ~= except and not DB().blocked[name] then
      out[#out + 1] = name
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Hellos
---------------------------------------------------------------------------
local function HelloFor(code, query)
  local store = ns.Store(code)
  return table.concat({ "H", PROTO, code, E36(store and store.t or 0), E36(store and store.n or 0),
    query and "q" or "-", store and store.by or "", ns.VERSION }, "^")
end

local function HelloMessages(query)
  local codes, seen = {}, {}
  for _, code in ipairs(ns.Markets()) do
    codes[#codes + 1] = code
    seen[code] = true
  end
  local home = ns.HomeMarket()
  if not seen[home] then
    codes[#codes + 1] = home
  end
  local msgs = {}
  for _, code in ipairs(codes) do
    msgs[#msgs + 1] = HelloFor(code, query)
  end
  return msgs
end

local function HelloTo(name, query)
  for _, m in ipairs(HelloMessages(query)) do
    Queue(m, "WHISPER", name)
  end
end

local function Broadcast(msgs)
  if IsInGuild and IsInGuild() then
    for _, m in ipairs(msgs) do
      Queue(m, "GUILD")
    end
  end
  local groupChat = (IsInRaid and IsInRaid()) and "RAID" or ((IsInGroup and IsInGroup()) and "PARTY") or nil
  if groupChat then
    for _, m in ipairs(msgs) do
      Queue(m, groupChat)
    end
  end
end

-- Say hello to everyone who might run PriceShare. query: ask them to answer.
function Sync.Announce(query, force)
  if not DB().share then
    return
  end
  Broadcast(HelloMessages(query))
  local targets = Sweep()
  local peers, now = ns.Peers(), ns.Now()
  for name, p in pairs(peers) do
    if p.seen and now - p.seen > PEER_KEEP then
      peers[name] = nil
    elseif not offline[name] then
      targets[name] = true
    end
  end
  local t = GetTime()
  for name in pairs(targets) do
    -- people known to run PriceShare: every PING_EVERY; everyone else once per session
    local due = not pinged[name] or (peers[name] ~= nil and t - pinged[name] > PING_EVERY)
    if not ns.IsMe(name) and not DB().blocked[name] and social[name] ~= "guild" and (force or due) then
      pinged[name] = t
      HelloTo(name, query)
    end
  end
end

local function Gossip(who)
  if gossiped[who] then
    return
  end
  gossiped[who] = true
  local names = OnlinePeers(who)
  local msg = "P"
  for _, name in ipairs(names) do
    if #msg + 1 + #name > MAX_MSG then
      Queue(msg, "WHISPER", who)
      msg = "P"
    end
    msg = msg .. "^" .. name
  end
  if msg ~= "P" then
    Queue(msg, "WHISPER", who)
  end
  -- ...and tell them about the newcomer, so both sides accept each other's hello
  for _, name in ipairs(names) do
    Queue("P^" .. who, "WHISPER", name)
  end
end

local function ReplyHello(who)
  if replied[who] and GetTime() - replied[who] < 30 then
    return
  end
  replied[who] = GetTime()
  C_Timer.After(0.5 + math.random() * 1.5, function()
    HelloTo(who, false)
    Gossip(who)
  end)
end

---------------------------------------------------------------------------
-- Receiving a transfer
---------------------------------------------------------------------------
function Sync.Want(code)
  if req[code] or choosing[code] or not DB().share then
    return
  end
  choosing[code] = true
  C_Timer.After(CHOOSE_WAIT, function()
    choosing[code] = nil
    Sync.Choose(code)
  end)
end

function Sync.Choose(code)
  if req[code] then
    return
  end
  local store = ns.Store(code)
  local mine = store and store.t or 0
  local best, cands = 0, {}
  for name, k in pairs(known[code] or {}) do
    if k.t > mine and k.t <= ns.Now() + 600 and online[name] and not offline[name] and not DB().blocked[name]
        and (not failed[name] or failed[name] < GetTime()) then
      if k.t > best then
        best, cands = k.t, { name }
      elseif k.t == best then
        cands[#cands + 1] = name
      end
    end
  end
  if #cands == 0 then
    return
  end
  local from = cands[math.random(#cands)]
  req[code] = { from = from, X = mine, last = GetTime() }
  ns.Debug("asking " .. ns.Short(from) .. " for " .. code .. " prices newer than " .. mine)
  Queue("R^" .. code .. "^" .. E36(mine), "WHISPER", from)
end

local function FailRequest(code, why, pause)
  local r = req[code]
  if not r then
    return
  end
  ns.Debug("transfer from " .. ns.Short(r.from) .. " failed: " .. why)
  failed[r.from] = GetTime() + (pause or 300)
  req[code] = nil
  Sync.Want(code)
end

local function OnStart(who, f)
  local code = f[2]
  local r = req[code]
  if not r or r.from ~= who then
    return
  end
  local T = D36(f[3])
  local store = ns.Store(code)
  if T <= (store and store.t or 0) or T > ns.Now() + 600 or (f[4] == "d" and r.X == 0) then
    FailRequest(code, "nothing newer", 60)
    return
  end
  r.T, r.mode, r.count, r.nmsg, r.by = T, f[4] == "d" and "d" or "f", D36(f[5]), D36(f[6]), f[7] ~= "" and f[7] or who
  r.kind = f[8] == "q" and "quick" or "full"
  r.items, r.gone, r.seen, r.got = {}, {}, {}, 0
  r.last = GetTime()
end

local function OnData(who, f)
  local code = f[2]
  local r = req[code]
  if not r or r.from ~= who or not r.T or D36(f[3]) ~= r.T then
    return
  end
  local seq = D36(f[4])
  if r.seen[seq] then
    return
  end
  r.seen[seq] = true
  r.got = r.got + 1
  r.last = GetTime()
  local T = r.T
  for entry in (f[5] or ""):gmatch("[^;]+") do
    if entry:sub(1, 1) == "~" then
      local id, off = entry:match("^~([%w]+),?([%w]*)$")
      id = D36(id)
      if id > 0 then
        r.gone[id] = T - D36(off)
      end
    else
      local id, m, sd, q, co = entry:match("^([%w]+),([%w]+),([%w]*),([%w]*),?([%w]*)$")
      id, m = D36(id), D36(m)
      if id > 0 and m > 0 then
        r.items[id] = { m = m, s = m + D36(sd), q = D36(q), c = T - D36(co) }
      end
    end
  end
end

local function Commit(code, r, who)
  local store = ns.Store(code, true)
  local changed = 0
  if store.t >= r.T then
    req[code] = nil -- we scanned (or got) something newer meanwhile
    return
  end
  if r.mode == "d" then
    if store.t ~= r.X then
      FailRequest(code, "our prices changed meanwhile", 5)
      return
    end
    for id, e in pairs(r.items) do
      store.items[id] = e
      store.gone[id] = nil
      changed = changed + 1
    end
    for id, t in pairs(r.gone) do
      store.items[id] = nil
      store.gone[id] = t
      changed = changed + 1
    end
    ns.Lineage(store, r.T)
  else
    store.items, store.gone, store.lin = r.items, {}, { r.T }
  end
  store.t, store.by, store.kind = r.T, r.by, r.kind
  local n = 0
  for _ in pairs(store.items) do
    n = n + 1
  end
  store.n = n
  req[code] = nil
  stats.got = stats.got + 1
  known[code] = known[code] or {}
  known[code][who] = { t = r.T, n = n }
  ns.Fire(code)
  if DB().chat and not (r.mode == "d" and changed == 0) then
    local what = r.mode == "d" and string.format("%d change%s", changed, changed == 1 and "" or "s")
      or string.format("%d items", n)
    local scanner = ns.IsMe(r.by) and "you" or ns.Short(r.by)
    ns.Print(string.format("Got %s AH prices from %s: %s (%s %s by %s).", ns.MARKET_NAMES[code] or code,
      ns.Short(who), what, ns.KindText(store), ns.Ago(ns.Now() - r.T), scanner))
  end
  -- Friends still behind can now ask us too.
  for name, k in pairs(known[code]) do
    if k.t < r.T and name ~= who and online[name] and not offline[name] then
      HelloTo(name, false)
    end
  end
end

local function OnEnd(who, f)
  local code = f[2]
  local r = req[code]
  if not r or r.from ~= who or not r.T or D36(f[3]) ~= r.T then
    return
  end
  local nmsg = D36(f[4])
  if r.nmsg ~= nmsg then
    FailRequest(code, "mixed-up transfer", 60)
    return
  end
  if r.got < nmsg then
    if not Sync.RequestMissing(code, r) then
      FailRequest(code, string.format("missing data (%d of %d messages)", r.got, nmsg), 60)
    end
    return
  end
  Commit(code, r, who)
end

-- Ask for the messages that didn't arrive. false = too many, start over.
function Sync.RequestMissing(code, r)
  local missing = {}
  for seq = 1, r.nmsg or 0 do
    if not r.seen[seq] then
      missing[#missing + 1] = E36(seq)
    end
  end
  r.resends = (r.resends or 0) + 1
  if r.resends > MAX_RESENDS or #missing > 50 then
    return false
  end
  r.last = GetTime()
  ns.Debug(string.format("asking %s again for %d missing messages", ns.Short(r.from), #missing))
  Queue("M^" .. code .. "^" .. E36(r.T) .. "^" .. table.concat(missing, ","), "WHISPER", r.from)
  return true
end

---------------------------------------------------------------------------
-- Sending a transfer
---------------------------------------------------------------------------
-- delta: also send when the item last changed (a full copy doesn't need it)
local function Entry(id, e, T, delta)
  local s = E36(id) .. "," .. E36(e.m) .. "," .. ((e.s and e.s > e.m) and E36(e.s - e.m) or "") .. "," .. E36(e.q or 0)
  if delta and e.c and e.c < T then
    s = s .. "," .. E36(T - e.c)
  end
  return s
end

-- Messages for everything newer than X (just the changes when our data grew from X).
local function BuildStream(store, code, X)
  local T = store.t
  local delta = X > 0 and X < T and ns.HasLineage(store, X)
  local header = "D^" .. code .. "^" .. E36(T) .. "^"
  local msgs, buf, len, seq, count = {}, {}, 0, 0, 0
  local function Flush()
    if #buf > 0 then
      seq = seq + 1
      msgs[#msgs + 1] = header .. E36(seq) .. "^" .. table.concat(buf, ";")
      buf, len = {}, 0
    end
  end
  local function Add(s)
    if #header + 3 + len + #s + 1 > MAX_MSG then
      Flush()
    end
    buf[#buf + 1] = s
    len = len + #s + 1
    count = count + 1
  end
  for id, e in pairs(store.items) do
    if not delta or (e.c or T) > X then
      Add(Entry(id, e, T, delta))
    end
  end
  if delta then
    for id, r in pairs(store.gone) do
      if r > X then
        Add("~" .. E36(id) .. (r < T and ("," .. E36(T - r)) or ""))
      end
    end
  end
  Flush()
  msgs[#msgs + 1] = "E^" .. code .. "^" .. E36(T) .. "^" .. E36(seq)
  return msgs, delta and "d" or "f", count, seq
end

local function OnRequest(who, f)
  local code = f[2]
  local X = D36(f[3])
  local store = ns.Store(code)
  if not MARKETS[code] then
    return
  end
  local busy = #streams >= MAX_STREAMS
  for _, s in ipairs(streams) do
    if s.target == who then
      busy = true
    end
  end
  if not store or store.t <= X or busy then
    Queue("B^" .. code, "WHISPER", who)
    return
  end
  local msgs, mode, count, seq = BuildStream(store, code, X)
  Queue(table.concat({ "S", code, E36(store.t), mode, E36(count), E36(seq), store.by or "",
    store.kind == "quick" and "q" or "f" }, "^"), "WHISPER", who)
  streams[#streams + 1] = { target = who, msgs = msgs, i = 1, market = code }
  lastBuilt[who] = { code = code, T = store.t, msgs = msgs, at = GetTime() }
  ns.Debug(string.format("sending %s %d entries (%d messages) to %s", mode == "d" and "changes:" or "everything:",
    count, #msgs, ns.Short(who)))
end

-- They missed some messages: send just those again (and the end marker).
local function OnMissing(who, f)
  local code, lb = f[2], lastBuilt[who]
  if not lb or lb.code ~= code or E36(lb.T) ~= f[3] or GetTime() - lb.at > RESEND_KEEP then
    Queue("B^" .. code, "WHISPER", who)
    return
  end
  local msgs = {}
  for seq in (f[4] or ""):gmatch("[%w]+") do
    local m = lb.msgs[D36(seq)]
    if m and m:sub(1, 1) == "D" then
      msgs[#msgs + 1] = m
    end
  end
  msgs[#msgs + 1] = lb.msgs[#lb.msgs] -- E
  DropStreamsTo(who)
  streams[#streams + 1] = { target = who, msgs = msgs, i = 1, market = code }
  ns.Debug(string.format("re-sending %d messages to %s", #msgs - 1, ns.Short(who)))
end

---------------------------------------------------------------------------
-- Incoming messages
---------------------------------------------------------------------------
local function OnHello(who, f, channel)
  if f[2] ~= PROTO then
    if not versionNoted[who] then
      versionNoted[who] = true
      ns.Print(ns.Short(who) .. " runs a PriceShare that can't share with yours. Whoever has the older one: "
        .. ns.UPDATE_HOW .. ".")
    end
    return
  end
  local code, T, n = f[3], D36(f[4]), D36(f[5])
  if not MARKETS[code] then
    return
  end
  Touch(who, channel)
  local version = f[8] ~= "" and f[8] or nil
  ns.Peers()[who].version = version or "1.0"
  if version and ns.VersionNewer(version, ns.VERSION) and not versionNoted[version] then
    versionNoted[version] = true
    ns.Print(string.format("|cffffd040Update available:|r %s has PriceShare %s, you have %s. To update: %s.",
      ns.Short(who), version, ns.VERSION, ns.UPDATE_HOW))
  end
  known[code] = known[code] or {}
  known[code][who] = { t = T, n = n }
  if f[6] == "q" then
    ReplyHello(who)
  end
  local store = ns.Store(code)
  if T > (store and store.t or 0) and T <= ns.Now() + 600 then
    Sync.Want(code)
  end
end

local function OnPeers(who, f)
  local t = GetTime()
  for i = 2, #f do
    local name = ns.Norm(f[i])
    if name and not ns.IsMe(name) and not online[name] and not DB().blocked[name] and ns.SameRealmGroup(name) then
      introduced[name] = introduced[name] or who
      if not pinged[name] or t - pinged[name] > PING_EVERY then
        pinged[name] = t
        HelloTo(name, true)
      end
    end
  end
end

local function OnMessage(text, channel, sender)
  if ns.Unreadable(text, sender) or type(text) ~= "string" or not DB().share then
    return
  end
  local who = ns.Norm(sender)
  if not who or ns.IsMe(who) or not ns.SameRealmGroup(who) then
    return
  end
  local kind = text:sub(1, 1)
  local h = heard[who] or { n = 0 }
  heard[who] = h
  h.n, h.last, h.channel = h.n + 1, GetTime(), channel
  if not Trusted(who, channel) then
    h.ignored = true
    ns.Debug("ignored a message from " .. tostring(who) .. " (not a friend, guild or group member)")
    if pingWatch[who] then
      ns.Print(ns.Short(who) .. " answered, but isn't linked to you, so it's ignored. /ps add " .. ns.Short(who) .. " fixes that.")
    end
    return
  end
  h.ignored = nil
  if pingWatch[who] and kind == "H" then
    pingWatch[who] = nil
    ns.Print(ns.Short(who) .. " answered: PriceShare is working between you.")
  end
  local f = Split(text)
  if kind == "H" then
    OnHello(who, f, channel)
    return
  end
  if channel ~= "WHISPER" then
    return
  end
  online[who] = GetTime()
  offline[who] = nil
  if kind == "D" then
    OnData(who, f)
  elseif kind == "S" then
    OnStart(who, f)
  elseif kind == "E" then
    OnEnd(who, f)
  elseif kind == "R" then
    OnRequest(who, f)
  elseif kind == "M" then
    OnMissing(who, f)
  elseif kind == "B" then
    if req[f[2]] and req[f[2]].from == who then
      FailRequest(f[2], "busy", 20)
    end
  elseif kind == "P" then
    OnPeers(who, f)
  end
end

---------------------------------------------------------------------------
-- Hooks from Core
---------------------------------------------------------------------------
function Sync.OnScan(code)
  if not DB().share then
    return
  end
  local msgs = { HelloFor(code, false) }
  Broadcast(msgs)
  for _, name in ipairs(OnlinePeers()) do
    if social[name] ~= "guild" then
      for _, m in ipairs(msgs) do
        Queue(m, "WHISPER", name)
      end
    end
  end
end

function Sync.OnAHOpen()
  if GetTime() - lastAHHello > AH_HELLO_EVERY then
    lastAHHello = GetTime()
    Sync.Announce(true)
  end
end

local function InstallErrorFilter()
  local add = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
  if not add then
    return
  end
  local raw = ERR_CHAT_PLAYER_NOT_FOUND_S or "No player named '%s' is currently playing."
  local pat = "^" .. (raw:gsub("[%-%.%+%[%]%(%)%$%^%%%?%*]", "%%%0"):gsub("%%%%s", "(.-)")) .. "$"
  add("CHAT_MSG_SYSTEM", function(_, _, msg)
    if ns.Unreadable(msg) or type(msg) ~= "string" then
      return false
    end
    local name = ns.Norm(msg:match(pat))
    local t = name and whispered[name]
    if not t or GetTime() - t > ERR_WINDOW then
      return false
    end
    if not (online[name] and online[name] > t) then
      Sync.MarkOffline(name)
    end
    return true -- our addon whisper to someone offline: hide the error
  end)
end

function Sync.Start()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
  end
  InstallErrorFilter()
  if C_GuildInfo and C_GuildInfo.GuildRoster and IsInGuild and IsInGuild() then
    C_GuildInfo.GuildRoster()
  end
  C_Timer.After(LOGIN_DELAY, function()
    Sync.Announce(true)
  end)
  if C_Timer.NewTicker then
    C_Timer.NewTicker(5, function()
      for code, r in pairs(req) do
        if GetTime() - r.last > STREAM_TIMEOUT then
          -- the end marker may be what got lost: ask for what's missing first
          if not (r.T and r.nmsg and Sync.RequestMissing(code, r)) then
            FailRequest(code, "timed out")
          end
        end
      end
      -- someone online has newer prices and we aren't getting them (after a busy or failed try)
      for code, list in pairs(known) do
        local store = ns.Store(code)
        local mine = store and store.t or 0
        for name, k in pairs(list) do
          if k.t > mine and online[name] and not offline[name] and not req[code] then
            Sync.Want(code)
            break
          end
        end
      end
    end)
  end
end

---------------------------------------------------------------------------
-- Status and commands
---------------------------------------------------------------------------
function Sync.StatusLine()
  local total, on = 0, 0
  for name in pairs(ns.Peers()) do
    total = total + 1
    if online[name] and not offline[name] then
      on = on + 1
    end
  end
  local busy = {}
  for code, r in pairs(req) do
    busy[#busy + 1] = string.format("receiving %s prices from %s (%d/%s messages)", code, ns.Short(r.from), r.got or 0,
      r.nmsg and tostring(r.nmsg) or "?")
  end
  for _, s in ipairs(streams) do
    busy[#busy + 1] = string.format("sending to %s (%d/%d)", ns.Short(s.target), s.i - 1, #s.msgs)
  end
  if not DB().share then
    return "Sharing is off (/ps share on)."
  end
  return string.format("Friends with PriceShare: %d online, %d known.%s", on, total,
    #busy > 0 and (" " .. table.concat(busy, "; ") .. ".") or "")
end

local function NameArg(rest)
  rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if rest == "" then
    return nil
  end
  return ns.Norm(rest)
end

local function List(names, max)
  max = max or 8
  local shown = {}
  for i = 1, math.min(#names, max) do
    shown[i] = names[i]
  end
  local s = #shown > 0 and table.concat(shown, ", ") or "none"
  if #names > max then
    s = s .. string.format(" (+%d more)", #names - max)
  end
  return s
end

-- Everything that decides who you share with, for when two people don't link up.
local function Check()
  local whisper = Sweep()
  ns.Print("check")
  print(string.format("   You are \"%s\" on realm %s, %s. Friends must be on the same realm and faction.",
    tostring(ns.me), ns.MyRealm(), tostring(UnitFactionGroup("player"))))
  local codes = {}
  for code, n in pairs(results) do
    if code ~= "0" then
      codes[#codes + 1] = code .. " x" .. n
    end
  end
  print(string.format("   Sharing is %s. Messages sent this session: %d%s.", DB().share and "on" or "OFF",
    stats.sent, #codes > 0 and (" (refused by the game: " .. table.concat(codes, ", ") .. ")") or ""))
  local guildName = GetGuildInfo and GetGuildInfo("player")
  local guildOnline = {}
  for name, how in pairs(social) do
    if how == "guild" then
      guildOnline[#guildOnline + 1] = ns.Short(name)
    end
  end
  print("   Guild: " .. (guildName and (guildName .. " (" .. #guildOnline .. " members listed)") or "none"))
  local friends = {}
  for name, how in pairs(social) do
    if how == "friend" then
      friends[#friends + 1] = ns.Short(name) .. (whisper[name] and "" or " (offline)")
    end
  end
  table.sort(friends)
  print("   Friends list: " .. List(friends))
  local bn = {}
  for _, b in ipairs(bnetSeen) do
    bn[#bn + 1] = ns.Short(b.name) .. (b.why and (" (not used: " .. b.why .. ")") or "")
  end
  print("   Battle.net friends in WoW: " .. List(bn))
  local linked = {}
  for name in pairs(ns.Peers()) do
    linked[#linked + 1] = ns.Short(name) .. ((online[name] and not offline[name]) and " (online)" or "")
  end
  print("   Linked with PriceShare: " .. List(linked))
  local got = {}
  for name, h in pairs(heard) do
    got[#got + 1] = string.format("%s via %s, %s%s", ns.Short(name), tostring(h.channel):lower(),
      ns.Ago(GetTime() - h.last), h.ignored and " |cffff8040IGNORED: not linked|r" or "")
  end
  print("   PriceShare messages received this session: " .. List(got, 10))
  print("   To test one person: /ps ping Name (they must be online and have PriceShare).")
end

local function Ping(rest)
  local name = NameArg(rest)
  if not name then
    ns.Print("Usage: /ps ping Name")
    return
  end
  offline[name] = nil
  local started = GetTime()
  pingWatch[name] = started
  pinged[name] = started
  HelloTo(name, true)
  ns.Print("Pinging " .. ns.Short(name) .. "...")
  C_Timer.After(15, function()
    if pingWatch[name] == started then
      pingWatch[name] = nil
      local h = heard[name]
      if h and h.ignored and h.last >= started then
        return -- they answered and it was explained then
      end
      ns.Print(string.format("No answer from %s in 15 s. Either they're offline, don't have PriceShare loaded, " ..
        "or haven't linked you: ask them to type  /ps add %s  (or invite each other to a group once).",
        ns.Short(name), ns.Short(ns.me)))
    end
  end)
end

function Sync.Command(cmd, rest)
  local peers = ns.Peers()
  if cmd == "check" then
    Check()
    return true
  elseif cmd == "ping" then
    Ping(rest)
    return true
  elseif cmd == "friends" or cmd == "peers" then
    ns.Print("friends running PriceShare:")
    local any = false
    for name, p in pairs(peers) do
      any = true
      local state = (online[name] and not offline[name]) and "|cff40ff40online|r" or "|cff888888offline|r"
      local parts = {}
      for code, list in pairs(known) do
        if list[name] and list[name].t > 0 then
          parts[#parts + 1] = string.format("%s prices from %s", ns.MARKET_NAMES[code] or code, ns.Ago(ns.Now() - list[name].t))
        end
      end
      print(string.format("   %s - %s, version %s, found via %s%s", ns.Short(name), state, p.version or "?", p.via or "?",
        #parts > 0 and (", " .. table.concat(parts, ", ")) or ""))
    end
    if not any then
      print("   Nobody yet. Friends are found automatically when they're online (guild, friends list,")
      print("   Battle.net friends, your group). Otherwise: /ps add Name")
    end
    return true
  elseif cmd == "sync" then
    Sync.Announce(true, true)
    ns.Print("Asked friends for newer prices.")
    return true
  elseif cmd == "add" then
    local name = NameArg(rest)
    if not name then
      ns.Print("Usage: /ps add Name")
      return true
    end
    peers[name] = peers[name] or { via = "added by you", seen = ns.Now() }
    DB().blocked[name] = nil
    offline[name] = nil
    pinged[name] = GetTime()
    HelloTo(name, true)
    ns.Print("Added " .. ns.Short(name) .. ". If they run PriceShare and are online, you'll start sharing.")
    return true
  elseif cmd == "remove" then
    local name = NameArg(rest)
    if name and peers[name] then
      peers[name] = nil
      ns.Print("Removed " .. ns.Short(name) .. ". They're added again if they're in your guild or friends list.")
    else
      ns.Print("Not in the list: " .. tostring(rest))
    end
    return true
  elseif cmd == "block" or cmd == "unblock" then
    local name = NameArg(rest)
    if not name then
      ns.Print("Usage: /ps " .. cmd .. " Name")
      return true
    end
    if cmd == "block" then
      DB().blocked[name] = true
      peers[name] = nil
      Sync.MarkOffline(name)
      ns.Print("Blocked " .. ns.Short(name) .. ": no prices are sent to or taken from them.")
    else
      DB().blocked[name] = nil
      offline[name] = nil
      ns.Print("Unblocked " .. ns.Short(name) .. ".")
    end
    return true
  end
  return false
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
-- Joining a group (or someone joining yours) says hello to the group, so grouping
-- up once is enough to link two people. They're remembered after that.
local groupSize, groupHelloPending = 0, false
local function OnGroupChanged()
  local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
  local grew = n > groupSize
  groupSize = n
  if not grew or n < 2 or groupHelloPending or not ns.db or not DB().share then
    return
  end
  groupHelloPending = true
  C_Timer.After(3, function() -- let the roster settle
    groupHelloPending = false
    local chat = (IsInRaid and IsInRaid()) and "RAID" or ((IsInGroup and IsInGroup()) and "PARTY") or nil
    if chat then
      for _, m in ipairs(HelloMessages(true)) do
        Queue(m, chat)
      end
    end
  end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:SetScript("OnEvent", function(_, event, prefix, text, channel, sender)
  if event == "CHAT_MSG_ADDON" and prefix == PREFIX then
    OnMessage(text, channel, sender)
  elseif event == "GROUP_ROSTER_UPDATE" then
    OnGroupChanged()
  end
end)
frame:SetScript("OnUpdate", function()
  if ns.db and (#control > 0 or #streams > 0) then
    Pump()
  end
end)
