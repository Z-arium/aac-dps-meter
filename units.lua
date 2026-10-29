-- Who is who. Combat messages only carry names, and the addon API only describes units it has
-- a token for (you, your target, party/raid members), so everything learnt is remembered by
-- name for the rest of the session.
local api = require("api")
local units = {}

local MAX_TEAM_MEMBERS = 50

function units.new()
  return {
    playerName = nil,
    -- Names of you and your party/raid members right now
    group = {},
    -- name -> { type = "character" | ..., faction = "hostile" | ... }, kept all session
    known = {}
  }
end

local function lookup(token)
  local id = api.Unit:GetUnitId(token)
  if id == nil then return nil end
  local name = api.Unit:GetUnitNameById(id)
  if name == nil or name == "" then return nil end
  return name, id
end

local function learn(resolver, name, id)
  local ok, info = pcall(function() return api.Unit:GetUnitInfoById(id) end)
  if not ok or type(info) ~= "table" then return end
  local known = resolver.known[name] or {}
  -- Only overwrite with real values, so partial info never wipes what we learnt
  if info.type ~= nil then known.type = info.type end
  if info.faction ~= nil then known.faction = info.faction end
  resolver.known[name] = known
end

-- Re-read the tokens. Called on every redraw.
function units.refresh(resolver)
  local group = {}
  local name, id = lookup("player")
  if name ~= nil then
    resolver.playerName = name
    group[name] = true
    learn(resolver, name, id)
  end
  name, id = lookup("target")
  if name ~= nil then learn(resolver, name, id) end
  for i = 1, MAX_TEAM_MEMBERS do
    name, id = lookup("team" .. i)
    if name ~= nil then
      group[name] = true
      learn(resolver, name, id)
    end
  end
  resolver.group = group
end

-- Name of a unit id, for crediting damage-over-time ticks to their caster
function units.nameOf(id)
  if id == nil then return nil end
  local ok, name = pcall(function() return api.Unit:GetUnitNameById(id) end)
  if ok and type(name) == "string" and name ~= "" then return name end
  return nil
end

function units.inGroup(resolver, name)
  return resolver.group[name] == true
end

-- "self", "group", "hostile" (hostile player), "player", "hostileNpc", "npc" or "unknown"
function units.category(resolver, name)
  if name == resolver.playerName then return "self" end
  if resolver.group[name] then return "group" end
  local known = resolver.known[name]
  if known == nil or known.type == nil then return "unknown" end
  local hostile = known.faction == "hostile"
  if known.type == "character" then return hostile and "hostile" or "player" end
  return hostile and "hostileNpc" or "npc"
end

-- Which units a scope lists
units.SCOPES = {
  { label = "Group", include = function(resolver, name) return resolver.group[name] == true end },
  { label = "Players", include = function(resolver, name)
      if resolver.group[name] then return true end
      local known = resolver.known[name]
      return known ~= nil and known.type == "character"
    end },
  { label = "All", include = nil },
}

return units
