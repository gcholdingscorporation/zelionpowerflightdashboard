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

H.group("build: things the radio cannot do")

-- EdgeTX registers `string` as a plain table and never calls luaopen_string,
-- so strings have no metatable and `s:gsub(...)` raises "attempt to index a
-- string value". Desktop Lua sets that metatable, so nothing here or in the
-- mock can catch it by running the code - it works everywhere except the one
-- place it matters. A scan of the shipped file is the only honest test.
--
-- Cost of learning this the other way: a flight lost to Host.mkdir doing
-- tostring(path):gsub("/+$", "") on the first line that touched the card.

local function scanForStringMethods(path)
  -- Mock.realIo, not io: by now the mock has swapped _G.io for its virtual
  -- filesystem and the built file is on the actual disk.
  local realIo = Mock.realIo or io
  local f = realIo.open(path, "r")
  H.truthy(f, "built file is readable: " .. path)
  local src = f:read("*a")
  f:close()

  local methods = "gsub gmatch find sub lower upper format rep len byte match reverse"
  local offenders = {}

  -- Line by line, with comments stripped: the prose explaining why this rule
  -- exists is full of the very syntax it bans, and a checker that flags its
  -- own rationale gets switched off.
  local n = 0
  for line in string.gmatch(src, "[^\n]*") do
    n = n + 1
    local code = string.gsub(line, "%-%-.*$", "")
    local pos = 1
    while true do
      local s, e, name = string.find(code, "[%w_%)\"'%]]:(%a+)%(", pos)
      if not s then break end
      if string.find(methods, name, 1, true) then
        offenders[#offenders + 1] = string.format("line %d: :%s(", n, name)
      end
      pos = e
    end
  end
  H.eq(#offenders, 0, path .. ": use string." .. "fn(s, ...) instead -- "
       .. table.concat(offenders, ", "))
end

H.test("no string method syntax survives into the build", function()
  scanForStringMethods(DIST)
end)

H.group("build: a hold switch round the wrong way")

-- Reversed, the hold switch freezes the extremes and silences the alerts for
-- the whole flight while looking exactly like a working one. Driven through
-- the built artifact because the inversion lives in the widget's option
-- handling, and the observable effect is a peak that stops moving.

local function heldPeak(invert, switchValue)
  local widgetDef, widget = boot(800, 480,
    { HoldSwitch = "SH", HoldInvert = invert },
    function()
      flying()
      Mock.addSensor("SH", nil, switchValue)
    end)
  Mock.advanceSeconds(0.2)
  widgetDef.refresh(widget)
  Mock.setSensor("Hspd", 2150)          -- a new peak, if it is allowed through
  Mock.advanceSeconds(0.5)
  widgetDef.refresh(widget)
  return Mock.lvglText()
end

H.test("held normally, the peak stops moving", function()
  local text = heldPeak(0, 1024)
  H.falsy(string.find(text, "MAX 2150", 1, true), "frozen while held")
end)

H.test("not held, the peak follows", function()
  local text = heldPeak(0, -1024)
  H.truthy(string.find(text, "MAX 2150", 1, true))
end)

H.test("inverted, the far end of the switch is what holds", function()
  local text = heldPeak(1, -1024)
  H.falsy(string.find(text, "MAX 2150", 1, true), "held, the other way round")
end)

H.test("inverted, the near end no longer holds", function()
  local text = heldPeak(1, 1024)
  H.truthy(string.find(text, "MAX 2150", 1, true))
end)

H.group("build: RF Tool reaches the screen")

H.test("the RF Tool rows appear on the sensor map", function()
  Mock.reset()
  Mock.state.lcdW, Mock.state.lcdH = 800, 480
  flying()
  Mock.installRf2({ apiVersion = 12.09, modelName = "GOBLIN 700" })
  Mock.install(); Mock.installLvgl(); Mock.installLogos()
  local opts = { SensorMap = 1 }
  local def = loadDist()
  local widget = def.create({ x = 0, y = 0, w = 800, h = 480 }, opts)
  def.update(widget, opts)
  for _ = 1, 70 do
    Mock.advanceSeconds(0.1)
    def.refresh(widget, 0, nil)
  end
  local t = Mock.lvglText()
  H.truthy(string.find(t, "RF TOOL", 1, true), "the row is there")
  H.truthy(string.find(t, "GOBLIN 700", 1, true), "with the FC craft name")
  H.truthy(string.find(t, "137 flights", 1, true), "and the FC's own total")
end)

H.test("and say 'not installed' rather than nothing when it is absent", function()
  local def, widget = boot(800, 480, { SensorMap = 1 }, flying)
  def.refresh(widget, 0, nil)
  local t = Mock.lvglText()
  H.truthy(string.find(t, "RF TOOL", 1, true))
  H.truthy(string.find(t, "not installed", 1, true),
           "absence has to be visible too - a blank row proves nothing")
end)

H.group("build: which timer is being overwritten")

-- Point Time Timer at a timer already in use and it quietly stops being that
-- timer. Nothing else on the radio says which one this widget has taken, so a
-- wrong setting would only surface in the air.

H.test("the flight row names the timer being driven", function()
  local def, widget = boot(800, 480, { SensorMap = 1, TimeTimer = 3 }, flying)
  def.refresh(widget, 0, nil)
  H.truthy(string.find(Mock.lvglText(), "-> T3", 1, true),
           "a wrong timer has to be obvious on the ground")
end)

H.test("and says nothing when no timer is being driven", function()
  local def, widget = boot(800, 480, { SensorMap = 1, TimeTimer = 0 }, flying)
  def.refresh(widget, 0, nil)
  H.falsy(string.find(Mock.lvglText(), "-> T", 1, true),
          "off means off, not a dangling arrow")
end)

H.test("option 1 means EdgeTX timer 1, not timer 2", function()
  -- Timers are 0-based in Lua and 1-based on the settings page. Getting that
  -- wrong would overwrite the neighbouring timer, which is precisely the
  -- accident this label exists to catch.
  local def, widget = boot(800, 480, { SensorMap = 1, TimeTimer = 1 }, flying)
  def.refresh(widget, 0, nil)
  H.truthy(string.find(Mock.lvglText(), "-> T1", 1, true))
end)

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
  H.truthy(string.find(t, "FLYING, from rotor", 1, true),
           "and how it decided the heli is flying")
  H.truthy(string.find(t, "no flight yet", 1, true),
           "an empty log says why, rather than looking like a failure")
end)

