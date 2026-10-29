"""Tests for the DPS Meter addon, run under Lua 5.1 through lupa.

    pip install lupa
    python3 -m unittest discover -s tests
"""
import pathlib
import unittest

from lupa import lua51

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODULES = ("fights", "units", "ui", "main")

# A stand-in for the game: every widget method exists and returns another stub, and the
# api table records events, files and settings so the test can drive the addon.
MOCK = r"""
local function stub()
  local s = {}
  local mt = {}
  mt.__index = function(t, k)
    local v = stub()
    rawset(t, k, v)
    return v
  end
  mt.__call = function() return stub() end
  setmetatable(s, mt)
  return s
end

local now = 1000
local windows = {}
-- Widgets have capitalised methods and a few built-in children; other fields start out nil
local BUILT_IN = { style = true, bg = true, statusBar = true }
local function window()
  local w = {}
  setmetatable(w, { __index = function(t, k)
    if string.match(k, "^%u") or BUILT_IN[k] then
      local v = stub()
      rawset(t, k, v)
      return v
    end
    return nil
  end })
  w.handlers = {}
  w.shown = true
  function w:SetHandler(name, fn) self.handlers[name] = fn end
  function w:GetOffset() return 10, 20 end
  function w:SetText(text) self.text = text end
  function w:Show(on) self.shown = on end
  function w:IsVisible() return self.shown end
  function w:CreateChildWidget() return window() end
  windows[#windows + 1] = w
  return w
end

-- Unit ids: 1 = you, 101.. = team members, 200 = your target
local team = {}
local names = { [1] = "Me", [200] = "Enemy" }
local infos = { [1] = { type = "character", faction = "friendly" }, [200] = { type = "character", faction = "hostile" } }
errors = {}
files = {}
DPS_METER_DEBUG = true
api = {
  Log = { Info = function() end, Err = function(_, m) table.insert(errors, m) end },
  Time = { GetUiMsec = function() return now end },
  Input = { IsShiftKeyDown = function() return false end },
  Cursor = stub(),
  File = { Write = function(_, path, data) files[path] = data end },
  Unit = {
    GetUnitId = function(_, token)
      if token == "player" then return 1 end
      if token == "target" then return 200 end
      local i = tonumber(string.match(token, "^team(%d+)$") or "")
      if i and team[i] then return 100 + i end
      return nil
    end,
    GetUnitNameById = function(_, id)
      if names[id] then return names[id] end
      if id > 100 and id < 200 then return team[id - 100] end
      return nil
    end,
    GetUnitInfoById = function(_, id)
      return infos[id] or { type = "character", faction = "friendly" }
    end,
  },
  Interface = {
    CreateEmptyWindow = function() return window() end,
    CreateWindow = function() return window() end,
    CreateWidget = function() return window() end,
    CreateStatusBar = function() return window() end,
    ApplyButtonSkin = function() end,
    Free = function() end,
  },
  settings = {},
  saved = 0,
}
function api.GetSettings() return api.settings end
function api.SaveSettings() api.saved = api.saved + 1 end

ALIGN = stub(); FONT_COLOR = stub(); FONT_SIZE = stub(); TEXTURE_PATH = stub()
BUTTON_BASIC = stub(); CURSOR_PATH = stub()
W_CTRL = { CreateMultiLineEdit = function() return window() end }
ConvertColor = function(v) return v / 255 end
ApplyTextColor = function() end
GetTextureInfo = function() return stub() end
-- Same argument layout as the game: (type, ?, skill, damage type, amount, ?, hit type)
ParseCombatMessage = function(event, _, skill, _, amount, _, hit)
  if event == "SPELL_HEALED" then return { heal = amount, spellName = skill } end
  if event == "SPELL_MISSED" then return { spellName = skill } end
  if event == "MELEE_DAMAGE" then return { damage = amount, reduced = -5, hitType = hit } end
  if event == "UNKNOWN_THING" then error("unknown combat event") end
  return { damage = amount, reduced = -10, spellName = skill }
end

harness = {
  advance = function(ms) now = now + ms end,
  setTeam = function(list) team = list end,
  setName = function(id, name) names[id] = name end,
  windows = windows,
}
"""


