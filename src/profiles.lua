-- Layer 2c: Aircraft profile.
--
-- What class of helicopter this is. The widget can read every sensor on the
-- model and still not know whether 300 A is a glitch or a Tuesday, because
-- that depends entirely on the aircraft: a 700-size electric pulls it, and a
-- 200-size would be on fire. Telemetry carries no such context, so it is
-- either configured or inferred.
--
-- A profile therefore carries only things the widget genuinely cannot detect
-- and that change what it does:
--
--   windows   what readings are plausible, so a bad frame can be rejected
--   spin      what headspeed means "the head is turning", for arm detection
--   settings  thresholds that differ by aircraft class rather than by chemistry
--
-- Anything the same on both aircraft is deliberately absent. Cell voltage
-- alerts are not here: a LiPo cell is 3.4 V in trouble whether it is one of
-- two or one of fourteen.
--
-- Naming follows what the pilot asked for, but the split is really by size and
-- pack rather than by firmware - Rotorflight runs 200-size helis too. A
-- Rotorflight 200 wants the small profile, and the auto rule below picks it,
-- because it goes on pack voltage rather than on which firmware is talking.

return function(ZD)

local Config = ZD.Config
local Host   = ZD.Host

local Profiles = {}
ZD.Profiles = Profiles

Profiles.AUTO, Profiles.LARGE, Profiles.SMALL = 0, 1, 2

-- Windows are upper bounds only. The lower bound stays 0 everywhere it already
-- was: a low reading is the thing you most want recorded, and clamping it is
-- how a real brownout gets thrown away.
Profiles.defs = {
  [Profiles.LARGE] = {
    id    = "rotorflight",
    label = "Rotorflight",
    note  = "6S and up",
    windows = {
      headspeed   = { max =   4000 },   -- 700-size turns 1500-2200
      packVoltage = { max =     72 },   -- 14S at an implausible 5.1V/cell
      current     = { max =    400 },
      capacity    = { max =  20000 },
      power       = { max =  20000 },
    },
    -- Proven on hardware at these values; a 700 idles far below 250.
    spinUp = 250, spinDown = 100,
    settings = { alertEsc = 110 },
  },
  [Profiles.SMALL] = {
    id    = "osf03",
    label = "OMPHOBBY OSF03",
    note  = "2S-3S",
    windows = {
      headspeed   = { max =  12000 },   -- 200-size flies around 5000
      packVoltage = { max =   13.5 },   -- 3S at 4.5V/cell
      current     = { max =     80 },
      capacity    = { max =   3000 },
      power       = { max =   1000 },
    },
    -- A 200-size flies at ~5000 rpm, so 250 would call a slow spool a flight.
    spinUp = 1000, spinDown = 400,
    -- A small ESC in a tight canopy is in trouble well before a 700's is.
    settings = { alertEsc = 90 },
  },
}

-- Above this the pack is 6S or more; below it, 3S or less. 6S is 18V flat and
-- 3S is 12.6V full, so nothing lands in the gap. Read once, from the pack
-- itself, which is why this works on a Rotorflight 200 as well.
Profiles.AUTO_VOLTS = 15

Profiles.selected = Profiles.AUTO   -- what the widget option says
Profiles.detected = nil             -- what auto-detection settled on

-- Watch the pack for this long before deciding, and decide on the HIGHEST
-- reading seen rather than the first.
--
-- Deciding on the first cost a real flight: a 12S M7R came up reading low for
-- a moment, latched as a 200-size, and then spent the flight rejecting its own
-- pack voltage and capacity as out of range. One sample is not a measurement,
-- and the error is one-directional - a pack coming up can read too low, never
-- too high - so the peak is the honest figure.
Profiles.SETTLE = Host.seconds(3)

local firstSeen, peakVolts = nil, nil

function Profiles.observe(volts, ok, now)
  if Profiles.detected ~= nil then return end
  if not ok then return end
  volts = tonumber(volts)
  if volts == nil or volts <= 0 then return end

  now = now or Host.now()
  if firstSeen == nil then firstSeen = now end
  if peakVolts == nil or volts > peakVolts then peakVolts = volts end
  if (now - firstSeen) < Profiles.SETTLE then return end

  Profiles.detected =
    (peakVolts >= Profiles.AUTO_VOLTS) and Profiles.LARGE or Profiles.SMALL
