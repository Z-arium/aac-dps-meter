-- The meter window and the skill breakdown window. Holds no combat state: main.lua passes in
-- what to draw and gets user actions through the `handlers` given to ui.create.
local api = require("api")
local ui = {}

local ROW_COUNT = 8
local ROW_HEIGHT = 20
local WIDTH = 260
local HEADER_HEIGHT = 30
local FOOTER_HEIGHT = 22

-- Bar colours (0-255 RGB)
local BAR_SELF = { 0, 204, 153 }
local BAR_GROUP = { 86, 198, 239 }
local BAR_OTHER = { 160, 160, 160 }

-- Status bars take a { r, g, b, a } table with 0-1 values
local function rgba(color, alpha)
  return { ConvertColor(color[1]), ConvertColor(color[2]), ConvertColor(color[3]), alpha or 1 }
end

-- A label that reacts to clicks, used for the header buttons
local function clickableLabel(parent, id, text, onClick)
  local label = parent:CreateChildWidget("label", id, 0, true)
  label:SetText(text)
  label.style:SetShadow(true)
  label.style:SetAlign(ALIGN.LEFT)
  ApplyTextColor(label, FONT_COLOR.WHITE)
  label:SetHandler("OnClick", function() onClick() end)
  return label
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
  name.style:SetShadow(true)
  name.style:SetAlign(ALIGN.LEFT)
  ApplyTextColor(name, FONT_COLOR.WHITE)
  name:AddAnchor("LEFT", bar, 5, 0)
  row.nameLabel = name

  local value = bar:CreateChildWidget("label", "value", 0, true)
  value.style:SetShadow(true)
  value.style:SetAlign(ALIGN.RIGHT)
  ApplyTextColor(value, FONT_COLOR.WHITE)
  value:AddAnchor("RIGHT", bar, -5, 0)
  row.valueLabel = value

  local function onClick()
    if row.unitName ~= nil then self.handlers.onRowClicked(row.unitName) end
  end
  for _, widget in ipairs({ row, bar, name, value }) do
    widget:SetHandler("OnClick", onClick)
  end
  return row
end

local function createMeter(self)
  local window = api.Interface:CreateEmptyWindow("dpsMeterWnd")
  window:SetExtent(WIDTH, HEADER_HEIGHT + ROW_COUNT * ROW_HEIGHT + FOOTER_HEIGHT)
  self.window = window

  window.bg = window:CreateNinePartDrawable(TEXTURE_PATH.HUD, "background")
  window.bg:SetTextureInfo("bg_quest")
  window.bg:SetColor(0, 0, 0, 0.55)
  window.bg:AddAnchor("TOPLEFT", window, 0, 0)
  window.bg:AddAnchor("BOTTOMRIGHT", window, 0, 0)

  -- Header: Shift + drag to move. Mode, fight and scope are clickable to cycle them.
  local header = window:CreateChildWidget("label", "dpsMeterHeader", 0, true)
  header:AddAnchor("TOPLEFT", window, 0, 0)
  header:AddAnchor("TOPRIGHT", window, 0, 0)
  header:SetHeight(HEADER_HEIGHT)
  header:SetText("")
  header:SetHandler("OnDragStart", function()
    if api.Input:IsShiftKeyDown() then
      window:StartMoving()
      api.Cursor:ClearCursor()
      api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
    end
  end)
  header:SetHandler("OnDragStop", function()
    window:StopMovingOrSizing()
    api.Cursor:ClearCursor()
    self.handlers.onMoved()
  end)
  header:EnableDrag(true)

  self.modeLabel = clickableLabel(window, "dpsMeterMode", "DPS", function() self.handlers.onModeClicked() end)
  self.modeLabel.style:SetFontSize(FONT_SIZE.LARGE)
  self.modeLabel:AddAnchor("TOPLEFT", window, 10, 8)
  self.modeLabel:SetExtent(90, 18)

  self.segmentLabel = clickableLabel(window, "dpsMeterSegment", "Current", function() self.handlers.onSegmentClicked() end)
  self.segmentLabel:AddAnchor("TOPLEFT", window, 100, 10)
  self.segmentLabel:SetExtent(80, 16)

  self.scopeLabel = clickableLabel(window, "dpsMeterScope", "Group", function() self.handlers.onScopeClicked() end)
  self.scopeLabel:AddAnchor("TOPLEFT", window, 180, 10)
  self.scopeLabel:SetExtent(50, 16)

  local reset = window:CreateChildWidget("button", "dpsMeterReset", 0, true)
  api.Interface:ApplyButtonSkin(reset, BUTTON_BASIC.RESET)
  reset:SetExtent(20, 20)
  reset:AddAnchor("TOPRIGHT", window, -8, 6)
  reset:SetHandler("OnClick", function() self.handlers.onReset() end)

  self.rows = {}
  for i = 1, ROW_COUNT do
    self.rows[i] = createRow(self, i)
  end

  -- Footer: your own number and rank, and the fight timer
  local footer = window:CreateChildWidget("label", "dpsMeterFooter", 0, true)
  footer:AddAnchor("BOTTOMLEFT", window, 10, -4)
  footer:SetExtent(WIDTH - 70, 16)
  footer.style:SetShadow(true)
  footer.style:SetAlign(ALIGN.LEFT)
  ApplyTextColor(footer, FONT_COLOR.WHITE)
  self.footer = footer

  local timer = window:CreateChildWidget("label", "dpsMeterTimer", 0, true)
  timer:AddAnchor("BOTTOMRIGHT", window, -10, -4)
  timer:SetExtent(50, 16)
  timer.style:SetShadow(true)
  timer.style:SetAlign(ALIGN.RIGHT)
  ApplyTextColor(timer, FONT_COLOR.WHITE)
  self.timer = timer

  window:Show(true)
