"""Tests for the DPS Meter addon, run under Lua 5.1 through lupa.

    pip install lupa
    python3 -m unittest discover -s tests
"""
import pathlib
import unittest

from lupa import lua51

ROOT = pathlib.Path(__file__).resolve().parent.parent

# A stand-in for the game: every widget method exists and returns another stub, and the
# api table records events and settings so the test can drive the addon.
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
  function w:SetHandler(name, fn) self.handlers[name] = fn end
  function w:GetOffset() return 10, 20 end
  function w:SetText(text) self.text = text end
  function w:CreateChildWidget() return window() end
  windows[#windows + 1] = w
  return w
end

local team = {}
errors = {}
DPS_METER_DEBUG = true
api = {
  Log = { Info = function() end, Err = function(_, m) table.insert(errors, m) end },
  Time = { GetUiMsec = function() return now end },
  Input = { IsShiftKeyDown = function() return false end },
  Cursor = stub(),
  Unit = {
    GetUnitId = function(_, token)
      if token == "player" then return 1 end
      local i = tonumber(string.match(token, "^team(%d+)$") or "")
      if i and team[i] then return 100 + i end
      return nil
    end,
    GetUnitNameById = function(_, id)
      if id == 1 then return "Me" end
      return team[id - 100]
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
ParseCombatMessage = function(event, damage, spell)
  if event == "SPELL_HEALED" then return { heal = damage, spellName = spell } end
  return { damage = -damage, reduced = 0, spellName = spell }
end

harness = {
  advance = function(ms) now = now + ms end,
  setTeam = function(names) team = names end,
  windows = windows,
}
"""


def runtime():
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(MOCK)
    # The game's require resolves "dps_meter/x" inside the Addon folder, and "api" to the api table
    lua.execute(
        """
        local root = ...
        package.preload["api"] = function() return api end
        for _, name in ipairs({ "fights", "ui", "main" }) do
          package.preload["dps_meter/" .. name] = function()
            return dofile(root .. "/" .. name .. ".lua")
          end
        end
        """.replace("...", repr(str(ROOT)))
    )
    return lua


class FightsTest(unittest.TestCase):
    def setUp(self):
        self.lua = runtime()
        self.lua.execute(
            """
            fights = require("dps_meter/fights")
            t = fights.new()
            function hit(src, dst, amount, spell, involved, at)
              fights.record(t, "SPELL_DAMAGE", src, dst, { damage = -amount, spellName = spell }, involved, at)
            end
            """
        )
        self.run = self.lua.execute
        self.eval = self.lua.eval

    def test_dps_uses_fight_length(self):
        self.run('hit("Me", "Mob", 1000, "Bolt", true, 0); hit("Me", "Mob", 1000, "Bolt", true, 4000)')
        self.run('rows = fights.rows(t, fights.segment(t, 0), fights.MODES[1], 4000)')
        self.assertEqual(self.eval("rows[1].name"), "Me")
        self.assertEqual(self.eval("rows[1].value"), 500)  # 2000 damage over 4s
        self.assertEqual(self.eval("fights.rows(t, fights.segment(t, 0), fights.MODES[5], 4000)[1].name"), "Mob")

    def test_idle_ends_fight_and_starts_new_one(self):
        self.run('hit("Me", "Mob", 100, "Bolt", true, 0)')
        self.run('hit("Me", "Mob", 300, "Bolt", true, 20000)')
        self.assertEqual(self.eval("#t.history"), 1)
        self.assertEqual(self.eval("t.current.damage.Me"), 300)
        self.assertEqual(self.eval("fights.segment(t, 1).damage.Me"), 100)
        self.assertEqual(self.eval("t.overall.damage.Me"), 400)
        # Overall time counts only time in fights: 0s + 2s now
        self.assertEqual(self.eval("fights.duration(t, t.overall, 22000)"), 2000)

    def test_bystanders_do_not_start_or_extend_fights(self):
        self.run('hit("Stranger", "Mob", 100, "Bolt", false, 0)')
        self.assertIsNone(self.eval("t.current"))
        self.run('hit("Me", "Mob", 100, "Bolt", true, 1000)')
        self.run('hit("Stranger", "Mob", 50, "Bolt", false, 5000)')
        self.assertEqual(self.eval("t.current.damage.Stranger"), 50)
        self.assertEqual(self.eval("t.current.lastTime"), 1000)
        self.assertTrue(self.eval("fights.tick(t, 7000)"))

    def test_group_filter_and_shares(self):
        self.run('hit("Me", "Mob", 300, "Bolt", true, 0); hit("Other", "Mob", 100, "Bolt", false, 0)')
        self.run('rows = fights.rows(t, t.current, fights.MODES[2], 0, function(n) return n == "Me" end)')
        self.assertEqual(self.eval("#rows"), 1)
        self.assertEqual(self.eval("rows[1].share"), 1)
        self.run("rows = fights.rows(t, t.current, fights.MODES[2], 0)")
        self.assertEqual(self.eval("rows[1].share"), 0.75)

    def test_skills_and_melee(self):
        self.run('hit("Me", "Mob", 300, "Bolt", true, 0); hit("Me", "Mob", 100, nil, true, 0)')
        self.run('s = fights.skills(t.current, fights.MODES[2], "Me")')
        self.assertEqual(self.eval("s[1].name"), "Bolt")
        self.assertEqual(self.eval("s[2].name"), "Melee Attack")
        self.assertEqual(self.eval("s[2].share"), 0.25)

    def test_heals_and_ignored(self):
        self.run('fights.record(t, "SPELL_HEALED", "Me", "Me", { heal = 500, spellName = "Mend" }, true, 0)')
        self.run('fights.record(t, "SPELL_HEALED", "Me", "Me", { heal = 9999, spellName = "Reset After Duel" }, true, 0)')
        self.assertEqual(self.eval("t.current.healing.Me"), 500)
        self.run('fights.record(t, "SPELL_DAMAGE", "Me", "Mob", nil, true, 0)')

    def test_history_is_capped(self):
        self.run("for i = 1, 15 do hit('Me', 'Mob', i, 'Bolt', true, i * 10000) end; fights.tick(t, 1e9)")
        self.assertEqual(self.eval("#t.history"), 10)
        self.assertEqual(self.eval("fights.previousCount(t)"), 9)

    def test_format(self):
        self.assertEqual(self.eval("fights.format(950)"), "950")
        self.assertEqual(self.eval("fights.format(12345)"), "12.3k")
        self.assertEqual(self.eval("fights.format(1234567)"), "1.23m")
        self.assertEqual(self.eval("fights.formatTime(75000)"), "1:15")


class AddonSmokeTest(unittest.TestCase):
    """Loads main.lua against the mocked API and drives it like the game would."""

    def test_load_fight_click_unload(self):
        lua = runtime()
        lua.execute(
            """
            addon = require("dps_meter/main")
            harness.setTeam({ "Buddy" })
            addon.OnLoad()
            meterWnd = harness.windows[1]
            onEvent = meterWnd.handlers.OnEvent
            onUpdate = meterWnd.handlers.OnUpdate
            onEvent(meterWnd, "COMBAT_MSG", 5, "SPELL_DAMAGE", "Me", "Mob", 400, "Bolt")
            onEvent(meterWnd, "COMBAT_MSG", 5, "SPELL_DAMAGE", "Buddy", "Mob", 200, "Shot")
            onEvent(meterWnd, "COMBAT_MSG", 5, "SPELL_HEALED", "Buddy", "Me", 50, "Mend")
            onEvent(meterWnd, "CHAT_MESSAGE", "ignored")
            harness.advance(2000)
            onUpdate(meterWnd, 600)
            texts = {}
            for _, w in ipairs(harness.windows) do
              if w.text then texts[#texts + 1] = w.text end
            end
            """
        )
        texts = list(lua.eval("texts").values())
        self.assertIn("1. Me", texts)
        self.assertIn("2. Buddy", texts)
        self.assertIn("200 (67%)", texts)  # 400 damage over 2s, 2/3 of the group's damage
        self.assertIn("You: 200 DPS  #1", texts)
        self.assertEqual(lua.eval("#errors"), 0, lua.eval("errors[1]"))
        # Click every clickable widget the addon made (mode, segment, scope, reset, rows)
        lua.execute(
            """
            clicks = 0
            for _, w in ipairs(harness.windows) do
              if w.handlers.OnClick then w.handlers.OnClick(); clicks = clicks + 1 end
            end
            harness.advance(10000)
            onUpdate(meterWnd, 600)
            addon.OnUnload()
            """
        )
        self.assertGreater(lua.eval("clicks"), 5)
        self.assertGreater(lua.eval("api.saved"), 0)
        self.assertEqual(lua.eval("#errors"), 0, lua.eval("errors[1]"))
        self.assertEqual(lua.eval("api.settings.posX"), 10)

    def test_errors_in_handlers_are_contained(self):
        lua = runtime()
        lua.execute(
            """
            addon = require("dps_meter/main")
            addon.OnLoad()
            ParseCombatMessage = function() error("boom") end
            local w = harness.windows[1]
            w.handlers.OnEvent(w, "COMBAT_MSG", 5, "SPELL_DAMAGE", "Me", "Mob", 1, "Bolt")
            """
        )
        self.assertIn("boom", lua.eval("errors[1]"))


if __name__ == "__main__":
    unittest.main()
