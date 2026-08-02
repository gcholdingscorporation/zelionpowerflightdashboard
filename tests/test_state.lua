-- State model: arm detection, session extremes, hold-freeze, flight timing,
-- derived power, and model switching.

return function(H, Mock, Loader)

local function fresh(setup)
  Mock.reset()
  if setup then setup() end
  Mock.install()
  local ZD = Loader.load()
  ZD.State.reloadModel()
  return ZD
end

-- Service repeatedly with time advancing, so multi-second behaviour can be
-- driven without hand-rolling the tick loop in every test.
local function run(ZD, seconds, opts)
  local steps = math.floor(seconds * 10)
  for _ = 1, steps do
    Mock.advanceSeconds(0.1)
    ZD.State.service(Mock.state.time, opts)
  end
end

H.group("state: arming")

H.test("ARM bit 0 set means armed", function()
  local ZD = fresh(function() Mock.addSensor("ARM", nil, 1) end)
  run(ZD, 0.3)
  H.truthy(ZD.State.armed)
  H.eq(ZD.State.armSource, "telemetry")
end)

H.test("odd ARM values are armed, even are not", function()
  local ZD = fresh(function() Mock.addSensor("ARM", nil, 3) end)
  run(ZD, 0.3)
  H.truthy(ZD.State.armed, "3 has bit 0 set")

  Mock.setSensor("ARM", 4)
  run(ZD, 0.3)
  H.falsy(ZD.State.armed, "4 does not have bit 0 set")
end)

H.test("no ARM telemetry leaves the widget disarmed", function()
  local ZD = fresh(function() Mock.addSensor("Hspd", 18, 1800) end)
  run(ZD, 0.3)
  H.falsy(ZD.State.armed)
  H.eq(ZD.State.armSource, "none")
end)

H.group("state: session extremes")

H.test("tracks a maximum across the session", function()
  local ZD = fresh(function() Mock.addSensor("Hspd", 18, 1000) end)
  run(ZD, 0.3)
  Mock.setSensor("Hspd", 2100)
  run(ZD, 0.3)
  Mock.setSensor("Hspd", 1500)
  run(ZD, 0.3)
  H.eq(ZD.State.num("headspeed"), 1500)
  H.eq(ZD.State.max("headspeed"), 2100)
end)

H.test("arming clears the previous flight's extremes", function()
  local ZD = fresh(function()
    Mock.addSensor("Hspd", 18, 2100)
    Mock.addSensor("ARM", nil, 0)
  end)
  run(ZD, 0.3)
  H.eq(ZD.State.max("headspeed"), 2100, "peak from pre-arm bench running")

  Mock.setSensor("Hspd", 1200)
  Mock.setSensor("ARM", 1)
  run(ZD, 0.3)
  H.eq(ZD.State.max("headspeed"), 1200, "new flight starts a new peak")
end)

H.test("a telemetry dropout does not erase the recorded peak", function()
  local ZD = fresh(function() Mock.addSensor("Hspd", 18, 2100) end)
  run(ZD, 0.3)
  H.eq(ZD.State.max("headspeed"), 2100)

  Mock.setSensor("Hspd", 2100, false) -- link lost
  run(ZD, 0.5)
  H.falsy(ZD.State.valid("headspeed"), "current value is untrustworthy")
  H.eq(ZD.State.max("headspeed"), 2100, "but the peak still stands")
end)

H.group("state: hold")

H.test("hold freezes extremes but not the live value", function()
  local ZD = fresh(function() Mock.addSensor("Curr", 2, 40) end)
  run(ZD, 0.3)
  H.eq(ZD.State.max("current"), 40)

  Mock.setSensor("Curr", 120)
  run(ZD, 0.5, { hold = true })
  H.eq(ZD.State.num("current"), 120, "live value keeps updating")
  H.eq(ZD.State.max("current"), 40, "peak is frozen while held")

  run(ZD, 0.3)
  H.eq(ZD.State.max("current"), 120, "and resumes when released")
end)

H.group("state: flight timer")

H.test("counts only while armed", function()
  local ZD = fresh(function() Mock.addSensor("ARM", nil, 0) end)
  run(ZD, 3)
  H.eq(ZD.State.flightSeconds, 0, "disarmed time is not flight time")

  Mock.setSensor("ARM", 1)
  run(ZD, 5)
  H.truthy(ZD.State.flightSeconds >= 4,
           "expected ~5s, got " .. tostring(ZD.State.flightSeconds))
end)

H.test("hold pauses the flight timer", function()
  local ZD = fresh(function() Mock.addSensor("ARM", nil, 1) end)
  run(ZD, 3)
  local before = ZD.State.flightSeconds
  run(ZD, 3, { hold = true })
  H.eq(ZD.State.flightSeconds, before, "held time does not accumulate")
end)

H.group("state: derived power")

H.test("derives watts from valid voltage and current", function()
  local ZD = fresh(function()
    Mock.addSensor("Vbat", 1, 50)
    Mock.addSensor("Curr", 2, 30)
  end)
  run(ZD, 0.3)
  H.eq(ZD.State.num("power"), 1500)
  H.eq(ZD.State.status("power"), "derived")
end)

H.test("does not invent power when a term is missing", function()
  local ZD = fresh(function() Mock.addSensor("Vbat", 1, 50) end)
  run(ZD, 0.3)
  H.falsy(ZD.State.valid("power"), "no current means no power reading")
end)

H.test("a published power sensor is preferred over derivation", function()
  local ZD = fresh(function()
    Mock.addSensor("Vbat", 1, 50)
    Mock.addSensor("Curr", 2, 30)
    Mock.addSensor("Pwr", nil, 1490)
  end)
  run(ZD, 0.3)
  H.eq(ZD.State.num("power"), 1490)
  H.eq(ZD.State.status("power"), "ok")
end)

H.group("state: model switching")

H.test("changing model rebinds sensors and clears the session", function()
  local ZD = fresh(function()
    Mock.addSensor("Hspd", 18, 2100)
    Mock.writeFile("/WIDGETS/ZelionDash/sensors.cfg",
      "[Other Heli]\nheadspeed = Alt\n")
    Mock.addSensor("Alt", 18, 900)
  end)
  run(ZD, 0.3)
  H.eq(ZD.Sensors.boundTo("headspeed"), "Hspd")
  H.eq(ZD.State.max("headspeed"), 2100)

  Mock.state.modelName = "Other Heli"
  run(ZD, 0.3)
  H.eq(ZD.Sensors.boundTo("headspeed"), "Alt", "override for the new model")
  H.eq(ZD.State.max("headspeed"), 900, "extremes do not carry across models")
end)

H.group("state: disarm latch")

H.test("disarm is latched once and consumed once", function()
  local ZD = fresh(function() Mock.addSensor("ARM", nil, 1) end)
  run(ZD, 0.3)
  H.falsy(ZD.State.disarmPending)

  Mock.setSensor("ARM", 0)
  run(ZD, 0.3)
  H.truthy(ZD.State.disarmPending)
  H.truthy(ZD.State.consumeDisarm(), "first consumer gets the flight")
  H.falsy(ZD.State.consumeDisarm(), "second consumer must not re-log it")
end)

end
