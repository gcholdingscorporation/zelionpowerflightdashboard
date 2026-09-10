-- Layer 5g: ESC status decoding.
--
-- Rotorflight publishes two sensors that nothing here reads until now: Esc#,
-- the vendor signature, and EscF, the ESC's own status word. Between them they
-- carry the fault the ESC is already aware of - desync, over-temperature, a
-- motor connection it does not like - minutes before the pilot works it out
-- from a temperature climbing on the dashboard.
--
-- THE FIRMWARE DOES NOT INTERPRET THAT WORD. Reading esc_sensor.c, every
-- decoder ends the same way:
--
--     escSensorData[0].status = tele->status1;
--
-- The bytes are handed on exactly as the ESC sent them. So the meaning lives
-- with the vendor, and there are sixteen vendors. Of those, exactly three have
-- their bit layouts written down in the firmware source: HobbyWing V5, Scorpion
-- and OpenYGE. Those three are implemented here from that documentation.
--
-- EVERYTHING ELSE REPORTS ITS CODE AND RAISES NOTHING, and that restraint is
-- the whole design. It is tempting to treat any non-zero status as a fault,
-- which would cover every vendor at a stroke and be wrong on the first one you
-- tried: OpenYGE puts the MOTOR STATE in the low nibble, so a perfectly healthy
-- ESC running normally reports 0x0E all flight. A rule like that does not
-- degrade gracefully on an unknown ESC - it invents a fault on every flight,
-- and an alert that cries wolf is worse than no alert at all.
--
-- A vendor gets added here when its layout can be read from somewhere
-- authoritative, not when a plausible guess is available.

return function(ZD)

local State = ZD.State

local EscFault = {}
ZD.EscFault = EscFault

-- Signatures, from esc_sensor.c. Naming an ESC we cannot decode is still worth
-- doing: it tells the pilot which vendor's documentation would be needed.
-- Not a vendor. 0xFF is what the firmware substitutes for the signature while
-- an ESC is waiting to be power-cycled after a settings change.
EscFault.VENDORS = {
  [0x00] = "none",      [0xC8] = "BLHeli32",  [0x9B] = "HobbyWing V4",
  [0x4B] = "Kontronik", [0xD0] = "OMPHOBBY",  [0xDD] = "ZTW",
  [0xA0] = "APD",       [0xFD] = "HobbyWing V5", [0x53] = "Scorpion",
  [0xA5] = "OpenYGE",   [0xA6] = "XDFly",     [0x73] = "FLYROTOR",
  [0xC0] = "Graupner",  [0xC1] = "BLHeli_S",  [0xC2] = "AM32",
  [0xCC] = "Castle",    [0xFF] = "RESTART",
}

-- Vendors that send no status word at all. Their frames have no such field, so
-- EscF sits at zero for the whole flight and a decoder for them cannot exist.
-- Worth naming so "always OK" is understood as "never says", not as health.
EscFault.SILENT = {
  [0xC8] = true, [0x9B] = true, [0xCC] = true, [0xC1] = true, [0xC2] = true,
}

local function bit(v, n)
  return math.floor(v / (2 ^ n)) % 2 == 1
end

-- HobbyWing V5. Fault code bits, esc_sensor.c "Hobbywing V5 Telemetry".
local PL5_FAULTS = {
  [0] = "motor locked", [1] = "over temperature",
  [2] = "throttle at startup", [3] = "throttle signal lost",
  [4] = "over current", [5] = "low voltage",
  [6] = "input voltage", [7] = "motor connection",
}

-- Scorpion / Tribunus. Error code bits, esc_sensor.c "Scorpion Telemetry".
-- Bits 0 and 6 are documented N/A and are deliberately absent rather than
-- guessed at.
local TRIB_FAULTS = {
  [1] = "BEC voltage", [2] = "temperature", [3] = "consumption",
  [4] = "input voltage", [5] = "current", [7] = "throttle",
}

