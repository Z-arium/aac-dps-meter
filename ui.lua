-- The meter window, its minimized bar and the breakdown window. Holds no combat state:
-- main.lua passes in what to draw and gets user actions through the `handlers` given to
-- ui.create.
local api = require("api")
local ui = {}

local ROW_COUNT = 10
local ROW_HEIGHT = 20
local WIDTH = 280
local HEADER_HEIGHT = 30
local FOOTER_HEIGHT = 22
local MINI_WIDTH = 190
local MINI_HEIGHT = 26

-- Bar colour (0-255 RGB) for each units.category()
local BAR_COLORS = {
  self = { 0, 204, 153 },     -- teal
  group = { 86, 198, 239 },   -- blue
  player = { 134, 207, 82 },  -- green
  hostile = { 223, 69, 69 },  -- red
  hostileNpc = { 170, 60, 60 }, -- dark red
  npc = { 230, 141, 36 },     -- orange
  unknown = { 150, 150, 150 } -- grey
}

-- Status bars take a { r, g, b, a } table with 0-1 values
local function rgba(color, alpha)
  return { ConvertColor(color[1]), ConvertColor(color[2]), ConvertColor(color[3]), alpha or 1 }
end

local function styleLabel(label, align)
  label.style:SetShadow(true)
  label.style:SetAlign(align or ALIGN.LEFT)
  ApplyTextColor(label, FONT_COLOR.WHITE)
end

-- A label that reacts to clicks, used for the header buttons
local function clickableLabel(parent, id, text, onClick)
  local label = parent:CreateChildWidget("label", id, 0, true)
  label:SetText(text)
  styleLabel(label)
  label:SetHandler("OnClick", function() onClick() end)
  return label
end

local function addBackground(window, alpha)
  window.bg = window:CreateNinePartDrawable(TEXTURE_PATH.HUD, "background")
  window.bg:SetTextureInfo("bg_quest")
  window.bg:SetColor(0, 0, 0, alpha)
  window.bg:AddAnchor("TOPLEFT", window, 0, 0)
  window.bg:AddAnchor("BOTTOMRIGHT", window, 0, 0)
end

-- Shift + drag on `handle` moves `window`
local function makeDraggable(self, handle, window)
  handle:SetHandler("OnDragStart", function()
    if api.Input:IsShiftKeyDown() then
      window:StartMoving()
      api.Cursor:ClearCursor()
      api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
    end
  end)
  handle:SetHandler("OnDragStop", function()
    window:StopMovingOrSizing()
    api.Cursor:ClearCursor()
    self.handlers.onMoved()
  end)
  handle:EnableDrag(true)
end

local function createRow(self, index)
  local row = api.Interface:CreateWidget("label", "dpsMeterRow" .. index, self.window)
  row:AddAnchor("TOPLEFT", self.window, 8, HEADER_HEIGHT + (index - 1) * ROW_HEIGHT)
  row:SetExtent(WIDTH - 16, ROW_HEIGHT)
  row:SetText("")

  local bar = api.Interface:CreateStatusBar("dpsMeterBar" .. index, row, "item_evolving_material")
  -- Show only the top half of the bar texture, which is a flat fill
  pcall(function()
    local coords = { GetTextureInfo(TEXTURE_PATH.COSPLAY_ENCHANT, "grade_01"):GetCoords() }
    bar.statusBar:SetBarTextureCoords(coords[1], coords[2], coords[3] / 2, coords[4])
  end)
  bar:AddAnchor("TOPLEFT", row, 0, 1)
  bar:AddAnchor("BOTTOMRIGHT", row, 0, -1)
  bar:SetMinMaxValues(0, 100)
  bar:SetValue(0)
  bar.bg:SetColor(0, 0, 0, 0.35)
  row.bar = bar

  local name = bar:CreateChildWidget("label", "name", 0, true)
  styleLabel(name)
  name:AddAnchor("LEFT", bar, 5, 0)
  row.nameLabel = name

  local value = bar:CreateChildWidget("label", "value", 0, true)
  styleLabel(value, ALIGN.RIGHT)
  value:AddAnchor("RIGHT", bar, -5, 0)
  row.valueLabel = value

  -- Clicks open the breakdown; the wheel scrolls. Both go to whichever part is under the
  -- cursor, so every part of the row gets the handlers.
  local function onClick()
    if row.unitName ~= nil then self.handlers.onRowClicked(row.unitName) end
  end
  for _, widget in ipairs({ row, bar, name, value }) do
    widget:SetHandler("OnClick", onClick)
    widget:SetHandler("OnWheelUp", function() self.handlers.onScroll(-1) end)
    widget:SetHandler("OnWheelDown", function() self.handlers.onScroll(1) end)
  end
  return row