end

-- A profile that keeps rejecting readings the role itself accepts is a wrong
-- profile. Nothing else notices: the windows do their job silently, and the
-- symptom is a dashboard quietly showing "out of range" for an aircraft that
-- is working perfectly.
--
-- Consecutive, so a single glitched frame - which is what the windows are for
-- in the first place - does not undo a correct decision. Two seconds of
-- continuous rejection at 10 Hz is a mismatch, not a glitch.
Profiles.REJECTS_BEFORE_REDETECT = 20

-- Counted per role, not globally. A service pass samples every role in turn,
-- so one shared counter is reset by whichever role happens to be fine a
-- microsecond after the wrong one was rejected - it can never accumulate, and
-- the self-correction never fires. The streak has to belong to the reading
-- that keeps being refused.
local rejectStreak = {}

function Profiles.noteRejection(role)
  -- Only ever second-guesses its own inference. A pilot who set the option
  -- meant it, and may be deliberately clamping an aircraft this widget would
  -- classify differently.
  if Profiles.selected ~= Profiles.AUTO then return end
  if Profiles.detected == nil then return end
  local n = (rejectStreak[role] or 0) + 1
  rejectStreak[role] = n
  if n >= Profiles.REJECTS_BEFORE_REDETECT then
    Profiles.redetections = (Profiles.redetections or 0) + 1
    Profiles.reset()
  end
end

function Profiles.noteAccept(role)
  rejectStreak[role] = 0
end

-- Cleared on model change: the next model is quite possibly the other heli.
-- Also used to abandon a decision the readings have disproved.
function Profiles.reset()
  Profiles.detected = nil
  firstSeen, peakVolts = nil, nil
  rejectStreak = {}
end

function Profiles.set(n)
  n = tonumber(n)
  if n ~= Profiles.LARGE and n ~= Profiles.SMALL then n = Profiles.AUTO end
  if n ~= Profiles.selected then
    Profiles.selected = n
    Profiles.reset()
  end
end

-- Returns the active profile, or nil when nothing has been chosen or detected
-- yet. nil is a real answer and callers must handle it: before telemetry
-- arrives there is no honest way to say how big the helicopter is, and
-- guessing would narrow the windows against an aircraft nobody has seen.
function Profiles.current()
  if Profiles.selected ~= Profiles.AUTO then
    return Profiles.defs[Profiles.selected]
  end
  if Profiles.detected ~= nil then return Profiles.defs[Profiles.detected] end
  return nil
end

-- "set" | "auto" | "waiting" - shown on the sensor map beside the name, the
-- same way a sensor binding says how it was made. A profile silently moves
-- alert thresholds, so how it was chosen has to be as visible as what it is.
function Profiles.how()
  if Profiles.selected ~= Profiles.AUTO then return "set" end
  if Profiles.detected ~= nil then
    -- Say so when the first answer was wrong. A profile that silently
    -- corrected itself mid-flight is a thing the pilot should be able to see,
    -- because it explains a stretch of readings that went missing.
    if (Profiles.redetections or 0) > 0 then return "auto*" end
    return "auto"
  end
  return "waiting"
end

Profiles.redetections = 0

function Profiles.label()
  local p = Profiles.current()
  if not p then return "--" end
  return p.label
end

-- Tightens a role's sanity window. Never widens one: the role definition is
-- the outer limit and a profile only ever says "and on this aircraft, less
-- than that".
function Profiles.window(role)
  local p = Profiles.current()
  if not p then return nil end
  return p.windows[role]
end

function Profiles.spin()
  local p = Profiles.current()
  if not p then return nil, nil end
  return p.spinUp, p.spinDown
end

-- sensors.cfg wins. Someone who wrote a threshold down meant it, and a profile
-- guessing from pack voltage does not get to overrule that.
function Profiles.setting(name)
  if Config.explicit and Config.explicit[name] then
    return Config.setting(name)
  end
  local p = Profiles.current()
  if p and p.settings[name] ~= nil then return p.settings[name] end
  return Config.setting(name)
end

return Profiles

end
