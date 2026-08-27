-- Time remaining: the number a pilot actually wants, and the one no telemetry
-- stream carries.
--
-- Most of these are about refusing to answer. An estimate that is confidently
-- wrong is worse than a dash, because a pilot plans a landing around it.

return function(H, Mock, Loader)

local function fresh(setup)
  Mock.reset()
  Mock.removeRf2()
  if setup then setup() end
  Mock.install()
  local ZD = Loader.load()
  ZD.State.reloadModel()
  return ZD
end

local function run(ZD, seconds)
  for _ = 1, math.floor(seconds * 10) do
    Mock.advanceSeconds(0.1)
    ZD.State.service(Mock.state.time)
    ZD.FlightTime.service(Mock.state.time)
  end
end

-- A 1000 mAh 3S turning, drawing a steady rate. Capacity used and percent are
-- driven together, the way a flight controller reports them.
local function heli(pack)
  pack = pack or 1000
  Mock.addSensor("Hspd", 18, 5000)
  Mock.addSensor("Vbat", 1, 11.4)
  Mock.addSensor("Capa", 14, 0)
  Mock.addSensor("Bat%", 13, 100)
  return {
    -- Burn `mah` more, and move percent to match a pack of this size.
    burn = function(used)
      Mock.setSensor("Capa", used)
      Mock.setSensor("Bat%", math.max(0, 100 - (used / pack) * 100))
    end,
  }
end

-- Fly for `secs` at `mahPerMin`, stepping capacity as the FC would.
local function fly(ZD, h, secs, mahPerMin, used0)
  local used = used0 or 0
  for i = 1, math.floor(secs) do
    used = used + mahPerMin / 60
    h.burn(used)
    run(ZD, 1)
  end
  return used
end

H.group("flighttime: refusing to answer")

H.test("says nothing on the ground", function()
  local ZD = fresh(function()
    Mock.addSensor("Hspd", 18, 0)
    Mock.addSensor("Capa", 14, 0)
    Mock.addSensor("Bat%", 13, 100)
  end)
  run(ZD, 20)
  H.nilv(ZD.FlightTime.seconds)
  H.eq(ZD.FlightTime.why, "idle")
end)

H.test("will not guess in the first few seconds", function()
  local ZD, h = nil, nil
  ZD = fresh(function() h = heli() end)
  fly(ZD, h, 4, 600)
  H.nilv(ZD.FlightTime.seconds, "four seconds of draw is not a measurement")
  H.eq(ZD.FlightTime.why, "measuring")
end)

H.test("will not guess off a full pack", function()
  -- Near 100% the remainder arithmetic divides by almost nothing and the
  -- answer runs away.
  local ZD, h = nil, nil
  ZD = fresh(function() h = heli(100000) end)   -- huge pack, percent barely moves
  fly(ZD, h, 20, 600)
  H.nilv(ZD.FlightTime.seconds)
  H.eq(ZD.FlightTime.why, "pack too full to tell")
end)

H.test("no capacity sensor, no estimate", function()
  local ZD = fresh(function()
    Mock.addSensor("Hspd", 18, 5000)
    Mock.addSensor("Bat%", 13, 60)
  end)
  run(ZD, 20)
  H.nilv(ZD.FlightTime.seconds)
  H.eq(ZD.FlightTime.why, "no capacity sensor")
end)

H.test("no battery percent, no estimate", function()
  local ZD = fresh(function()
    Mock.addSensor("Hspd", 18, 5000)
    Mock.addSensor("Capa", 14, 200)
  end)
  run(ZD, 20)
  H.nilv(ZD.FlightTime.seconds)
  H.eq(ZD.FlightTime.why, "no battery percent")
end)

H.group("flighttime: the estimate")

H.test("works out the remainder without being told the pack size", function()
  -- 1000 mAh pack, 600 mAh/min. At 50% used there is 300 mAh left above a
  -- 20% reserve, which at 10 mAh/s is 30 seconds.
  local ZD, h = nil, nil
  ZD = fresh(function() h = heli(1000) end)
  fly(ZD, h, 50, 600)
  local s = ZD.FlightTime.seconds
  H.truthy(s, "an estimate exists: " .. tostring(ZD.FlightTime.why))
  H.truthy(s > 20 and s < 45, "about half a minute, got " .. string.format("%.0f", s))
end)

H.test("the same maths holds on a 400mAh pack", function()
  -- Nothing anywhere is told which pack this is. 80 mAh gone of 400 leaves
  -- 240 above a 20% reserve, and 240 mAh/min is 4 mAh/s - so a minute.
  local ZD, h = nil, nil
  ZD = fresh(function() h = heli(400) end)
  fly(ZD, h, 20, 240)
  local s = ZD.FlightTime.seconds
  H.truthy(s, tostring(ZD.FlightTime.why))
  H.truthy(s > 50 and s < 70, "about a minute, got " .. string.format("%.0f", s))
end)

H.test("draws harder, lands sooner", function()
  local a, b
  do
    local ZD, h = nil, nil
    ZD = fresh(function() h = heli(1000) end)
    fly(ZD, h, 30, 300)
    a = ZD.FlightTime.seconds
  end
  do
    local ZD, h = nil, nil
    ZD = fresh(function() h = heli(1000) end)
    fly(ZD, h, 30, 900)
    b = ZD.FlightTime.seconds
  end
  H.truthy(a and b)
  H.truthy(b < a, "three times the draw must not read as longer")
end)

