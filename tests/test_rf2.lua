-- Rotorflight RF Tool integration.
--
-- The governing requirement is that RF Tool is OPTIONAL. Most of these tests
-- exist to prove the dashboard is unharmed by its absence, its late arrival,
-- or its misbehaviour.

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
  end
end

H.group("rf2: absent")

H.test("everything works with RF Tool not installed", function()
  local ZD = fresh(function() Mock.addSensor("Hspd", 18, 1850) end)
  run(ZD, 6)
  H.falsy(ZD.RF2.available())
  H.falsy(ZD.RF2.registered)
  H.nilv(ZD.RF2.connected, "unknown, not false")
  H.nilv(ZD.State.linkConnected, "callers must fall back to inference")
  H.eq(ZD.State.num("headspeed"), 1850, "telemetry is unaffected")
end)

H.group("rf2: registration")

H.test("registers a single stable proxy", function()
  local ZD = fresh(function() Mock.installRf2() end)
  run(ZD, 6)
  H.truthy(ZD.RF2.registered)
  H.eq(#Mock.rf2Widgets, 1)
end)

H.test("does not re-register on repeated service passes", function()
  local ZD = fresh(function() Mock.installRf2() end)
  run(ZD, 30)
  -- RF Tool's registry is append-only, so a duplicate would receive every
  -- event twice for the life of the session.
  H.eq(#Mock.rf2Widgets, 1)
end)

H.test("picks up RF Tool that loads after us", function()
  local ZD = fresh()
  run(ZD, 1)
  H.falsy(ZD.RF2.registered, "nothing to register with yet")

  Mock.installRf2()
  run(ZD, 6)
  H.truthy(ZD.RF2.registered)
end)

H.group("rf2: flight statistics")

H.test("reads FC flight stats on connect", function()
  local ZD = fresh(function() Mock.installRf2({ apiVersion = 12.09 }) end)
  run(ZD, 6)
  Mock.rf2Fire("connected")

  H.eq(ZD.RF2.statsStatus, "ok")
  H.eq(ZD.RF2.totalFlights, 137)
  H.eq(ZD.RF2.totalFlightSeconds, 41230)
end)

H.test("re-reads after landing", function()
  local ZD = fresh(function() Mock.installRf2({ apiVersion = 12.09 }) end)
  run(ZD, 6)
  Mock.rf2Fire("connected")
  local afterConnect = Mock.rf2Reads

  Mock.rf2Fire("armed")
  H.eq(Mock.rf2Reads, afterConnect, "no MSP traffic while flying")

  Mock.rf2Fire("disarmed")
  H.truthy(Mock.rf2Reads > afterConnect, "stats refresh once the flight ends")
end)

H.test("seeds from an already-connected FC", function()
  -- RF Tool publishes state only on change. Registering after the FC is
  -- already up means no event is coming, so we must not sit waiting for one.
  local ZD = fresh(function()
    Mock.installRf2({ apiVersion = 12.09, modelName = "Goblin 700" })
  end)
  run(ZD, 6)

  H.truthy(ZD.RF2.connected)
  H.eq(ZD.RF2.totalFlights, 137)
  H.eq(ZD.RF2.craftName, "Goblin 700")
end)

H.test("reports an FC too old for MSP_FLIGHT_STATS", function()
  local ZD = fresh(function() Mock.installRf2({ apiVersion = 12.06 }) end)
  run(ZD, 6)
  Mock.rf2Fire("connected")
  H.eq(ZD.RF2.statsStatus, "unsupported")
  H.nilv(ZD.RF2.totalFlights)
end)

H.test("waits rather than guessing when the FC has not handshaked", function()
  local ZD = fresh(function() Mock.installRf2({ apiVersion = nil }) end)
  run(ZD, 6)
  H.eq(ZD.RF2.statsStatus, "none")
  H.eq(Mock.rf2Reads, 0, "no point asking before the API version is known")
end)

H.group("rf2: connection state")

H.test("disconnect clears FC data and is reported as false", function()
  local ZD = fresh(function() Mock.installRf2({ apiVersion = 12.09 }) end)
  run(ZD, 6)
  Mock.rf2Fire("connected")
  H.eq(ZD.RF2.totalFlights, 137)

  Mock.rf2Fire("disconnected")
  run(ZD, 0.3)
  H.eq(ZD.RF2.connected, false)
  H.eq(ZD.State.linkConnected, false)
  H.nilv(ZD.RF2.totalFlights, "stale FC data must not linger")
  H.eq(ZD.RF2.statsStatus, "none")
end)

H.test("arm and disarm both count as connected", function()
  local ZD = fresh(function() Mock.installRf2({ apiVersion = 12.09 }) end)
  run(ZD, 6)
  Mock.rf2Fire("armed")
  run(ZD, 0.3)
  H.truthy(ZD.State.linkConnected)
end)

H.group("rf2: misbehaviour")

H.test("survives useApi throwing", function()
  local ZD = fresh(function()
    Mock.installRf2({ apiVersion = 12.09, failUseApi = true })
  end)
  run(ZD, 6)
  Mock.rf2Fire("connected")
  H.eq(ZD.RF2.statsStatus, "error", "reported, not crashed")
  H.truthy(ZD.RF2.connected)
end)

H.test("survives a malformed stats reply", function()
  local ZD = fresh(function()
    Mock.installRf2({ apiVersion = 12.09, stats = { garbage = true } })
  end)
  run(ZD, 6)
  Mock.rf2Fire("connected")
  H.eq(ZD.RF2.statsStatus, "error")
  H.nilv(ZD.RF2.totalFlights, "an unparseable reply is not a zero")
end)

H.test("survives rf2 being a non-table", function()
  local ZD = fresh(function() _G.rf2 = "not a table" end)
  run(ZD, 6)
  H.falsy(ZD.RF2.available())
  H.falsy(ZD.RF2.registered)
end)

end