def runtime():
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(MOCK)
    # The game's require resolves "dps_meter/x" inside the Addon folder, and "api" to the api table
    lua.execute('package.preload["api"] = function() return api end')
    load = lua.eval("function(name, path) package.preload['dps_meter/' .. name] = function() return dofile(path) end end")
    for name in MODULES:
        load(name, str(ROOT / f"{name}.lua"))
    return lua


class FightsTest(unittest.TestCase):
    def setUp(self):
        self.lua = runtime()
        self.lua.execute(
            """
            fights = require("dps_meter/fights")
            t = fights.new()
            function hit(src, dst, amount, spell, involved, at, crit, absorbed)
              fights.record(t, { kind = "damage", source = src, target = dst, amount = amount,
                spell = spell, involved = involved, crit = crit, absorbed = absorbed }, at)
            end
            function mode(id)
              for _, m in ipairs(fights.MODES) do if m.id == id then return m end end
            end
            """
        )
        self.run = self.lua.execute
        self.eval = self.lua.eval

    def test_dps_uses_fight_length(self):
        self.run('hit("Me", "Mob", 1000, "Bolt", true, 0); hit("Me", "Mob", 1000, "Bolt", true, 4000)')
        self.run('rows = fights.rows(t, fights.segment(t, 0), mode("dps"), 4000)')
        self.assertEqual(self.eval("rows[1].name"), "Me")
        self.assertEqual(self.eval("rows[1].value"), 500)  # 2000 damage over 4s
        self.assertEqual(self.eval("#rows"), 1)  # the mob dealt nothing
        self.assertEqual(self.eval('fights.rows(t, t.current, mode("taken"), 4000)[1].name'), "Mob")

    def test_idle_ends_fight_and_starts_new_one(self):
        self.run('hit("Me", "Mob", 100, "Bolt", true, 0)')
        self.run('hit("Me", "Mob", 300, "Bolt", true, 20000)')
        self.assertEqual(self.eval("#t.history"), 1)
        self.assertEqual(self.eval("t.current.units.Me.damage"), 300)
        self.assertEqual(self.eval("fights.segment(t, 1).units.Me.damage"), 100)
        self.assertEqual(self.eval("t.overall.units.Me.damage"), 400)
        # Overall time counts only time in fights: 0s + 2s now
        self.assertEqual(self.eval("fights.duration(t, t.overall, 22000)"), 2000)

    def test_bystanders_do_not_start_or_extend_fights(self):
        self.run('hit("Stranger", "Mob", 100, "Bolt", false, 0)')
        self.assertIsNone(self.eval("t.current"))
        self.run('hit("Me", "Mob", 100, "Bolt", true, 1000)')
        self.run('hit("Stranger", "Mob", 50, "Bolt", false, 5000)')
        self.assertEqual(self.eval("t.current.units.Stranger.damage"), 50)
        self.assertEqual(self.eval("t.current.lastTime"), 1000)
        self.assertTrue(self.eval("fights.tick(t, 7000)"))

    def test_scope_filter_and_shares(self):
        self.run('hit("Me", "Mob", 300, "Bolt", true, 0); hit("Other", "Mob", 100, "Bolt", false, 0)')
        self.run('rows = fights.rows(t, t.current, mode("damage"), 0, function(n) return n == "Me" end)')
        self.assertEqual(self.eval("#rows"), 1)
        self.assertEqual(self.eval("rows[1].share"), 1)
        self.run('rows = fights.rows(t, t.current, mode("damage"), 0)')
        self.assertEqual(self.eval("rows[1].share"), 0.75)

    def test_skill_stats_crits_targets_absorbed(self):
        self.run('hit("Me", "Mob", 300, "Bolt", true, 0, true, 40)')
        self.run('hit("Me", "Mob", 100, "Bolt", true, 0, false, 20)')
        self.run('hit("Me", "Boss", 600, "Smite", true, 0, false, 0)')
        self.run('fights.record(t, { kind = "miss", source = "Me", target = "Mob", spell = "Bolt", involved = true }, 0)')
        self.run('s = fights.skills(t.current, mode("damage"), "Me")')
        self.assertEqual(self.eval("s[1].name"), "Smite")
        self.assertEqual(self.eval("s[2].hits"), 2)
        self.assertEqual(self.eval("s[2].crits"), 1)
        self.assertEqual(self.eval("s[2].max"), 300)
        self.assertEqual(self.eval("t.current.units.Me.misses"), 1)
        self.assertEqual(self.eval("t.current.units.Mob.absorbed"), 60)
        self.assertEqual(self.eval('fights.rows(t, t.current, mode("absorbed"), 0)[1].name'), "Mob")
        self.assertEqual(self.eval('fights.targets(t.current, "Me")[1].name'), "Boss")
        text = self.eval('fights.detailsText(t, t.current, mode("damage"), "Me", 2000)')
        self.assertIn("Crit 33%", text)
        self.assertIn("Missed 25%", text)
        self.assertIn("2. Bolt  400  40%  x2  50%  avg 200  max 300", text)
        self.assertIn("1. Boss  600  60%", text)
        text = self.eval('fights.detailsText(t, t.current, mode("absorbed"), "Mob", 2000)')
        self.assertIn("Absorbed 60 (13% of incoming)", text)
        self.assertIn("Bolt", text)

    def test_heals_and_bad_events(self):
        self.run('fights.record(t, { kind = "heal", source = "Me", target = "Me", amount = 500, spell = "Mend", involved = true }, 0)')
        self.assertEqual(self.eval("t.current.units.Me.healing"), 500)
        self.run('fights.record(t, { kind = "damage", source = "Me", target = "Mob", spell = "Bolt", involved = true }, 0)')
        self.run('fights.record(t, { kind = "heal", target = "Me", amount = 5, spell = "Mend", involved = true }, 0)')
        self.assertEqual(self.eval("t.current.units.Me.damage"), 0)
        self.assertIsNone(self.eval("t.current.units.Mob"))

    def test_history_is_capped_and_snapshot(self):
        self.run("for i = 1, 15 do hit('Me', 'Mob', i, 'Bolt', true, i * 10000) end; fights.tick(t, 1e9)")
        self.assertEqual(self.eval("#t.history"), 10)
        self.assertEqual(self.eval("fights.previousCount(t)"), 9)
        self.run("snap = fights.snapshot(t, 1e9)")
        self.assertEqual(self.eval("#snap.fights"), 10)
        self.assertEqual(self.eval("snap.fights[10].units.Me.damage"), 15)  # newest last

    def test_format(self):
        self.assertEqual(self.eval("fights.format(950)"), "950")
        self.assertEqual(self.eval("fights.format(12345)"), "12.3k")
        self.assertEqual(self.eval("fights.format(1234567)"), "1.23m")
        self.assertEqual(self.eval("fights.formatTime(75000)"), "1:15")
        self.assertEqual(self.eval("fights.percent(0.256)"), "26%")


