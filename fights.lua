-- Fight tracking: splits combat into fights and adds up damage, healing, damage taken and
-- damage absorbed per unit name, with per-skill and per-target detail. Pure Lua with no game
-- API calls, so it can be tested outside the game.
local fights = {}

-- A fight ends when nobody we care about has dealt or taken damage or healing for this long
fights.IDLE_MS = 6000
-- How many finished fights are kept for the "Previous" views
fights.HISTORY = 10

-- What each view shows: the per-unit total it reads, whether it is divided by the fight's
-- length, and which breakdown a click on a row opens
fights.MODES = {
  { id = "dps", label = "DPS", total = "damage", perSecond = true },
  { id = "damage", label = "Damage", total = "damage" },
  { id = "hps", label = "HPS", total = "healing", perSecond = true },
  { id = "healing", label = "Healing", total = "healing" },
  { id = "taken", label = "Damage Taken", total = "taken" },
  { id = "absorbed", label = "Absorbed", total = "absorbed", details = "taken" },
}

local TOTALS = { "damage", "healing", "taken", "absorbed" }
-- Breakdowns kept per unit: what they dealt, healed and took, by skill
local BREAKDOWNS = { "damage", "healing", "taken" }

-- One unit's numbers in one segment
local function newUnit()
  local unit = { hits = 0, crits = 0, misses = 0, skills = {}, targets = {} }
  for _, name in ipairs(TOTALS) do unit[name] = 0 end
  for _, name in ipairs(BREAKDOWNS) do unit.skills[name] = {} end
  return unit
end

local function newSegment(label, now)
  return { label = label, startTime = now, lastTime = now, units = {} }
end

local function unitIn(segment, name)
  local unit = segment.units[name]
  if unit == nil then
    unit = newUnit()
    segment.units[name] = unit
  end
  return unit
end

local function addSkill(unit, breakdown, spell, amount, crit)
  local skills = unit.skills[breakdown]
  local skill = skills[spell]
  if skill == nil then
    skill = { amount = 0, hits = 0, crits = 0, max = 0 }
    skills[spell] = skill
  end
  skill.amount = skill.amount + amount
  skill.hits = skill.hits + 1
  if crit then skill.crits = skill.crits + 1 end
  if amount > skill.max then skill.max = amount end
end

