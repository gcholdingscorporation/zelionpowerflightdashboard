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

end
