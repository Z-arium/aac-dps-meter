-- Fight tracking: splits combat into fights and adds up damage, healing and damage taken per
-- unit name. Pure Lua with no game API calls, so it can be tested outside the game.
local fights = {}

-- A fight ends when nobody we care about has dealt or taken damage or healing for this long
fights.IDLE_MS = 6000
-- How many finished fights are kept for the "Previous" views
fights.HISTORY = 10

-- What each view shows: the total it reads, and whether it is divided by the fight's length
fights.MODES = {
  { id = "dps", label = "DPS", total = "damage", perSecond = true },
  { id = "damage", label = "Damage", total = "damage" },
  { id = "hps", label = "HPS", total = "healing", perSecond = true },
  { id = "healing", label = "Healing", total = "healing" },
  { id = "taken", label = "Damage Taken", total = "taken" },
}

local DAMAGE_EVENTS = { SPELL_DAMAGE = true, SPELL_DOT_DAMAGE = true, MELEE_DAMAGE = true }
local HEAL_EVENTS = { SPELL_HEALED = true }
local MELEE_NAME = "Melee Attack"

-- Spells that would distort the numbers
local IGNORED_SPELLS = {
  ["Reset After Duel"] = true, -- the full heal when a duel ends
}

local TOTALS = { "damage", "healing", "taken" }

-- Whether a COMBAT_MSG type is worth parsing at all
function fights.isTracked(combatEvent)
  return DAMAGE_EVENTS[combatEvent] == true or HEAL_EVENTS[combatEvent] == true
end

local function newSegment(label, now)
  local segment = { label = label, startTime = now, lastTime = now, skills = {} }
  for _, name in ipairs(TOTALS) do
    segment[name] = {}
    segment.skills[name] = {}
  end
  return segment
end

local function add(segment, totalName, unitName, spellName, amount)
  local totals = segment[totalName]
  totals[unitName] = (totals[unitName] or 0) + amount
  local bySpell = segment.skills[totalName][unitName]
  if bySpell == nil then
    bySpell = {}
    segment.skills[totalName][unitName] = bySpell
  end
  bySpell[spellName] = (bySpell[spellName] or 0) + amount
end

function fights.new()
  local tracker = {}
  fights.reset(tracker)
  return tracker
end

-- Forget everything, including the overall totals
function fights.reset(tracker)
  tracker.current = nil
  tracker.history = {}
  tracker.overall = nil
end

-- Close the current fight if it has been idle for IDLE_MS. Returns true if a fight ended.
function fights.tick(tracker, now)
  local current = tracker.current
  if current == nil or now - current.lastTime < fights.IDLE_MS then return false end
  table.insert(tracker.history, 1, current)
  while #tracker.history > fights.HISTORY do
    table.remove(tracker.history)
  end
  tracker.current = nil
  return true
end

