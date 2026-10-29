-- DPS Meter: wires combat events, settings and the meter window together.
--   fights.lua  splitting combat into fights and adding up the numbers
--   ui.lua      the windows
local api = require("api")
local fights = require("dps_meter/fights")
local ui = require("dps_meter/ui")

local dps_meter_addon = {
  name = "DPS Meter",
  author = "Z-arium",
  version = "0.1.0",
  desc = "Damage and healing per fight for you and your group."
}

local SETTINGS_ID = "dps_meter"
local REFRESH_MS = 500
local MAX_TEAM_MEMBERS = 50
local SCOPES = { "Group", "Everyone" }

-- Print handler errors to chat (each distinct error once). Set DPS_METER_DEBUG = true to debug.
local DEBUG = DPS_METER_DEBUG == true

local meter = nil
local tracker = nil
local settings = nil
local modeIndex = 1
local scopeIndex = 1
-- 0 = current or last fight, 1..n = earlier fights, "overall" = since the last reset
local view = 0
local playerName = nil
-- Names of you and your party/raid members, refreshed every redraw
local groupNames = {}
local sinceRefresh = 0
local positionApplied = false

local reportedErrors = {}
local function reportError(where, err)
  if not DEBUG then return end
  local msg = "[DPS Meter] " .. where .. ": " .. tostring(err)
  if reportedErrors[msg] then return end
  reportedErrors[msg] = true
  api.Log:Err(msg)
end

local function unitName(token)
  local id = api.Unit:GetUnitId(token)
  if id == nil then return nil end
  local name = api.Unit:GetUnitNameById(id)
  if name == nil or name == "" then return nil end
  return name
end

local function refreshGroup()
  local names = {}
  playerName = unitName("player") or playerName
  if playerName ~= nil then names[playerName] = true end
  for i = 1, MAX_TEAM_MEMBERS do
    local name = unitName("team" .. i)
    if name ~= nil then names[name] = true end
  end
  groupNames = names
end

local function saveSettings()
  if not positionApplied then return end
  local x, y = meter:getPosition()
  settings.posX = x
  settings.posY = y
  settings.mode = modeIndex
  settings.scope = scopeIndex
  api.SaveSettings()
end

local function viewLabel()
  if view == "overall" then return "Overall" end
  if view == 0 then
    if tracker.current ~= nil then return "Current" end
    return "Last fight"
  end
  return "Previous " .. view
end

local function includeFn()
  if SCOPES[scopeIndex] == "Everyone" then return nil end
  return function(name) return groupNames[name] == true end
end

local function redraw()
  local now = api.Time:GetUiMsec()
  refreshGroup()
  local mode = fights.MODES[modeIndex]
  local segment = fights.segment(tracker, view)
  local rows = fights.rows(tracker, segment, mode, now, includeFn())

  local top = rows[1] and rows[1].value or 0
  local entries = {}
  local ownRank, ownRow = nil, nil
  for rank, row in ipairs(rows) do
    if row.name == playerName then ownRank, ownRow = rank, row end
    if rank <= meter:rowCount() then
      local kind = "other"
      if row.name == playerName then kind = "self" elseif groupNames[row.name] then kind = "group" end
      entries[rank] = {
        name = row.name,
        text = fights.format(row.value) .. " (" .. math.floor(row.share * 100 + 0.5) .. "%)",
        percent = top > 0 and math.floor(row.value / top * 100) or 0,
        kind = kind
      }
    end
  end

  meter:setHeader(mode.label, viewLabel(), SCOPES[scopeIndex])
  meter:drawRows(entries)
  if ownRow ~= nil then
    meter:setFooter("You: " .. fights.format(ownRow.value) .. " " .. mode.label .. "  #" .. ownRank)
  elseif segment == nil then
    meter:setFooter("Waiting for a fight")
  else
    meter:setFooter("You: 0 " .. mode.label)
  end
  meter:setTimer(fights.formatTime(fights.duration(tracker, segment, now)))
end

local function showSkills(name)
  local mode = fights.MODES[modeIndex]
  local segment = fights.segment(tracker, view)
  local lines = { name .. " - " .. mode.label .. " - " .. viewLabel(), "" }
  for i, skill in ipairs(fights.skills(segment, mode, name)) do
    lines[#lines + 1] = string.format("%d. %s: %s (%d%%)", i, skill.name,
      fights.format(skill.amount), math.floor(skill.share * 100 + 0.5))
  end
  meter:showDetails(table.concat(lines, "\n"))
end

local function onCombatMessage(targetUnitId, combatEvent, source, target, ...)
  if not fights.isTracked(combatEvent) then return end
  local result = ParseCombatMessage(combatEvent, ...)
  local involved = groupNames[source] == true or groupNames[target] == true
  fights.record(tracker, combatEvent, source, target, result, involved, api.Time:GetUiMsec())
end

local eventHandlers = {
  COMBAT_MSG = onCombatMessage
}

local function onUpdate(dt)
  if not positionApplied then
    meter:setPosition(settings.posX, settings.posY)
    positionApplied = true
  end
  sinceRefresh = sinceRefresh + dt
  if sinceRefresh < REFRESH_MS then return end
  sinceRefresh = 0
  fights.tick(tracker, api.Time:GetUiMsec())
  redraw()
end

local uiHandlers = {
  onModeClicked = function()
    modeIndex = modeIndex % #fights.MODES + 1
    saveSettings()
    redraw()
  end,
  onSegmentClicked = function()
    -- Current -> Previous 1..n -> Overall -> Current
    if view == "overall" then
      view = 0
    elseif view < fights.previousCount(tracker) then
      view = view + 1
    else
      view = "overall"
    end
    redraw()
  end,
  onScopeClicked = function()
    scopeIndex = scopeIndex % #SCOPES + 1
    saveSettings()
    redraw()
  end,
  onReset = function()
    fights.reset(tracker)
    view = 0
    redraw()
  end,
  onRowClicked = function(name)
    showSkills(name)
  end,
  onMoved = function()
    saveSettings()
  end
}

-- Run a handler without letting an error break the game's event loop
local function guarded(where, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then reportError(where, err) end
  end
end

local function OnLoad()
  settings = api.GetSettings(SETTINGS_ID)
  modeIndex = fights.MODES[settings.mode] and settings.mode or 1
  scopeIndex = SCOPES[settings.scope] and settings.scope or 1
  tracker = fights.new()
  view = 0
  sinceRefresh = 0
  positionApplied = false
  refreshGroup()

  local handlers = {}
  for name, fn in pairs(uiHandlers) do handlers[name] = guarded(name, fn) end
  meter = ui.create(handlers)

  meter.window:SetHandler("OnEvent", function(_, event, ...)
    local handler = eventHandlers[event]
    if handler == nil then return end
    local ok, err = pcall(handler, ...)
    if not ok then reportError(tostring(event), err) end
  end)
  for event in pairs(eventHandlers) do
    meter.window:RegisterEvent(event)
  end
  meter.window:SetHandler("OnUpdate", function(_, dt)
    local ok, err = pcall(onUpdate, dt)
    if not ok then reportError("OnUpdate", err) end
  end)
  redraw()

  api.Log:Info("[DPS Meter] Loaded. Shift + drag the title to move it; click DPS, Current or Group to switch views.")
end

local function OnUnload()
  if meter == nil then return end
  saveSettings()
  meter:free()
  meter = nil
end

dps_meter_addon.OnLoad = OnLoad
dps_meter_addon.OnUnload = OnUnload

return dps_meter_addon