end

local function createDetails(self)
  local window = api.Interface:CreateWindow("dpsMeterDetailsWnd", "DPS Meter", 0, 0)
  window:AddAnchor("CENTER", "UIParent", 0, 0)
  window:SetExtent(380, 420)
  window:Show(false)

  local text = W_CTRL.CreateMultiLineEdit("dpsMeterDetailsText", window)
  text:AddAnchor("TOPLEFT", window, 12, 48)
  text:AddAnchor("BOTTOMRIGHT", window, -12, -12)
  text:SetMaxTextLength(5000)
  window.text = text
  self.details = window
end

local UI = {}

-- handlers: onModeClicked, onSegmentClicked, onScopeClicked, onReset, onRowClicked(name), onMoved
function ui.create(handlers)
  -- setmetatable isn't available to addons, so copy the methods onto the instance
  local self = { handlers = handlers }
  for name, method in pairs(UI) do self[name] = method end
  createMeter(self)
  createDetails(self)
  return self
end

function UI:setPosition(x, y)
  self.window:RemoveAllAnchors()
  if x == nil or y == nil then
    self.window:AddAnchor("RIGHT", "UIParent", -20, 0)
  else
    self.window:AddAnchor("TOPLEFT", "UIParent", x, y)
  end
end

function UI:getPosition()
  return self.window:GetOffset()
end

function UI:rowCount()
  return #self.rows
end

function UI:setHeader(modeText, segmentText, scopeText)
  self.modeLabel:SetText(modeText)
  self.segmentLabel:SetText(segmentText)
  self.scopeLabel:SetText(scopeText)
end

-- entries[i] = { name, text, percent (0-100 bar fill), kind = "self" | "group" | "other" }
function UI:drawRows(entries)
  for i, row in ipairs(self.rows) do
    local entry = entries[i]
    if entry ~= nil then
      row.unitName = entry.name
      row.nameLabel:SetText(i .. ". " .. entry.name)
      row.valueLabel:SetText(entry.text)
      row.bar:SetValue(entry.percent)
      local color = BAR_OTHER
      if entry.kind == "self" then color = BAR_SELF elseif entry.kind == "group" then color = BAR_GROUP end
      row.bar:SetBarColor(rgba(color, 0.85))
    else
      row.unitName = nil
      row.nameLabel:SetText("")
      row.valueLabel:SetText("")
      row.bar:SetValue(0)
    end
  end
end

function UI:setFooter(text)
  if self.footerText ~= text then
    self.footerText = text
    self.footer:SetText(text)
  end
end

function UI:setTimer(text)
  if self.timerText ~= text then
    self.timerText = text
    self.timer:SetText(text)
  end
end

function UI:showDetails(text)
  self.details.text:SetText(text)
  self.details:Show(true)
end

function UI:free()
  for _, window in ipairs({ self.window, self.details }) do
    window:Show(false)
    api.Interface:Free(window)
  end
end

return ui
