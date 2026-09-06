-- Alert engine: when it fires, when it stays quiet, and when it gives up.
--
-- The failure mode that matters is not a missed alert - it is an alert that
-- cries wolf. A pilot who has learned to ignore the radio is worse off than
-- one who never had alerts at all, so most of these test silence.

return function(H, Mock, Loader)

local function fresh(setup)
  Mock.reset()
  Mock.removeRf2()
  if setup then setup() end
  Mock.install()
  local ZD = Loader.load()
  ZD.State.reloadModel()
  ZD.Alerts.reset()
  return ZD
end

-- Service both layers for `seconds`, the way the widget does every frame.
local function run(ZD, seconds)
  for _ = 1, math.floor(seconds * 10) do
    Mock.advanceSeconds(0.1)
    ZD.State.service(Mock.state.time)
    ZD.Alerts.service(Mock.state.time)
  end
end

local function flying(cell)
  Mock.addSensor("Vcel", 1, cell or 3.90)
  Mock.addSensor("Vbat", 1, 47.0)
  Mock.addSensor("Hspd", 18, 1850)
end

local function haptics()
  local n = 0
  for _, p in ipairs(Mock.played or {}) do
    if p.op == "haptic" then n = n + 1 end
  end
  return n
end

H.group("alerts: cell voltage")

