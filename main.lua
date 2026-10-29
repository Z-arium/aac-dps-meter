-- DPS Meter: wires combat events, settings and the windows together.
--   fights.lua  splitting combat into fights and adding up the numbers
--   units.lua   who is you, your group, a player, hostile or an NPC
--   ui.lua      the windows
local api = require("api")
local fights = require("dps_meter/fights")
local units = require("dps_meter/units")
local ui = require("dps_meter/ui")

local dps_meter_addon = {
  name = "DPS Meter",
  author = "Z-arium",
  version = "0.2.0",
  desc = "Damage, healing, damage taken and absorbed, per fight, for you, your group and everyone nearby."
}

local SETTINGS_ID = "dps_meter"
local REFRESH_MS = 500
local LOG_PATH = "dps_meter/logs/fights_%.0f.txt"

local DAMAGE_EVENTS = { SPELL_DAMAGE = true, SPELL_DOT_DAMAGE = true, MELEE_DAMAGE = true, RANGED_DAMAGE = true }
local HEAL_EVENTS = { SPELL_HEALED = true }
local MISS_EVENTS = { SPELL_MISSED = true, MELEE_MISSED = true, RANGED_MISSED = true }
local MELEE_NAME = "Melee Attack"
-- Spells that would distort the numbers
local IGNORED_SPELLS = {
  ["Reset After Duel"] = true, -- the full heal when a duel ends
}
-- A damage-over-time tick's COMBAT_TEXT arrives right before its COMBAT_MSG
local TICK_PAIR_MS = 200

-- Print handler errors to chat (each distinct error once). Set DPS_METER_DEBUG = true to debug.
local DEBUG = DPS_METER_DEBUG == true

local meter = nil
local tracker = nil
local resolver = nil
local settings = nil
local modeIndex = 1
local scopeIndex = 1
-- 0 = current or last fight, 1..n = earlier fights, "overall" = since the last reset
local view = 0
-- How many rows the meter is scrolled down, and the furthest it can go
local scrollOffset = 0
local maxScroll = 0
local sinceRefresh = 0
local positionApplied = false
-- The latest COMBAT_TEXT, used to credit ticks to their caster
local lastText = nil

local reportedErrors = {}
local function reportError(where, err)
  if not DEBUG then return end
  local msg = "[DPS Meter] " .. where .. ": " .. tostring(err)
  if reportedErrors[msg] then return end
  reportedErrors[msg] = true
  api.Log:Err(msg)
end

local function saveSettings()
  if not positionApplied then return end
  local x, y = meter:getPosition()
  settings.posX = x
  settings.posY = y
  settings.mode = modeIndex
  settings.scope = scopeIndex
  settings.minimized = meter:isMinimized() and 1 or 0
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
  local include = units.SCOPES[scopeIndex].include
  if include == nil then return nil end
  return function(name) return include(resolver, name) end
end

