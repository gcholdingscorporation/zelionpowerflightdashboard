-- ESC status decoding, against the bit tables the firmware documents.
--
-- Every expectation in here traces to a comment block in Rotorflight's
-- esc_sensor.c. Three vendors have their layouts written down there; the rest
-- deliberately decode to nothing, and the tests for THAT are the ones that
-- matter most - a fault invented on a healthy ESC is worse than silence.

return function(H, Mock, Loader)

local function esc(sig, status)
  Mock.reset()
  Mock.removeRf2()
  Mock.addSensor("Vbat", 1, 47.0)
  Mock.addSensor("Esc#", nil, sig)
  if status ~= nil then Mock.addSensor("EscF", nil, status) end
  Mock.install()
  local ZD = Loader.load()
  ZD.State.reloadModel()
  Mock.advanceSeconds(0.2)
  ZD.State.service(Mock.state.time)
  return ZD
end

H.group("esc: HobbyWing V5, whose fault bits are documented")

-- esc_sensor.c, "Hobbywing V5 Telemetry": fault code bits 0..7.
local PL5 = {
  [0] = "motor locked",       [1] = "over temperature",
  [2] = "throttle at startup",[3] = "throttle signal lost",
  [4] = "over current",       [5] = "low voltage",
  [6] = "input voltage",      [7] = "motor connection",
}

H.test("every documented fault bit decodes to its own fault", function()
  for n, name in pairs(PL5) do
    local ZD = esc(0xFD, 2 ^ n)
    local text, sev = ZD.EscFault.read()
    H.eq(text, name, "bit " .. n)
    H.eq(sev, "crit", "a HobbyWing fault code is a fault, not a state")
  end
end)

H.test("several at once are all reported", function()
  local ZD = esc(0xFD, 0x01 + 0x10)          -- motor locked + over current
  local text = ZD.EscFault.read()
  H.truthy(string.find(text, "motor locked", 1, true), text)
  H.truthy(string.find(text, "over current", 1, true), text)
end)

H.test("zero is healthy and raises nothing", function()
  local ZD = esc(0xFD, 0)
  H.nilv(ZD.EscFault.read())
  H.falsy(ZD.EscFault.critical())
end)

H.group("esc: Scorpion, whose error bits are documented")

-- esc_sensor.c, "Scorpion Telemetry". Bits 0 and 6 are documented N/A.
H.test("documented error bits decode; the N/A ones stay silent", function()
  local named = { [1]="BEC voltage", [2]="temperature", [3]="consumption",
                  [4]="input voltage", [5]="current", [7]="throttle" }
  for n, name in pairs(named) do
    local ZD = esc(0x53, 2 ^ n)
    H.eq(ZD.EscFault.read(), name, "bit " .. n)
  end
  for _, n in ipairs({ 0, 6 }) do
    local ZD = esc(0x53, 2 ^ n)
    H.nilv(ZD.EscFault.read(),
           "bit " .. n .. " is documented N/A - naming it would be invention")
  end
end)

H.group("esc: OpenYGE, where the low nibble is a state and not a fault")

-- This is the vendor that makes a general "non-zero means bad" rule wrong.
H.test("an ESC running normally is not a fault", function()
  -- STATE_RUNNING_NORM = 0x0E, warning nibble clear. A healthy OpenYGE sits
  -- here for the whole flight.
  local ZD = esc(0xA5, 0x0E)
  H.nilv(ZD.EscFault.read(),
         "0x0E is 'running normally' - alarming on it would cry wolf on "
         .. "every single flight")
  H.falsy(ZD.EscFault.critical())
end)

H.test("every motor state on its own is silent", function()
  for state = 0x00, 0x0F do
    if state ~= 0x01 then                     -- 0x01 is power-cut, see below
      local ZD = esc(0xA5, state)
      H.nilv(ZD.EscFault.read(), "state 0x" .. string.format("%02X", state))
    end
  end
end)

H.test("the warning nibble decodes", function()
  local ZD = esc(0xA5, 0x20 + 0x0E)           -- over-temp while running
  local text, sev = ZD.EscFault.read()
  H.eq(text, "over temperature")
  H.eq(sev, "warn", "running, so a warning rather than a failure")
end)

H.test("the same warning is a failure in the state that makes it one", function()
  -- Documented: "WARN_OVERTEMP - Fail if Motor Status == STATE_POWER_CUT".
  -- The state is half the reading, not context.
  local ZD = esc(0xA5, 0x20 + 0x01)
  local text, sev = ZD.EscFault.read()
  H.eq(text, "over temperature")
  H.eq(sev, "crit", "power was cut - that is a failure, not a warning")
  H.truthy(ZD.EscFault.critical())
end)

H.test("a warning against the BEC says so", function()
  local ZD = esc(0xA5, 0x80 + 0x10 + 0x0E)    -- device BEC, undervoltage
  H.truthy(string.find(ZD.EscFault.read(), "BEC", 1, true))
end)

H.test("0xC0 is setpoint noise, not over-current on the BEC", function()
  -- The firmware reuses the device mask as a value here, on the grounds that a
  -- BEC can never report over-current. Read naively it decodes as both.
  local ZD = esc(0xA5, 0xC0 + 0x0E)
  H.eq(ZD.EscFault.read(), "setpoint noise")
end)

H.test("no warning plus power cut is over-voltage", function()
  local ZD = esc(0xA5, 0x00 + 0x01)
  H.eq(ZD.EscFault.read(), "over voltage")
  H.eq(select(2, ZD.EscFault.read()), "crit")
end)

H.group("esc: vendors this widget cannot decode")

H.test("an unknown vendor reports its code and raises nothing", function()
  -- OMPHOBBY. Rotorflight passes its status through untouched and documents no
  -- bit layout, so there is nothing here entitled to call it a fault.
  local ZD = esc(0xD0, 7)
  local text, sev, vendor = ZD.EscFault.read()
  H.eq(vendor, "OMPHOBBY", "the vendor is still worth naming")
  H.truthy(string.find(text, "7", 1, true), "and the raw code shown: " .. tostring(text))
  H.nilv(sev, "but no severity - the bits are not documented anywhere here")
  H.falsy(ZD.EscFault.critical(), "and no alarm")
end)

H.test("a vendor that sends no status is not reported as healthy", function()
  -- BLHeli32 has no status field at all, so EscF sits at zero all flight.
  -- "OK" would be a claim; "no status sent" is the fact.
  local ZD = esc(0xC8, 0)
  local text = ZD.EscFault.summary()
  H.truthy(string.find(text, "no status sent", 1, true), text)
end)

H.test("a restart is a fault on any vendor", function()
  local ZD = esc(0xFF, 0)
  H.eq(ZD.EscFault.read(), "RESTART")
  H.truthy(ZD.EscFault.critical())
end)

H.test("no ESC sensors at all is silence, not a fault", function()
  Mock.reset(); Mock.removeRf2()
  Mock.addSensor("Vbat", 1, 47.0)
  Mock.install()
  local ZD = Loader.load()
  ZD.State.reloadModel()
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  H.nilv(ZD.EscFault.summary(), "most setups do not publish these sensors")
  H.falsy(ZD.EscFault.critical())
end)

end
