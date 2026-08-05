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

end
