-- Exercises the amalgamated dist/ file, not the src/ modules.
--
-- A build that compiles but does not run is the failure mode that matters
-- here: on the radio it surfaces as an opaque "widget script error" with no
-- indication of which module broke. So load the real artifact and drive a
-- full widget lifecycle through it.

return function(H, Mock, Loader)

local DIST = "dist/WIDGETS/ZelionDash/main.lua"

local function loadDist()
  local chunk, err = loadfile(DIST)
  if not chunk then error("built file does not compile: " .. tostring(err)) end
  return chunk()
end

H.group("build: amalgamated artifact")

H.test("exports the EdgeTX widget interface", function()
  Mock.reset()
  Mock.install()
  local w = loadDist()
  H.eq(w.name, "ZelionDash")
  H.truthy(type(w.create) == "function")
  H.truthy(type(w.update) == "function")
  H.truthy(type(w.refresh) == "function")
  H.truthy(type(w.background) == "function")
  H.truthy(type(w.options) == "table")
end)

H.test("runs a full lifecycle at 800x480", function()
  Mock.reset()
  Mock.state.lcdW, Mock.state.lcdH = 800, 480
  Mock.addSensor("Hspd", 18, 1850)
  Mock.addSensor("Curr", 2, 42)
  Mock.install()

  local w = loadDist()
  local widget = w.create({ x = 0, y = 0, w = 800, h = 480 }, {})
  w.background(widget)
  Mock.advanceSeconds(0.2)
  w.refresh(widget, 0, nil)

  local text = Mock.drawnText()
  H.truthy(string.find(text, "ZelionDash", 1, true), "header drawn")
  H.truthy(string.find(text, "Hspd", 1, true), "bound sensor listed")
  H.truthy(string.find(text, "1850", 1, true), "live value shown")
end)

H.test("runs a full lifecycle at 480x272", function()
  Mock.reset()
  Mock.state.lcdW, Mock.state.lcdH = 480, 272
  Mock.state.radio = "tx16s"
  Mock.addSensor("Hspd", 18, 1850)
  Mock.install()

  local w = loadDist()
  local widget = w.create({ x = 0, y = 0, w = 480, h = 272 }, {})
  Mock.advanceSeconds(0.2)
  w.refresh(widget, 0, nil)

  H.truthy(string.find(Mock.drawnText(), "Hspd", 1, true),
           "the small screen still renders the sensor map")
end)

H.test("the small screen shows fewer rows and can scroll", function()
  Mock.reset()
  Mock.state.lcdW, Mock.state.lcdH = 480, 272
  Mock.addSensor("Hspd", 18, 1850)
  Mock.install()

  local w = loadDist()
  local widget = w.create({ x = 0, y = 0, w = 480, h = 272 }, {})
  Mock.advanceSeconds(0.2)

  w.refresh(widget, 0, nil)
  local firstPage = Mock.drawnText()

  -- Scrolling must actually change what is on screen, otherwise roles past
  -- the fold are unreachable on the smaller radio.
  Mock.draws = {}
  for _ = 1, 8 do w.refresh(widget, 100, nil) end
  local scrolled = Mock.drawnText()

  H.truthy(firstPage ~= scrolled, "scrolling changed the visible rows")
end)

H.test("survives a model with no telemetry at all", function()
  Mock.reset()
  Mock.install()
  local w = loadDist()
  local widget = w.create({ x = 0, y = 0, w = 800, h = 480 }, {})
  Mock.advanceSeconds(0.2)
  w.refresh(widget, 0, nil)
  H.truthy(string.find(Mock.drawnText(), "0/", 1, true),
           "reports nothing bound rather than erroring")
end)

end