end

local function createMeter(self)
  local window = api.Interface:CreateEmptyWindow("dpsMeterWnd")
  window:SetExtent(WIDTH, HEADER_HEIGHT + ROW_COUNT * ROW_HEIGHT + FOOTER_HEIGHT)
  self.window = window
  addBackground(window, 0.55)
  window:SetHandler("OnWheelUp", function() self.handlers.onScroll(-1) end)
  window:SetHandler("OnWheelDown", function() self.handlers.onScroll(1) end)

  -- Header: Shift + drag to move. Mode, fight and scope are clickable to cycle them.
  local header = window:CreateChildWidget("label", "dpsMeterHeader", 0, true)
  header:AddAnchor("TOPLEFT", window, 0, 0)
  header:AddAnchor("TOPRIGHT", window, 0, 0)
  header:SetHeight(HEADER_HEIGHT)
  header:SetText("")
  makeDraggable(self, header, window)

  self.modeLabel = clickableLabel(window, "dpsMeterMode", "DPS", function() self.handlers.onModeClicked() end)
  self.modeLabel.style:SetFontSize(FONT_SIZE.LARGE)
  self.modeLabel:AddAnchor("TOPLEFT", window, 10, 8)
  self.modeLabel:SetExtent(100, 18)

  self.segmentLabel = clickableLabel(window, "dpsMeterSegment", "Current", function() self.handlers.onSegmentClicked() end)
  self.segmentLabel:AddAnchor("TOPLEFT", window, 112, 10)
  self.segmentLabel:SetExtent(72, 16)

  self.scopeLabel = clickableLabel(window, "dpsMeterScope", "Group", function() self.handlers.onScopeClicked() end)
  self.scopeLabel:AddAnchor("TOPLEFT", window, 186, 10)
  self.scopeLabel:SetExtent(46, 16)

  local reset = window:CreateChildWidget("button", "dpsMeterReset", 0, true)
  api.Interface:ApplyButtonSkin(reset, BUTTON_BASIC.RESET)
  reset:SetExtent(20, 20)
  reset:AddAnchor("TOPRIGHT", window, -28, 6)
  reset:SetHandler("OnClick", function() self.handlers.onReset() end)

  local minimize = clickableLabel(window, "dpsMeterMinimize", "_", function()
    self:setMinimized(true)
    self.handlers.onMinimizedChanged(true)
  end)
  minimize.style:SetFontSize(FONT_SIZE.LARGE)
  minimize:AddAnchor("TOPRIGHT", window, -8, 4)
  minimize:SetExtent(16, 20)

  self.rows = {}
  for i = 1, ROW_COUNT do
    self.rows[i] = createRow(self, i)
  end

  -- Footer: your own number and rank, and the fight timer
  local footer = window:CreateChildWidget("label", "dpsMeterFooter", 0, true)
  footer:AddAnchor("BOTTOMLEFT", window, 10, -4)
  footer:SetExtent(WIDTH - 70, 16)
  styleLabel(footer)
  self.footer = footer

  local timer = window:CreateChildWidget("label", "dpsMeterTimer", 0, true)
  timer:AddAnchor("BOTTOMRIGHT", window, -10, -4)
  timer:SetExtent(50, 16)
  styleLabel(timer, ALIGN.RIGHT)
  self.timer = timer

  window:Show(true)
end

-- The bar shown while minimized: your own number, and a button to bring the meter back
local function createMini(self)
  local mini = api.Interface:CreateEmptyWindow("dpsMeterMiniWnd")
  mini:SetExtent(MINI_WIDTH, MINI_HEIGHT)
  addBackground(mini, 0.55)

  local label = mini:CreateChildWidget("label", "dpsMeterMiniLabel", 0, true)
  label:AddAnchor("TOPLEFT", mini, 0, 0)
  label:SetExtent(MINI_WIDTH - 24, MINI_HEIGHT)
  label:SetText("")
  label:SetHandler("OnClick", function()
    self:setMinimized(false)
    self.handlers.onMinimizedChanged(false)
  end)
  makeDraggable(self, label, mini)
  local text = mini:CreateChildWidget("label", "dpsMeterMiniText", 0, true)
  text:AddAnchor("LEFT", mini, 10, 0)
  text:SetExtent(MINI_WIDTH - 40, 16)
  styleLabel(text)
  self.miniText = text

  local restore = clickableLabel(mini, "dpsMeterRestore", "+", function()
    self:setMinimized(false)
    self.handlers.onMinimizedChanged(false)
  end)
  restore.style:SetFontSize(FONT_SIZE.LARGE)
  restore:AddAnchor("RIGHT", mini, -8, 0)
  restore:SetExtent(16, 20)

  mini:Show(false)
  self.mini = mini
