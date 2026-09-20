-- Config parsing and host filesystem behaviour.

return function(H, Mock, Loader)

local function fresh(setup)
  Mock.reset()
  if setup then setup() end
  Mock.install()
  return Loader.load()
end

H.group("config: parsing")

H.test("parses sections and key/value pairs", function()
  local ZD = fresh()
  local sections = ZD.Config.parse(
    "[*]\nheadspeed = Hspd\n\n[Goblin 700]\ncurrent=Curr\n")
  H.eq(sections["*"].headspeed, "Hspd")
  H.eq(sections["goblin 700"].current, "Curr")
end)

H.test("ignores blank lines and both comment styles", function()
  local ZD = fresh()
  local sections, problems = ZD.Config.parse(
    "# hash comment\n; semicolon comment\n\n[*]\nheadspeed = Hspd\n")
  H.eq(sections["*"].headspeed, "Hspd")
  H.eq(#problems, 0)
end)

H.test("reports an unknown role instead of dropping it", function()
  local ZD = fresh()
  local sections, problems = ZD.Config.parse("[*]\nhedspeed = Hspd\n")
  H.nilv(sections["*"].hedspeed)
  H.eq(#problems, 1)
  H.truthy(string.find(problems[1], "hedspeed", 1, true),
           "the problem should name the offending key")
end)

H.test("reports a malformed line", function()
  local ZD = fresh()
  local _, problems = ZD.Config.parse("[*]\nthis is not a pair\n")
  H.eq(#problems, 1)
end)

H.test("section matching is case-insensitive", function()
  local ZD = fresh(function()
    Mock.state.modelName = "Goblin 700"
    Mock.writeFile("/WIDGETS/ZelionDash/sensors.cfg",
      "[GOBLIN 700]\nheadspeed = Custom\n")
  end)
  local overrides = ZD.Config.overridesFor("Goblin 700")
  H.eq(overrides.headspeed, "Custom")
end)

H.test("a missing config file is normal, not an error", function()
  local ZD = fresh()
  local overrides = ZD.Config.overridesFor("Anything")
  H.eq(next(overrides), nil, "no overrides, no problems")
  H.eq(#ZD.Config.problems, 0)
end)

H.group("host: filesystem")

H.test("round-trips a file", function()
  local ZD = fresh()
  H.truthy(ZD.Host.writeFile("/test.txt", "hello"))
  H.eq(ZD.Host.readFile("/test.txt"), "hello")
  H.truthy(ZD.Host.exists("/test.txt"))
end)

H.test("reads a file larger than one chunk", function()
  local ZD = fresh()
  local big = string.rep("x", 4096) .. "END"
  ZD.Host.writeFile("/big.txt", big)
  H.eq(ZD.Host.readFile("/big.txt"), big)
end)

H.test("reports a missing file as nil rather than empty", function()
  local ZD = fresh()
  H.nilv(ZD.Host.readFile("/nope.txt"))
  H.falsy(ZD.Host.exists("/nope.txt"))
end)

H.test("atomic write leaves no temp files behind", function()
  Mock.reset()
  Mock.install()
  Mock.enableAtomicWrites()
  local ZD = Loader.load()

  ZD.Host.writeFile("/atomic.txt", "first")
  ZD.Host.writeFile("/atomic.txt", "second")
  H.eq(ZD.Host.readFile("/atomic.txt"), "second")
  H.nilv(Mock.state.files["/atomic.txt.tmp"], "temp file must be cleaned up")
  H.nilv(Mock.state.files["/atomic.txt.bak"], "backup must be cleaned up")
end)

H.group("host: capability fallback")

H.test("works without getSourceValue", function()
  Mock.reset()
  Mock.state.hasSourceValue = false
  Mock.addSensor("Hspd", 18, 1750)
  Mock.install()
  local ZD = Loader.load()
  ZD.State.reloadModel()
  Mock.advanceSeconds(0.2)
  ZD.State.service(Mock.state.time)
  H.eq(ZD.State.num("headspeed"), 1750)
end)

H.test("works without model.getSensor, losing only unit discovery", function()
  Mock.reset()
  Mock.state.hasGetSensor = false
  Mock.addSensor("Hspd", 18, 1750)
  Mock.addSensor("Weird", 2, 42)
  Mock.install()
  local ZD = Loader.load()
  ZD.State.reloadModel()
  H.eq(ZD.Sensors.boundTo("headspeed"), "Hspd", "name binding still works")
  H.nilv(ZD.Sensors.boundTo("current"), "unit discovery is unavailable")
end)

H.group("config: [battery] settings")

local function parse(text)
  Mock.reset(); Mock.install()
  local ZD = Loader.load()
  local _, problems, settings = ZD.Config.parse(text)
  return settings, problems, ZD
end

H.test("defaults match Rotorflight's stock cell thresholds", function()
  local s = parse(nil)
  H.eq(s.cellFull, 4.00)
  H.eq(s.cellMin, 3.30)
end)

H.test("a pilot can retune the curve for their chemistry", function()
  local s, problems = parse("[battery]\ncellFull = 4.20\ncellMin = 3.00\n")
  H.eq(s.cellFull, 4.20)
  H.eq(s.cellMin, 3.00)
  H.eq(#problems, 0)
end)

H.test("the reserved section does not swallow sensor overrides", function()
  Mock.reset(); Mock.install()
  local ZD = Loader.load()
  local sections, problems = ZD.Config.parse(
    "[battery]\ncellMin = 3.20\n\n[Goblin 700]\nheadspeed = Hspd\n")
  H.eq(#problems, 0)
  H.eq(sections["goblin 700"].headspeed, "Hspd")
  H.nilv(sections["battery"], "settings are not sensor bindings")
end)

H.test("a value outside the plausible range is a typo, not an intention", function()
  local s, problems = parse("[battery]\ncellMin = 33\n")
  H.truthy(#problems > 0, "must be reported")
  H.eq(s.cellMin, 3.30, "and must not be applied")
end)

H.test("an inverted pair falls back rather than inverting the curve", function()
  local s, problems = parse("[battery]\ncellFull = 3.40\ncellMin = 3.90\n")
  H.truthy(#problems > 0)
  H.eq(s.cellMin, 3.30)
  H.eq(s.cellFull, 4.00)
end)

H.test("an unknown setting is named, not silently ignored", function()
  local _, problems = parse("[battery]\ncellNominal = 3.7\n")
  H.truthy(#problems > 0)
  H.truthy(string.find(problems[1], "cellNominal", 1, true))
end)

H.group("config: settings scoped to an aircraft")

-- Loads a real file through Config.load and points it at one aircraft, which
-- is how the widget gets there: Sensors.reload sets the scope.
local function scoped(text, modelName, craftName, cells)
  Mock.reset()
  Mock.state.modelName = modelName
  Mock.writeFile("/WIDGETS/ZelionDash/sensors.cfg", text)
  Mock.install()
  local ZD = Loader.load()
  ZD.Config.load()
  ZD.Config.scope(modelName, craftName, cells)
  return ZD
end

local FLEET = table.concat({
  "[battery]", "reservePct = 40", "",
  "[OMP Microheli]", "reservePct = 30", "",
  "[cells:2]", "reservePct = 25", "",
  "[ALZRC Devil 380]", "reservePct = 45", "",
}, "\n")

H.test("with nothing scoped, [battery] is still radio-wide", function()
  local ZD = scoped(FLEET, ">Rotorflight", nil, 12)
  H.eq(ZD.Config.setting("reservePct"), 40)
end)

H.test("a reserve scoped to the model beats the radio-wide one", function()
  local ZD = scoped(FLEET, "OMP Microheli", nil, 3)
  H.eq(ZD.Config.setting("reservePct"), 30)
end)

H.test("a cell count is more specific than the model slot", function()
  local ZD = scoped(FLEET, "OMP Microheli", nil, 2)
  H.eq(ZD.Config.setting("reservePct"), 25)
end)

H.test("a reported craft name beats every other scope", function()
  local ZD = scoped(FLEET, ">Rotorflight", "ALZRC Devil 380", 6)
  H.eq(ZD.Config.setting("reservePct"), 45)
end)

-- The bug this whole change exists to prevent, and the one a flat table makes
-- almost inevitable: resolve has to rebuild from the base every time, or the
-- helicopter that just landed keeps deciding the reserve for the next one.
H.test("changing aircraft does not leave the last one's reserve behind", function()
  local ZD = scoped(FLEET, ">Rotorflight", "ALZRC Devil 380", 6)
  H.eq(ZD.Config.setting("reservePct"), 45)
  ZD.Config.scope(">Rotorflight", nil, 12)
  H.eq(ZD.Config.setting("reservePct"), 40, "back to the radio-wide figure")
end)

H.test("a setting a pilot scoped to an aircraft counts as explicit", function()
  local ZD = scoped(FLEET, "OMP Microheli", nil, 2)
  H.truthy(ZD.Config.explicit.reservePct)
end)

-- Profiles.setting may fill in a threshold nobody set and must never overrule
-- one that was written down. Scoping is writing it down.
H.test("an aircraft profile cannot overrule a scoped threshold", function()
  local ZD = scoped("[OMP Microheli]\nalertEsc = 70\n", "OMP Microheli", nil, 2)
  H.eq(ZD.Profiles.setting("alertEsc"), 70)
end)

H.test("a scoped setting shows up on the config row", function()
  local ZD = scoped(FLEET, "OMP Microheli", nil, 2)
  local applied, count = ZD.Config.appliedFor("OMP Microheli", nil, 2)
  H.eq(count, 3, "[OMP Microheli] + [cells:2] + [battery], one each")
  local joined = table.concat(applied, ",")
  H.truthy(string.find(joined, "cells:2", 1, true))
  H.truthy(string.find(joined, "battery", 1, true))
end)

H.test("an out-of-range scoped setting is reported, not applied", function()
  local s, problems = parse("[Goblin 700]\nreservePct = 400\n")
  H.truthy(#problems > 0)
  H.eq(s.reservePct, 20, "the default stands")
end)

-- A section may set one half of the pair and inherit the other, so the check
-- has to be against the base rather than within the section.
H.test("a scoped cell range that inverts is refused", function()
  local _, problems = parse("[battery]\ncellFull = 4.00\n\n[Goblin 700]\ncellMin = 4.10\n")
  H.truthy(#problems > 0)
  H.truthy(string.find(problems[1], "cellMin", 1, true))
end)

-- The wiring rather than the resolution. Every other test in this group sets
-- the scope itself, so all of them keep passing with the scope call commented
-- out of Sensors.reload - and that call is the only thing connecting any of
-- this to the radio. This one goes through the call the widget actually makes.
H.test("reloading the bindings re-scopes the settings with them", function()
  Mock.reset()
  Mock.state.modelName = ">Rotorflight"
  Mock.writeFile("/WIDGETS/ZelionDash/sensors.cfg", FLEET)
  Mock.install()
  local ZD = Loader.load()
  ZD.Sensors.reload(">Rotorflight", "ALZRC Devil 380", 6)
  H.eq(ZD.Config.setting("reservePct"), 45, "the craft's reserve, not [battery]'s")
end)

H.test("a role binding and a setting coexist in one section", function()
  local ZD = scoped("[Goblin 700]\nheadspeed = Hspd\nreservePct = 35\n",
                    "Goblin 700", nil, 6)
  H.eq(ZD.Config.overridesFor("Goblin 700").headspeed, "Hspd")
  H.eq(ZD.Config.setting("reservePct"), 35)
end)

end