-- Record one combat message.
--   combatEvent  COMBAT_MSG type, e.g. "SPELL_DAMAGE"
--   source       name of whoever caused it, target  name of whoever it hit
--   result       the table ParseCombatMessage returned
--   involved     true when the source or target is you or a group member; only those
--                start a fight or keep it going, so fights nearby don't stretch yours
function fights.record(tracker, combatEvent, source, target, result, involved, now)
  if type(result) ~= "table" then return end
  local spellName = result.spellName
  if spellName ~= nil and IGNORED_SPELLS[spellName] then return end
  if spellName == nil or spellName == "" then spellName = MELEE_NAME end
  local hasSource = source ~= nil and source ~= ""
  local hasTarget = target ~= nil and target ~= ""

  local entries = {}
  if DAMAGE_EVENTS[combatEvent] then
    local damage = tonumber(result.damage)
    if damage == nil then return end
    if damage < 0 then damage = -damage end -- damage arrives as a negative number
    if hasSource then entries[#entries + 1] = { "damage", source, damage } end
    if hasTarget then entries[#entries + 1] = { "taken", target, damage } end
  elseif HEAL_EVENTS[combatEvent] then
    local heal = tonumber(result.heal)
    if heal == nil or not hasSource then return end
    entries[#entries + 1] = { "healing", source, heal }
  end
  if #entries == 0 then return end

  fights.tick(tracker, now)
  if tracker.current == nil then
    if not involved then return end
    tracker.current = newSegment("Fight", now)
  end
  if tracker.overall == nil then
    tracker.overall = newSegment("Overall", now)
  end

  for _, segment in ipairs({ tracker.current, tracker.overall }) do
    for _, entry in ipairs(entries) do
      add(segment, entry[1], entry[2], spellName, entry[3])
    end
  end
  if involved then tracker.current.lastTime = now end
  tracker.overall.lastTime = now
end

-- The segment a view index points at: 0 = the fight in progress (or the last one if
-- none is), 1..HISTORY = earlier fights, "overall" = everything since the last reset
function fights.segment(tracker, view)
  if view == "overall" then return tracker.overall end
  if view == 0 then return tracker.current or tracker.history[1] end
  local offset = tracker.current ~= nil and 0 or 1
  return tracker.history[view + offset]
end

-- How many "Previous" views have a fight behind them
function fights.previousCount(tracker)
  local count = #tracker.history
  if tracker.current == nil and count > 0 then count = count - 1 end
  return count
end

-- Length of a segment in ms. A fight still in progress runs until now; the overall segment
-- counts only time spent in fights, so walking between packs doesn't lower your DPS.
function fights.duration(tracker, segment, now)
  if segment == nil then return 0 end
  if segment == tracker.overall then
    local total = 0
    for _, fight in ipairs(tracker.history) do
      total = total + (fight.lastTime - fight.startTime)
    end
    if tracker.current ~= nil then
      total = total + (now - tracker.current.startTime)
    end
    return total
  end
  if segment == tracker.current then
    return now - segment.startTime
  end
  return segment.lastTime - segment.startTime
end

local function seconds(ms)
  -- At least a second, so the first hit doesn't show an absurd rate
  return math.max(ms, 1000) / 1000
end

-- Rows for a view: list of { name, value, share } sorted highest first.
-- `include(name)` decides which units are listed (nil lists everyone).
function fights.rows(tracker, segment, mode, now, include)
  local rows = {}
  if segment == nil then return rows end
  local totals = segment[mode.total]
  local divisor = 1
  if mode.perSecond then divisor = seconds(fights.duration(tracker, segment, now)) end
  local sum = 0
  for name, amount in pairs(totals) do
    if include == nil or include(name) then
      rows[#rows + 1] = { name = name, value = math.floor(amount / divisor), amount = amount }
      sum = sum + amount
    end
  end
  table.sort(rows, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return a.name < b.name
  end)
  for _, row in ipairs(rows) do
    row.share = sum > 0 and row.amount / sum or 0
  end
  return rows
end

-- One unit's skills for a mode: list of { name, amount, share } sorted highest first
function fights.skills(segment, mode, unitName)
  local list = {}
  if segment == nil then return list end
  local bySpell = segment.skills[mode.total][unitName] or {}
  local total = 0
  for spellName, amount in pairs(bySpell) do
    list[#list + 1] = { name = spellName, amount = amount }
    total = total + amount
  end
  table.sort(list, function(a, b) return a.amount > b.amount end)
  for _, skill in ipairs(list) do
    skill.share = total > 0 and skill.amount / total or 0
  end
  return list
end

-- 950 -> "950", 12345 -> "12.3k", 1234567 -> "1.23m"
function fights.format(number)
  if number >= 1000000 then
    return string.format("%.2fm", number / 1000000)
  elseif number >= 10000 then
    return string.format("%.1fk", number / 1000)
  end
  return tostring(math.floor(number))
end

-- 75000 -> "1:15"
function fights.formatTime(ms)
  local total = math.floor(ms / 1000)
  return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

return fights
