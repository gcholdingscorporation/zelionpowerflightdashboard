-- Resolver behaviour: binding priority, ambiguity refusal, late discovery,
-- stale-id recovery, and the missing-vs-zero distinction.

return function(H, Mock, Loader)

local function fresh(setup)
  Mock.reset()
  if setup then setup() end
  Mock.install()
  local ZD = Loader.load()
  ZD.State.reloadModel()
  -- One service pass so State has sampled every role. Without this the tests
  -- would be asserting against an empty state model rather than the resolver.
  Mock.advanceSeconds(0.2)
  ZD.State.service(Mock.state.time)
  return ZD
end

H.group("sensors: binding priority")

H.test("binds a role by its preferred candidate name", function()
  local ZD = fresh(function()
    Mock.addSensor("Hspd", 18, 1850)
  end)
  H.eq(ZD.Sensors.boundTo("headspeed"), "Hspd")
  H.eq(ZD.Sensors.howBound("headspeed"), "name")
end)

H.test("prefers the earlier candidate when several exist", function()
  local ZD = fresh(function()
    Mock.addSensor("RPM", 18, 1000)
    Mock.addSensor("Hspd", 18, 1850)
  end)
  -- Hspd is listed before RPM in the role definition, so it must win
  -- regardless of the order the radio reports its sensors.
  H.eq(ZD.Sensors.boundTo("headspeed"), "Hspd")
end)

H.test("an override beats every candidate name", function()
  local ZD = fresh(function()
    Mock.addSensor("Hspd", 18, 1850)
    Mock.addSensor("MyRPM", 18, 1234)
    Mock.writeFile("/WIDGETS/ZelionDash/sensors.cfg",
      "[Test Heli]\nheadspeed = MyRPM\n")
  end)
  H.eq(ZD.Sensors.boundTo("headspeed"), "MyRPM")
  H.eq(ZD.Sensors.howBound("headspeed"), "override")
  H.eq(ZD.State.num("headspeed"), 1234)
end)

H.test("a model section overrides the [*] defaults", function()
  local ZD = fresh(function()
    Mock.addSensor("Tesc", 11, 60)
    Mock.addSensor("Tmp1", 11, 71)
    Mock.writeFile("/WIDGETS/ZelionDash/sensors.cfg",
      "[*]\nescTemperature = Tesc\n\n[Test Heli]\nescTemperature = Tmp1\n")
  end)
  H.eq(ZD.Sensors.boundTo("escTemperature"), "Tmp1")
end)

H.test("an override naming a sensor that does not exist falls back", function()
  local ZD = fresh(function()
    Mock.addSensor("Hspd", 18, 1850)
    Mock.writeFile("/WIDGETS/ZelionDash/sensors.cfg",
      "[*]\nheadspeed = Nonsense\n")
  end)
  -- Failing loud would mean an empty panel because of one typo. Falling back
  -- to auto-detection keeps the dashboard useful; the diagnostics screen is
  -- where the typo gets reported.
  H.eq(ZD.Sensors.boundTo("headspeed"), "Hspd")
  H.eq(ZD.Sensors.howBound("headspeed"), "name")
end)

H.group("sensors: unit discovery")

H.test("binds an unnamed sensor when exactly one carries the unit", function()
  local ZD = fresh(function()
    Mock.addSensor("Weird", 2, 42) -- amps, matches no candidate name
  end)
  H.eq(ZD.Sensors.boundTo("current"), "Weird")
  H.eq(ZD.Sensors.howBound("current"), "unit")
end)

H.test("refuses to guess when two sensors share the unit", function()
  local ZD = fresh(function()
    Mock.addSensor("WeirdA", 2, 42)
    Mock.addSensor("WeirdB", 2, 17)
  end)
  -- Ambiguity must produce no binding at all. A confidently wrong tile is
  -- worse than an empty one.
  H.nilv(ZD.Sensors.boundTo("current"))
end)

H.test("does not steal a sensor already claimed by name", function()
  local ZD = fresh(function()
    Mock.addSensor("Tesc", 11, 60)  -- claimed by escTemperature via name
  end)
  H.eq(ZD.Sensors.boundTo("escTemperature"), "Tesc")
  H.nilv(ZD.Sensors.boundTo("mcuTemperature"))
end)

H.group("sensors: missing vs zero")

H.test("a genuine zero reads as valid", function()
  local ZD = fresh(function()
    Mock.addSensor("Hspd", 18, 0)
  end)
  local v, ok = ZD.State.get("headspeed")
  H.eq(v, 0)
  H.truthy(ok, "a real zero must be valid")
end)

H.test("an absent sensor is invalid, not zero", function()
  local ZD = fresh(function() end)
  local v, ok = ZD.State.get("headspeed")
  H.nilv(v)
  H.falsy(ok)
  H.eq(ZD.State.status("headspeed"), "unbound")
end)

H.test("an out-of-range reading is rejected rather than shown", function()
  local ZD = fresh(function()
    Mock.addSensor("Vcel", 1, 9.9) -- no cell is 9.9V
  end)
  H.falsy(ZD.State.valid("cellVoltage"))
  H.eq(ZD.State.status("cellVoltage"), "insane")
end)

H.group("sensors: late discovery and recovery")

H.test("a sensor appearing later gets picked up", function()
  local ZD = fresh(function() end)
  H.nilv(ZD.Sensors.boundTo("headspeed"), "not present at startup")

  -- Heli powered on after the radio.
  Mock.addSensor("Hspd", 18, 1600)
  Mock.advanceSeconds(1.5)
  ZD.State.service(Mock.state.time)

  H.eq(ZD.Sensors.boundTo("headspeed"), "Hspd")
  H.eq(ZD.State.num("headspeed"), 1600)
end)

H.test("a source that stops reporting is released and rebound", function()
  local ZD = fresh(function()
    Mock.addSensor("Hspd", 18, 1600)
  end)
  H.eq(ZD.Sensors.boundTo("headspeed"), "Hspd")

  Mock.setSensor("Hspd", 1600, false) -- link lost
  Mock.advanceSeconds(0.2)
  ZD.State.service(Mock.state.time)
  H.falsy(ZD.State.valid("headspeed"))

  Mock.setSensor("Hspd", 1700, true)  -- link back
  Mock.advanceSeconds(1.5)
  ZD.State.service(Mock.state.time)
  H.eq(ZD.State.num("headspeed"), 1700)
end)

H.group("sensors: diagnostics")

H.test("report covers every role and flags the important ones", function()
  local ZD = fresh(function()
    Mock.addSensor("Hspd", 18, 1850)
  end)
  local rows = ZD.Sensors.report()
  H.eq(#rows, #ZD.Roles.order)

  local byRole = {}
  for _, r in ipairs(rows) do byRole[r.role] = r end
  H.eq(byRole.headspeed.sensor, "Hspd")
  H.eq(byRole.headspeed.status, "ok")
  H.truthy(byRole.headspeed.important)
  H.eq(byRole.governor.status, "unbound")
end)

end
