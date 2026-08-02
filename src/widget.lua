-- Widget entry point.
--
-- Phase 2/3 deliverable: a sensor diagnostics screen. It renders one row per
-- role showing what that role bound to, how it bound, and what it currently
-- reads. This is the screen to look at when a panel on the finished dashboard
-- shows dashes, and it is deliberately the first thing that exists - it proves
-- the resolver against real hardware before any layout work is committed to.
--
-- Drawing here uses plain lcd.draw* rather than LVGL. That is intentional for
-- scaffolding: it is trivially portable across both target resolutions and
-- will be replaced wholesale by the real renderer once the layout lands.

return function(ZD)

local Host    = ZD.Host
local Roles   = ZD.Roles
local Config  = ZD.Config
local Sensors = ZD.Sensors
local RF2     = ZD.RF2
local State   = ZD.State

local Widget = {}
ZD.Widget = Widget

local function flag(name, fallback)
  return rawget(_G, name) or fallback
end

local SMLSIZE = flag("SMLSIZE", 0)
local BOLD    = flag("BOLD", 0)
local RIGHT   = flag("RIGHT", 0)
local SOURCE  = flag("SOURCE", 1)
local BOOL    = flag("BOOL", 2)

local EVT_NEXT = flag("EVT_VIRTUAL_NEXT", -1)
local EVT_PREV = flag("EVT_VIRTUAL_PREV", -2)

local C = {}
local function initColors()
  local rgb = lcd.RGB
  C.bg     = rgb(0, 0, 0)
  C.text   = rgb(235, 238, 242)
  C.dim    = rgb(124, 134, 148)
  C.line   = rgb(42, 45, 51)
  C.ok     = rgb(34, 197, 94)
  C.warn   = rgb(240, 180, 41)
  C.bad    = rgb(239, 68, 68)
  C.accent = rgb(95, 211, 188)
end

--------------------------------------------------------------------------
-- Row formatting
--------------------------------------------------------------------------

-- How a role bound is worth showing: "unit" means the widget guessed, and a
-- guess is exactly the thing a pilot should sanity-check before flying.
local HOW_LABEL = {
  override = "cfg",
  name     = "auto",
  unit     = "guess",
}

local function statusColor(row)
  if row.status == "ok" or row.status == "derived" then return C.ok end
  if row.status == "insane" then return C.bad end
  if row.important then return C.warn end
  return C.dim
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

--------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------

local scroll = 0

