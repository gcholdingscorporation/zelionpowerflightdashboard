-- Layer 5c: Alert engine.
--
-- The dashboard shows you a problem. This tells you about one - which is the
-- part that matters, because for most of a flight you are looking at the
-- helicopter and not at the screen.
--
-- Reads State, drives Host's audio and haptic. Owns no telemetry logic and
-- draws nothing, so the whole thing is testable off-radio.
--
-- Three rules keep it from becoming noise, which is the only way an alert
-- system fails in practice:
--
--   Hysteresis. Every alert clears at a different value from the one that
--   triggers it. A cell sagging across 3.40V under load would otherwise
--   announce itself on every rotor beat.
--
--   Repeat, don't chatter. While a condition holds, it repeats on a timer
--   rather than every service pass, and the timer is long enough to be
--   ignorable and short enough to not be forgotten.
--
--   Settle first. Nothing fires until telemetry has been live for a few
--   seconds. A pack reads 0.00V for the instant before the ESC reports, and
--   an alarm on power-up teaches the pilot to ignore alarms.

return function(ZD)

local Host   = ZD.Host
local State  = ZD.State
local Config = ZD.Config

local Alerts = {}
ZD.Alerts = Alerts

Alerts.enabled = true

-- Telemetry has to be live this long before anything can fire.
Alerts.SETTLE = Host.seconds(4)

Alerts.fired = {}          -- id -> true while the condition is held
Alerts.lastSpoken = nil    -- id of the most recent alert, for the UI
Alerts.count = 0           -- total fires this session, for tests and diagnostics

local liveSince = nil
local state = {}           -- id -> { active, nextAt }

--------------------------------------------------------------------------
-- Definitions
--------------------------------------------------------------------------

-- trigger/clear are deliberately asymmetric. speak() is called on every fire,
-- after the haptic, and may say nothing at all - a governor fault has no
-- number worth reading out.
local function cellLow()  return Config.setting("alertCell") end
local function escHigh()  return Config.setting("alertEsc") end

local GOV_FAULT = { ["THR-OFF"] = true, ["LOST-HS"] = true, AUTOROT = true }

local DEFS = {
  {
    id = "cell",
    -- The one the pilot actually flies to. A margin of 0.10V on the way back
    -- up: a pack that has hit its floor does not recover quietly.
    test  = function() return State.valid("cellVoltage")
                          and State.num("cellVoltage") <= cellLow() end,
    clear = function() return not State.valid("cellVoltage")
                          or State.num("cellVoltage") >= cellLow() + 0.10 end,
    repeatAfter = 15,
    haptic = { 60, 80, 2 },
    speak = function()
      Host.playNumber(math.floor(State.num("cellVoltage") * 100 + 0.5),
                      Host.UNIT_VOLTS, Host.PREC2)
    end,
  },
  {
    id = "esc",
    test  = function() return State.valid("escTemperature")
                          and State.num("escTemperature") >= escHigh() end,
    clear = function() return not State.valid("escTemperature")
                          or State.num("escTemperature") <= escHigh() - 8 end,
    repeatAfter = 20,
    haptic = { 90, 90, 2 },
    speak = function()
      Host.playNumber(math.floor(State.num("escTemperature") + 0.5),
                      Host.UNIT_CELSIUS, 0)
    end,
  },
  {
    id = "governor",
    -- No number to read out: the state is the message, and the pilot has
    -- rather more urgent things to do than listen to a word.
    test  = function()
      return State.valid("governor") and GOV_FAULT[State.governorText()] == true
    end,
    clear = function()
      return not State.valid("governor")
             or GOV_FAULT[State.governorText()] ~= true
    end,
    repeatAfter = 10,
    haptic = { 40, 60, 3 },
    tone = { 260, 200, 40 },
  },
  {
    id = "link",
    -- Only meaningful once a link has existed. Rotorflight tells us
    -- authoritatively when it can; otherwise link quality carries it.
    test = function()
      if State.linkConnected == false then return true end
      return State.valid("linkQuality") and State.num("linkQuality") <= 30
    end,
    clear = function()
      if State.linkConnected == true then return true end
      return not State.valid("linkQuality") or State.num("linkQuality") >= 45
    end,
    repeatAfter = 12,
    haptic = { 50, 50, 2 },
    tone = { 180, 300, 60 },
  },
}

Alerts.DEFS = DEFS

--------------------------------------------------------------------------
-- Firing
--------------------------------------------------------------------------

local function fire(def)
  local h = def.haptic
  if h then
    for _ = 1, (h[3] or 1) do Host.playHaptic(h[1], h[2], Host.PLAY_NOW) end
  end
  if def.tone then
    Host.playTone(def.tone[1], def.tone[2], def.tone[3], Host.PLAY_NOW)
  end
  if def.speak then pcall(def.speak) end
  Alerts.lastSpoken = def.id
  Alerts.count = Alerts.count + 1
end

function Alerts.reset()
  state = {}
  liveSince = nil
  Alerts.fired = {}
  Alerts.lastSpoken = nil
  Alerts.count = 0
end

-- Any live flight value counts as telemetry being up. Deliberately the same
-- test the dashboard once used to decide it had something worth drawing.
local function telemetryLive()
  return State.valid("cellVoltage") or State.valid("packVoltage")
      or State.valid("headspeed") or State.valid("batteryPercent")
      or State.valid("current")
end

function Alerts.service(now)
  now = now or Host.now()
  if not Alerts.enabled then
    liveSince = nil
    return
  end

  if not telemetryLive() then
    -- Losing telemetry is not itself an alert - a dropout is common and the
    -- dashboard already says so. Clear the settle timer so a reconnect gets
    -- its grace period back rather than firing on the first noisy sample.
    liveSince = nil
    return
  end
  if liveSince == nil then liveSince = now end
  if (now - liveSince) < Alerts.SETTLE then return end

  -- A held hold switch means the pilot is deliberately parked with the model
  -- powered. Freezing the extremes without silencing the alarms would make
  -- the feature useless on the bench.
  if State.holdActive then return end

  for _, def in ipairs(DEFS) do
    local s = state[def.id]
    if not s then s = { active = false, nextAt = 0 }; state[def.id] = s end

    if s.active then
      if def.clear() then
        s.active = false
        Alerts.fired[def.id] = nil
      elseif now >= s.nextAt then
        fire(def)
        s.nextAt = now + Host.seconds(def.repeatAfter)
      end
    elseif def.test() then
      s.active = true
      Alerts.fired[def.id] = true
      fire(def)
      s.nextAt = now + Host.seconds(def.repeatAfter)
    end
  end
end

-- What is currently sounding, worst first, for anything that wants to show it.
function Alerts.active()
  local out = {}
  for _, def in ipairs(DEFS) do
    if Alerts.fired[def.id] then out[#out + 1] = def.id end
  end
  return out
end

return Alerts

end
