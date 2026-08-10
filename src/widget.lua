-- Widget entry point.
--
-- Owns the EdgeTX lifecycle and nothing else: which screen is showing, when to
-- rebuild it, and servicing telemetry from both refresh() and background().
--
-- Two screens. The dashboard is the product; the sensor map is a diagnostics
-- view, reachable from the settings, that shows which telemetry sensor got
-- bound to each role. It is the first place to look when a panel reads "--".

return function(ZD)

local Host    = ZD.Host
local Roles   = ZD.Roles
local Config  = ZD.Config
local Sensors = ZD.Sensors
local RF2     = ZD.RF2
local State   = ZD.State
local Alerts  = ZD.Alerts
local FlightLog = ZD.FlightLog
local Profiles = ZD.Profiles
local Theme   = ZD.Theme
local Dashboard = ZD.Dashboard

local Widget = {}
ZD.Widget = Widget

-- EdgeTX publishes its constants through a read-only global lookup table
-- rather than as raw entries in _G, so rawget() alone returns nil for every
-- one of them. Missing this silently collapses every font size and alignment
-- to 0: on hardware the dashboard rendered entirely in the default font,
-- left-aligned, with no error anywhere to say why.
local function flag(name, fallback)
  local v = rawget(_G, name)
  if v == nil then v = _G[name] end
  if v == nil then v = fallback end
  return v
end
local SOURCE = flag("SOURCE", 1)
local BOOL   = flag("BOOL", 2)
local VALUE  = flag("VALUE", 0)
local SMLSIZE, BOLD, RIGHT = flag("SMLSIZE", 0), flag("BOLD", 0), flag("RIGHT", 0)

Widget.showSensors = false
local built = nil          -- "dash" | "sensors" | nil
local scroll = 0
local zoneW, zoneH = nil, nil

-- EdgeTX gives each widget a zone, which is only the whole screen when it sits
-- in a full-screen layout slot. LVGL objects are children of the widget, so
-- anything laid out against LCD_W/LCD_H gets clipped at the zone edge - the
-- dashboard renders with its right-hand side simply missing.
local function readZone(widget)
  local z = widget and widget.zone
  local w = tonumber(z and z.w) or Host.lcdW
  local h = tonumber(z and z.h) or Host.lcdH
  if w <= 0 then w = Host.lcdW end
  if h <= 0 then h = Host.lcdH end
  return w, h
end

--------------------------------------------------------------------------
-- Diagnostics screen
--------------------------------------------------------------------------
--
-- Builds the row data only. The drawing lives in Dashboard, because a widget
-- that declares useLvgl gets no immediate-mode drawing at all: EdgeTX calls
-- refresh(nullptr) on that path and every lcd.draw* bails on the null buffer.
-- This screen used lcd.drawText and therefore rendered nothing whatsoever.

local HOW = { override = "cfg", name = "auto", unit = "guess" }

local function formatValue(row)
  if row.status == "unbound" then return "--" end
  if row.status == "stale"   then return "no data" end
  if row.status == "insane"  then return "out of range" end
  local v = row.value
  if v == nil then return "--" end
  if math.abs(v - math.floor(v + 0.5)) < 0.05 then
    return string.format("%d", math.floor(v + 0.5))
  end
  return string.format("%.2f", v)
end

-- Appended to the diagnostics list. Answers, from the radio itself, what is
-- actually in the widget folder and what each probe makes of it - rather than
-- inferring any of it from this side of the link.
local ASSET_FILES = { "logo_panel.png", "logo_small.png" }

