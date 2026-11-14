-- PriceShare price lookup: what any item costs on the Auction House, from the newest
-- scan anyone in your PriceShare group has (yours or a friend's), without standing at
-- the Auction House or having the item. Laid out like the Auction House's Buy tab:
-- search box and market at the top, categories on the left, results in the middle.
--
-- The shared scans carry item numbers only, so item names are learned from the game in
-- the background while the window is open, and kept (PRICESHARE_DB.names) for next time.
--
-- Open it with the minimap button, the "Price Lookup" button above the Auction House,
-- a key (Key Bindings > AddOns > PriceShare) or /ps find [name].

local _, ns = ...
local Lookup = {}
ns.Lookup = Lookup

local W, H = 800, 538
local ROWS, ROW_H = 17, 21
local LEARN_PER_TICK, LEARN_TICK = 30, 0.25 -- item names asked from the game: at most 120 a second
local LEARN_GIVE_UP = 15                    -- seconds to wait for an item's name
local SEARCH_DELAY = 0.25                   -- seconds after typing before the list updates
local ICON = "Interface\\Icons\\INV_Misc_Spyglass_02"
local NO_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local GetItemClassInfo = (C_Item and C_Item.GetItemClassInfo) or GetItemClassInfo
local RequestLoad = (C_Item and C_Item.RequestLoadItemDataByID) or function() end

-- The Auction House's categories, in its order (Classic item classes).
local CATEGORIES = {
  { nil, "All" },
  { 2, "Weapons" }, { 4, "Armor" }, { 1, "Containers" }, { 0, "Consumables" }, { 7, "Trade Goods" },
  { 6, "Projectile" }, { 11, "Quiver" }, { 9, "Recipes" }, { 5, "Reagent" }, { 15, "Miscellaneous" },
  { 12, "Quest Items" }, { 13, "Keys" },
}

local QUALITIES = { { 0, "Poor" }, { 1, "Common" }, { 2, "Uncommon" }, { 3, "Rare" }, { 4, "Epic" }, { 5, "Legendary" } }

local COLUMNS = {
  { key = "name", label = "Name", width = 262, justify = "LEFT" },
  { key = "q", label = "Available", width = 66, justify = "RIGHT" },
  { key = "m", label = "Cheapest", width = 104, justify = "RIGHT" },
  { key = "s", label = "Sells for", width = 104, justify = "RIGHT" },
  { key = "c", label = "Changed", width = 70, justify = "RIGHT" },
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function HasTemplate(name)
  if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
    local ok, info = pcall(C_XMLUtil.GetTemplateInfo, name)
    return ok and info ~= nil
  end
  return true -- older client: try it
end

local function MakeFrame(kind, name, parent, template)
  if template and HasTemplate(template) then
    local ok, f = pcall(CreateFrame, kind, name, parent, template)
    if ok and f then
      return f, true
    end
  end
  return CreateFrame(kind, name, parent), false
end

-- The Auction House's own textures where the game has them, plain colors otherwise.
local function Atlas(tex, atlas, fallback)
  local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)
  if info and tex.SetAtlas then
    tex:SetAtlas(atlas)
    return true
  end
  if type(fallback) == "table" then
    tex:SetColorTexture(fallback[1], fallback[2], fallback[3], fallback[4] or 1)
  elseif fallback then
    tex:SetTexture(fallback)
  end
  return false
end

local function MoneyText(c)
  c = math.floor((c or 0) + 0.5)
  if GetMoneyString then
    local ok, s = pcall(GetMoneyString, c, true)
    if ok and s then
      return s
    end
  end
  return ns.Money(c)
end

local function Count(n)
  n = n or 0
  if BreakUpLargeNumbers then
    return BreakUpLargeNumbers(n)
  end
  return tostring(n)
end

local function Tip(owner, title, text)
  owner:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(title)
    if text then
      GameTooltip:AddLine(text, 1, 1, 1, true)
    end
    GameTooltip:Show()
  end)
  owner:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
end

local function ItemClass(id)
  local ok, _, _, _, _, icon, classID = pcall(GetItemInfoInstant, id)
  if ok then
    return classID, icon
  end
end

---------------------------------------------------------------------------
-- Item names: learned from the game, kept for next time
---------------------------------------------------------------------------
local names               -- PRICESHARE_DB.names: [itemID] = "quality:Name"
local asked = {}          -- [itemID] = GetTime() we asked the game for it
local queue, queued = {}, {}
local learnTicker
local dirty = false       -- names arrived since the list was last built

local function Names()
  if not names and ns.db then
    ns.db.names = ns.db.names or {}
    names = ns.db.names
  end
  return names or {}
end