end

local function createDetails(self)
  local window = api.Interface:CreateWindow("dpsMeterDetailsWnd", "DPS Meter", 0, 0)
  window:AddAnchor("CENTER", "UIParent", 0, 0)
  window:SetExtent(460, 480)
  window:Show(false)

  local title = window:CreateChildWidget("label", "dpsMeterDetailsTitle", 0, true)
  title:AddAnchor("TOPLEFT", window, 14, 46)
  title:SetExtent(430, 18)
  title.style:SetFontSize(FONT_SIZE.LARGE)
  title.style:SetAlign(ALIGN.LEFT)
  ApplyTextColor(title, FONT_COLOR.DEFAULT)
  window.title = title

  local text = W_CTRL.CreateMultiLineEdit("dpsMeterDetailsText", window)
  text:AddAnchor("TOPLEFT", window, 12, 68)
  text:AddAnchor("BOTTOMRIGHT", window, -12, -12)
  text:SetMaxTextLength(8000)
  window.body = text
  self.details = window
end

local UI = {}

-- handlers: onModeClicked, onSegmentClicked, onScopeClicked, onReset, onRowClicked(name),
-- onScroll(rows), onMinimizedChanged(minimized), onMoved
function ui.create(handlers)
  -- setmetatable isn't available to addons, so copy the methods onto the instance
  local self = { handlers = handlers }
  for name, method in pairs(UI) do self[name] = method end
  createMeter(self)
  createMini(self)
  createDetails(self)
  return self
end

-- Place the meter at a saved position, or at the right edge of the screen
function UI:setPosition(x, y)
  self.window:RemoveAllAnchors()
  if x == nil or y == nil then
    self.window:AddAnchor("RIGHT", "UIParent", -20, 0)
  else
    self.window:AddAnchor("TOPLEFT", "UIParent", x, y)
  end
end

-- Position of whichever of the meter and the mini bar is showing
function UI:getPosition()
  if self:isMinimized() then return self.mini:GetOffset() end
  return self.window:GetOffset()
end

-- The meter and the mini bar share a top-left corner, so each opens where the other was
function UI:setMinimized(minimized)
  local x, y = self:getPosition()
  local shown = minimized and self.mini or self.window
  shown:RemoveAllAnchors()
  shown:AddAnchor("TOPLEFT", "UIParent", x, y)
  self.window:Show(not minimized)
  self.mini:Show(minimized)
end

function UI:isMinimized()
  return self.mini:IsVisible() == true
end

function UI:rowCount()
  return #self.rows
end

function UI:setHeader(modeText, segmentText, scopeText)
  self.modeLabel:SetText(modeText)
  self.segmentLabel:SetText(segmentText)
  self.scopeLabel:SetText(scopeText)
end

-- entries[i] = { rank, name, text, percent (0-100 bar fill), category } for row i, or nil
function UI:drawRows(entries)
  for i, row in ipairs(self.rows) do
    local entry = entries[i]
    if entry ~= nil then
      row.unitName = entry.name
      row.nameLabel:SetText(entry.rank .. ". " .. entry.name)
      row.valueLabel:SetText(entry.text)
      row.bar:SetValue(entry.percent)
      row.bar:SetBarColor(rgba(BAR_COLORS[entry.category] or BAR_COLORS.unknown, 0.85))
    else
      row.unitName = nil
      row.nameLabel:SetText("")
      row.valueLabel:SetText("")
      row.bar:SetValue(0)
    end
  end
end

-- Only touch labels whose text changed
local function setCached(self, key, label, text)
  if self[key] ~= text then
    self[key] = text
    label:SetText(text)
  end
end

function UI:setFooter(text)
  setCached(self, "footerText", self.footer, text)
end

function UI:setTimer(text)
  setCached(self, "timerText", self.timer, text)
end

function UI:setMiniText(text)
  setCached(self, "miniTextValue", self.miniText, text)
end

function UI:showDetails(title, text)
  self.details.title:SetText(title)
  self.details.body:SetText(text)
  self.details:Show(true)
end

function UI:free()
  for _, window in ipairs({ self.window, self.mini, self.details }) do
    window:Show(false)
    api.Interface:Free(window)
  end
end

return ui