-- Add one event to one segment (see fights.record for the event's fields)
local function apply(segment, event)
  local source = event.source
  local target = event.target
  if event.kind == "damage" then
    if source ~= nil then
      local unit = unitIn(segment, source)
      unit.damage = unit.damage + event.amount
      unit.hits = unit.hits + 1
      if event.crit then unit.crits = unit.crits + 1 end
      addSkill(unit, "damage", event.spell, event.amount, event.crit)
      if target ~= nil then
        unit.targets[target] = (unit.targets[target] or 0) + event.amount
      end
    end
    if target ~= nil then
      local unit = unitIn(segment, target)
      unit.taken = unit.taken + event.amount
      unit.absorbed = unit.absorbed + (event.absorbed or 0)
      addSkill(unit, "taken", event.spell, event.amount, event.crit)
    end
  elseif event.kind == "heal" then
    local unit = unitIn(segment, source)
    unit.healing = unit.healing + event.amount
    addSkill(unit, "healing", event.spell, event.amount, event.crit)
  elseif event.kind == "miss" then
    local unit = unitIn(segment, source)
    unit.misses = unit.misses + 1
  end
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

function fights.isEmpty(tracker)
  return tracker.overall == nil
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

-- Record one combat event:
--   kind      "damage", "heal" or "miss"
--   source    who did it, target  who it hit (either may be nil)
--   amount    damage or healing, positive
--   absorbed  damage the target's armour and resistances took off (damage only)
--   spell     skill name, crit  true for a critical hit
--   involved  true when the source or target is you or a group member; only those start a
--             fight or keep it going, so fights nearby don't stretch yours
function fights.record(tracker, event, now)
  if event.kind ~= "miss" and (event.amount == nil or event.amount <= 0) then return end
  if event.kind ~= "damage" and event.source == nil then return end
  if event.source == nil and event.target == nil then return end

  fights.tick(tracker, now)
  if tracker.current == nil then
    if not event.involved or event.kind == "miss" then return end
    tracker.current = newSegment("Fight", now)
  end
  if tracker.overall == nil then
    tracker.overall = newSegment("Overall", now)
  end

  apply(tracker.current, event)
  apply(tracker.overall, event)
  if event.involved then tracker.current.lastTime = now end
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

-- Rows for a view: list of { name, value, amount, share } sorted highest first, leaving out
-- units with nothing to show. `include(name)` decides which units are listed (nil lists all).
function fights.rows(tracker, segment, mode, now, include)
  local rows = {}
  if segment == nil then return rows end
  local divisor = 1
  if mode.perSecond then divisor = seconds(fights.duration(tracker, segment, now)) end
  local sum = 0
  for name, unit in pairs(segment.units) do
    local amount = unit[mode.total]
    if amount > 0 and (include == nil or include(name)) then
      rows[#rows + 1] = { name = name, value = math.floor(amount / divisor), amount = amount }
      sum = sum + amount
    end
  end
  table.sort(rows, function(a, b)
    if a.amount ~= b.amount then return a.amount > b.amount end
    return a.name < b.name
  end)
  for _, row in ipairs(rows) do
    row.share = sum > 0 and row.amount / sum or 0
  end
  return rows
end

local function sortedByAmount(map, amountOf)
  local list = {}
  local total = 0
  for name, entry in pairs(map) do
    local amount = amountOf(entry)
    list[#list + 1] = { name = name, amount = amount, entry = entry }
    total = total + amount
  end
  table.sort(list, function(a, b)
    if a.amount ~= b.amount then return a.amount > b.amount end
    return a.name < b.name
  end)
  for _, item in ipairs(list) do
    item.share = total > 0 and item.amount / total or 0
  end
  return list
end

-- One unit's skills for a mode: list of { name, amount, share, hits, crits, max } sorted
-- highest first
function fights.skills(segment, mode, unitName)
  if segment == nil or segment.units[unitName] == nil then return {} end
  local breakdown = mode.details or mode.total
  local list = sortedByAmount(segment.units[unitName].skills[breakdown] or {}, function(s) return s.amount end)
  for _, item in ipairs(list) do
    item.hits, item.crits, item.max = item.entry.hits, item.entry.crits, item.entry.max
    item.entry = nil
  end
  return list
end

-- Who a unit damaged: list of { name, amount, share } sorted highest first
function fights.targets(segment, unitName)
  if segment == nil or segment.units[unitName] == nil then return {} end
  local list = sortedByAmount(segment.units[unitName].targets, function(amount) return amount end)
  for _, item in ipairs(list) do item.entry = nil end
  return list
end

-- A unit's totals in a segment (zeros if it isn't there)
function fights.unit(segment, unitName)
  if segment == nil or segment.units[unitName] == nil then return newUnit() end
  return segment.units[unitName]
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

-- 0.256 -> "26%"
function fights.percent(fraction)
  return math.floor(fraction * 100 + 0.5) .. "%"
end

-- Text for the breakdown window when a row is clicked
function fights.detailsText(tracker, segment, mode, unitName, now)
  local unit = fights.unit(segment, unitName)
  local secs = seconds(fights.duration(tracker, segment, now))
  local lines = {}
  if mode.total == "damage" then
    local swings = unit.hits + unit.misses
    lines[#lines + 1] = string.format("Damage %s  |  DPS %s  |  Crit %s  |  Missed %s",
      fights.format(unit.damage), fights.format(unit.damage / secs),
      fights.percent(unit.hits > 0 and unit.crits / unit.hits or 0),
      fights.percent(swings > 0 and unit.misses / swings or 0))
  elseif mode.total == "healing" then
    lines[#lines + 1] = string.format("Healing %s  |  HPS %s",
      fights.format(unit.healing), fights.format(unit.healing / secs))
  else
    local hitFor = unit.taken + unit.absorbed
    lines[#lines + 1] = string.format("Taken %s  |  Absorbed %s (%s of incoming)",
      fights.format(unit.taken), fights.format(unit.absorbed),
      fights.percent(hitFor > 0 and unit.absorbed / hitFor or 0))
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Skills (amount, share, hits, crit, average, biggest):"
  for i, skill in ipairs(fights.skills(segment, mode, unitName)) do
    lines[#lines + 1] = string.format("%d. %s  %s  %s  x%d  %s  avg %s  max %s", i, skill.name,
      fights.format(skill.amount), fights.percent(skill.share), skill.hits,
      fights.percent(skill.hits > 0 and skill.crits / skill.hits or 0),
      fights.format(skill.hits > 0 and skill.amount / skill.hits or 0), fights.format(skill.max))
  end

  if mode.total == "damage" then
    local targets = fights.targets(segment, unitName)
    if #targets > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Targets:"
      for i, target in ipairs(targets) do
        lines[#lines + 1] = string.format("%d. %s  %s  %s", i, target.name,
          fights.format(target.amount), fights.percent(target.share))
      end
    end
  end
  return table.concat(lines, "\n")
end

-- What gets written to the log file when the meter is reset
function fights.snapshot(tracker, now)
  local fightsOut = {}
  for i = #tracker.history, 1, -1 do
    fightsOut[#fightsOut + 1] = tracker.history[i]
  end
  if tracker.current ~= nil then fightsOut[#fightsOut + 1] = tracker.current end
  return {
    savedAt = now,
    overallMs = fights.duration(tracker, tracker.overall, now),
    overall = tracker.overall,
    fights = fightsOut
  }
end

return fights