-- Returns a one-line summary and the full detail block separately. The detail
-- used to lead the list, from when a missing PNG was the open problem - but it
-- is seven rows, and it pushed the roles a pilot actually consults down past
-- the fold. The summary carries the only bit worth seeing every time: whether
-- the artwork loaded. Detail goes to the bottom, where it is still one scroll
-- away when something breaks.
local function assetRows()
  local dir = Host.widgetDir()
  local detail, bad = {}, 0

  local listing = Host.listDir(dir)
  if listing == nil then
    detail[#detail + 1] = { label = "  dir()", sensor = "unavailable",
                            status = "unbound" }
  elseif #listing == 0 then
    detail[#detail + 1] = { label = "  dir()", sensor = "EMPTY", status = "insane" }
    bad = bad + 1
  else
    for _, name in ipairs(listing) do
      detail[#detail + 1] = { label = "  " .. name, sensor = "", status = "ok" }
    end
  end

  for _, f in ipairs(ASSET_FILES) do
    local p = Host.probeImage(dir .. f)
    local ok = p.bmp and p.w and p.w > 0
    if not ok then bad = bad + 1 end
    local s = string.format("%s%s%s", p.fstat and "F" or "-",
                            p.io and "I" or "-", p.bmp and "B" or "-")
    if p.size then s = s .. " " .. tostring(p.size) .. "b" end
    if p.w then s = s .. " w" .. tostring(p.w) end
    detail[#detail + 1] = { label = "  " .. f, sensor = s,
                            status = ok and "ok" or "insane" }
  end

  local summary = {
    label = "-- ARTWORK --",
    sensor = dir,
    value = (bad == 0) and string.format("%d ok", #ASSET_FILES)
            or string.format("%d MISSING", bad),
    status = (bad == 0) and "ok" or "insane",
    important = true,
  }
  detail[#detail + 1] = { label = "-- ARTWORK DETAIL --",
                          sensor = Host.widgetDirSource, status = "ok",
                          important = true }
  -- The header belongs above the block it heads.
  table.insert(detail, 1, table.remove(detail))
  return summary, detail
end

local function sensorMapRows()
  local sensorRows, bound = Sensors.report(), 0
  for _, r in ipairs(sensorRows) do if r.sensor then bound = bound + 1 end end

  -- Roles first: they are what the screen is consulted for. Two status lines
  -- above them, the artwork detail below.
  --
  -- The flight log is silent by design - it writes once, at landing, and says
  -- nothing. That leaves no way to tell it is working without pulling the card,
  -- so it reports itself here: how it decided the heli was flying, how long,
  -- and whether the last write landed.
  local summary, detail = assetRows()
  local where, verdict = FlightLog.status()
  local profile = Profiles.current()
  local rfWhere, rfVerdict, rfStatus = RF2.status()
  local statsText, statsVerdict, statsStatus = RF2.statsText()
  local rows = { summary, {
    -- Optional, and silent either way. Without this the only outward sign of
    -- RF Tool was the footer quietly showing the FC's craft name, which cannot
    -- distinguish "not installed" from "installed but never registered" from
    -- "registered but the FC never handshaked".
    label = "-- RF TOOL --",
    sensor = rfWhere,
    value = rfVerdict,
    status = rfStatus,
    important = true,
  }, {
    label = "  fc stats",
    sensor = statsText,
    value = statsVerdict,
    status = statsStatus,
  }, {
    -- What the widget thinks it is bolted to. It decides which readings are
    -- plausible, what headspeed counts as flying, and when the ESC is too hot,
    -- so a wrong profile is quiet and consequential.
    label = "-- PROFILE --",
    sensor = Profiles.label() .. (profile and ("  " .. profile.note) or ""),
    value = Profiles.how(),
    status = profile and "ok" or "unbound",
    important = true,
  }, {
    label = "-- FLIGHT LOG --",
    sensor = where,
    value = verdict,
    status = FlightLog.lastError and "insane"
             or (FlightLog.written > 0 and "ok" or "unbound"),
    important = true,
  }, {
    -- The line that says whether a flight is even being detected. Without a
    -- flight there is nothing to write, and "no file appeared" reads exactly
    -- the same either way.
    label = "  flight",
    sensor = State.armed and ("FLYING, from " .. State.armSource)
             or ("idle, arm source " .. State.armSource),
    value = string.format("%d:%02d  min %ds",
                          math.floor(State.flightSeconds / 60),
                          math.floor(State.flightSeconds % 60),
                          FlightLog.MIN_SECONDS),
    status = State.armed and "ok" or "unbound",
  } }
  for _, r in ipairs(sensorRows) do
    rows[#rows + 1] = {
      label = r.label, sensor = r.off and "off" or r.sensor, status = r.status,
      important = r.important, how = r.how and HOW[r.how] or nil,
      value = formatValue(r),
    }
  end
  for _, r in ipairs(detail) do rows[#rows + 1] = r end

  local note, bad = nil, false
  if #Config.problems > 0 then
    note, bad = "cfg: " .. Config.problems[1], true
  else
    note = (State.armed and "ARMED" or "disarmed") .. "  " ..
           (RF2.craftName or Host.modelName())
    if #Sensors.unresolved > 0 then
      note = note .. "  (" .. #Sensors.unresolved .. " unresolved)"
    end
  end
  return rows, bound, note, bad
end

-- Exposed for tools/dump_screen.lua, so the documented sensor map is the one
-- the radio builds rather than a hand-written sample that drifts.
Widget.sensorMapRows = sensorMapRows

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

local function serviceOpts(widget)
  local opts = widget.options or {}
  State.armSwitch = opts.ArmSwitch
  State.armInvert = opts.ArmInvert == 1
  local hold = false
  if opts.HoldSwitch and opts.HoldSwitch ~= 0 then
    local v = Host.read(opts.HoldSwitch)
    if v ~= nil then
      hold = v > 0
      if opts.HoldInvert == 1 then hold = not hold end
    end
  end
  return { hold = hold }
end

-- Rebuild only when the screen we should be showing actually changes.
-- Tearing down and recreating every LVGL object per frame would defeat the
-- entire point of retained mode.
local function ensureScreen(widget)
  local w, h = readZone(widget)
  if w ~= zoneW or h ~= zoneH then
    zoneW, zoneH = w, h
    built = nil          -- a resized zone needs a fresh layout
  end
  if Widget.showSensors then
    if built ~= "sensors" then
      -- It used to clear the screen and draw nothing, which is exactly what a
      -- widget looks like when it has disappeared.
      pcall(Dashboard.buildSensorMap, zoneW, zoneH)
      built = "sensors"
      scroll = 0
    end
    return
  end

  -- One screen. It is built once and then only ever updated, so there is no
  -- longer a standby-to-dashboard transition to get wrong.
  if built ~= "dash" then
    -- A widget must never be able to fault the transmitter. Lua raises on
    -- memory exhaustion, and an unhandled raise from a widget is what puts
    -- EdgeTX into emergency mode - so every build is caught, and each failure
    -- steps down to something cheaper rather than propagating.
    local ok = pcall(Dashboard.build, zoneW, zoneH)
    if not ok and not Dashboard.noLogo then
      Dashboard.noLogo = true          -- retry without any bitmap
      Widget.degraded = "no-logo"
      ok = pcall(Dashboard.build, zoneW, zoneH)
    end
    if not ok and not Dashboard.noRound then
      Dashboard.noRound = true         -- then without rounded corners
      Widget.degraded = "no-round"
      ok = pcall(Dashboard.build, zoneW, zoneH)
    end
    if not ok then
      Widget.degraded = "safe-mode"
      pcall(Dashboard.buildMinimal, zoneW, zoneH)
    end
    built = "dash"
  end
end

function Widget.create(zone, options)
  -- create() and update() were the two entry points still unguarded. Anything
  -- that raises here happens before a screen exists at all.
  pcall(Theme.build)
  pcall(Config.load)
  pcall(State.reloadModel)
  built = nil
  zoneW, zoneH = nil, nil
  return { zone = zone, options = options }
end

function Widget.update(widget, options)
  widget.options = options
  Widget.showSensors = (options and options.SensorMap == 1) or false
  Alerts.enabled = not (options and options.Alerts == 0)
  FlightLog.enabled = not (options and options.FlightLog == 0)
  Profiles.set(options and options.Profile)

  -- Edge-triggered: switching Test Alert on sounds one alert, switching it off
  -- and on again sounds another. update() is only called when the options
  -- change, but guarding on the transition costs nothing and means a firmware
  -- that calls it more often cannot turn this into a siren.
  local test = (options and options.TestAlert == 1) or false
  if test and not Widget.lastTestOption then pcall(Alerts.selfTest) end
  Widget.lastTestOption = test
  -- There used to be a Level option here, stepping the renderer down one
  -- construct at a time. It existed only to bisect the emergency-mode reboot
  -- on hardware; the cause turned out to be XXLSIZE + BOLD selecting a font
  -- index EdgeTX has no font for (see Theme.font), so the option has done its
  -- job. The automatic ladder in ensureScreen() stays - it is the part that
  -- protects a radio nobody is standing next to.
  Dashboard.noRound = false
  Dashboard.noLogo  = false
  Widget.degraded = nil
  pcall(Config.load)
  pcall(Sensors.reload, Host.modelName())
  pcall(Alerts.reset)
  built = nil
  ensureScreen(widget)
end

Widget.degraded = nil

function Widget.refresh(widget, event, touchState)
  local now = Host.now()
  pcall(State.service, now, serviceOpts(widget))
  pcall(Alerts.service, now)
  pcall(FlightLog.service)
  ensureScreen(widget)

  if Widget.showSensors then
    if event == flag("EVT_VIRTUAL_NEXT", -1) then scroll = scroll + 1
    elseif event == flag("EVT_VIRTUAL_PREV", -2) then scroll = scroll - 1 end
    local ok, rows, bound, note, bad = pcall(sensorMapRows)
    if ok then
      local clamped = Dashboard.updateSensorMap(rows, scroll, bound, note, bad)
      if clamped then scroll = clamped end
    end
  else
    pcall(Dashboard.update)
  end
end

-- Telemetry is serviced here too, so session peaks and flight time are
-- recorded while another screen is in front - and, more to the point, so the
-- alerts still sound. A low cell does not stop mattering because the pilot
-- happened to be looking at the model setup page.
function Widget.background(widget)
  local now = Host.now()
  pcall(State.service, now, serviceOpts(widget))
  pcall(Alerts.service, now)
  -- Logged from here too: a flight can end while the pilot is on another
  -- screen, and an unwritten flight is lost the moment the model changes.
  pcall(FlightLog.service)
end

Widget.options = {
  -- 0 auto, 1 Rotorflight (6S and up), 2 OMPHOBBY OSF03 (200-size).
  --
  -- A number rather than a name because EdgeTX widget options have no list
  -- type - BOOL, VALUE, SOURCE, SWITCH, COLOR, STRING and TIMER, and nothing
  -- that presents a set of named choices. So the resolved name is printed on
  -- the sensor map instead, where it can also say whether it was set or
  -- detected. A profile moves alert thresholds silently, and an unlabelled
  -- "2" in a settings page is not good enough on its own.
  { "Profile",    VALUE,  0, 0, 2 },
  -- EdgeTX reports a two-position switch as -1024 and +1024, and nothing in
  -- the value says which end the pilot calls "armed" - that depends on how the
  -- switch is mounted. Getting it backwards is silent and consequential in
  -- both cases: a reversed arm switch runs the flight timer on the bench and
  -- logs a flight when you switch off, and a reversed hold switch silences the
  -- alerts for the whole flight while looking exactly like a working one.
  { "ArmSwitch",  SOURCE, 0 },
  { "ArmInvert",  BOOL,   0 },
  { "HoldSwitch", SOURCE, 0 },
  { "HoldInvert", BOOL,   0 },
  { "SensorMap",  BOOL,   0 },
  { "Alerts",     BOOL,   1 },
  { "TestAlert",  BOOL,   0 },
  { "FlightLog",  BOOL,   1 },
}

Widget.OPTION_LABELS = {
  ArmSwitch  = "Arm Switch (fallback)",
  HoldSwitch = "Hold Switch",
  SensorMap  = "Show Sensor Map",
  Alerts     = "Audio + Vibe Alerts",
  TestAlert  = "Test Alert (toggle)",
  FlightLog  = "Log Flights",
}

function Widget.translate(name)
  return Widget.OPTION_LABELS[name] or name
end

return Widget

end