local function redraw()
  local now = api.Time:GetUiMsec()
  units.refresh(resolver)
  local mode = fights.MODES[modeIndex]
  local segment = fights.segment(tracker, view)
  local rows = fights.rows(tracker, segment, mode, now, includeFn())
  local playerName = resolver.playerName

  local ownRank = nil
  for rank, row in ipairs(rows) do
    if row.name == playerName then
      ownRank = rank
      break
    end
  end
  local own = ownRank and rows[ownRank]
  local ownText = "You: " .. fights.format(own and own.value or 0) .. " " .. mode.label
  if ownRank ~= nil then ownText = ownText .. "  #" .. ownRank end

  if meter:isMinimized() then
    meter:setMiniText(ownText)
    return
  end

  local rowCount = meter:rowCount()
  maxScroll = math.max(0, #rows - rowCount)
  scrollOffset = math.max(0, math.min(scrollOffset, maxScroll))
  local top = rows[1] and rows[1].value or 0
  local entries = {}
  for i = 1, rowCount do
    local rank = scrollOffset + i
    -- Keep yourself on the last row whenever you'd otherwise be out of view
    if i == rowCount and ownRank ~= nil and (ownRank <= scrollOffset or ownRank > scrollOffset + rowCount) then
      rank = ownRank
    end
    local row = rows[rank]
    if row ~= nil then
      entries[i] = {
        rank = rank,
        name = row.name,
        text = fights.format(row.value) .. " (" .. fights.percent(row.share) .. ")",
        percent = top > 0 and math.floor(row.value / top * 100) or 0,
        category = units.category(resolver, row.name)
      }
    end
  end

  meter:setHeader(mode.label, viewLabel(), units.SCOPES[scopeIndex].label)
  meter:drawRows(entries)
  meter:setFooter(segment == nil and "Waiting for a fight" or ownText)
  meter:setTimer(fights.formatTime(fights.duration(tracker, segment, now)))
end

local function showDetails(name)
  local mode = fights.MODES[modeIndex]
  local segment = fights.segment(tracker, view)
  local now = api.Time:GetUiMsec()
  meter:showDetails(name .. " - " .. mode.label .. " - " .. viewLabel(),
    fights.detailsText(tracker, segment, mode, name, now))
end

-- The hit type is in the parser's result for melee and in the details for spells
local function isCrit(hitType, detailA, detailB)
  for _, value in pairs({ hitType, detailA, detailB }) do
    if string.find(string.upper(tostring(value)), "CRIT") then return true end
  end
  return false
end

local function positive(value)
  local number = tonumber(value)
  if number == nil then return nil end
  if number < 0 then return -number end
  return number
end

-- COMBAT_MSG: (target unit id, event type, source name, target name, details...)
-- For spells the details are: ?, skill, damage type, amount, ?, hit type, raw amount.
local function onCombatMessage(targetUnitId, combatEvent, source, target, ...)
  local kind = nil
  if DAMAGE_EVENTS[combatEvent] then kind = "damage"
  elseif HEAL_EVENTS[combatEvent] then kind = "heal"
  elseif MISS_EVENTS[combatEvent] then kind = "miss"
  else return end

  local details = { ... }
  -- The game's parser throws on event types it doesn't know, so guard it
  local ok, result = pcall(ParseCombatMessage, combatEvent, ...)
  if not ok or type(result) ~= "table" then result = {} end

  local spell = result.spellName
  if spell == nil or spell == "" then
    if combatEvent == "MELEE_DAMAGE" or combatEvent == "MELEE_MISSED" then
      spell = MELEE_NAME
    else
      spell = details[2] and tostring(details[2]) or MELEE_NAME
    end
  end
  if IGNORED_SPELLS[spell] then return end

  local amount = nil
  if kind == "damage" then
    amount = positive(result.damage) or positive(details[4])
  elseif kind == "heal" then
    amount = positive(result.heal) or positive(details[4])
  end

  if source == "" then source = nil end
  if target == "" then target = nil end
  -- Damage and healing over time name the effect as the source; credit the caster instead,
  -- found through the COMBAT_TEXT that came just before with the same amount
  if source ~= nil and source == spell and lastText ~= nil and amount ~= nil
      and positive(lastText.amount) == amount and api.Time:GetUiMsec() - lastText.at <= TICK_PAIR_MS then
    source = units.nameOf(lastText.sourceId) or source
  end

  fights.record(tracker, {
    kind = kind,
    source = source,
    target = target,
    amount = amount,
    absorbed = positive(result.reduced) or 0,
    spell = spell,
    crit = isCrit(result.hitType, details[6], details[5]),
    involved = units.inGroup(resolver, source) or units.inGroup(resolver, target)
  }, api.Time:GetUiMsec())
end

-- COMBAT_TEXT: (source unit id, target unit id, amount, kind, result)
local function onCombatText(sourceId, targetId, amount)
  lastText = { sourceId = sourceId, targetId = targetId, amount = amount, at = api.Time:GetUiMsec() }
end

local eventHandlers = {
  COMBAT_MSG = onCombatMessage,
  COMBAT_TEXT = onCombatText
}

local function onUpdate(dt)
  if not positionApplied then
    meter:setPosition(settings.posX, settings.posY)
    if settings.minimized == 1 then meter:setMinimized(true) end
    positionApplied = true
  end
  sinceRefresh = sinceRefresh + dt
  if sinceRefresh < REFRESH_MS then return end
  sinceRefresh = 0
  fights.tick(tracker, api.Time:GetUiMsec())
  redraw()
end

-- Save everything recorded so far to a log file, then start over
local function reset()
  local now = api.Time:GetUiMsec()
  if not fights.isEmpty(tracker) then
    local ok, err = pcall(function()
      api.File:Write(string.format(LOG_PATH, now), fights.snapshot(tracker, now))
    end)
    if not ok then reportError("saving the fight log", err) end
  end
  fights.reset(tracker)
  view = 0
  scrollOffset = 0
  redraw()
end

local uiHandlers = {
  onModeClicked = function()
    modeIndex = modeIndex % #fights.MODES + 1
    scrollOffset = 0
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
    scrollOffset = 0
    redraw()
  end,
  onScopeClicked = function()
    scopeIndex = scopeIndex % #units.SCOPES + 1
    scrollOffset = 0
    saveSettings()
    redraw()
  end,
  onReset = reset,
  onRowClicked = showDetails,
  onScroll = function(rows)
    scrollOffset = math.max(0, math.min(scrollOffset + rows, maxScroll))
    redraw()
  end,
  onMinimizedChanged = function()
    saveSettings()
    redraw()
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
  scopeIndex = units.SCOPES[settings.scope] and settings.scope or 1
  tracker = fights.new()
  resolver = units.new()
  view = 0
  scrollOffset = 0
  sinceRefresh = 0
  positionApplied = false
  lastText = nil
  units.refresh(resolver)

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
  -- The mini bar keeps updating while the meter window is hidden
  meter.mini:SetHandler("OnUpdate", function(_, dt)
    if not meter:isMinimized() then return end
    local ok, err = pcall(onUpdate, dt)
    if not ok then reportError("OnUpdate", err) end
  end)
  meter.window:SetHandler("OnUpdate", function(_, dt)
    if meter:isMinimized() then return end
    local ok, err = pcall(onUpdate, dt)
    if not ok then reportError("OnUpdate", err) end
  end)
  redraw()

  api.Log:Info("[DPS Meter] Loaded. Shift + drag the title to move it; click DPS, Current or Group to switch views, and a name for the breakdown.")
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
