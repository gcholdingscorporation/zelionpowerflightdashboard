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

H.test("no estimate means the timer reads zero, not the last flight's number", function()
  -- This test used to assert the opposite - that the timer was left alone -
  -- with the comment "a stale countdown is worse than none" attached to the
  -- behaviour that produces exactly that. Leaving it alone does not clear it:
  -- it leaves the previous pack's estimate sitting on the screen. Arm on a
  -- fresh battery and the timer reads four minutes, from the pack before it,
  -- until the new one falls under 95% and a real estimate appears.
  local ZD = fresh(function()
    Mock.addSensor("Hspd", 18, 0)
    Mock.addSensor("Capa", 14, 0)
    Mock.addSensor("Bat%", 13, 100)
  end)
  ZD.FlightTime.timerIndex = 1
  run(ZD, 20)
  ZD.FlightTime.driveTimer()
  H.eq(Mock.state.timers[1].value, 0, "a stale countdown is worse than none")

  -- Once, though. Zero is a value like any other and the per-second dedupe
  -- still applies; rewriting it every pass would be ten writes a second.
  local writes = Mock.state.timerWrites
  for _ = 1, 20 do ZD.FlightTime.driveTimer() end
  H.eq(Mock.state.timerWrites, writes, "rewrote a value that had not changed")
end)


H.group("flighttime: two flights on one pack")

-- Land with pack left, launch again, and the countdown has to carry on rather
-- than start over. It used to start over: the monotonic floor was cleared at
-- the landing, the estimate was rebuilt from scratch, the timer jumped back UP
-- - and EdgeTX announces a threshold as a timer walks DOWN through it and will
-- not speak one it has already passed. So the second flight of a pack counted
-- down in silence, which is the flight where the callouts matter most.

local function land(ZD)
  Mock.setSensor("Hspd", 0)
  run(ZD, 8)
  Mock.setSensor("Hspd", 5000)
end

H.test("the countdown carries on rather than starting over", function()
  -- Flown hard, then landed and flown gently. A fresh estimate on the second
  -- flight would be far LARGER - the draw is a fifth of what it was - so this
  -- only passes if the floor from the first flight survived the landing.
  --
  -- An earlier version of this test compared the two estimates directly, which
  -- proves nothing: the pack is emptier the second time, so the number falls
  -- either way. It passed with the bug still in place.
  local ZD, h = nil, nil
  ZD = fresh(function() h = heli(1000) end)
  local used = fly(ZD, h, 60, 600)
  local before = ZD.FlightTime.seconds
  H.truthy(before, "no estimate on the first flight")

  land(ZD)
  H.nilv(ZD.FlightTime.seconds, "an estimate while disarmed")

  fly(ZD, h, 40, 120, used)          -- a fifth of the draw
  local after = ZD.FlightTime.seconds
  H.truthy(after, "the second flight never produced one")
  H.truthy(after <= before,
           string.format("the timer jumped back up on the same pack: "
                         .. "%.0f -> %.0f", before, after))
end)

H.test("but a pack change wipes it", function()
  -- The trap. Keeping the floor across a landing is right; keeping it across a
  -- PACK is a full battery reading forty seconds remaining, with no way back up
  -- because a floor only falls. The naive version of this fix passes every
  -- other test in this file and fails exactly here.
  local ZD, h = nil, nil
  ZD = fresh(function() h = heli(1000) end)
  fly(ZD, h, 90, 600)
  local low = ZD.FlightTime.seconds
  H.truthy(low, "no estimate to inherit")

  land(ZD)
  h.burn(0)                          -- unplugged, replugged: counter and pack reset
  run(ZD, 0.1)                       -- the single pass that spots it
  H.eq(ZD.FlightTime.why, "new pack", "the swap went unnoticed")

  -- Fly the fresh pack down past 95% so an estimate is possible at all.
  fly(ZD, h, 40, 600)
  local fresh_ = ZD.FlightTime.seconds
  H.truthy(fresh_, "no estimate on the new pack")
  H.truthy(fresh_ > low,
           string.format("the new pack inherited the old one's floor: %.0f vs %.0f",
                         fresh_, low))
end)

