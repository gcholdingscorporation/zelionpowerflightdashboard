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

H.test("nothing at all leaves the widget disarmed", function()
  local ZD = fresh()
  run(ZD, 0.3)
  H.falsy(ZD.State.armed)
  H.eq(ZD.State.armSource, "none")
end)

H.group("state: arming from the rotor")

-- Without this, a flight controller that publishes no ARM flags never records
-- a flight, never resets its peaks and never runs the flight timer - which is
-- every non-Rotorflight stack tried so far.

H.test("a turning head counts as a flight when nothing better exists", function()
  local ZD = fresh(function() Mock.addSensor("Hspd", 18, 1800) end)
  run(ZD, 0.3)
  H.truthy(ZD.State.armed)
  H.eq(ZD.State.armSource, "rotor")
end)

H.test("a stationary rotor does not", function()
  local ZD = fresh(function() Mock.addSensor("Hspd", 18, 0) end)
  run(ZD, 2)
  H.falsy(ZD.State.armed, "a powered heli on the bench is not flying")
end)

H.test("ARM telemetry always wins over the rotor", function()
  local ZD = fresh(function()
    Mock.addSensor("Hspd", 18, 1800)
    Mock.addSensor("ARM", nil, 0)
  end)
  run(ZD, 0.3)
  H.falsy(ZD.State.armed, "the flight controller said no")
  H.eq(ZD.State.armSource, "telemetry")
end)

H.test("spooling down does not end the flight until it stays down", function()
  local ZD = fresh(function() Mock.addSensor("Hspd", 18, 1800) end)
  run(ZD, 1)
  H.truthy(ZD.State.armed)
  Mock.setSensor("Hspd", 60)          -- autorotation, or a bounced landing
  run(ZD, 3)
  H.truthy(ZD.State.armed, "still counting")
  run(ZD, 4)
  H.falsy(ZD.State.armed, "and then it is over")
end)

H.test("a telemetry dropout is not a landing", function()
  local ZD = fresh(function() Mock.addSensor("Hspd", 18, 1800) end)
  run(ZD, 1)
  Mock.removeSensor("Hspd")
  run(ZD, 20)
  H.truthy(ZD.State.armed, "losing the sensor says nothing about the rotor")
end)

H.test("the rotor latch does not follow you to the next model", function()
  -- resetSession clears it, but the `local` it was clearing was declared
  -- further down the file and so was not in scope: the assignment made a
  -- global and the latch survived. A model selected while the previous one was
  -- spinning then started out flying.
  local ZD = fresh(function() Mock.addSensor("Hspd", 18, 1800) end)
  run(ZD, 1)
  H.truthy(ZD.State.armed)

  Mock.state.modelName = "A DIFFERENT HELI"
  Mock.removeSensor("Hspd")           -- the new model has no headspeed at all
  run(ZD, 0.3)
  H.falsy(ZD.State.armed, "a freshly selected model is not in the air")
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

--------------------------------------------------------------------------
-- Battery charge
--------------------------------------------------------------------------
--
-- Rotorflight computes this on the flight controller (Smart Fuel) and ships it
-- as the Bat% sensor, so on a Rotorflight heli none of this runs. The fallback
-- exists for a flight controller that is not Rotorflight, or one with Smart
-- Fuel switched off, and it reproduces Rotorflight's own VOLTAGE-mode curve so
-- the two setups do not disagree about the same pack.

H.group("state: battery charge from voltage")

H.test("matches Rotorflight's curve", function()
  local ZD = fresh()
  local f = ZD.State.chargeFromCellVoltage
  -- The sigmoid from src/main/sensors/smartfuel.c, evaluated at the stock
  -- 3.30/4.00 thresholds. EdgeTX Lua has no reliable math.exp, so this is an
  -- approximation - it has to stay within a percentage point of the real one.
  for _, c in ipairs({ {4.20,100.0}, {4.00,100.0}, {3.90,98.1}, {3.80,86.8},
                       {3.75,70.2},  {3.70,45.7},  {3.65,23.1}, {3.60,9.7},
                       {3.50,1.4},   {3.30,0.0},   {3.20,0.0} }) do
    local got = f(c[1], 3.30, 4.00)
    H.truthy(math.abs(got - c[2]) < 1.0,
             string.format("%.2fV/cell: got %.1f%%, Rotorflight says %.1f%%",
                           c[1], got, c[2]))
  end
end)

H.test("never leaves 0..100, and never goes backwards", function()
  local ZD = fresh()
  local f, last = ZD.State.chargeFromCellVoltage, -1
  for mv = 250, 450 do
    local pct = f(mv / 100, 3.30, 4.00)
    H.truthy(pct >= 0 and pct <= 100,
             string.format("%.2fV gave %.2f%%", mv / 100, pct))
    H.truthy(pct >= last, "charge must rise with voltage")
    last = pct
  end
end)

H.test("derives a percentage when the flight controller publishes none", function()
  local ZD = fresh(function() Mock.addSensor("Vcel", 1, 3.80) end)
  run(ZD, 0.3)
  H.truthy(ZD.State.valid("batteryPercent"), "cell voltage is enough on its own")
  H.eq(ZD.State.status("batteryPercent"), "derived")
  H.truthy(math.abs(ZD.State.num("batteryPercent") - 86.8) < 1.0)
end)

H.test("the flight controller's own reading always wins", function()
  -- Rotorflight knows the pack's history, models sag from stick deflection and
  -- can count coulombs. Overriding that with a bare voltage curve would be a
  -- downgrade, so a valid Bat% is never touched.
  local ZD = fresh(function()
    Mock.addSensor("Vcel", 1, 3.80)      -- the curve would say ~87%
    Mock.addSensor("Bat%", 13, 42)
  end)
  run(ZD, 0.3)
  H.eq(ZD.State.num("batteryPercent"), 42)
  H.eq(ZD.State.status("batteryPercent"), "ok")
end)

H.test("no cell voltage means no guess", function()
  local ZD = fresh(function() Mock.addSensor("Hspd", 18, 1850) end)
  run(ZD, 0.3)
  H.falsy(ZD.State.valid("batteryPercent"),
          "a fabricated percentage is worse than an honest --")
end)

end
