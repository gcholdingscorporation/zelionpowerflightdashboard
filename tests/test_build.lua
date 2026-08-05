-- Exercises the amalgamated dist/ file, not the src/ modules.
--
-- A build that compiles but does not run is the failure mode that matters:
-- on the radio it surfaces as an opaque "widget script error" with no hint of
-- which module broke. So load the real artifact and drive full lifecycles
-- through it, on both screens and on both of its screens.

return function(H, Mock, Loader)

local DIST = "dist/WIDGETS/ZelionDash/main.lua"

local function loadDist()
  local chunk, err = loadfile(DIST)
  if not chunk then error("built file does not compile: " .. tostring(err)) end
  return chunk()
end

local function boot(w, h, opts, setup)
  Mock.reset()
  Mock.removeRf2()
  Mock.state.lcdW, Mock.state.lcdH = w, h
  if setup then setup() end
  Mock.install()
  Mock.installLvgl()
  Mock.installLogos()
  opts = opts or {}
  local widgetDef = loadDist()
  local widget = widgetDef.create({ x = 0, y = 0, w = w, h = h }, opts)
  widgetDef.update(widget, opts)
  Mock.advanceSeconds(0.2)
  return widgetDef, widget
end

local function flying()
  Mock.addSensor("Hspd", 18, 1850)
  Mock.addSensor("Vcel", 1, 3.94)
  Mock.addSensor("Vbat", 1, 47.3)
  Mock.addSensor("Bat%", 13, 68)
  Mock.addSensor("Curr", 2, 42)
  Mock.addSensor("Tesc", 11, 71)
  Mock.addSensor("Gov",  nil, 4)
end

H.group("build: artifact")

H.test("exports the EdgeTX widget interface", function()
  Mock.reset(); Mock.install(); Mock.installLvgl()
  local w = loadDist()
  H.eq(w.name, "ZelionDash")
  for _, fn in ipairs({"create","update","refresh","background"}) do
    H.truthy(type(w[fn]) == "function", fn .. " must be a function")
  end
  H.truthy(type(w.options) == "table")
  H.truthy(w.useLvgl, "the dashboard is retained-mode")
end)

H.group("build: dashboard lifecycle")

H.test("full lifecycle at 800x480 (TX16S Mk3)", function()
  local def, widget = boot(800, 480, nil, flying)
  def.background(widget)
  def.refresh(widget, 0, nil)
  local t = Mock.lvglText()
  H.truthy(string.find(t, "1850", 1, true), "headspeed on screen")
  H.truthy(string.find(t, "HEADSPEED", 1, true))
  H.truthy(string.find(t, "ACTIVE", 1, true), "governor state")
end)

H.test("full lifecycle at 480x320 (TX15)", function()
  local def, widget = boot(480, 320, nil, flying)
  def.refresh(widget, 0, nil)
  H.truthy(string.find(Mock.lvglText(), "1850", 1, true))
end)

H.test("full lifecycle at 480x272", function()
  local def, widget = boot(480, 272, nil, flying)
  def.refresh(widget, 0, nil)
  H.truthy(string.find(Mock.lvglText(), "1850", 1, true))
end)

H.test("repeated frames do not rebuild the screen", function()
  local def, widget = boot(800, 480, nil, flying)
  def.refresh(widget, 0, nil)
  local clears = Mock.lv.cleared
  for _ = 1, 20 do
    Mock.advanceSeconds(0.15)
    def.refresh(widget, 0, nil)
  end
  H.eq(Mock.lv.cleared, clears, "steady state must not tear down and rebuild")
end)

H.group("build: before the heli is powered")

