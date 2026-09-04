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

H.group("sensors: switching a role off")

-- The percent sensors an ExpressLRS radio actually publishes. Every one of
-- them matters to the outcome: Bat% and RQly get claimed by name, which is
-- what leaves TQly as the single unclaimed percent sensor for the unit pass
-- to hand to throttle. Drop any one and the guess does not happen.
local function elrs()
  Mock.addSensor("Bat%", 13, 99)
  Mock.addSensor("RQly", 13, 100)
  Mock.addSensor("TQly", 13, 100)
end

-- The unit pass is a guess, and a guess a pilot cannot overrule is worse than
-- no guess. On an ExpressLRS radio there is no Thr sensor, so throttle fell
-- through to the unit pass and matched TQly - the transmitter link quality -
-- producing a confident, permanent THR 100%.

H.test("off leaves a role unbound instead of guessing", function()
  local ZD = fresh(function()
    elrs()
    Mock.writeFile("/WIDGETS/ZelionDash/sensors.cfg",
      "[*]\nthrottle = off\n")
  end)
  H.nilv(ZD.Sensors.boundTo("throttle"))
  H.eq(ZD.State.status("throttle"), "unbound")
end)

H.test("a sensor another role knows by name is never a guess for throttle", function()
  -- This test used to pin the opposite: TQly guessed as throttle, kept as a
  -- reminder that "off" existed to defeat it. Then it happened in the field
  -- on the second aircraft, the one whose config section said it needed no
  -- override. A guess the widget can rule out by reading its own role table
  -- is not a guess worth making.
  local ZD = fresh(function()
    elrs()
  end)
  H.eq(ZD.Sensors.boundTo("throttle"), nil,
       "TQly is a linkQuality candidate; the resolver knows what it is")
  H.eq(ZD.State.status("throttle"), "unbound")
end)

H.test("a sensor nobody knows by name can still be guessed by unit", function()
  -- The unit pass still has a job: an unfamiliar sensor with the right unit
  -- and no competition. That is what makes "off" still worth having - it is
  -- the only way to refuse a guess the widget cannot rule out by itself.
  local ZD = fresh(function()
    Mock.addSensor("Bat%", 13, 99)
    Mock.addSensor("RQly", 13, 100)
    Mock.addSensor("Thrtl", 13, 40)     -- not a name any role lists
  end)
  H.eq(ZD.Sensors.boundTo("throttle"), "Thrtl")
  H.eq(ZD.Sensors.howBound("throttle"), "unit")
end)

H.test("a role switched off is not reported as unresolved", function()
  -- It is a decision, not a gap. Counting it would inflate the number the
  -- sensor map footer shows and send the pilot looking for a missing sensor.
  local ZD = fresh(function()
    Mock.writeFile("/WIDGETS/ZelionDash/sensors.cfg", "[*]\nthrottle = off\n")
  end)
  for _, role in ipairs(ZD.Sensors.unresolved) do
    H.truthy(role ~= "throttle", "throttle must not be in the unresolved list")
  end
end)

H.test("the sensor map says off rather than showing a blank", function()
  local ZD = fresh(function()
    elrs()
    Mock.writeFile("/WIDGETS/ZelionDash/sensors.cfg", "[*]\nthrottle = off\n")
  end)
  local byRole = {}
  for _, r in ipairs(ZD.Sensors.report()) do byRole[r.role] = r end
  H.truthy(byRole.throttle.off, "flagged as a deliberate choice")
end)

-- A percent sensor with a name no role lists, so the unit pass still guesses
-- it for throttle. These tests are about "off", and need a guess to switch
-- off; TQly no longer qualifies, since linkQuality knows it by name.
local function guessableThrottle()
  Mock.addSensor("Bat%", 13, 99)
  Mock.addSensor("RQly", 13, 100)
  Mock.addSensor("Thrtl", 13, 40)
end

H.test("switching a role off releases a binding it already had", function()
  local ZD = fresh(function()
    guessableThrottle()
  end)
  H.eq(ZD.Sensors.boundTo("throttle"), "Thrtl", "bound before")
  Mock.writeFile("/WIDGETS/ZelionDash/sensors.cfg", "[*]\nthrottle = off\n")
  ZD.Config.load()
  ZD.Sensors.reload("Test Heli")
  H.nilv(ZD.Sensors.boundTo("throttle"), "and released after")
end)

H.test("one model can switch a role off without affecting the others", function()
  local ZD = fresh(function()
    guessableThrottle()
    Mock.writeFile("/WIDGETS/ZelionDash/sensors.cfg",
      "[Other Heli]\nthrottle = off\n")
  end)
  H.eq(ZD.Sensors.boundTo("throttle"), "Thrtl", "this model was not the one")
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
