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
local Theme   = ZD.Theme
local Dashboard = ZD.Dashboard

local Widget = {}
ZD.Widget = Widget

local function flag(n, f) return rawget(_G, n) or f end
local SOURCE = flag("SOURCE", 1)
local BOOL   = flag("BOOL", 2)
local SMLSIZE, BOLD, RIGHT = flag("SMLSIZE", 0), flag("BOLD", 0), flag("RIGHT", 0)

Widget.showSensors = false
local built = nil          -- "dash" | "standby" | "sensors" | nil
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
-- Diagnostics screen (immediate mode - it is a tool, not the product)
--------------------------------------------------------------------------

local HOW = { override = "cfg", name = "auto", unit = "guess" }

local function statusColor(row)
  if row.status == "ok" or row.status == "derived" then return Theme.lime end
  if row.status == "insane" then return Theme.crit end
  if row.important then return Theme.warn end
  return Theme.dim
end

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

local function drawSensorMap()
  local w, h = zoneW or Host.lcdW, zoneH or Host.lcdH
  local compact = w < 700
  lcd.drawFilledRectangle(0, 0, w, h, Theme.bg)

  local pad     = compact and 6 or 12
  local headerH = compact and 20 or 28
  local rowH    = compact and 14 or 20

  local rows, bound = Sensors.report(), 0
  for _, r in ipairs(rows) do if r.sensor then bound = bound + 1 end end

  lcd.drawText(pad, compact and 2 or 5,
               compact and "Sensors" or "ZelionDash - sensor map", BOLD + Theme.steel)
  lcd.drawText(w - pad, compact and 2 or 5,
               string.format("%d/%d bound", bound, #rows), RIGHT + SMLSIZE + Theme.dim)
  lcd.drawLine(0, headerH, w, headerH, SOLID, Theme.rule)

  local colRole, colSensor = pad, math.floor(w * 0.34)
  local colHow, colValue   = math.floor(w * 0.56), w - pad
  local footerH = compact and 16 or 22
  local listTop = headerH + (compact and 3 or 6)
  local visible = math.max(1, math.floor((h - listTop - footerH) / rowH))

  if scroll > #rows - visible then scroll = math.max(0, #rows - visible) end
  if scroll < 0 then scroll = 0 end

  for i = 1, visible do
    local row = rows[i + scroll]
    if row then
      local y, color = listTop + (i - 1) * rowH, statusColor(row)
      lcd.drawText(colRole, y, row.label,
                   SMLSIZE + (row.important and BOLD or 0) + Theme.ink)
      lcd.drawText(colSensor, y, row.sensor or "-", SMLSIZE + color)
      lcd.drawText(colHow, y, row.how and HOW[row.how] or "", SMLSIZE + Theme.dim)
      lcd.drawText(colValue, y, formatValue(row), RIGHT + SMLSIZE + color)
    end
  end

  local fy = h - footerH + (compact and 1 or 3)
  if #Config.problems > 0 then
    lcd.drawText(pad, fy, "cfg: " .. Config.problems[1], SMLSIZE + Theme.crit)
  else
    local note = (State.armed and "ARMED" or "disarmed") .. "  " ..
                 (RF2.craftName or Host.modelName())
    if #Sensors.unresolved > 0 then
      note = note .. "  (" .. #Sensors.unresolved .. " unresolved)"
    end
    lcd.drawText(pad, fy, note, SMLSIZE + Theme.dim)
  end
  if #rows > visible then
    lcd.drawText(w - pad, fy,
                 string.format("%d-%d", scroll + 1, math.min(#rows, scroll + visible)),
                 RIGHT + SMLSIZE + Theme.dim)
  end
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

local function serviceOpts(widget)
  local opts = widget.options or {}
  State.armSwitch = opts.ArmSwitch
  local hold = false
  if opts.HoldSwitch and opts.HoldSwitch ~= 0 then
    local v = Host.read(opts.HoldSwitch)
    hold = v ~= nil and v > 0
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
      if type(lvgl) == "table" then lvgl.clear() end
      built = "sensors"
    end
    return
  end
  local want = Dashboard.shouldStandby() and "standby" or "dash"
  if built ~= want then
    Dashboard.build(want == "standby", zoneW, zoneH)
    built = want
  end
end

function Widget.create(zone, options)
  Theme.build()
  Config.load()
  State.reloadModel()
  built = nil
  zoneW, zoneH = nil, nil
  return { zone = zone, options = options }
end

function Widget.update(widget, options)
  widget.options = options
  Widget.showSensors = (options and options.SensorMap == 1) or false
  Config.load()
  Sensors.reload(Host.modelName())
  built = nil
  ensureScreen(widget)
end

function Widget.refresh(widget, event, touchState)
  State.service(Host.now(), serviceOpts(widget))
  ensureScreen(widget)

  if Widget.showSensors then
    if event == flag("EVT_VIRTUAL_NEXT", -1) then scroll = scroll + 1
    elseif event == flag("EVT_VIRTUAL_PREV", -2) then scroll = scroll - 1 end
    drawSensorMap()
  else
    Dashboard.update()
  end
end

-- Telemetry is serviced here too, so session peaks and flight time are
-- recorded while another screen is in front.
function Widget.background(widget)
  State.service(Host.now(), serviceOpts(widget))
end

Widget.options = {
  { "ArmSwitch",  SOURCE, 0 },
  { "HoldSwitch", SOURCE, 0 },
  { "SensorMap",  BOOL,   0 },
}

Widget.OPTION_LABELS = {
  ArmSwitch  = "Arm Switch (fallback)",
  HoldSwitch = "Hold Switch",
  SensorMap  = "Show Sensor Map",
}

function Widget.translate(name)
  return Widget.OPTION_LABELS[name] or name
end

return Widget

end