H.test("reaches zero at the reserve, not at a flat pack", function()
  local ZD, h = nil, nil
  ZD = fresh(function() h = heli(1000) end)
  fly(ZD, h, 80, 600)          -- 800 mAh gone, 20% left
  H.eq(ZD.FlightTime.seconds, 0, "the reserve is the floor")
end)

H.group("flighttime: not lying to the pilot")

H.test("the estimate never climbs", function()
  -- A number that goes up while you fly reads as broken even when the
  -- arithmetic is right after a spell of hovering - and EdgeTX announces a
  -- countdown by watching thresholds, so a value drifting back over 60 would
  -- say "one minute" twice.
  local ZD, h = nil, nil
  ZD = fresh(function() h = heli(1000) end)
  local used = fly(ZD, h, 40, 900)      -- hard
  local hard = ZD.FlightTime.seconds
  H.truthy(hard)
  fly(ZD, h, 40, 60, used)              -- then barely drawing at all
  H.truthy(ZD.FlightTime.seconds <= hard, "must not climb back up")
end)

H.test("a new pack starts over rather than reading a negative draw", function()
  local ZD, h = nil, nil
  ZD = fresh(function() h = heli(1000) end)
  fly(ZD, h, 40, 600)
  H.truthy(ZD.FlightTime.seconds)
  h.burn(0)                              -- FC counter reset: fresh battery
  run(ZD, 0.1)                           -- the pass that spots it
  H.nilv(ZD.FlightTime.seconds)
  H.eq(ZD.FlightTime.why, "new pack")
  run(ZD, 2)
  H.nilv(ZD.FlightTime.seconds, "and it is measuring again, not estimating")
end)

H.test("landing clears it", function()
  local ZD, h = nil, nil
  ZD = fresh(function() h = heli(1000) end)
  fly(ZD, h, 40, 600)
  H.truthy(ZD.FlightTime.seconds)
  Mock.setSensor("Hspd", 0)
  run(ZD, 8)
  H.nilv(ZD.FlightTime.seconds, "no flight, no estimate")
end)

H.test("the reserve is configurable", function()
  local ZD, h = nil, nil
  ZD = fresh(function()
    h = heli(1000)
    Mock.writeFile("/WIDGETS/ZelionDash/sensors.cfg",
      "[battery]\nreservePct = 0\n")
  end)
  fly(ZD, h, 50, 600)
  local s = ZD.FlightTime.seconds
  H.truthy(s > 45, "flying it to empty is a longer flight, got " ..
                   string.format("%.0f", s))
end)

H.group("flighttime: driving an EdgeTX timer")

H.test("off by default, and touches nothing", function()
  local ZD, h = nil, nil
  ZD = fresh(function() h = heli(1000) end)
  fly(ZD, h, 40, 600)
  ZD.FlightTime.driveTimer()
  H.eq(Mock.state.timerWrites, 0, "no timer selected, so no writes")
end)

H.test("writes the estimate into the chosen timer", function()
  local ZD, h = nil, nil
  ZD = fresh(function() h = heli(1000) end)
  ZD.FlightTime.timerIndex = 1
  fly(ZD, h, 50, 600)
  ZD.FlightTime.driveTimer()
  local t = Mock.state.timers[1]
  H.truthy(t, "timer 2 exists now")
  H.eq(t.value, math.floor(ZD.FlightTime.seconds + 0.5))
end)

H.test("writes only the value, never the pilot's settings", function()
  local ZD, h = nil, nil
  ZD = fresh(function()
    h = heli(1000)
    Mock.state.timers[1] = { value = 0, start = 300, name = "MINE",
                             countdownBeep = 2, persistent = 1 }
  end)
  ZD.FlightTime.timerIndex = 1
  fly(ZD, h, 50, 600)
  ZD.FlightTime.driveTimer()
  local t = Mock.state.timers[1]
  H.eq(t.name, "MINE", "the name is the pilot's")
  H.eq(t.countdownBeep, 2, "and so is the countdown voice")
  H.eq(t.start, 300)
  H.eq(t.persistent, 1)
end)

H.test("does not rewrite the same second over and over", function()
  local ZD, h = nil, nil
  ZD = fresh(function() h = heli(1000) end)
  ZD.FlightTime.timerIndex = 1
  fly(ZD, h, 50, 600)
  ZD.FlightTime.driveTimer()             -- the one legitimate write
  Mock.state.timerWrites = 0
  for _ = 1, 20 do ZD.FlightTime.driveTimer() end
  H.eq(Mock.state.timerWrites, 0, "the value has not changed, so neither has the timer")
end)

H.test("no estimate means the timer is left alone", function()
  local ZD = fresh(function()
    Mock.addSensor("Hspd", 18, 0)
    Mock.addSensor("Capa", 14, 0)
    Mock.addSensor("Bat%", 13, 100)
  end)
  ZD.FlightTime.timerIndex = 1
  run(ZD, 20)
  ZD.FlightTime.driveTimer()
  H.eq(Mock.state.timerWrites, 0, "a stale countdown is worse than none")
end)

end
