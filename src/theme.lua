-- Layer 5a: Colours and font ladder.
--
-- Zelion lime doubles as the "healthy" state. Brand green and battery-OK green
-- would otherwise be two competing greens on one display; merged, there is
-- exactly one green on screen and it is the brand's. Amber and red stay
-- strictly reserved for a value that needs attention now, so an alarm keeps
-- its meaning.
--
-- Colours are built lazily: lcd.RGB does not exist until the widget is
-- created, so this cannot run at module load.

return function(ZD)

local Theme = {}
ZD.Theme = Theme

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

-- EdgeTX offers a fixed ladder of font sizes, not arbitrary point values.
-- Everything the renderer draws picks from these, which is why the layout
-- positions text by anchor rather than by measured height.
Theme.font = {
  small  = flag("SMLSIZE", 0),
  normal = 0,
  mid    = flag("MIDSIZE", 0),
  large  = flag("DBLSIZE", 0),
  huge   = flag("XXLSIZE", flag("DBLSIZE", 0)),
  bold   = flag("BOLD", 0),
}

Theme.built = false

function Theme.build()
  if Theme.built then return end
  if type(lcd) ~= "table" or type(lcd.RGB) ~= "function" then return end
  local rgb = lcd.RGB

  Theme.bg     = rgb(  6,   8,  11)
  Theme.panel  = rgb( 16,  20,  26)
  Theme.rule   = rgb( 35,  42,  51)
  Theme.track  = rgb(  9,  12,  16)
  Theme.ink    = rgb(242, 245, 248)
  Theme.dim    = rgb(118, 129, 143)

  -- Brand
  Theme.lime     = rgb(139, 224,  74)
  Theme.limeDark = rgb( 78, 143,  34)
  Theme.steel    = rgb(127, 196, 238)

  -- Status. Reserved: never used for decoration.
  Theme.warn = rgb(245, 179,   1)
  Theme.crit = rgb(239,  68,  68)

  -- Recorded extremes. Deliberately desaturated so a session peak never
  -- reads as a live warning.
  Theme.peak = rgb(185, 154,  74)

  -- Governor panel backgrounds, keyed by the severity of the state.
  Theme.govRunBg  = rgb( 21,  42,  12)
  Theme.govRunBr  = rgb( 61, 107,  31)
  Theme.govWarnBg = rgb( 42,  33,  10)
  Theme.govWarnBr = rgb( 90,  67,  19)
  Theme.govCritBg = rgb( 42,  13,  13)
  Theme.govCritBr = rgb( 88,  27,  27)
  Theme.govIdleBg = Theme.panel
  Theme.govIdleBr = Theme.rule

  Theme.built = true
end

--------------------------------------------------------------------------
-- Value -> colour
--------------------------------------------------------------------------

function Theme.batteryColor(pct)
  if pct == nil then return Theme.dim end
  if pct >= 50 then return Theme.lime end
  if pct >= 20 then return Theme.warn end
  return Theme.crit
end

-- 3.50V/cell is the conventional "land now" threshold on a LiPo.
function Theme.cellColor(v)
  if v == nil then return Theme.dim end
  if v <= 3.50 then return Theme.crit end
  if v <= 3.65 then return Theme.warn end
  return Theme.ink
end

function Theme.tempColor(c)
  if c == nil then return Theme.dim end
  if c >= 110 then return Theme.crit end
  if c >= 95  then return Theme.warn end
  return Theme.ink
end

function Theme.becColor(v)
  if v == nil then return Theme.dim end
  if v < 4.8 then return Theme.crit end
  if v < 5.1 then return Theme.warn end
  return Theme.ink
end

function Theme.linkColor(pct)
  if pct == nil or pct <= 0 then return Theme.crit end
  if pct >= 60 then return Theme.lime end
  if pct >= 40 then return Theme.warn end
  return Theme.crit
end

-- Governor states that mean the rotor is driven, in trouble, or stopped.
local GOV_RUNNING = { ACTIVE=true, SPOOLUP=true, RECOVERY=true, BAILOUT=true, BYPASS=true }
local GOV_CRIT    = { ["THR-OFF"]=true, ["LOST-HS"]=true }

function Theme.govColors(state)
  if GOV_RUNNING[state] then
    return Theme.lime, Theme.govRunBg, Theme.govRunBr
  elseif GOV_CRIT[state] then
    return Theme.crit, Theme.govCritBg, Theme.govCritBr
  elseif state == "IDLE" or state == "AUTOROT" then
    return Theme.warn, Theme.govWarnBg, Theme.govWarnBr
  end
  return Theme.dim, Theme.govIdleBg, Theme.govIdleBr
end

return Theme

end
