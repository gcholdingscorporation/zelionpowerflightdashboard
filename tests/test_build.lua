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
  -- Safe Mode defaults on so a stricken radio can boot; tests exercising the
  -- real dashboard have to opt out of it explicitly.
  opts = opts or {}
  if opts.Level == nil then opts.Level = 3 end
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

H.group("build: standby")

H.test("no telemetry shows the brand, not a grid of dashes", function()
  local def, widget = boot(800, 480)
  def.refresh(widget, 0, nil)
  H.truthy(string.find(Mock.lvglText(), "WAITING FOR TELEMETRY", 1, true))
end)

H.test("telemetry appearing switches to the dashboard", function()
  local def, widget = boot(800, 480)
  def.refresh(widget, 0, nil)
  H.truthy(string.find(Mock.lvglText(), "WAITING", 1, true))

  -- Heli powered on after the radio. Unbound roles are re-probed on a one
  -- second timer, so the switch is not instantaneous by design.
  flying()
  for _ = 1, 15 do
    Mock.advanceSeconds(0.15)
    def.refresh(widget, 0, nil)
  end
  local t = Mock.lvglText()
  H.truthy(string.find(t, "1850", 1, true), "dashboard took over")
  H.falsy(string.find(t, "WAITING", 1, true), "standby is gone")
end)

H.group("build: FC integration")

H.test("shows the flight controller's flight count", function()
  Mock.reset(); Mock.removeRf2()
  Mock.state.lcdW, Mock.state.lcdH = 800, 480
  flying()
  Mock.install(); Mock.installLvgl(); Mock.installLogos()
  Mock.installRf2({ apiVersion = 12.09, modelName = "Goblin 700" })

  local def = loadDist()
  local opts = { Level = 3 }
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

H.test("level 1 draws no rounded corner anywhere", function()
  local def, widget = boot(800, 480, { Level = 1 }, flying)
  def.refresh(widget, 0, nil)
  for _, o in ipairs(Mock.lv.objects) do
    if o.kind == "rect" then
      H.eq(o.props.rounded, 0, "level 1 must be square-cornered throughout")
    end
  end
  H.eq(#Mock.lvglImages(), 0, "and carry no images")
end)

H.test("level 2 restores rounded corners but still no images", function()
  local def, widget = boot(800, 480, { Level = 2 }, flying)
  def.refresh(widget, 0, nil)
  local rounded = 0
  for _, o in ipairs(Mock.lv.objects) do
    if o.kind == "rect" and (o.props.rounded or 0) > 0 then rounded = rounded + 1 end
  end
  H.truthy(rounded > 0, "corners are back")
  H.eq(#Mock.lvglImages(), 0, "images are not")
end)

H.test("safe mode is the default, so a stricken radio still boots", function()
  Mock.reset(); Mock.removeRf2()
  Mock.state.lcdW, Mock.state.lcdH = 800, 480
  flying()
  Mock.install(); Mock.installLvgl(); Mock.installLogos()
  local def = loadDist()
  local widget = def.create({ x=0, y=0, w=800, h=480 }, {})
  def.update(widget, {})            -- no SafeMode key at all
  Mock.advanceSeconds(0.2)
  def.refresh(widget, 0, nil)
  H.truthy(string.find(Mock.lvglText(), "SAFE MODE", 1, true))
  H.eq(#Mock.lvglImages(), 0, "no bitmap until explicitly enabled")
end)

H.group("build: sensor map")

H.test("the option switches to the diagnostics screen", function()
  local def, widget = boot(800, 480, { SensorMap = 1 }, flying)
  Mock.draws = {}
  def.refresh(widget, 0, nil)
  local t = Mock.drawnText()
  H.truthy(string.find(t, "sensor map", 1, true), "diagnostics header")
  H.truthy(string.find(t, "Hspd", 1, true), "bound sensor listed")
end)

H.test("the diagnostics list scrolls on the small screen", function()
  local def, widget = boot(480, 320, { SensorMap = 1 }, flying)
  def.refresh(widget, 0, nil)
  Mock.draws = {}
  def.refresh(widget, 0, nil)
  local first = Mock.drawnText()

  Mock.draws = {}
  for _ = 1, 8 do def.refresh(widget, 100, nil) end
  H.truthy(first ~= Mock.drawnText(), "roles past the fold must be reachable")
end)

H.test("lists the widget folder so the radio reports its own assets", function()
  local def, widget = boot(800, 480, { SensorMap = 1 }, flying)
  Mock.draws = {}
  def.refresh(widget, 0, nil)
  local t = Mock.drawnText()
  -- "the PNGs are in the folder" and "the widget cannot load them" were
  -- indistinguishable for three rounds. The radio can just say which.
  H.truthy(string.find(t, "ASSETS", 1, true), "assets section present")
  H.truthy(string.find(t, "logo_panel.png", 1, true), "each expected file probed")
  H.truthy(string.find(t, "FIB", 1, true), "per-probe result shown")
end)

H.test("survives a model with no telemetry at all", function()
  local def, widget = boot(800, 480, { SensorMap = 1 })
  Mock.draws = {}
  def.refresh(widget, 0, nil)
  H.truthy(string.find(Mock.drawnText(), "0 bound", 1, true),
           "reports nothing bound rather than erroring")
end)

end