-- Name and quality of an item, or nil while the game doesn't have it yet.
local function NameOf(id)
  local known = Names()[id]
  if known then
    local q, n = known:match("^(%d+):(.+)$")
    if n then
      return n, tonumber(q)
    end
  end
  local ok, name, _, quality = pcall(GetItemInfo, id)
  if ok and type(name) == "string" and name ~= "" and not ns.Unreadable(name) then
    if names then
      names[id] = (quality or 1) .. ":" .. name
    end
    return name, quality or 1
  end
end

local function LinkOf(id)
  local ok, _, link = pcall(GetItemInfo, id)
  if ok and type(link) == "string" then
    return link
  end
end

local function StopLearning()
  if learnTicker then
    learnTicker:Cancel()
    learnTicker = nil
  end
end

local function LearnTick()
  local now = GetTime()
  local sent = 0
  while sent < LEARN_PER_TICK and #queue > 0 do
    local id = table.remove(queue)
    queued[id] = nil
    if not NameOf(id) and not asked[id] then
      asked[id] = now
      pcall(RequestLoad, id)
      sent = sent + 1
    end
  end
  local waiting = false
  for id, at in pairs(asked) do
    if NameOf(id) then
      asked[id] = nil
      dirty = true
    elseif now - at > LEARN_GIVE_UP then
      asked[id] = nil -- the game didn't answer: it'll show as "item 12345"
    else
      waiting = true
    end
  end
  if #queue == 0 and not waiting then
    StopLearning()
    dirty = true
  end
end

-- Asks the game for the names of the items in a market's data that aren't known yet.
local function LearnNames(store)
  if not store then
    return
  end
  for _, list in ipairs({ store.items or {}, store.gone or {} }) do
    for id in pairs(list) do
      if not queued[id] and not asked[id] and not NameOf(id) then
        queued[id] = true
        queue[#queue + 1] = id
      end
    end
  end
  if #queue > 0 and not learnTicker then
    learnTicker = C_Timer.NewTicker(LEARN_TICK, ns.Guard("learning item names", LearnTick))
  end
end

-- How many of a market's listed items have a known name (worked out at most every 2 s).
local progress = { store = nil, at = -100, known = 0, total = 0 }
local function NameProgress(store)
  if progress.store ~= store or GetTime() - progress.at >= 2 then
    local total, known = 0, 0
    for id in pairs(store and store.items or {}) do
      total = total + 1
      if NameOf(id) then
        known = known + 1
      end
    end
    progress.store, progress.at, progress.known, progress.total = store, GetTime(), known, total
  end
  return progress.known, progress.total
end

---------------------------------------------------------------------------
-- State and results
---------------------------------------------------------------------------
local ui
local state = { category = 1, text = "", sort = "name", desc = false, offset = 0,
  quality = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true } }
local results = {}
local Refresh -- defined below

local function Market()
  if state.market then
    return state.market -- picked in the menu: shown even with no prices yet
  end
  local here = ns.AHOpen() and ns.ahMarket or ns.HomeMarket()
  if ns.Store(here) then
    return here
  end
  for _, code in ipairs(ns.Markets()) do
    return code
  end
  return here
end

local function SortValue(e, key)
  if key == "name" then
    return (e.name or ("~item " .. e.id)):lower()
  elseif key == "c" then
    return e.c or 0
  end
  return e[key] or (e.gone and -1) or 0
end

local function SortResults()
  local key, desc = state.sort, state.desc
  table.sort(results, function(a, b)
    if (a.gone ~= nil) ~= (b.gone ~= nil) then
      return b.gone ~= nil -- no longer listed: always last
    end
    local x, y = SortValue(a, key), SortValue(b, key)
    if x == y then
      return a.id < b.id
    end
    if desc then
      return x > y
    end
    return x < y
  end)
end