H.test("the dashboard is up before any telemetry arrives", function()
  -- There is no standby screen. A splash used to stand in until telemetry
  -- appeared; showing the real layout says more, because you can see the
  -- widget is alive and waiting on named values rather than just waiting.
  local def, widget = boot(800, 480)
  def.refresh(widget, 0, nil)
  local t = Mock.lvglText()
  H.truthy(string.find(t, "BATTERY", 1, true), "the real layout, immediately")
  H.truthy(string.find(t, "HEADSPEED", 1, true))
  H.truthy(string.find(t, "--", 1, true), "with honest blanks, not zeroes")
  H.truthy(#Mock.lvglImages() > 0, "and the brand is on screen anyway")
end)

H.test("telemetry arriving fills the same screen in place", function()
  local def, widget = boot(800, 480)
  def.refresh(widget, 0, nil)
  local built = Mock.lv.cleared

  -- Heli powered on after the radio. Unbound roles are re-probed on a one
  -- second timer, so the values are not instantaneous by design.
  flying()
  for _ = 1, 15 do
    Mock.advanceSeconds(0.15)
    def.refresh(widget, 0, nil)
  end
  H.truthy(string.find(Mock.lvglText(), "1850", 1, true), "values arrived")
  H.eq(Mock.lv.cleared, built,
       "and nothing was torn down to show them - this transition is where the "
       .. "emergency-mode reboot used to happen")
end)

H.group("build: FC integration")

H.test("shows the flight controller's flight count", function()
  Mock.reset(); Mock.removeRf2()
  Mock.state.lcdW, Mock.state.lcdH = 800, 480
  flying()
  Mock.install(); Mock.installLvgl(); Mock.installLogos()
  Mock.installRf2({ apiVersion = 12.09, modelName = "Goblin 700" })

  local def = loadDist()
  local opts = {}
  local widget = def.create({ x=0, y=0, w=800, h=480 }, opts)
  def.update(widget, opts)
  for _ = 1, 70 do
    Mock.advanceSeconds(0.1)
    def.background(widget)
  end
  def.refresh(widget, 0, nil)

  local t = Mock.lvglText()
  H.truthy(string.find(t, "137 FLIGHTS", 1, true), "FC counter shown")
  H.truthy(string.find(t, "Goblin 700", 1, true), "FC craft name used")
end)

H.group("build: never fault the radio")

H.test("an out-of-memory build degrades instead of raising", function()
  -- EdgeTX puts the transmitter into EMERGENCY MODE when a widget raises.
  -- Running out of memory mid-build must never do that.
  local def, widget = boot(800, 480, nil, flying)
  def.refresh(widget, 0, nil)

  Mock.lvglFailAfter = 20        -- dashboard needs ~65 objects
  local ok = pcall(function()
    for _ = 1, 5 do
      Mock.advanceSeconds(0.2)
      def.refresh(widget, 0, nil)
    end
  end)
  Mock.lvglFailAfter = nil
  H.truthy(ok, "refresh must not propagate the failure")
end)

H.test("safe mode still shows the values that matter", function()
  Mock.reset(); Mock.removeRf2()
  Mock.state.lcdW, Mock.state.lcdH = 800, 480
  flying()
  Mock.install(); Mock.installLvgl(); Mock.installLogos()
  local ZD = Loader.load()
  ZD.State.reloadModel()
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)

  ZD.Dashboard.buildMinimal(800, 480)
  local t = Mock.lvglText()
  H.truthy(string.find(t, "SAFE MODE", 1, true), "says it is degraded")
  H.truthy(string.find(t, "68%", 1, true), "battery still shown")
  H.truthy(string.find(t, "1850 RPM", 1, true), "headspeed still shown")
  H.truthy(string.find(t, "3.94", 1, true), "cell voltage still shown")
  H.eq(#Mock.lvglImages(), 0, "no bitmap in safe mode")
end)

H.test("safe mode is a fraction of the full dashboard", function()
  local def, widget = boot(800, 480, nil, flying)
  def.refresh(widget, 0, nil)
  local full = #Mock.lv.objects
  local ZD = Loader.load()
  ZD.Dashboard.buildMinimal(800, 480)
  H.truthy(#Mock.lv.objects < full / 3,
           string.format("safe mode %d vs full %d", #Mock.lv.objects, full))
end)

H.test("the full dashboard is what a fresh install shows", function()
  -- There used to be a Level option that stepped the renderer down one
  -- construct at a time, defaulting to safe mode. It existed only to bisect
  -- the emergency-mode reboot on hardware, and that turned out to be
  -- XXLSIZE + BOLD selecting a font index EdgeTX has no font for. Option gone;
  -- the automatic ladder below is the part that still matters.
  Mock.reset(); Mock.removeRf2()
  Mock.state.lcdW, Mock.state.lcdH = 800, 480
  flying()
  Mock.install(); Mock.installLvgl(); Mock.installLogos()
  local def = loadDist()
  local widget = def.create({ x=0, y=0, w=800, h=480 }, {})
  def.update(widget, {})            -- no options at all
  Mock.advanceSeconds(0.2)
  def.refresh(widget, 0, nil)
  local t = Mock.lvglText()
  H.falsy(string.find(t, "SAFE MODE", 1, true), "not degraded out of the box")
  H.truthy(string.find(t, "1850", 1, true), "headspeed on screen")
  H.truthy(#Mock.lvglImages() > 0, "and the artwork is on")
  for _, name in ipairs({"ArmSwitch", "HoldSwitch", "SensorMap"}) do
    local found = false
    for _, o in ipairs(def.options) do if o[1] == name then found = true end end
    H.truthy(found, name .. " must survive")
  end
  for _, o in ipairs(def.options) do
    H.truthy(o[1] ~= "Level", "the Level option is gone")
  end
end)

H.test("a build that keeps failing still lands on something drawable", function()
  -- The ladder: full -> no logo -> no rounded corners -> safe mode. Nothing
  -- selects those any more, so this is the only thing exercising them.
  local def, widget = boot(800, 480, nil, flying)
  def.refresh(widget, 0, nil)
  Mock.lvglFailAfter = 3
  local ok = pcall(function()
    Mock.advanceSeconds(5)
    Mock.setSensor("Hspd", 0)
    for _ = 1, 20 do Mock.advanceSeconds(0.3); def.refresh(widget, 0, nil) end
  end)
  Mock.lvglFailAfter = nil
  H.truthy(ok, "a failing build must never propagate out of refresh")
end)

H.group("build: alerts")

H.test("a sounding alert names itself on the strip", function()
  -- The radio may be muted, and a buzz pattern is not self-explanatory.
  local def, widget = boot(800, 480, nil, flying)
  for _ = 1, 80 do
    Mock.advanceSeconds(0.1)
    def.refresh(widget, 0, nil)
  end
  H.falsy(string.find(Mock.lvglText(), "ALERT", 1, true), "quiet so far")

  Mock.setSensor("Vcel", 3.20)
  for _ = 1, 20 do
    Mock.advanceSeconds(0.1)
    def.refresh(widget, 0, nil)
  end
  local t = Mock.lvglText()
  H.truthy(string.find(t, "ALERT: CELL", 1, true), "and says which")
  H.falsy(string.find(t, "NO HYPE", 1, true), "the slogan stands down")
end)

H.test("alerts sound while another screen is in front", function()
  -- background() runs when the widget is not the visible one. A low cell does
  -- not stop mattering because the pilot opened the model setup page.
  local def, widget = boot(800, 480, nil, flying)
  for _ = 1, 80 do
    Mock.advanceSeconds(0.1)
    def.background(widget)
  end
  Mock.played = {}
  Mock.setSensor("Vcel", 3.10)
  for _ = 1, 20 do
    Mock.advanceSeconds(0.1)
    def.background(widget)
  end
  H.truthy(#Mock.played > 0, "still audible off-screen")
end)

H.test("the test option sounds one alert per toggle, not a siren", function()
  local def, widget = boot(800, 480, nil, flying)
  def.refresh(widget, 0, nil)
  Mock.played = {}

  def.update(widget, { TestAlert = 1 })
  local afterOn = #Mock.played
  H.truthy(afterOn > 0, "switching it on sounds one")

  -- update() firing again with the option unchanged must not re-sound it.
  def.update(widget, { TestAlert = 1 })
  H.eq(#Mock.played, afterOn, "and only one")

  def.update(widget, { TestAlert = 0 })
  def.update(widget, { TestAlert = 1 })
  H.truthy(#Mock.played > afterOn, "off and on again sounds another")
end)

H.test("the option switches them off", function()
  local def, widget = boot(800, 480, { Alerts = 0 }, flying)
  Mock.setSensor("Vcel", 3.10)
  for _ = 1, 150 do
    Mock.advanceSeconds(0.1)
    def.refresh(widget, 0, nil)
  end
  H.eq(#Mock.played, 0)
end)

H.group("build: sensor map")

-- These assert on LVGL objects, not on lcd.draw* calls. The screen was written
-- in immediate mode and drew literally nothing on hardware for its entire
-- existence - a widget that declares useLvgl gets refresh(nullptr), so every
-- lcd.draw* returns on the null buffer. The tests passed anyway, because the
-- mock recorded calls the radio was discarding.

H.test("nothing anywhere tries to draw in immediate mode", function()
  -- The guard against that whole class of bug returning.
  local def, widget = boot(800, 480, { SensorMap = 1 }, flying)
  Mock.immediateDrawAttempts = 0
  def.refresh(widget, 0, nil)
  def.refresh(widget, 0, nil)
  H.eq(Mock.immediateDrawAttempts, 0,
       "lcd.draw* is a no-op on an LVGL widget - use lvgl objects")

  local def2, w2 = boot(800, 480, nil, flying)
  Mock.immediateDrawAttempts = 0
  def2.refresh(w2, 0, nil)
  H.eq(Mock.immediateDrawAttempts, 0, "and on the dashboard too")
end)

H.test("the option switches to the diagnostics screen", function()
  local def, widget = boot(800, 480, { SensorMap = 1 }, flying)
  def.refresh(widget, 0, nil)
  local t = Mock.lvglText()
  H.truthy(string.find(t, "SENSOR MAP", 1, true), "diagnostics header")
  H.truthy(string.find(t, "Hspd", 1, true), "bound sensor listed")
  H.truthy(string.find(t, "Headspeed", 1, true), "under its role name")
end)

H.test("switching back rebuilds the dashboard", function()
  local def, widget = boot(800, 480, { SensorMap = 1 }, flying)
  def.refresh(widget, 0, nil)
  H.truthy(string.find(Mock.lvglText(), "SENSOR MAP", 1, true))

  def.update(widget, { SensorMap = 0 })
  def.refresh(widget, 0, nil)
  local t = Mock.lvglText()
  H.falsy(string.find(t, "SENSOR MAP", 1, true), "diagnostics gone")
  H.truthy(string.find(t, "1850", 1, true), "dashboard is back")
end)

H.test("the diagnostics list scrolls on the small screen", function()
  local def, widget = boot(480, 320, { SensorMap = 1 }, flying)
  def.refresh(widget, 0, nil)
  local first = Mock.lvglText()
  for _ = 1, 8 do def.refresh(widget, 100, nil) end
  H.truthy(first ~= Mock.lvglText(), "roles past the fold must be reachable")
end)

H.test("scrolling cannot run off either end of the list", function()
  local def, widget = boot(800, 480, { SensorMap = 1 }, flying)
  def.refresh(widget, 0, nil)
  local top = Mock.lvglText()
  for _ = 1, 40 do def.refresh(widget, 101, nil) end   -- PREV, past the start
  H.eq(Mock.lvglText(), top, "held at the top")
  for _ = 1, 200 do def.refresh(widget, 100, nil) end  -- NEXT, past the end
  local bottom = Mock.lvglText()
  for _ = 1, 20 do def.refresh(widget, 100, nil) end
  H.eq(Mock.lvglText(), bottom, "and at the bottom")
end)

H.test("scrolling does not rebuild the screen", function()
  local def, widget = boot(800, 480, { SensorMap = 1 }, flying)
  def.refresh(widget, 0, nil)
  local built, objects = Mock.lv.cleared, #Mock.lv.objects
  for _ = 1, 30 do def.refresh(widget, 100, nil) end
  H.eq(Mock.lv.cleared, built, "rows are rewritten, not recreated")
  H.eq(#Mock.lv.objects, objects)
end)

H.test("the flight log reports itself, since it is otherwise silent", function()
  -- It writes once, at landing, and says nothing. Without this line there is
  -- no way to tell it is working short of pulling the card.
  local def, widget = boot(800, 480, { SensorMap = 1 }, flying)
  def.refresh(widget, 0, nil)
  local t = Mock.lvglText()
  H.truthy(string.find(t, "FLIGHT LOG", 1, true))
  H.truthy(string.find(t, "zeliondash.csv", 1, true), "and where it writes")
  H.truthy(string.find(t, "flying, from rotor", 1, true),
           "and how it decided the heli is flying")
end)

H.test("a failed write says so on the sensor map", function()
  local def, widget = boot(800, 480, { SensorMap = 1 }, flying)
  Mock.state.readOnly = true
  Mock.setSensor("Hspd", 1850)
  for _ = 1, 300 do Mock.advanceSeconds(0.1); def.refresh(widget, 0, nil) end
  Mock.setSensor("Hspd", 0)
  for _ = 1, 100 do Mock.advanceSeconds(0.1); def.refresh(widget, 0, nil) end
  Mock.state.readOnly = false
  H.truthy(string.find(Mock.lvglText(), "FAILED", 1, true),
           "a card that will not take the write must not fail quietly")
end)

H.test("the roles come first, with artwork summarised above them", function()
  -- The full artwork block used to lead, from when a missing PNG was the open
  -- problem. Seven rows of it pushed the governor - the row actually being
  -- looked for - off the bottom of the screen.
  local def, widget = boot(800, 480, { SensorMap = 1 }, flying)
  def.refresh(widget, 0, nil)
  local t = Mock.lvglText()
  local artwork = string.find(t, "ARTWORK", 1, true)
  H.truthy(artwork, "one summary line, so a failed load still announces itself")
  H.truthy(string.find(t, "2 ok", 1, true), "and says whether they loaded")
  H.truthy(string.find(t, "Governor", 1, true), "the roles fit on one screen now")
  H.truthy(string.find(t, "Headspeed", 1, true) > artwork, "roles below the summary")
end)

H.test("the artwork detail is still reachable, at the bottom", function()
  local def, widget = boot(800, 480, { SensorMap = 1 }, flying)
  def.refresh(widget, 0, nil)
  H.falsy(string.find(Mock.lvglText(), "FIB", 1, true), "not on the first page")
  -- "the PNGs are in the folder" and "the widget cannot load them" were
  -- indistinguishable for three rounds. The radio can still say which.
  for _ = 1, 30 do def.refresh(widget, 100, nil) end
  local t = Mock.lvglText()
  H.truthy(string.find(t, "logo_panel.png", 1, true), "each expected file probed")
  H.truthy(string.find(t, "FIB", 1, true), "per-probe result shown")
end)

H.test("a missing PNG is called out on the summary line", function()
  Mock.reset(); Mock.removeRf2()
  Mock.state.lcdW, Mock.state.lcdH = 800, 480
  flying()
  Mock.noDefaultLogos = true
  Mock.install(); Mock.installLvgl()
  local def = loadDist()
  local opts = { SensorMap = 1 }
  local widget = def.create({ x=0, y=0, w=800, h=480 }, opts)
  def.update(widget, opts)
  def.refresh(widget, 0, nil)
  Mock.noDefaultLogos = nil
  H.truthy(string.find(Mock.lvglText(), "MISSING", 1, true),
           "without having to scroll for it")
end)

H.test("survives a model with no telemetry at all", function()
  local def, widget = boot(800, 480, { SensorMap = 1 })
  def.refresh(widget, 0, nil)
  H.truthy(string.find(Mock.lvglText(), "0 bound", 1, true),
           "reports nothing bound rather than erroring")
end)

end