class AddonSmokeTest(unittest.TestCase):
    """Loads main.lua against the mocked API and drives it like the game would."""

    def setUp(self):
        self.lua = lua = runtime()
        lua.execute(
            """
            addon = require("dps_meter/main")
            harness.setTeam({ "Buddy" })
            addon.OnLoad()
            meterWnd = harness.windows[1]
            onEvent = function(...) meterWnd.handlers.OnEvent(meterWnd, ...) end
            onUpdate = function(dt) meterWnd.handlers.OnUpdate(meterWnd, dt) end
            function texts()
              local out = {}
              for _, w in ipairs(harness.windows) do
                if w.text then out[#out + 1] = w.text end
              end
              return out
            end
            function clickLabel(text)
              for _, w in ipairs(harness.windows) do
                if w.text == text and w.handlers.OnClick then w.handlers.OnClick(); return true end
              end
              return false
            end
            """
        )

    def texts(self):
        values = list(self.lua.eval("texts()").values())
        bad = [v for v in values if not isinstance(v, str)]
        self.assertEqual(bad, [], "SetText got something other than a string")
        return values

    def assertNoErrors(self):
        self.assertEqual(self.lua.eval("#errors"), 0, self.lua.eval("errors[1]"))

    def test_fight_is_drawn_with_categories_and_breakdown(self):
        lua = self.lua
        lua.execute(
            """
            onEvent("COMBAT_MSG", 5, "SPELL_DAMAGE", "Me", "Mob", "x", "Bolt", "MAGIC", -400, "x", "CRITICAL")
            onEvent("COMBAT_MSG", 5, "MELEE_DAMAGE", "Buddy", "Mob", "x", "x", "x", -200, "x", "HIT")
            onEvent("COMBAT_MSG", 5, "SPELL_HEALED", "Buddy", "Me", "x", "Mend", "x", 50)
            onEvent("COMBAT_MSG", 5, "SPELL_MISSED", "Me", "Mob", "x", "Bolt", "x", "DODGE")
            onEvent("COMBAT_MSG", 5, "SPELL_DAMAGE", "Enemy", "Me", "x", "Stab", "x", -100, "x", "HIT")
            onEvent("COMBAT_MSG", 5, "UNKNOWN_THING", "Me", "Mob")
            onEvent("CHAT_MESSAGE", "ignored")
            harness.advance(2000)
            onUpdate(600)
            """
        )
        self.assertNoErrors()
        texts = self.texts()
        self.assertIn("1. Me", texts)
        self.assertIn("2. Buddy", texts)
        self.assertIn("200 (67%)", texts)  # 400 damage over 2s, 2/3 of the group's damage
        self.assertIn("You: 200 DPS  #1", texts)
        self.assertNotIn("3. Enemy", texts)  # Group scope hides the hostile player

        lua.execute('clickLabel("Group")')  # -> Players
        lua.execute("onUpdate(600)")
        self.assertIn("3. Enemy", self.texts())
        lua.execute('clickLabel("1. Me")')
        details = [t for t in self.texts() if t.startswith("Damage 400")]
        self.assertTrue(details, self.texts())
        self.assertIn("Crit 100%", details[0])
        self.assertIn("Missed 50%", details[0])
        self.assertIn("Me - DPS - Current", self.texts())
        self.assertNoErrors()

    def test_dot_ticks_are_credited_to_the_caster(self):
        self.lua.execute(
            """
            harness.setName(77, "Me")
            onEvent("COMBAT_MSG", 5, "SPELL_DAMAGE", "Me", "Mob", "x", "Bolt", "x", -10, "x", "HIT")
            onEvent("COMBAT_TEXT", 77, 5, -30, "DOT")
            onEvent("COMBAT_MSG", 5, "SPELL_DOT_DAMAGE", "Poison", "Mob", "x", "Poison", "x", -30, "x", "HIT")
            harness.advance(1000)
            onUpdate(600)
            """
        )
        self.assertIn("1. Me", self.texts())
        self.assertNotIn("2. Poison", self.texts())
        self.lua.execute('clickLabel("1. Me")')
        self.assertTrue(any("Poison" in t for t in self.texts()))
        self.assertNoErrors()

    def test_every_control_minimize_reset_unload(self):
        lua = self.lua
        lua.execute(
            """
            onEvent("COMBAT_MSG", 5, "SPELL_DAMAGE", "Me", "Mob", "x", "Bolt", "x", -400, "x", "HIT")
            harness.advance(1000)
            onUpdate(600)
            clicks = 0
            for _, w in ipairs(harness.windows) do
              for _, name in ipairs({ "OnClick", "OnWheelUp", "OnWheelDown" }) do
                if w.handlers[name] then w.handlers[name](); clicks = clicks + 1 end
              end
            end
            """
        )
        self.assertGreater(lua.eval("clicks"), 20)
        self.assertNoErrors()
        # Minimize, and the mini bar keeps showing your number
        lua.execute('clickLabel("+")')
        lua.execute('clickLabel("_")')
        self.assertTrue(lua.eval("harness.windows[1].shown == false"))
        lua.execute(
            """
            for _, w in ipairs(harness.windows) do
              if w ~= meterWnd and w.handlers.OnUpdate then w.handlers.OnUpdate(w, 600) end
            end
            """
        )
        self.assertTrue(any(t.startswith("You: ") for t in self.texts()))
        self.assertEqual(lua.eval("api.settings.minimized"), 1)
        lua.execute('clickLabel("+")')
        self.assertEqual(lua.eval("api.settings.minimized"), 0)
        # Reset saved a log first (the click-everything pass pressed reset)
        self.assertEqual(len(list(lua.eval("files").keys())), 1)
        lua.execute("addon.OnUnload()")
        self.assertNoErrors()
        self.assertEqual(lua.eval("api.settings.posX"), 10)

    def test_errors_in_handlers_are_contained(self):
        self.lua.execute(
            """
            units = require("dps_meter/units")
            units.inGroup = function() error("boom") end
            onEvent("COMBAT_MSG", 5, "SPELL_DAMAGE", "Me", "Mob", "x", "Bolt", "x", -1, "x", "HIT")
            """
        )
        self.assertIn("boom", self.lua.eval("errors[1]"))


if __name__ == "__main__":
    unittest.main()