-- What the search box asks for: an item link or number (that one item), or words in names.
local function Needle()
  local text = state.text or ""
  local linkID = tonumber(text:match("item:(%d+)"))
  if linkID then
    return nil, linkID
  end
  local id = tonumber(text:match("^%s*(%d+)%s*$"))
  if id then
    return nil, id
  end
  local words = {}
  for w in text:lower():gmatch("%S+") do
    words[#words + 1] = w
  end
  return words
end

local function Matches(id, words, wantID, classID)
  if wantID then
    return id == wantID
  end
  if classID then
    local c = ItemClass(id)
    if c ~= classID then
      return false
    end
  end
  local name, q = NameOf(id)
  if q and not state.quality[q] then
    return false
  end
  if #words == 0 then
    return true
  end
  if not name then
    return false
  end
  local lower = name:lower()
  for _, w in ipairs(words) do
    if not lower:find(w, 1, true) then
      return false
    end
  end
  return true
end

local function BuildResults()
  wipe(results)
  local store = ns.Store(Market())
  if not store then
    return
  end
  local words, wantID = Needle()
  local classID = CATEGORIES[state.category] and CATEGORIES[state.category][1]
  for id, e in pairs(store.items or {}) do
    if Matches(id, words, wantID, classID) then
      results[#results + 1] = { id = id, name = (NameOf(id)), m = e.m, s = e.s or e.m, q = e.q, c = e.c }
    end
  end
  -- Searched for something: also say what's no longer listed.
  if wantID or #words > 0 then
    for id, when in pairs(store.gone or {}) do
      if not store.items[id] and Matches(id, words, wantID, classID) then
        results[#results + 1] = { id = id, name = (NameOf(id)), gone = when }
      end
    end
  end
  SortResults()
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local function SetTitle(f, text)
  if f.SetTitle then
    f:SetTitle(text)
  elseif f.TitleText then
    f.TitleText:SetText(text)
  elseif f.TitleContainer and f.TitleContainer.TitleText then
    f.TitleContainer.TitleText:SetText(text)
  else
    local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("TOP", 0, -6)
    t:SetText(text)
  end
end

local function SetPortrait(f, icon)
  if f.SetPortraitToAsset then
    pcall(f.SetPortraitToAsset, f, icon)
  elseif f.PortraitContainer and f.PortraitContainer.portrait then
    f.PortraitContainer.portrait:SetTexture(icon)
  elseif f.portrait then
    if SetPortraitToTexture then
      pcall(SetPortraitToTexture, f.portrait, icon)
    else
      f.portrait:SetTexture(icon)
    end
  end
end

local function MarketLabel(code)
  local name = ns.MARKET_NAMES[code] or code
  return (name:gsub(" %(goblin%)", "")) .. " AH"
end

local function ShowMarketMenu(button)
  local function Choose(code)
    state.market = code
    state.offset, state.selected = 0, nil
    LearnNames(ns.Store(code))
    Lookup.Search(true)
  end
  local codes = { "H", "A", "N" }
  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(button, function(_, root)
      root:CreateTitle("Auction House")
      for _, code in ipairs(codes) do
        local store = ns.Store(code)
        local label = (ns.MARKET_NAMES[code] or code) .. (store and store.t and store.t > 0
          and (" |cff999999(" .. ns.Ago(ns.Now() - store.t) .. ")|r") or " |cff999999(no prices)|r")
        root:CreateRadio(label, function()
          return Market() == code
        end, function()
          Choose(code)
        end)
      end
    end)
  else
    local current = Market()
    for i, code in ipairs(codes) do
      if code == current then
        Choose(codes[i % #codes + 1])
        return
      end
    end
    Choose(codes[1])
  end
end

local function ShowFilterMenu(button)
  if not (MenuUtil and MenuUtil.CreateContextMenu) then
    return
  end
  MenuUtil.CreateContextMenu(button, function(_, root)
    root:CreateTitle("Rarity")
    for _, q in ipairs(QUALITIES) do
      local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q[1]]
      local label = color and color.hex and (color.hex .. q[2] .. "|r") or q[2]
      root:CreateCheckbox(label, function()
        return state.quality[q[1]]
      end, function()
        state.quality[q[1]] = not state.quality[q[1]]
        state.offset = 0
        Lookup.Search(true)
      end)
    end
  end)
end

local function HeaderClick(key)
  if state.sort == key then
    state.desc = not state.desc
  else
    state.sort, state.desc = key, key == "c" -- "Changed": newest first
  end
  SortResults()
  Refresh()
end

local function SelectRow(e)
  state.selected = e and e.id or nil
  Refresh()
end

local function RowClick(row)
  local e = row.entry
  if not e then
    return
  end
  if IsModifiedClick and IsModifiedClick() and HandleModifiedItemClick then
    local link = LinkOf(e.id)
    if link then
      HandleModifiedItemClick(link)
    end
    return
  end
  SelectRow(e)
end

local function RowEnter(row)
  local e = row.entry
  if not e then
    return
  end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  if GameTooltip.SetItemByID then
    GameTooltip:SetItemByID(e.id)
  else
    GameTooltip:SetHyperlink("item:" .. e.id)
  end
  GameTooltip:Show()
end

local function CreateRow(parent, i)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(W - 220, ROW_H)
  row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(i - 1) * ROW_H)
  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAllPoints()
  Atlas(row.bg, i % 2 == 1 and "auctionhouse-rowstripe-1" or "auctionhouse-rowstripe-2",
    i % 2 == 1 and { 1, 1, 1, 0.03 } or { 0, 0, 0, 0 })
  row.selected = row:CreateTexture(nil, "BORDER")
  row.selected:SetAllPoints()
  Atlas(row.selected, "auctionhouse-ui-row-select", { 1, 0.82, 0, 0.15 })
  row.selected:Hide()
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  if not Atlas(hl, "auctionhouse-ui-row-highlight") then
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetBlendMode("ADD")
  end
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(ROW_H - 4, ROW_H - 4)
  row.icon:SetPoint("LEFT", 4, 0)
  row.cells = {}
  local x = 4 + ROW_H
  for c, col in ipairs(COLUMNS) do
    local fs = row:CreateFontString(nil, "ARTWORK", c == 1 and "GameFontNormal" or "GameFontHighlightSmall")
    local width = c == 1 and (col.width - ROW_H) or col.width
    fs:SetPoint("LEFT", row, "LEFT", x, 0)
    fs:SetWidth(width - 6)
    fs:SetJustifyH(col.justify)
    if fs.SetWordWrap then
      fs:SetWordWrap(false)
    end
    row.cells[c] = fs
    x = x + width
  end
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnClick", RowClick)
  row:SetScript("OnEnter", RowEnter)
  row:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
  return row
end

local function CreateCategoryButton(parent, i, cat)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(158, 20)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(i - 1) * 21)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  Atlas(b.bg, "auctionhouse-nav-button", { 0.15, 0.12, 0.08, 0.85 })
  b.sel = b:CreateTexture(nil, "BORDER")
  b.sel:SetAllPoints()
  Atlas(b.sel, "auctionhouse-nav-button-select", { 1, 0.82, 0, 0.25 })
  b.sel:Hide()
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  if not Atlas(hl, "auctionhouse-nav-button-highlight") then
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetBlendMode("ADD")
  end
  b.text = b:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  b.text:SetPoint("LEFT", 10, 0)
  b.text:SetPoint("RIGHT", -6, 0)
  b.text:SetJustifyH("LEFT")
  local label = cat[2]
  if cat[1] and GetItemClassInfo then
    local ok, name = pcall(GetItemClassInfo, cat[1])
    if ok and type(name) == "string" and name ~= "" then
      label = name
    end
  end
  b.label = label
  b.text:SetText(label)
  b:SetScript("OnClick", function()
    state.category = i
    state.offset, state.selected = 0, nil
    Lookup.Search(true)
  end)
  return b
end

local function OnTextChanged(box, userInput)
  if not userInput then
    return
  end
  state.text = box:GetText() or ""
  local my = (ui.searchSeq or 0) + 1
  ui.searchSeq = my
  C_Timer.After(SEARCH_DELAY, function()
    if ui.searchSeq == my then
      state.offset, state.selected = 0, nil
      Lookup.Search(true)
    end
  end)
end

local function CreateUI()
  local f = MakeFrame("Frame", "PriceShareLookupFrame", UIParent, "PortraitFrameTemplate")
  ui = f
  f:SetSize(W, H)
  f:SetPoint("CENTER", 0, 20)
  f:SetFrameStrata("HIGH")
  f:SetToplevel(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  if not f.CloseButton and not _G["PriceShareLookupFrameCloseButton"] then
    -- no template: a plain dark panel with a close button
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.06, 0.95)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
  end
  SetTitle(f, "PriceShare: Auction House Prices")
  SetPortrait(f, ICON)
  tinsert(UISpecialFrames, "PriceShareLookupFrame")
  f:SetScript("OnShow", function()
    LearnNames(ns.Store(Market()))
    Lookup.Search(true)
  end)
  f:SetScript("OnHide", function()
    StopLearning()
    GameTooltip:Hide()
  end)
  local refreshIn = 0
  f:SetScript("OnUpdate", function(_, elapsed)
    refreshIn = refreshIn - (elapsed or 0)
    if refreshIn <= 0 then
      refreshIn = 0.5
      if dirty then
        dirty = false
        progress.at = -100 -- names arrived: count again
        Lookup.Search(false)
      else
        Refresh(true) -- ages and progress
      end
    end
  end)

  -- Top bar: search box, rarity filter, market, Search button (like the AH's).
  local search = MakeFrame("EditBox", "PriceShareLookupSearchBox", f,
    HasTemplate("SearchBoxTemplate") and "SearchBoxTemplate" or "InputBoxTemplate")
  search:SetSize(300, 22)
  search:SetPoint("TOPLEFT", f, "TOPLEFT", 186, -32)
  search:SetAutoFocus(false)
  search:SetMaxLetters(80)
  if search.Instructions then
    search.Instructions:SetText("Search (item name, or shift-click an item)")
  end
  search:HookScript("OnTextChanged", OnTextChanged)
  search:SetScript("OnEnterPressed", function(box)
    state.text = box:GetText() or ""
    state.offset, state.selected = 0, nil
    box:ClearFocus()
    Lookup.Search(true)
  end)
  search:SetScript("OnEscapePressed", function(box)
    box:ClearFocus()
  end)
  ui.search = search

  local go = MakeFrame("Button", nil, f, "UIPanelButtonTemplate")
  go:SetSize(132, 22)
  go:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -32)
  go:SetText(SEARCH or "Search")
  go:SetScript("OnClick", function()
    state.text = search:GetText() or ""
    state.offset, state.selected = 0, nil
    search:ClearFocus()
    Lookup.Search(true)
  end)

  local market = MakeFrame("Button", nil, f, "UIPanelButtonTemplate")
  market:SetSize(118, 22)
  market:SetPoint("RIGHT", go, "LEFT", -6, 0)
  market:SetScript("OnClick", ShowMarketMenu)
  Tip(market, "Auction House", "Which Auction House's prices to show: your faction's, or the goblin one " ..
    "(Booty Bay, Gadgetzan, Everlook). Each has its own scans.")
  ui.market = market

  local filter = MakeFrame("Button", nil, f, "UIPanelButtonTemplate")
  filter:SetSize(84, 22)
  filter:SetPoint("RIGHT", market, "LEFT", -6, 0)
  filter:SetText(FILTER or "Filter")
  filter:SetScript("OnClick", ShowFilterMenu)
  Tip(filter, FILTER or "Filter", "Show only some rarities.")
  ui.filter = filter

  -- Left: categories
  local cats = CreateFrame("Frame", nil, f)
  cats:SetSize(158, #CATEGORIES * 21)
  cats:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -66)
  ui.cats = {}
  for i, cat in ipairs(CATEGORIES) do
    ui.cats[i] = CreateCategoryButton(cats, i, cat)
  end

  -- Middle: the results table
  local area = CreateFrame("Frame", nil, f)
  area:SetPoint("TOPLEFT", f, "TOPLEFT", 180, -66)
  area:SetSize(W - 194, 24 + ROWS * ROW_H)
  local areaBg = area:CreateTexture(nil, "BACKGROUND")
  areaBg:SetAllPoints()
  Atlas(areaBg, "auctionhouse-background-index", { 0, 0, 0, 0.35 })

  local header = CreateFrame("Frame", nil, area)
  header:SetSize(W - 220, 22)
  header:SetPoint("TOPLEFT", area, "TOPLEFT", 0, 0)
  ui.headers = {}
  local x = 0
  for c, col in ipairs(COLUMNS) do
    local h = CreateFrame("Button", nil, header)
    h:SetSize(col.width, 22)
    h:SetPoint("LEFT", header, "LEFT", x, 0)
    local hbg = h:CreateTexture(nil, "BACKGROUND")
    hbg:SetAllPoints()
    Atlas(hbg, "auctionhouse-ui-row-header", { 1, 1, 1, 0.06 })
    local hhl = h:CreateTexture(nil, "HIGHLIGHT")
    hhl:SetAllPoints()
    hhl:SetColorTexture(1, 1, 1, 0.08)
    h.text = h:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    h.text:SetText(col.label)
    if col.justify == "RIGHT" then
      h.text:SetPoint("RIGHT", h, "RIGHT", -16, 0)
    else
      h.text:SetPoint("LEFT", h, "LEFT", c == 1 and (4 + ROW_H) or 6, 0)
    end
    -- The Auction House's classic sort arrow (flipped with texture coordinates).
    h.arrow = h:CreateTexture(nil, "ARTWORK")
    h.arrow:SetSize(9, 8)
    h.arrow:SetPoint("LEFT", h.text, "RIGHT", 3, -1)
    h.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
    h.arrow:Hide()
    h.key = col.key
    h:SetScript("OnClick", function()
      HeaderClick(col.key)
    end)
    ui.headers[c] = h
    x = x + col.width
  end

  local list = CreateFrame("Frame", nil, area)
  list:SetSize(W - 220, ROWS * ROW_H)
  list:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
  list:EnableMouseWheel(true)
  ui.rows = {}
  for i = 1, ROWS do
    ui.rows[i] = CreateRow(list, i)
  end

  local scroll = HasTemplate("FauxScrollFrameTemplate") and
    MakeFrame("ScrollFrame", "PriceShareLookupScroll", area, "FauxScrollFrameTemplate") or nil
  if scroll and FauxScrollFrame_Update then
    scroll:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -2, 0)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
      FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, function()
        state.offset = FauxScrollFrame_GetOffset(self)
        Refresh()
      end)
    end)
    ui.scroll = scroll
    ui.scrollBar = scroll.ScrollBar or _G["PriceShareLookupScrollScrollBar"]
    -- The rows sit above the scroll frame (so they get the clicks); the wheel scrolls it.
    list:SetFrameLevel(scroll:GetFrameLevel() + 2)
    list:SetScript("OnMouseWheel", function(_, delta)
      local bar = ui.scrollBar
      if bar then
        bar:SetValue(bar:GetValue() - delta * ROW_H * 3)
      end
    end)
  else
    list:SetScript("OnMouseWheel", function(_, delta)
      state.offset = math.max(0, math.min(state.offset - delta * 3, math.max(0, #results - ROWS)))
      Refresh()
    end)
  end

  ui.empty = area:CreateFontString(nil, "ARTWORK", "GameFontDisable")
  ui.empty:SetPoint("CENTER", list, "CENTER", 0, 0)
  ui.empty:SetWidth(420)

  -- Bottom: the selected item, then where the prices come from
  ui.detailIcon = f:CreateTexture(nil, "ARTWORK")
  ui.detailIcon:SetSize(30, 30)
  ui.detailIcon:SetPoint("TOPLEFT", area, "BOTTOMLEFT", 2, -8)
  ui.detail = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  ui.detail:SetPoint("TOPLEFT", ui.detailIcon, "TOPRIGHT", 8, 0)
  ui.detail:SetWidth(W - 240)
  ui.detail:SetJustifyH("LEFT")
  ui.detail2 = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  ui.detail2:SetPoint("TOPLEFT", ui.detail, "BOTTOMLEFT", 0, -3)
  ui.detail2:SetWidth(W - 240)
  ui.detail2:SetJustifyH("LEFT")

  ui.status = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  ui.status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 12)
  ui.status:SetWidth(W - 32)
  ui.status:SetJustifyH("LEFT")
  f:Hide() -- a new frame starts out shown; hidden, opening it runs OnShow
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
local function QualityColor(q)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c then
    return c.r, c.g, c.b
  end
  return 1, 1, 1
end

local function DrawDetail(store)
  local e
  for _, r in ipairs(results) do
    if r.id == state.selected then
      e = r
      break
    end
  end
  if not e then
    ui.detailIcon:Hide()
    ui.detail:SetText("|cff999999Click an item for its details. Shift-click links it in chat, Ctrl-click tries it on.|r")
    ui.detail2:SetText("")
    return
  end
  local _, icon = ItemClass(e.id)
  ui.detailIcon:SetTexture(icon or NO_ICON)
  ui.detailIcon:Show()
  local name, q = NameOf(e.id)
  local qc = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  local hex = qc and qc.hex
  if not hex then
    local r, g, b = QualityColor(q)
    hex = string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
  end
  local colored = hex .. (name or ("item " .. e.id)) .. "|r"
  if e.gone then
    ui.detail:SetText(string.format("%s: none listed (the last one went %s).", colored, ns.Ago(ns.Now() - e.gone)))
    ui.detail2:SetText("")
    return
  end
  local text = string.format("%s: cheapest %s each", colored, MoneyText(e.m))
  if e.s and e.s > e.m then
    text = text .. string.format(", sells for ~%s", MoneyText(e.s))
  end
  ui.detail:SetText(text .. string.format(", %s listed.", Count(e.q)))
  local more = {}
  if e.c then
    more[#more + 1] = "Price last changed " .. ns.Ago(ns.Now() - e.c) .. "."
  end
  local get = (C_Item and C_Item.GetItemCount) or GetItemCount
  if get then
    local ok, have = pcall(get, e.id, true)
    if ok and (tonumber(have) or 0) > 0 then
      more[#more + 1] = string.format("You have %d, worth ~%s at the cheapest price.", have, MoneyText(e.m * have))
    end
  end
  more[#more + 1] = "|cff999999After the 5% Auction House cut a sale brings ~" .. MoneyText(math.floor((e.s or e.m) * 0.95)) .. ".|r"
  ui.detail2:SetText(table.concat(more, "  "))
end

local function DrawStatus(store, code)
  local parts = {}
  if store and store.t and store.t > 0 then
    local age = ns.Now() - store.t
    parts[#parts + 1] = string.format("%s: %s %s by %s, %s items listed%s.", MarketLabel(code), ns.KindText(store), ns.Ago(age),
      ns.IsMe(store.by) and "you" or ns.Short(store.by), Count(store.n or 0),
      age >= (ns.FRESH or 48 * 3600) and " |cffff8040(old: these prices may have moved)|r" or "")
    local known, total = NameProgress(store)
    if known < total then
      parts[#parts + 1] = string.format("|cffffd100Learning item names: %s of %s known.|r Searches by name cover the known ones.",
        Count(known), Count(total))
    end
  else
    parts[#parts + 1] = MarketLabel(code) .. ": no prices yet. Open that Auction House to scan, or wait for a friend's scan."
  end
  ui.status:SetText(table.concat(parts, "  "))
end

function Refresh(light)
  if not ui or not ui:IsShown() then
    return
  end
  local code = Market()
  local store = ns.Store(code)
  ui.market:SetText(MarketLabel(code))
  for i, b in ipairs(ui.cats) do
    b.sel:SetShown(i == state.category)
    b.text:SetFontObject(i == state.category and "GameFontHighlightSmall" or "GameFontNormalSmall")
  end
  for _, h in ipairs(ui.headers) do
    local on = h.key == state.sort
    h.arrow:SetShown(on)
    if on then
      if state.desc then
        h.arrow:SetTexCoord(0, 0.5625, 0, 1)
      else
        h.arrow:SetTexCoord(0, 0.5625, 1, 0)
      end
    end
  end
  local total = #results
  if ui.scroll then
    FauxScrollFrame_Update(ui.scroll, total, ROWS, ROW_H)
    state.offset = FauxScrollFrame_GetOffset(ui.scroll)
  end
  state.offset = math.max(0, math.min(state.offset, math.max(0, total - ROWS)))
  local now = ns.Now()
  for i, row in ipairs(ui.rows) do
    local e = results[i + state.offset]
    row.entry = e
    if e then
      local name, q = NameOf(e.id)
      e.name = name or e.name
      local _, icon = ItemClass(e.id)
      row.icon:SetTexture(icon or NO_ICON)
      row.icon:SetDesaturated(e.gone ~= nil)
      local c = row.cells
      c[1]:SetText(name or ("item " .. e.id))
      c[1]:SetTextColor(QualityColor(q))
      if e.gone then
        c[1]:SetTextColor(0.5, 0.5, 0.5)
        c[2]:SetText("|cff808080none|r")
        c[3]:SetText("|cff808080-|r")
        c[4]:SetText("|cff808080-|r")
        c[5]:SetText("|cff808080gone " .. ns.Ago(now - e.gone):gsub(" ago", "") .. "|r")
      else
        c[2]:SetText(Count(e.q))
        c[3]:SetText(MoneyText(e.m))
        c[4]:SetText((e.s and e.s > e.m) and MoneyText(e.s) or "|cff808080same|r")
        c[5]:SetText(e.c and ns.Ago(now - e.c):gsub(" ago", "") or "")
      end
      row.selected:SetShown(e.id == state.selected)
      row:Show()
    else
      row.selected:Hide()
      row:Hide()
    end
  end
  if total == 0 then
    if not store then
      ui.empty:SetText("No prices for this Auction House yet.")
    elseif state.text ~= "" then
      local known, all = NameProgress(store)
      ui.empty:SetText("Nothing listed matches \"" .. state.text .. "\"." ..
        (known < all and "\n|cffffd100Still learning item names, it may show up in a moment.|r" or ""))
    else
      ui.empty:SetText("Nothing in this category.")
    end
    ui.empty:Show()
  else
    ui.empty:Hide()
  end
  DrawDetail(store)
  DrawStatus(store, code)
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------
-- rebuild: true when the search changed (keeps the scroll position otherwise)
function Lookup.Search(rebuild)
  if not ui then
    return
  end
  BuildResults()
  if rebuild and ui.scroll then
    FauxScrollFrame_SetOffset(ui.scroll, 0)
    if ui.scrollBar then
      ui.scrollBar:SetValue(0)
    end
  end
  Refresh()
end

-- Opens the window, searching for text when given (a name or an item link).
function Lookup.Open(text)
  if not ns.db then
    return
  end
  if not ui then
    CreateUI()
  end
  if text and text ~= "" then
    state.text = text
    state.category, state.offset, state.selected = 1, 0, nil
    ui.search:SetText(text)
  end
  ui:Show()
  ui:Raise()
  LearnNames(ns.Store(Market()))
  Lookup.Search(text ~= nil)
end

function Lookup.Toggle()
  if ui and ui:IsShown() then
    ui:Hide()
  else
    Lookup.Open()
  end
end

-- Key Bindings > AddOns > PriceShare
BINDING_HEADER_PRICESHARE = "PriceShare"
BINDING_NAME_PRICESHARE_LOOKUP = "Price lookup window"
function PriceShare_ToggleLookup()
  Lookup.Toggle()
end

---------------------------------------------------------------------------
-- Minimap button: left-click opens the lookup, right-click shows the status.
---------------------------------------------------------------------------
local mm

local function PlaceMinimapButton()
  local angle = math.rad(ns.db.minimapAngle or 225)
  local radius = (Minimap:GetWidth() / 2) + 5
  mm:ClearAllPoints()
  mm:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function CreateMinimapButton()
  if mm or not Minimap then
    return
  end
  mm = CreateFrame("Button", "PriceShareMinimapButton", Minimap)
  mm:SetSize(31, 31)
  mm:SetFrameStrata("MEDIUM")
  mm:SetFrameLevel(8)
  mm:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  mm:RegisterForDrag("LeftButton")
  mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local bg = mm:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetPoint("TOPLEFT", 7, -5)
  local icon = mm:CreateTexture(nil, "ARTWORK")
  icon:SetSize(17, 17)
  icon:SetTexture(ICON)
  icon:SetPoint("TOPLEFT", 7, -6)
  local border = mm:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetPoint("TOPLEFT")
  mm:SetScript("OnClick", function(self, button)
    if button ~= "RightButton" then
      Lookup.Toggle()
    elseif MenuUtil and MenuUtil.CreateContextMenu then
      MenuUtil.CreateContextMenu(self, function(_, root)
        root:CreateTitle("PriceShare " .. ns.VERSION)
        root:CreateButton("Price lookup", function()
          Lookup.Open()
        end)
        root:CreateButton("Status in chat", function()
          SlashCmdList.PRICESHARE("")
        end)
        local sounds = root:CreateButton("Update reminder sound")
        for _, s in ipairs(ns.SOUNDS) do
          -- picking one plays it, so you can hear them all
          sounds:CreateRadio(s.label, function()
            return (ns.db.remindSound or "workwork") == s.key
          end, function()
            ns.SetReminderSound(s.key)
          end)
        end
        root:CreateButton("Show the update reminder", function()
          SlashCmdList.PRICESHARE("remind")
        end)
        root:CreateDivider()
        root:CreateButton("|cff808080Hide this button (/ps minimap brings it back)|r", function()
          Lookup.SetMinimapShown(false)
        end)
      end)
    else
      SlashCmdList.PRICESHARE("")
    end
  end)
  mm:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("PriceShare")
    GameTooltip:AddLine("Left-click: look up any item's price", 1, 1, 1)
    GameTooltip:AddLine("Right-click: menu (status, update reminder sound)", 1, 1, 1)
    GameTooltip:AddLine("Drag: move around the minimap", 0.6, 0.6, 0.6)
    local store = ns.Store(ns.HomeMarket())
    if store and store.t and store.t > 0 then
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(string.format("%s: %s %s by %s", MarketLabel(ns.HomeMarket()), ns.KindText(store),
        ns.Ago(ns.Now() - store.t), ns.IsMe(store.by) and "you" or ns.Short(store.by)), 0.4, 0.8, 1)
    end
    GameTooltip:Show()
  end)
  mm:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
  mm:SetScript("OnDragStart", function(self)
    GameTooltip:Hide()
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local px, py = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      ns.db.minimapAngle = math.deg(math.atan2(py / scale - my, px / scale - mx))
      PlaceMinimapButton()
    end)
  end)
  mm:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
  end)
  PlaceMinimapButton()
end

function Lookup.SetMinimapShown(shown)
  ns.db.minimapHidden = not shown
  if shown then
    CreateMinimapButton()
  end
  if mm then
    mm:SetShown(shown)
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
pcall(events.RegisterEvent, events, "GET_ITEM_INFO_RECEIVED")
events:SetScript("OnEvent", ns.Guard("lookup events", function(_, event, itemID)
  if event == "PLAYER_LOGIN" then
    if ns.db and not ns.db.minimapHidden then
      CreateMinimapButton()
    end
    -- Shift-clicking an item while the search box has focus searches for it.
    if ChatEdit_InsertLink then
      hooksecurefunc("ChatEdit_InsertLink", function(link)
        if ui and ui:IsShown() and ui.search:HasFocus() and type(link) == "string" then
          local name = link:match("|h%[(.-)%]|h")
          if name then
            ui.search:SetText(name)
            state.text = name
            state.category, state.offset, state.selected = 1, 0, nil
            Lookup.Search(true)
          end
        end
      end)
    end
    if PriceShare and PriceShare.RegisterCallback then
      PriceShare.RegisterCallback(function()
        if ui and ui:IsShown() then
          LearnNames(ns.Store(Market()))
          dirty = true
        end
      end)
    end
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    if itemID and asked[itemID] then
      asked[itemID] = nil
      if NameOf(itemID) then
        dirty = true
      end
    end
  end
end))