H.test("a pack too full to be the one just landed on also wipes it", function()
  -- Belt and braces for a flight controller that keeps power across the swap,
  -- or a percentage published from voltage rather than counted coulombs - both
  -- leave the capacity counter looking continuous.
  local ZD, h = nil, nil
  ZD = fresh(function() h = heli(1000) end)
  fly(ZD, h, 90, 600)
  local low = ZD.FlightTime.seconds
  H.truthy(low, "no estimate to inherit")
  land(ZD)

  -- A swap the capacity counter never saw: percent jumps back to full while
  -- the consumed figure carries on climbing, so nothing looks discontinuous.
  local used = 900
  for _ = 1, 12 do
    used = used + 10
    Mock.setSensor("Capa", used)
    Mock.setSensor("Bat%", 100)
    run(ZD, 1)
  end
  H.eq(ZD.FlightTime.why, "pack too full to tell")

  for _ = 1, 40 do
    used = used + 10
    Mock.setSensor("Capa", used)
    Mock.setSensor("Bat%", math.max(0, 100 - (used - 900) / 1000 * 100))
    run(ZD, 1)
  end
  local after = ZD.FlightTime.seconds
  H.truthy(after, "no estimate after the swap")
  H.truthy(after > low,
           string.format("the full pack kept the old floor: %.0f vs %.0f",
                         after, low))
end)

H.group("flighttime: a reserve that belongs to one helicopter")

-- A reserve can now be written against a craft name rather than against the
-- whole radio, and the craft name arrives from the flight controller a moment
-- AFTER the link comes up - so the number the countdown is built on can change
-- underneath a live estimate. Normally that moment is long before the pack is
-- below 95% and long before the eight-second window has filled, so no pilot
-- ever sees it. This forces the worst case anyway: the name lands mid-flight,
-- on an estimate that already exists.
--
-- The property that has to hold is the one the whole countdown rests on. The
-- estimate may only fall. A helicopter-specific reserve is the more
-- conservative number of the two - it is measured on that aircraft - so
-- applying it late must shorten the countdown, never lengthen it, and never
-- make it jump back up over a threshold EdgeTX has already announced.
H.test("a craft reserve arriving late only ever shortens the countdown", function()
  local ZD, h = nil, nil
  ZD = fresh(function()
    h = heli(2200)
    Mock.writeFile("/WIDGETS/ZelionDash/sensors.cfg",
      "[battery]\nreservePct = 20\n[Late Heli]\nreservePct = 50\n")
  end)

  local used, prev, climbed = 0, nil, 0
  for s = 1, 60 do
    used = used + 260 / 60
    h.burn(used)
    -- The flight controller finally says what it is flying.
    if s == 30 then Mock.installRf2({ apiVersion = 12.09, modelName = "Late Heli" }) end
    run(ZD, 1)
    local cur = ZD.FlightTime.seconds
    if cur and prev and cur > prev + 0.001 then climbed = climbed + 1 end
    if cur then prev = cur end
  end

  H.eq(ZD.Config.setting("reservePct"), 50, "the craft reserve never applied")
  H.eq(climbed, 0, "the countdown climbed when the reserve changed")
  H.truthy(ZD.FlightTime.seconds, "no estimate left at all")
end)

-- The other direction, which is the dangerous one: a craft whose reserve is
-- LOWER than the radio-wide number would, on the arithmetic alone, hand back
-- time a pilot has already been told they do not have.
H.test("a lower craft reserve does not hand time back", function()
  local ZD, h = nil, nil
  ZD = fresh(function()
    h = heli(2200)
    Mock.writeFile("/WIDGETS/ZelionDash/sensors.cfg",
      "[battery]\nreservePct = 50\n[Late Heli]\nreservePct = 0\n")
  end)

  local used = 0
  for s = 1, 30 do
    used = used + 260 / 60
    h.burn(used); run(ZD, 1)
  end
  local before = ZD.FlightTime.seconds
  H.truthy(before, "no estimate to hold onto")

  Mock.installRf2({ apiVersion = 12.09, modelName = "Late Heli" })
  for s = 1, 10 do
    used = used + 260 / 60
    h.burn(used); run(ZD, 1)
  end

  H.eq(ZD.Config.setting("reservePct"), 0, "the craft reserve never applied")
  H.truthy(ZD.FlightTime.seconds <= before,
           string.format("the countdown grew: %.0f -> %.0f",
                         before, ZD.FlightTime.seconds))
end)


end