H.test("stays quiet on a healthy pack", function()
  local ZD = fresh(function() flying(3.90) end)
  run(ZD, 30)
  H.eq(#Mock.played, 0, "nothing to say")
end)

H.test("fires below the threshold and speaks the reading", function()
  local ZD = fresh(function() flying(3.90) end)
  run(ZD, 6)
  Mock.setSensor("Vcel", 3.38)
  run(ZD, 1)
  H.truthy(haptics() > 0, "the pilot feels it")
  H.eq(Mock.spokenCount(), 1, "and hears the value once")
  H.eq(Mock.spokenValues()[1], 3.38, "the actual reading, not the threshold")
end)

H.test("nothing fires until telemetry has settled", function()
  -- A pack reads garbage for the instant before the ESC reports. An alarm on
  -- power-up is how a pilot learns to ignore alarms.
  local ZD = fresh(function() flying(3.20) end)
  run(ZD, 2)
  H.eq(#Mock.played, 0, "still settling")
  run(ZD, 4)
  H.truthy(#Mock.played > 0, "and then it speaks up")
end)

H.test("a cell hovering on the threshold does not chatter", function()
  -- Sag under load crosses and re-crosses the line on every rotor beat. Only
  -- a real recovery re-arms it.
  local ZD = fresh(function() flying(3.90) end)
  run(ZD, 6)
  Mock.setSensor("Vcel", 3.39)
  run(ZD, 2)
  local first = #Mock.played
  H.truthy(first > 0)

  for _ = 1, 10 do
    Mock.setSensor("Vcel", 3.44)     -- above the trigger, below the clear
    run(ZD, 0.4)
    Mock.setSensor("Vcel", 3.39)
    run(ZD, 0.4)
  end
  H.eq(#Mock.played, first, "no second alarm from crossing the line again")
end)

H.test("repeats on a timer while the pack stays low", function()
  local ZD = fresh(function() flying(3.90) end)
  run(ZD, 6)
  Mock.setSensor("Vcel", 3.30)
  run(ZD, 1)
  H.eq(Mock.spokenCount(), 1)
  run(ZD, 16)
  H.eq(Mock.spokenCount(), 2, "one reminder, not a stream of them")
end)

H.test("recovering re-arms it", function()
  local ZD = fresh(function() flying(3.90) end)
  run(ZD, 6)
  Mock.setSensor("Vcel", 3.30)
  run(ZD, 1)
  local after = #Mock.played
  Mock.setSensor("Vcel", 3.85)          -- a fresh pack
  run(ZD, 3)
  H.eq(#Mock.played, after, "silent once it is fine again")
  Mock.setSensor("Vcel", 3.30)
  run(ZD, 1)
  H.truthy(#Mock.played > after, "and ready to warn about the next one")
end)

H.test("the threshold is configurable", function()
  local ZD = fresh(function()
    flying(3.60)
    Mock.state.files["/WIDGETS/ZelionDash/sensors.cfg"] =
      "[battery]\nalertCell = 3.70\n"
  end)
  ZD.Config.load()
  run(ZD, 8)
  H.truthy(#Mock.played > 0, "3.60 is low if you said 3.70 is")
end)

H.group("alerts: other conditions")

H.test("a hot ESC speaks its temperature", function()
  local ZD = fresh(function()
    flying(3.90)
    Mock.addSensor("Tesc", 11, 70)
  end)
  run(ZD, 6)
  Mock.setSensor("Tesc", 114)
  run(ZD, 1)
  H.eq(Mock.spokenValues()[1], 114)
end)

H.test("a governor fault buzzes without reading anything out", function()
  -- There is nothing worth saying and the pilot is busy.
  local ZD = fresh(function()
    flying(3.90)
    Mock.addSensor("Gov", nil, 4)       -- ACTIVE
  end)
  run(ZD, 6)
  H.eq(#Mock.played, 0)
  Mock.setSensor("Gov", 6)              -- LOST-HS
  run(ZD, 1)
  H.truthy(haptics() > 0, "felt")
  H.eq(Mock.spokenCount(), 0, "but not narrated")
end)

H.test("a link that never existed is not a lost link", function()
  local ZD = fresh(function() flying(3.90) end)
  run(ZD, 20)
  H.eq(#Mock.played, 0)
end)

H.group("alerts: staying out of the way")

H.test("no telemetry means nothing to alert about", function()
  local ZD = fresh()
  run(ZD, 30)
  H.eq(#Mock.played, 0, "a radio on the bench must be silent")
end)

H.test("a dropout gets its settle time back on reconnect", function()
  -- Otherwise the first noisy sample after a reconnect fires immediately.
  local ZD = fresh(function() flying(3.90) end)
  run(ZD, 8)
  Mock.removeSensor("Vcel"); Mock.removeSensor("Vbat"); Mock.removeSensor("Hspd")
  run(ZD, 3)
  Mock.addSensor("Vcel", 1, 3.20)
  Mock.addSensor("Vbat", 1, 40.0)
  run(ZD, 2)
  H.eq(#Mock.played, 0, "settling again")
  run(ZD, 4)
  H.truthy(#Mock.played > 0)
end)

H.test("the hold switch silences them", function()
  -- Hold means the pilot is deliberately parked with the model powered.
  -- Freezing the extremes but not the alarms would make hold unusable.
  local ZD = fresh(function() flying(3.20) end)
  for _ = 1, 200 do
    Mock.advanceSeconds(0.1)
    ZD.State.service(Mock.state.time, { hold = true })
    ZD.Alerts.service(Mock.state.time)
  end
  H.eq(#Mock.played, 0)
end)

H.test("turning them off turns them off", function()
  local ZD = fresh(function() flying(3.20) end)
  ZD.Alerts.enabled = false
  run(ZD, 30)
  H.eq(#Mock.played, 0)
  ZD.Alerts.enabled = true
  run(ZD, 8)
  H.truthy(#Mock.played > 0, "and back on again")
end)

H.test("a radio with no haptic or speaker does not fault", function()
  local ZD = fresh(function() flying(3.20) end)
  _G.playHaptic, _G.playNumber, _G.playTone = nil, nil, nil
  local ok = pcall(run, ZD, 10)
  H.truthy(ok, "an alert that cannot be heard must not raise")
end)

H.group("alerts: self test")

H.test("sounds one alert on demand, without a flat pack", function()
  -- The alternative was editing a threshold on the SD card and editing it
  -- back afterwards, to answer "does the buzzer work".
  local ZD = fresh(function() flying(3.90) end)
  run(ZD, 10)
  H.eq(#Mock.played, 0, "nothing is actually wrong")
  ZD.Alerts.selfTest()
  H.truthy(haptics() > 0, "felt")
  H.eq(Mock.spokenCount(), 1, "and heard")
end)

H.test("speaks the live reading, so it proves the binding too", function()
  local ZD = fresh(function() flying(3.77) end)
  run(ZD, 6)
  ZD.Alerts.selfTest()
  H.eq(Mock.spokenValues()[1], 3.77)
end)

H.test("works on a bench with no telemetry at all", function()
  local ZD = fresh()
  ZD.Alerts.selfTest()
  H.truthy(#Mock.played > 0, "a pre-flight check cannot require a heli")
  H.eq(Mock.spokenValues()[1], 3.40, "falls back to the configured threshold")
end)

H.test("does not disturb the real alerts", function()
  local ZD = fresh(function() flying(3.90) end)
  run(ZD, 6)
  ZD.Alerts.selfTest()
  Mock.played = {}
  run(ZD, 30)
  H.eq(#Mock.played, 0, "still nothing wrong")
end)

H.test("reports what is currently sounding", function()
  local ZD = fresh(function()
    flying(3.90)
    Mock.addSensor("Tesc", 11, 70)
  end)
  run(ZD, 6)
  H.eq(#ZD.Alerts.active(), 0)
  Mock.setSensor("Vcel", 3.20)
  Mock.setSensor("Tesc", 130)
  run(ZD, 1)
  local active = ZD.Alerts.active()
  H.eq(#active, 2)
  H.eq(active[1], "cell", "worst first")
end)


--------------------------------------------------------------------------
H.group("alerts: a supply collapse is not a flat battery")

-- The decay a pilot actually sees when a connector lets go in flight: the
-- flight controller keeps talking on the ESC's capacitors while the rail falls
-- away under it. Every value on the way down is a plausible-looking voltage.
local function decay(ZD, from, steps)
  local v = from
  for _ = 1, steps do
    v = v - 0.6
    if v < 0 then v = 0 end
    Mock.setSensor("Vcel", v)
    Mock.advanceSeconds(0.1)
    ZD.State.service(Mock.state.time)
    ZD.Alerts.service(Mock.state.time)
  end
end

H.test("a collapsing pack never gets announced as a low cell", function()
  local ZD = fresh(function() flying(3.90) end)
  run(ZD, 8)                       -- settled, flying, nothing wrong
  Mock.played = {}
  decay(ZD, 3.90, 8)

  -- The whole point. "battery critical, zero volts" is the announcement this
  -- replaces, and it is worse than silence: it is the alert that matters
  -- telling the pilot something that is not true.
  for _, v in ipairs(Mock.spokenValues()) do
    H.truthy(v == nil or v > ZD.State.MIN_PLAUSIBLE_CELL,
             "spoke a collapse voltage as if it were a cell reading: " .. tostring(v))
  end
  H.truthy(ZD.State.powerLost, "and the collapse itself is recognised")
end)

H.test("the collapse is announced, and it outranks the cell alert", function()
  local ZD = fresh(function() flying(3.90) end)
  run(ZD, 8)
  Mock.played = {}
  decay(ZD, 3.90, 8)

  local active = ZD.Alerts.active()
  local found = false
  for _, a in ipairs(active) do
    if a == "MAIN POWER LOST" then found = true end
    H.truthy(a ~= "cell",
             "the cell alert must stand down: its readings are the decay")
  end
  H.truthy(found, "main power lost was not announced at all")
  H.truthy(haptics() > 0, "and it is felt, not just drawn")
end)

H.test("the flight's minimum survives the collapse", function()
  local ZD = fresh(function() flying(3.90) end)
  run(ZD, 8)
  Mock.setSensor("Vcel", 3.55)     -- a real sag, and the real minimum
  run(ZD, 1)
  local before = ZD.State.min("cellVoltage")
  H.near(before, 3.55, 0.01, "the sag should have been recorded")

  decay(ZD, 3.55, 8)
  H.near(ZD.State.min("cellVoltage"), before, 0.001,
         "the decay was recorded as the flight's minimum - it is not a reading")
end)

H.test("a hard punch-out is sag, and shows immediately", function()
  -- The other half of the bargain. If questioning a fall costs the dashboard
  -- its honesty about real load, the cure is worse than the disease.
  local ZD = fresh(function() flying(3.90) end)
  run(ZD, 8)
  Mock.setSensor("Vcel", 3.45)     -- 0.45 V/cell, a genuine hard pull
  Mock.advanceSeconds(0.1)
  ZD.State.service(Mock.state.time)
  H.near(ZD.State.num("cellVoltage"), 3.45, 0.001,
         "real sag must reach the screen on the very next pass")
  H.falsy(ZD.State.powerLost, "and must not read as a collapse")
end)

H.test("unplugging on the bench is not an emergency", function()
  local ZD = fresh(function()
    Mock.addSensor("Vcel", 1, 3.90)
    Mock.addSensor("Vbat", 1, 47.0)
    Mock.addSensor("Hspd", 18, 0)     -- rotor stopped: disarmed
  end)
  run(ZD, 8)
  Mock.played = {}
  decay(ZD, 3.90, 8)
  H.falsy(ZD.State.powerLost,
          "a pack pulled on the bench collapses identically - alarming for it "
          .. "is how a pilot learns to ignore the alarm")
end)

H.test("a pack swapped for a lower one is accepted, once it holds", function()
  -- The reading the disarmed rule must NOT throw away: a genuinely lower pack
  -- reads steady, where a decay keeps falling.
  local ZD = fresh(function()
    Mock.addSensor("Vcel", 1, 4.15)
    Mock.addSensor("Vbat", 1, 49.8)
    Mock.addSensor("Hspd", 18, 0)
  end)
  run(ZD, 6)
  Mock.setSensor("Vcel", 3.70)      -- a part-used pack, sitting still
  run(ZD, 6)
  H.near(ZD.State.num("cellVoltage"), 3.70, 0.001,
         "a steady lower reading is a real pack, not a decay")
end)

--------------------------------------------------------------------------
H.group("alerts: is this pack actually charged")

H.test("a part-charged pack says so, once, on the ground", function()
  local ZD = fresh(function()
    Mock.addSensor("Vcel", 1, 3.75)   -- well under the 4.00 default full
    Mock.addSensor("Vbat", 1, 45.0)
    Mock.addSensor("Hspd", 18, 0)
  end)
  run(ZD, 12)
  H.eq(Mock.spokenCount(), 1, "asked once")
  H.near(Mock.spokenValues()[1], 3.75, 0.001, "and says what it found")

  -- Once. It is a pre-flight check, not a nag.
  run(ZD, 30)
  H.eq(Mock.spokenCount(), 1, "and only once")
end)

H.test("a full pack is checked and stays quiet", function()
  local ZD = fresh(function()
    Mock.addSensor("Vcel", 1, 4.15)
    Mock.addSensor("Vbat", 1, 49.8)
    Mock.addSensor("Hspd", 18, 0)
  end)
  run(ZD, 20)
  H.eq(Mock.spokenCount(), 0)
end)

H.test("a LiHV pack above full is not called low", function()
  -- 4.31 V/cell off the charger, measured on a 3S micro. A check that flags
  -- the fullest pack you own is a check that gets switched off.
  local ZD = fresh(function()
    Mock.addSensor("Vcel", 1, 4.31)
    Mock.addSensor("Vbat", 1, 12.93)
    Mock.addSensor("Hspd", 18, 0)
  end)
  run(ZD, 20)
  H.eq(Mock.spokenCount(), 0)
end)

H.test("the check waits for the pack to settle", function()
  -- The inrush dip when the ESC comes up is not the pack's state of charge.
  local ZD = fresh(function()
    Mock.addSensor("Vcel", 1, 3.60)   -- sagging under inrush
    Mock.addSensor("Vbat", 1, 43.2)
    Mock.addSensor("Hspd", 18, 0)
  end)
  run(ZD, 5)
  H.eq(Mock.spokenCount(), 0, "must not judge the pack during the dip")
  Mock.setSensor("Vcel", 4.10)        -- recovered: the pack is fine
  run(ZD, 10)
  H.eq(Mock.spokenCount(), 0, "and judges the settled value, which is full")
end)

H.test("it is never asked in the air", function()
  local ZD = fresh(function() flying(3.75) end)   -- rotor turning, part pack
  run(ZD, 20)
  for _, v in ipairs(Mock.spokenValues()) do
    H.truthy(v <= 3.40 or v > 4.0,
             "the pack check spoke in flight: " .. tostring(v))
  end
end)

H.test("the next pack gets asked too", function()
  local ZD = fresh(function()
    Mock.addSensor("Vcel", 1, 3.75)
    Mock.addSensor("Vbat", 1, 45.0)
    Mock.addSensor("Hspd", 18, 0)
  end)
  run(ZD, 12)
  H.eq(Mock.spokenCount(), 1)

  -- Unplug: telemetry goes away for longer than a dropout.
  Mock.removeSensor("Vcel"); Mock.removeSensor("Vbat"); Mock.removeSensor("Hspd")
  ZD.State.reloadModel()
  run(ZD, 8)

  Mock.addSensor("Vcel", 1, 3.80)
  Mock.addSensor("Vbat", 1, 45.6)
  Mock.addSensor("Hspd", 18, 0)
  ZD.State.reloadModel()
  run(ZD, 12)
  H.eq(Mock.spokenCount(), 2, "a new pack is a new question")
end)


H.test("a buffer holding the rail up is still a collapse", function()
  -- The case a "below one volt" floor cannot catch, and the one a backup
  -- buffer actually produces: the rail does not fall to zero, it falls to
  -- whatever the buffer holds and stops there. Nothing about 2 V/cell is
  -- implausible on its own. What gives it away is the trip getting there.
  local ZD = fresh(function() flying(3.90) end)
  run(ZD, 8)
  local v = 3.90
  for _ = 1, 6 do
    v = math.max(2.00, v - 0.45)
    Mock.setSensor("Vcel", v)
    run(ZD, 0.2)
  end
  run(ZD, 2)                       -- and it sits there, steady
  H.truthy(ZD.State.powerLost,
           "a rail that fell 1.9 V/cell and stopped is not a battery reading")
end)

H.test("a rail already dead at power-up is not a cell reading", function()
  -- Nothing to compare against - this is the first reading there has ever
  -- been - so the run logic has no opinion. Only the floor can refuse it.
  local ZD = fresh(function()
    Mock.addSensor("Vcel", 1, 0.50)
    Mock.addSensor("Vbat", 1, 6.0)
    Mock.addSensor("Hspd", 18, 0)
  end)
  run(ZD, 10)
  H.falsy(ZD.State.valid("cellVoltage"),
          "0.5 V is not a cell, and presenting it as one is how the widget "
          .. "ends up announcing a voltage nobody has")
  H.eq(Mock.spokenCount(), 0, "and there is nothing to announce about it")
end)

H.test("the cell alarm stands down for a collapse it did not cause", function()
  -- Pack and cell come from different sensors and need not fail together. If
  -- the cell reading settles low while the pack rail is collapsing, the low
  -- reading is a symptom of the collapse - announcing it as a flat battery
  -- sends the pilot after the wrong problem.
  local ZD = fresh(function() flying(3.90) end)
  run(ZD, 8)
  local vb = 47.0
  for _ = 1, 6 do
    vb = vb - 6.0
    Mock.setSensor("Vbat", vb)
    Mock.setSensor("Vcel", 3.20)   -- settles low, and holds there
    run(ZD, 0.2)
  end
  run(ZD, 2)

  local names = {}
  for _, a in ipairs(ZD.Alerts.active()) do names[a] = true end
  H.truthy(names["MAIN POWER LOST"], "the collapse must be the alarm raised")
  H.falsy(names["cell"], "and the low-cell alarm must not join in")
end)

H.test("a gap in telemetry forgets what the pack used to read", function()
  -- Without this the widget compares a fresh pack against the one before it
  -- and refuses the new one forever as a decay that never stops - which looks,
  -- from the flight line, exactly like a dead dashboard.
  local ZD = fresh(function()
    Mock.addSensor("Vcel", 1, 4.15)
    Mock.addSensor("Vbat", 1, 49.8)
    Mock.addSensor("Hspd", 18, 0)
  end)
  run(ZD, 6)
  H.near(ZD.State.num("cellVoltage"), 4.15, 0.001)

  -- Unplugged. Same model, same session, same sensor - the link simply stops
  -- carrying it, which is what pulling the pack looks like from up here.
  Mock.setSensor("Vcel", 4.15, false)
  run(ZD, 6)
  H.falsy(ZD.State.valid("cellVoltage"), "the gap should have registered")

  -- A well-used pack goes on. It reads a long way below the last one.
  Mock.setSensor("Vcel", 3.20, true)
  run(ZD, 6)
  H.near(ZD.State.num("cellVoltage"), 3.20, 0.001,
         "the new pack was refused because the old one was still remembered")
end)

end
