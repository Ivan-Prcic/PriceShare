-- PriceShare Quick Scan: an empty Auction House search, every page loaded.
--
-- No 15 minute cooldown (unlike the Full Scan). Search pages show each item's
-- cheapest price and how many are listed; the sale price is carried over from the
-- last scan where it still fits. Only a complete Quick Scan is saved: saving part
-- of one would mark everything not reached yet as sold out.
--
-- Quick Scans started by other addons (VendorSnipe) are picked up too: any empty,
-- unfiltered search that gets loaded to the last page is saved.
--
-- Also: Full Scan / Quick Scan buttons above the Auction House window.

local _, ns = ...
local Quick = {}
ns.Quick = Quick

local TIMEOUT = 20   -- seconds without a new page before giving up
local MIN_GAP = 60   -- seconds between your own Quick Scans

local q = { active = false, own = false, pages = 0, count = 0, last = 0 }
local sendingOwn = false
local lastOwn = -1000

local function Sorts()
  local price = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0
  return { { sortOrder = price, reverseSort = false } }
end

-- A search for everything: no text, no filters, no level range.
local function EmptyQuery(query)
  if type(query) ~= "table" then
    return false
  end
  if query.searchString and query.searchString ~= "" then
    return false
  end
  if (query.filters and #query.filters > 0) or (query.itemClassFilters and #query.itemClassFilters > 0) then
    return false
  end
  if (query.minLevel or 0) > 0 or (query.maxLevel or 0) > 0 then
    return false
  end
  return true
end

function Quick.Busy()
  return q.active
end

local function Stop()
  q.active = false
  q.requesting = false
end

local function Begin(own)
  q.active, q.own = true, own
  q.pages, q.count, q.requesting = 0, 0, false
  q.last = GetTime()
  q.market = ns.ahMarket or ns.MarketHere()
end

local function Finish()
  local own, code = q.own, q.market
  Stop()
  local results = C_AuctionHouse.GetBrowseResults() or {}
  local new, n = {}, 0
  for _, r in ipairs(results) do
    local id = r.itemKey and r.itemKey.itemID
    local price, total = r.minPrice, r.totalQuantity or 0
    if id and price and price > 0 and total > 0 then
      price = math.max(1, math.floor(price + 0.5))
      local v = new[id]
      if not v then
        v = { m = price, q = 0 }
        new[id] = v
        n = n + 1
      elseif price < v.m then
        v.m = price -- several rows for one item (random suffixes): keep the cheapest
      end
      v.q = v.q + total
    end
  end
  if n == 0 then
    if own then
      ns.Print("The Quick Scan came back empty, nothing saved.")
    end
    return
  end
  local store = ns.Store(code)
  local items = store and store.items or {}
  for id, v in pairs(new) do
    local old = items[id]
    if old and old.s and old.s > v.m then
      v.s = math.min(old.s, math.floor(v.m * 1.5 + 0.5))
    else
      v.s = v.m
    end
  end
  local changed, removed = ns.ApplyScan(code, new, ns.Now(), ns.me, "quick")
  if ns.db.chat then
    ns.Print(string.format("Quick Scan%s: %d items at the %s AH (%d changed, %d no longer listed).",
      own and "" or " (from another addon's search)", n, ns.MARKET_NAMES[code] or code, changed, removed))
  end
  if ns.Sync then
    ns.Sync.OnScan(code)
  end
end

local function NextPage()
  if not q.active or not q.own or q.requesting then
    return
  end
  if C_AuctionHouse.HasFullBrowseResults() then
    Finish()
    return
  end
  if not C_AuctionHouse.IsThrottledMessageSystemReady() then
    C_Timer.After(0.2, NextPage)
    return
  end
  q.requesting = true
  q.pages = q.pages + 1
  C_AuctionHouse.RequestMoreBrowseResults()
end

local function OnBrowse(event, added)
  if not q.active then
    return
  end
  q.last = GetTime()
  if event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
    q.requesting = false
    q.count = q.count + (type(added) == "table" and #added or 0)
  elseif not q.requesting then
    q.count = #(C_AuctionHouse.GetBrowseResults() or {})
  end
  if C_AuctionHouse.HasFullBrowseResults() then
    Finish()
  elseif q.own then
    NextPage()
  end
end

function Quick.Start()
  if not ns.AHOpen() then
    ns.Print("Open the Auction House first.")
    return
  end
  if q.active or ns.FullScanBusy() then
    ns.Print("A scan is already running.")
    return
  end
  if GetTime() - lastOwn < MIN_GAP then
    ns.Print(string.format("Quick Scan ran %d s ago; wait a minute between them.", math.floor(GetTime() - lastOwn)))
    return
  end
  if not C_AuctionHouse.IsThrottledMessageSystemReady() then
    ns.Print("The Auction House is busy, try again in a moment.")
    return
  end
  lastOwn = GetTime()
  Begin(true)
  if ns.db.chat then
    ns.Print("Quick Scan started: loading every search page...")
  end
  sendingOwn = true
  local ok, err = pcall(C_AuctionHouse.SendBrowseQuery,
    { searchString = "", sorts = Sorts(), filters = {}, itemClassFilters = {} })
  sendingOwn = false
  if not ok then
    Stop()
    ns.Print("Couldn't start the Quick Scan: " .. tostring(err))
  end
end

-- Someone else searched: an empty search is watched (they turn the pages), any
-- other search ends ours, since its results replace ours.
hooksecurefunc(C_AuctionHouse, "SendBrowseQuery", function(query)
  if sendingOwn then
    return
  end
  if EmptyQuery(query) then
    Begin(false)
  elseif q.active then
    if q.own then
      ns.Print("Quick Scan stopped: another search was started. Nothing saved.")
    end
    Stop()
  end
end)

---------------------------------------------------------------------------
-- Buttons above the Auction House window
---------------------------------------------------------------------------
local ui

local function UpdateButtons()
  if not ui or not ns.db then
    return
  end
  local wait = ns.ScanWait()
  if ns.FullScanBusy() then
    ui.full:SetText("Full Scan...")
    ui.full:Disable()
  elseif wait > 0 then
    ui.full:SetText(string.format("Full Scan (%dm)", math.ceil(wait / 60)))
    ui.full:Disable()
  else
    ui.full:SetText("Full Scan")
    ui.full:Enable()
  end
  if q.active then
    ui.quick:SetText(q.own and string.format("Page %d...", q.pages + 1) or "Watching...")
    ui.quick:Disable()
  else
    ui.quick:SetText("Quick Scan")
    ui.quick:Enable()
  end
  local store = ns.Store(ns.ahMarket)
  if store and store.t and store.t > 0 then
    ui.label:SetText(string.format("PriceShare: %s %s by %s", ns.KindText(store), ns.Ago(ns.Now() - store.t),
      ns.IsMe(store.by) and "you" or ns.Short(store.by)))
  else
    ui.label:SetText("PriceShare: no prices yet")
  end
end

local function Tip(button, title, text)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(title)
    GameTooltip:AddLine(text, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
end

function Quick.CreateButtons()
  if ui or not AuctionHouseFrame then
    return
  end
  ui = CreateFrame("Frame", nil, AuctionHouseFrame)
  ui:SetSize(420, 24)
  ui:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "TOPRIGHT", -4, 2)
  ui.quick = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
  ui.quick:SetSize(104, 22)
  ui.quick:SetPoint("RIGHT", ui, "RIGHT", 0, 0)
  ui.quick:SetScript("OnClick", function()
    Quick.Start()
    UpdateButtons()
  end)
  Tip(ui.quick, "Quick Scan", "Loads every page of an empty search. No 15 minute wait, but only cheapest prices. Shared with your friends.")
  ui.full = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
  ui.full:SetSize(116, 22)
  ui.full:SetPoint("RIGHT", ui.quick, "LEFT", -4, 0)
  ui.full:SetScript("OnClick", function()
    ns.StartFullScan(true)
    UpdateButtons()
  end)
  Tip(ui.full, "Full Scan", "Every auction at once, with sale prices. The server allows one every 15 minutes. Shared with your friends.")
  ui.label = ui:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  ui.label:SetPoint("RIGHT", ui.full, "LEFT", -8, 0)
  ui.label:SetJustifyH("RIGHT")
  local elapsed = 0
  ui:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed >= 0.5 then
      elapsed = 0
      UpdateButtons()
    end
  end)
  UpdateButtons()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
frame:SetScript("OnEvent", function(_, event, ...)
  if event == "AUCTION_HOUSE_SHOW" then
    if AuctionHouseFrame then
      Quick.CreateButtons()
    else
      C_Timer.After(0, Quick.CreateButtons)
    end
  elseif event == "AUCTION_HOUSE_CLOSED" then
    if q.active and q.own then
      ns.Print("Quick Scan cancelled: the Auction House closed. Nothing saved.")
    end
    Stop()
  else
    OnBrowse(event, ...)
  end
end)

C_Timer.NewTicker(2, function()
  if q.active and GetTime() - q.last > TIMEOUT then
    if q.own then
      ns.Print("Quick Scan stopped: no new page for 20 s. Nothing saved (part of a scan would mark the rest as sold out).")
    end
    Stop()
  end
end)