local function drawScreen(widget)
  local w, h = Host.lcdW, Host.lcdH
  local compact = w < 700

  lcd.drawFilledRectangle(0, 0, w, h, C.bg)

  local pad     = compact and 6 or 12
  local headerH = compact and 20 or 28
  local rowH    = compact and 14 or 20

  -- Header
  -- The full title would run into the RF Tool status at 480px wide.
  lcd.drawText(pad, compact and 2 or 5,
               compact and "Sensors" or "ZelionDash - sensor map",
               BOLD + C.accent)
  local bound = 0
  local rows = Sensors.report()
  for _, r in ipairs(rows) do
    if r.sensor then bound = bound + 1 end
  end
  lcd.drawText(w - pad, compact and 2 or 5,
               string.format("%d/%d bound", bound, #rows),
               RIGHT + SMLSIZE + C.dim)
  lcd.drawLine(0, headerH, w, headerH, SOLID, C.line)

  -- Column layout, proportional so both screen sizes stay readable.
  local colRole   = pad
  local colSensor = math.floor(w * 0.34)
  local colHow    = math.floor(w * 0.56)
  local colValue  = w - pad

  local footerH  = compact and 16 or 22
  local listTop  = headerH + (compact and 3 or 6)
  local listH    = h - listTop - footerH
  local visible  = math.max(1, math.floor(listH / rowH))

  if scroll > #rows - visible then scroll = math.max(0, #rows - visible) end
  if scroll < 0 then scroll = 0 end

  for i = 1, visible do
    local row = rows[i + scroll]
    if row then
      local y = listTop + (i - 1) * rowH
      local color = statusColor(row)
      lcd.drawText(colRole, y, row.label, SMLSIZE + (row.important and BOLD or 0) + C.text)
      lcd.drawText(colSensor, y, row.sensor or "-", SMLSIZE + color)
      lcd.drawText(colHow, y, row.how and HOW_LABEL[row.how] or "", SMLSIZE + C.dim)
      lcd.drawText(colValue, y, formatValue(row), RIGHT + SMLSIZE + color)
    end
  end

  -- Footer: the two things that explain most "why is it blank" questions.
  local fy = h - footerH + (compact and 1 or 3)
  local note
  if #Config.problems > 0 then
    note = "cfg: " .. Config.problems[1]
    lcd.drawText(pad, fy, note, SMLSIZE + C.bad)
  else
    note = State.armed and "ARMED" or "disarmed"
    note = note .. "  " .. (RF2.craftName or Host.modelName())
    if #Sensors.unresolved > 0 then
      note = note .. "  (" .. #Sensors.unresolved .. " unresolved)"
    end
    lcd.drawText(pad, fy, note, SMLSIZE + C.dim)
  end

  -- RF Tool status sits on the header line, where there is room on both
  -- screen sizes. Absent RF Tool draws nothing at all rather than an error:
  -- it is an optional enhancement, not a missing dependency.
  if RF2.available() then
    local rfNote, rfColor
    if RF2.statsStatus == "ok" and RF2.totalFlights then
      rfNote = string.format("RF2 %d flights", RF2.totalFlights)
      rfColor = C.ok
    elseif RF2.statsStatus == "unsupported" then
      rfNote, rfColor = "RF2 (needs MSP 12.9)", C.warn
    elseif RF2.connected == false then
      rfNote, rfColor = "RF2 disconnected", C.dim
    elseif RF2.registered then
      rfNote, rfColor = "RF2 linked", C.dim
    else
      rfNote, rfColor = "RF2 found", C.dim
    end
    lcd.drawText(colSensor, compact and 2 or 5, rfNote, SMLSIZE + rfColor)
  end
  if #rows > visible then
    lcd.drawText(w - pad, fy,
                 string.format("%d-%d", scroll + 1, math.min(#rows, scroll + visible)),
                 RIGHT + SMLSIZE + C.dim)
  end
end

--------------------------------------------------------------------------
-- Widget lifecycle
--------------------------------------------------------------------------

local function readOptions(widget)
  local opts = widget.options or {}
  State.armSwitch = opts.ArmSwitch
  return opts.HoldSwitch and Host.read(opts.HoldSwitch) or nil
end

local function serviceOpts(widget)
  local hold = readOptions(widget)
  return { hold = hold ~= nil and hold > 0 }
end

function Widget.create(zone, options)
  initColors()
  Config.load()
  State.reloadModel()
  return { zone = zone, options = options }
end

function Widget.update(widget, options)
  widget.options = options
  Config.load()
  Sensors.reload(Host.modelName())
end

function Widget.refresh(widget, event, touchState)
  State.service(Host.now(), serviceOpts(widget))

  if event == EVT_NEXT then
    scroll = scroll + 1
  elseif event == EVT_PREV then
    scroll = scroll - 1
  end

  drawScreen(widget)
end

-- Telemetry is serviced here too, so session peaks and flight time are
-- recorded while another screen is in front. Both reference dashboards do
-- this, and it is the single most important structural decision in either.
function Widget.background(widget)
  State.service(Host.now(), serviceOpts(widget))
end

Widget.options = {
  { "ArmSwitch",  SOURCE, 0 },
  { "HoldSwitch", SOURCE, 0 },
}

Widget.OPTION_LABELS = {
  ArmSwitch  = "Arm Switch (fallback)",
  HoldSwitch = "Hold Switch",
}

function Widget.translate(name)
  return Widget.OPTION_LABELS[name] or name
end

return Widget

end