-- The diagnostics screen is consulted to find out why a tile shows dashes, so
-- the value column has to say more than the dashboard, not less.

H.test("a coded reading is shown by name, not just by number", function()
  local def, widget = boot(800, 480, { SensorMap = 1 }, flying)
  def.refresh(widget, 0, nil)
  local t = Mock.lvglText()
  H.truthy(string.find(t, "4 ACTIVE", 1, true),
           "the dashboard says ACTIVE; a bare 4 here tells the pilot less "
           .. "than the screen they were already looking at")
end)

H.test("values carry their units", function()
  local def, widget = boot(800, 480, { SensorMap = 1 }, flying)
  def.refresh(widget, 0, nil)
  local t = Mock.lvglText()
  -- The point is not decoration: this screen exists to catch a binding that
  -- grabbed the wrong sensor, and the unit is the tell.
  H.truthy(string.find(t, "1850 rpm", 1, true), "headspeed in rpm")
  H.truthy(string.find(t, "47.30 V", 1, true), "pack voltage in volts")
  H.truthy(string.find(t, "42 A", 1, true), "current in amps")
  H.truthy(string.find(t, "71 ", 1, true), "esc temperature carries a unit")
end)

H.test("roles that bound to nothing fold into one counted line", function()
  local def, widget = boot(800, 480, { SensorMap = 1 }, flying)
  def.refresh(widget, 0, nil)
  local t = Mock.lvglText()

  H.truthy(string.find(t, "unbound", 1, true), "the fold line is present")
  -- Folded, not hidden. The names still have to be there or the screen has
  -- stopped answering "which roles found nothing".
  H.truthy(string.find(t, "Tail speed", 1, true), "and still names them")
  H.truthy(string.find(t, "Power", 1, true))

  -- The whole point of folding: every bound role reaches the first page,
  -- which is what the ten dead rows used to cost.
  for _, role in ipairs({ "Headspeed", "Pack voltage", "Cell voltage",
                          "Battery %", "Current", "ESC temp", "Governor" }) do
    H.truthy(string.find(t, role, 1, true),
             role .. " must be on the first page without scrolling")
  end
end)

-- Is this role drawn as a row of its own, or only mentioned inside the fold?
--
-- Exact match, and that is the whole point. A folded role still puts its name
-- on the screen, inside a comma-separated list, so any substring search
-- answers yes either way and proves nothing. Only a row has a label equal to
-- the role name.
local function hasOwnRow(role)
  for _, o in ipairs((Mock.lv or {}).objects or {}) do
    if o.kind == "label" and tostring(o.props.text or "") == role then
      return true
    end
  end
  return false
end

H.test("an important role that bound to nothing is never folded away", function()
  -- Only headspeed and pack voltage bound, so Battery %, Current, ESC temp and
  -- Governor are all unbound AND important. An unbound important role is a
  -- warning drawn amber; folded into a list of names it is a warning nobody
  -- reads. These are the rows the fold must leave alone.
  local def, widget = boot(800, 480, { SensorMap = 1 }, function()
    Mock.addSensor("Hspd", 18, 1850)
    Mock.addSensor("Vbat", 1, 47.3)
  end)
  def.refresh(widget, 0, nil)

  H.truthy(string.find(Mock.lvglText(), "unbound", 1, true),
           "the fold must have happened for this to mean anything")
  for _, role in ipairs({ "Battery %", "Current", "ESC temp", "Governor" }) do
    H.truthy(hasOwnRow(role),
             role .. " is important and unbound - it must keep its own row, "
             .. "not be folded into the list")
  end
  -- And the roles that are not important did fold, or nothing was gained.
  H.falsy(hasOwnRow("Tail speed"),
          "an ordinary unbound role should have folded away")
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