local function bitsToText(status, names)
  local out = {}
  for n = 0, 7 do
    if names[n] and bit(status, n) then out[#out + 1] = names[n] end
  end
  if #out == 0 then return nil end
  return table.concat(out, ", ")
end

-- OpenYGE keeps the motor state in the low nibble and the warning in the high
-- one, and the SAME warning is a warning or a failure depending on the state
-- it arrives with - the firmware documents each as "Fail if Motor Status ...".
-- So the state is not incidental here, it is half the reading.
local OYGE_STATE_POWER_CUT = 0x01
local OYGE_STATE_STARTING  = 0x08

local function openyge(status)
  local state = status % 16
  local warn  = status - state

  -- 0xC0 is both the device mask and, as a value, "setpoint noise" - the
  -- firmware reuses it on the grounds that a BEC can never report over-current.
  if warn == 0xC0 then return "setpoint noise", "warn" end

  local onBec = (warn % 256) >= 0x80
  local code  = warn % 128
  local where = onBec and "BEC " or ""

  if code == 0x00 then
    -- Documented: WARN_OK, except that it means overvoltage when the motor was
    -- cut. A healthy ESC lives here all flight.
    if state == OYGE_STATE_POWER_CUT then return "over voltage", "crit" end
    return nil, nil
  end
  if code == 0x10 then
    return where .. "under voltage", (state < OYGE_STATE_STARTING) and "crit" or "warn"
  end
  if code == 0x20 then
    return where .. "over temperature", (state == OYGE_STATE_POWER_CUT) and "crit" or "warn"
  end
  if code == 0x40 then
    return "over current", (state == OYGE_STATE_POWER_CUT) and "crit" or "warn"
  end
  return string.format("code 0x%02X", warn), "warn"
end

-- Returns: text, severity ("warn" | "crit" | nil), vendor name.
-- Text is nil when the ESC is reporting nothing wrong; severity is nil when
-- nothing here is entitled to an opinion.
function EscFault.read()
  local sig, sigOk = State.get("escSignature")
  if not sigOk then return nil, nil, nil end
  sig = math.floor(sig)
  local vendor = EscFault.VENDORS[sig] or string.format("ESC 0x%02X", sig)

  -- Not a fault, and it took reading the call sites to establish that. The
  -- signature is set only by paramEscNeedRestart(), which is reached from
  -- three places in esc_sensor.c and all three are PARAMETER flows - the
  -- HobbyWing V5 ping and reset responses, and the Tribunus UNC setup. It
  -- means "power-cycle the ESC to apply the settings you just changed", it
  -- happens on the bench with a configurator open, and it never happens in
  -- flight. Alarming on it would buzz at a pilot who is deliberately editing
  -- ESC settings.
  if sig == 0xFF then return "restart to apply settings", nil, vendor end

  local status, statusOk = State.get("escStatus")
  if not statusOk then return nil, nil, vendor end
  status = math.floor(status)

  if sig == 0xFD then
    return bitsToText(status, PL5_FAULTS), "crit", vendor
  end
  if sig == 0x53 then
    return bitsToText(status, TRIB_FAULTS), "crit", vendor
  end
  if sig == 0xA5 then
    local text, sev = openyge(status)
    return text, sev, vendor
  end

  -- Undecodable. Say what was seen and claim nothing about it.
  if status == 0 then return nil, nil, vendor end
  return string.format("code %d", status), nil, vendor
end

-- One line for the sensor map: what is talking and what it said.
function EscFault.summary()
  local text, sev, vendor = EscFault.read()
  if not vendor then return nil end
  if text then return vendor .. "  " .. text, sev end
  if EscFault.SILENT[math.floor(State.num("escSignature") or -1)] then
    -- Not the same as healthy. These vendors have no status field at all.
    return vendor .. "  no status sent", nil
  end
  return vendor .. "  ok", nil
end

-- Only a decoded, critical fault is worth an alarm. An unknown vendor's code
-- reaches the screen and stops there.
function EscFault.critical()
  local text, sev = EscFault.read()
  return text ~= nil and sev == "crit"
end

return EscFault

end
