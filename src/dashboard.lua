-- Layer 6: The dashboard renderer.
--
-- Retained-mode LVGL: every object is created once in build(), and refresh()
-- pushes only the properties whose values actually changed. A shadow table
-- holds the last value written to each object so an unchanged frame costs no
-- host calls at all.
--
-- Reads State and Layout; owns no telemetry logic of its own. If a number
-- looks wrong on screen, this file is almost never where the bug is.

return function(ZD)

local Host   = ZD.Host
local State  = ZD.State
local Theme  = ZD.Theme
local Layout = ZD.Layout
local RF2    = ZD.RF2

local Dashboard = {}
ZD.Dashboard = Dashboard

local function assetDir() return Host.widgetDir() end

function Dashboard.assetDir() return assetDir() end

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
local ALIGN_CENTER = flag("CENTER", flag("CENTERED", 0))
local ALIGN_RIGHT  = flag("RIGHT", 0)

local GOV_STATES = {
  [0]="OFF", [1]="IDLE", [2]="SPOOLUP", [3]="RECOVERY", [4]="ACTIVE",
  [5]="THR-OFF", [6]="LOST-HS", [7]="AUTOROT", [8]="BAILOUT", [9]="BYPASS",
}

local V, SHADOW = {}, {}

--------------------------------------------------------------------------
-- Retained-object helpers
--------------------------------------------------------------------------

local function remember(obj, props)
  local st = {}
  for k, v in pairs(props) do st[k] = v end
  st.visible = true
  SHADOW[obj] = st
  return obj
end

local function setp(obj, props)
  if not obj then return end
  local st = SHADOW[obj]
  if not st then st = {}; SHADOW[obj] = st end
  local changed = false
  for k, v in pairs(props) do
    if st[k] ~= v then st[k] = v; changed = true end
  end
  if changed then obj:set(props) end
end

local function setVisible(obj, vis)
  if not obj then return end
  local st = SHADOW[obj]
  if not st then st = {}; SHADOW[obj] = st end
  vis = vis and true or false
  if st.visible == vis then return end
  st.visible = vis
  if vis then obj:show() else obj:hide() end
end

local function label(x, y, w, text, font, color, align)
  local p = { x=x, y=y, w=w or 0, h=0, text=text or "",
              font=font or 0, color=color or Theme.ink, align=align or 0 }
  return remember(lvgl.label(p), p)
end

local function rectangle(x, y, w, h, color, filled, rounded, thickness)
  local p = { x=x, y=y, w=w, h=h, color=color,
              filled=filled and 1 or 0, rounded=rounded or 0,
              thickness=thickness or 1 }
  return remember(lvgl.rectangle(p), p)
end

-- A panel is a fill plus a separate border so the two can be recoloured
-- independently - the governor block changes both as its state changes.
local function panel(r, fill, border, rounded)
  return {
    fill   = rectangle(r.x, r.y, r.w, r.h, fill,   true,  rounded or 5, 1),
    border = rectangle(r.x, r.y, r.w, r.h, border, false, rounded or 5, 1),
  }
end

local function setPanel(p, fill, border)
  setp(p.fill,   { color = fill })
  setp(p.border, { color = border })
end

--------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------

local function fmt(v, pattern, scale)
  if v == nil then return "--" end
  return string.format(pattern, v * (scale or 1))
end

local function fmtInt(role)
  local v, ok = State.get(role)
  if not ok then return "--" end
  return string.format("%d", math.floor(v + 0.5))
end

local function fmtExtreme(prefix, value, pattern)
  if value == nil then return prefix .. " --" end
  return prefix .. " " .. string.format(pattern, value)
end

local function clockText(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Sag is the gap between the pack's best cell voltage this flight and what it
-- is delivering now: the number that actually says how the pack is holding up.
local function cellSag()
  local now, ok = State.get("cellVoltage")
  local best = State.max("cellVoltage")
  if not ok or best == nil then return nil end
  local sag = best - now
  if sag < 0 then sag = 0 end
  return sag
end

local function govText()
  local g, ok = State.get("governor")
  if not ok then return "--" end
  return GOV_STATES[math.floor(g)] or "UNKNOWN"
end

--------------------------------------------------------------------------
-- Standby
--------------------------------------------------------------------------

-- Nothing truthful to draw: no link, and none of the values a dashboard
-- exists to show. Anything less strict would blank the screen mid-flight
-- during a telemetry dropout, which is precisely when it must not.
function Dashboard.shouldStandby()
  if State.linkConnected == true then return false end
  if State.valid("headspeed") or State.valid("packVoltage")
     or State.valid("batteryPercent") or State.valid("cellVoltage")
     or State.valid("current") then
    return false
  end
  return true
end

--------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------

local L
local mode  -- "dash" | "standby"


-- Artwork lives on the SD card, so it can simply be absent - a widget copied
-- without its PNGs is the likeliest first-run mistake. Check before asking
-- LVGL to load it: a missing image otherwise fails silently and leaves a hole
-- with nothing to explain it.
Dashboard.logoMissing = false
Dashboard.missingPath = nil

function Dashboard.placeLogo(r, filename)
  if Dashboard.noLogo then
    local F = Theme.font
    label(r.x, r.y + math.floor(r.h / 2) - 12, r.w, "ZELION POWER",
          F.mid + F.bold, Theme.steel, ALIGN_CENTER)
    return
  end
  local path = assetDir() .. filename
  -- Cached in Host, so a rebuild does not re-open (and re-allocate) the file.
  local ok = Host.imageExists(path)

  -- Draw the wordmark FIRST, then the image over it. A probe that says
  -- "missing" is evidence, not proof: it was wrong on hardware once already.
  -- Ordering it this way means a working image always wins, and the wordmark
  -- is only ever seen when nothing loaded at all.
  if not ok then
    Dashboard.logoMissing = true
    Dashboard.missingPath = path
    -- One label, not two stacked: without a way to measure text there is no
    -- safe gap between them, and a two-line version overlapped itself the
    -- moment the fonts started resolving.
    local F = Theme.font
    label(r.x, r.y + math.floor(r.h / 2) - 12, r.w, "ZELION POWER",
          F.mid + F.bold, Theme.steel, ALIGN_CENTER)
  end

  -- Attempted unconditionally: if LVGL can load it, it renders regardless of
  -- what the probes concluded.
  lvgl.image({ x=r.x, y=r.y, w=r.w, h=r.h, fill=false, file=path })
end

local function buildTopBar()
  local F = Theme.font
  V.modelName = label(L.c.pad, L.class == "roomy" and 10 or 7, 260, "",
                      F.small + F.bold, Theme.ink)
  V.timer = label(0, L.class == "roomy" and 4 or 2, L.w, "",
                  F.mid + F.bold, Theme.ink, ALIGN_CENTER)

  -- Signal bars, then the TX battery glyph at the far right.
  local barsX = L.w - L.c.pad - (L.class == "roomy" and 200 or 128)
  local step  = L.class == "roomy" and 10 or 8
  local unit  = L.class == "roomy" and 6 or 5
  local baseY = L.class == "roomy" and 30 or 22
  V.signal = {}
  for i = 1, 4 do
    local bh = 6 + (i - 1) * 4
    V.signal[i] = rectangle(barsX + (i - 1) * step, baseY - bh, unit, bh,
                            Theme.rule, true, 0, 0)
  end

  local bw, bh = (L.class == "roomy" and 16 or 13), (L.class == "roomy" and 22 or 16)
  local bx = L.w - L.c.pad - 36
  local by = L.class == "roomy" and 14 or 10
  rectangle(bx + math.floor((bw - 8) / 2), by - 4, 8, 3, Theme.dim, true, 1, 0)
  V.txBody = panel({x=bx, y=by, w=bw, h=bh}, Theme.track, Theme.dim, 3)
  V.txFill = rectangle(bx + 2, by + bh - 3, bw - 4, 1, Theme.lime, true, 2, 0)
  V.txGeom = { x=bx, y=by, w=bw, h=bh }
  V.txText = label(L.w - L.c.pad - 30, L.class == "roomy" and 13 or 9, 30, "",
                   Theme.font.small + Theme.font.bold, Theme.ink)

  lvgl.hline({ x=0, y=L.topRule, w=L.w, h=1, color=Theme.rule })
end

local function buildLeftColumn()
  local F = Theme.font
  local c, b = L.cell, L.bar

  V.cellPanel = panel(c, Theme.bg, Theme.limeDark, 6)
  label(c.x, c.y + 6, c.w, "CELL", F.small + F.bold, Theme.lime, ALIGN_CENTER)
  V.cellValue = label(c.x, c.y + (L.class == "roomy" and 20 or 16), c.w, "",
                      F.large + F.bold, Theme.ink, ALIGN_CENTER)
  V.cellMin = label(c.x, c.y + c.h - (L.class == "roomy" and 16 or 14), c.w, "",
                    F.small, Theme.peak, ALIGN_CENTER)

  -- Brand-green border: the gauge is the Zelion instrument on this screen.
  rectangle(b.x, b.y, b.w, b.h, Theme.track, true,  7, 1)
  rectangle(b.x, b.y, b.w, b.h, Theme.lime,  false, 7, 2)
  V.barFill = rectangle(b.x + 3, b.y + b.h - 4, b.w - 6, 1, Theme.lime, true, 5, 0)
  V.barGeom = { x=b.x + 3, y=b.y + 3, w=b.w - 6, h=b.h - 6 }
end

local function buildHero()
  local F = Theme.font
  local roomy = L.class == "roomy"
  local padX, footY = 16, roomy and 150 or 95

  local r = L.battery
  panel(r, Theme.panel, Theme.rule)
  label(r.x + padX, r.y + 12, r.w - padX * 2, "BATTERY", F.small + F.bold, Theme.dim)
  V.batValue = label(r.x + padX, r.y + (roomy and 30 or 22), r.w - padX * 2, "",
                     F.huge + F.bold, Theme.ink)
  V.batUnit  = label(r.x + r.w - padX - 40, r.y + (roomy and 60 or 44), 40, "%",
                     F.mid, Theme.dim, ALIGN_RIGHT)
  V.batPack  = label(r.x + padX, r.y + r.h - (roomy and 62 or 46), r.w - padX * 2, "",
                     F.mid + F.bold, Theme.ink, ALIGN_RIGHT)
  lvgl.hline({ x=r.x + padX, y=r.y + r.h - (roomy and 30 or 24),
               w=r.w - padX * 2, h=1, color=Theme.rule })
  V.batFoot = {}
  local slots = roomy and 4 or 3
  local slotW = math.floor((r.w - padX * 2) / slots)
  for i = 1, slots do
    V.batFoot[i] = label(r.x + padX + slotW * (i - 1), r.y + r.h - (roomy and 22 or 18),
                         slotW, "", F.small, Theme.dim)
  end

  r = L.headspeed
  panel(r, Theme.panel, Theme.rule)
  label(r.x + padX, r.y + 12, r.w - padX * 2, "HEADSPEED", F.small + F.bold, Theme.dim)
  V.hsValue = label(r.x + padX, r.y + (roomy and 30 or 22), r.w - padX * 2, "",
                    F.huge + F.bold, Theme.ink)
  label(r.x + r.w - padX - 60, r.y + (roomy and 76 or 54), 60, "RPM",
        F.small + F.bold, Theme.dim, ALIGN_RIGHT)
  lvgl.hline({ x=r.x + padX, y=r.y + r.h - (roomy and 30 or 24),
               w=r.w - padX * 2, h=1, color=Theme.rule })
  V.hsFoot = {}
  local hslots = roomy and 3 or 2
  local hslotW = math.floor((r.w - padX * 2) / hslots)
  for i = 1, hslots do
    V.hsFoot[i] = label(r.x + padX + hslotW * (i - 1), r.y + r.h - (roomy and 22 or 18),
                        hslotW, "", F.small, Theme.dim)
  end
end

local function buildRightColumn()
  local F = Theme.font
  local roomy = L.class == "roomy"

  local g = L.gov
  V.govPanel = panel(g, Theme.govIdleBg, Theme.govIdleBr)
  label(g.x, g.y + 8, g.w, "GOVERNOR", F.small + F.bold, Theme.dim, ALIGN_CENTER)
  V.govState = label(g.x, g.y + (roomy and 28 or 20), g.w, "",
                     F.large + F.bold, Theme.dim, ALIGN_CENTER)

  -- Labels carry their units on both screens; at 54px wide there is no room
  -- for a separate unit glyph, and consistency beats a spare pixel.
  local defs = roomy
    and { {"CURRENT A"}, {"ESC °C"}, {"BEC V"} }
    or  { {"CURR A"},    {"ESC °C"}, {"BEC V"} }
  V.tiles = {}
  for i = 1, 3 do
    local t = L.tiles[i]
    panel(t, Theme.panel, Theme.rule)
    label(t.x + 6, t.y + 7, t.w - 12, defs[i][1], F.small, Theme.dim)
    V.tiles[i] = {
      value = label(t.x + 6, t.y + (roomy and 26 or 22), t.w - 12, "",
                    F.mid + F.bold, Theme.ink),
      foot  = label(t.x + 6, t.y + t.h - 16, t.w - 12, "", F.small, Theme.peak),
    }
  end

  -- No frame: a panel border fought the mark's own outline.
  Dashboard.placeLogo(L.logo, roomy and "logo_panel.png" or "logo_small.png")
end

local function buildStrip()
  local F = Theme.font
  lvgl.hline({ x=0, y=L.stripRule, w=L.w, h=1, color=Theme.rule })
  local y = L.stripRule + (L.class == "roomy" and 14 or 10)
  V.flights = label(L.c.pad, y, 300, "", F.small, Theme.dim)
  if L.class == "roomy" then
    label(0, y, L.w, "NO HYPE · JUST VOLTAGE · REAL POWER", F.small, Theme.dim, ALIGN_CENTER)
  end
  V.link = label(L.w - L.c.pad - 160, y, 160, "", F.small, Theme.steel, ALIGN_RIGHT)
end

-- Compact readout of what the radio itself finds in the widget folder.
-- Lives on standby because that is where a failed load is actually seen;
-- requiring the pilot to find a settings toggle to diagnose it was a mistake.
local ASSET_FILES = { "logo_panel.png", "logo_standby.png", "logo_small.png" }

function Dashboard.assetDiagLines(maxLines)
  local out = {}
  assetDir()

  -- main.lua is definitely present - the widget is running from it. If it also
  -- reads as missing then the probes are useless here and only a positive
  -- bitmap width means anything; if it reads fine, the folder is right and the
  -- PNGs specifically are the problem.
  local control = Host.probeImage(assetDir() .. "main.lua")
  out[#out + 1] = string.format("control main.lua %s%s%s  (must exist)",
    control.fstat and "F" or "-", control.io and "I" or "-",
    control.bmp and "B" or "-")

  out[#out + 1] = string.format("DIR (%s): %s",
                                Host.widgetDirSource, assetDir())

  for _, f in ipairs(ASSET_FILES) do
    local p = Host.probeImage(assetDir() .. f)
    out[#out + 1] = string.format("%s %s%s%s%s%s", f,
      p.fstat and "F" or "-", p.io and "I" or "-", p.bmp and "B" or "-",
      p.size and (" " .. p.size .. "b") or "",
      p.w and (" w" .. p.w) or "")
  end
  while maxLines and #out > maxLines do table.remove(out) end
  return out
end

local function buildStandby()
  local F = Theme.font
  V.modelName = label(L.c.pad, L.class == "roomy" and 10 or 7, 260, "",
                      F.small + F.bold, Theme.ink)
  lvgl.hline({ x=0, y=L.topRule, w=L.w, h=1, color=Theme.rule })

  Dashboard.placeLogo(L.logo, "logo_standby.png")
  lvgl.hline({ x=L.divider.x, y=L.divider.y, w=L.divider.w, h=1, color=Theme.rule })
  label(0, L.tagline.y, L.w, "NO HYPE · JUST VOLTAGE · REAL POWER",
        F.small, Theme.dim, ALIGN_CENTER)
  V.status = label(0, L.status.y, L.w, "WAITING FOR TELEMETRY",
                   F.mid + F.bold, Theme.warn, ALIGN_CENTER)

  local roomy = L.class == "roomy"
  local lineH = roomy and 15 or 12
  -- When the artwork failed there is no image in the logo box, only a one-line
  -- wordmark, so the diagnosis can use the space the image would have taken.
  -- placeLogo has already run by this point, so we know which case we are in.
  local dy = Dashboard.logoMissing
             and (L.logo.y + math.floor(L.logo.h / 2) + (roomy and 26 or 20))
             or (L.status.y + (roomy and 28 or 22))
  local room = math.floor((L.stripRule - dy) / lineH)
  V.diag = {}
  for i = 1, math.max(0, math.min(roomy and 6 or 3, room)) do
    V.diag[i] = label(L.c.pad, dy + (i - 1) * lineH, L.w - L.c.pad * 2, "",
                      F.small, Theme.dim, ALIGN_CENTER)
  end

  lvgl.hline({ x=0, y=L.stripRule, w=L.w, h=1, color=Theme.rule })
  local sy = L.stripRule + (L.class == "roomy" and 14 or 10)
  V.flights = label(L.c.pad, sy, 300, "", F.small, Theme.dim)
  -- Standby is where a first run lands, so the missing-artwork notice belongs
  -- here as well as on the dashboard. It lives in the strip rather than under
  -- the status line, which is where it previously collided with it.
  V.link = label(0, sy, L.w - L.c.pad, "", F.small + F.bold,
                 Theme.warn, ALIGN_RIGHT)
end

-- Smallest zone the tight layout can be drawn into honestly. Below this the
-- panels would overlap, so say so rather than render a mess.
Dashboard.MIN_W, Dashboard.MIN_H = 440, 250

-- Last resort. A dozen objects, no bitmap, no panels: if even this cannot be
-- built the widget is not the problem. Reached only after a real build has
-- already failed.
function Dashboard.buildMinimal(w, h)
  if type(lvgl) ~= "table" then return end
  lvgl.clear()
  V, SHADOW = {}, {}
  Host.collect()
  mode = "minimal"
  local F = Theme.font
  rectangle(0, 0, w, h, Theme.bg, true, 0, 0)
  V.modelName = label(8, 6, w - 16, "", F.small + F.bold, Theme.ink)
  label(0, 30, w, "ZELIONDASH - SAFE MODE", F.small + F.bold, Theme.warn, ALIGN_CENTER)
  V.minBat  = label(8,  math.floor(h * 0.30), w - 16, "", F.large + F.bold, Theme.ink, ALIGN_CENTER)
  V.minHs   = label(8,  math.floor(h * 0.55), w - 16, "", F.large + F.bold, Theme.ink, ALIGN_CENTER)
  V.minCell = label(8,  math.floor(h * 0.78), w - 16, "", F.mid, Theme.dim, ALIGN_CENTER)
  Dashboard.update()
end

local function buildTooSmall(w, h)
  local F = Theme.font
  rectangle(0, 0, w, h, Theme.bg, true, 0, 0)
  label(0, math.floor(h / 2) - 26, w, "ZELIONDASH", F.mid + F.bold,
        Theme.steel, ALIGN_CENTER)
  label(0, math.floor(h / 2), w, "NEEDS A FULL SCREEN WIDGET SLOT",
        F.small + F.bold, Theme.warn, ALIGN_CENTER)
  label(0, math.floor(h / 2) + 20, w,
        string.format("this zone is %dx%d, minimum is %dx%d",
                      w, h, Dashboard.MIN_W, Dashboard.MIN_H),
        F.small, Theme.dim, ALIGN_CENTER)
end

-- w,h are the WIDGET ZONE, not the screen. LVGL objects are children of the
-- widget, so anything drawn past the zone edge is silently clipped - laying
-- out against LCD_W/LCD_H produces a dashboard with its right half missing.
function Dashboard.build(standby, w, h)
  if type(lvgl) ~= "table" then return end
  Theme.build()
  lvgl.clear()
  V, SHADOW = {}, {}
  -- lvgl.clear() drops the previous screen's objects and bitmaps; reclaim them
  -- before allocating the next screen rather than letting both coexist.
  Host.collect()
  Dashboard.logoMissing = false
  w = w or Host.lcdW
  h = h or Host.lcdH

  if w < Dashboard.MIN_W or h < Dashboard.MIN_H then
    mode = "toosmall"
    buildTooSmall(w, h)
    return
  end

  mode = standby and "standby" or "dash"

  if standby then
    L = Layout.buildStandby(w, h)
    rectangle(0, 0, L.w, L.h, Theme.bg, true, 0, 0)
    buildStandby()
  else
    L = Layout.build(w, h)
    rectangle(0, 0, L.w, L.h, Theme.bg, true, 0, 0)
    buildTopBar()
    buildLeftColumn()
    buildHero()
    buildRightColumn()
    buildStrip()
  end
  Dashboard.update()
end

Dashboard.mode = function() return mode end

--------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------

local function flightsText()
  if RF2.statsStatus == "ok" and RF2.totalFlights then
    local t = string.format("%d FLIGHTS", RF2.totalFlights)
    if RF2.totalFlightSeconds then
      local s = RF2.totalFlightSeconds
      t = t .. string.format(" · %d:%02d:%02d", math.floor(s / 3600),
                             math.floor(s % 3600 / 60), s % 60)
    end
    return t
  end
  return ""
end

local function updateTopBar()
  setp(V.modelName, { text = RF2.craftName or Host.modelName() })
  setp(V.timer, { text = clockText(State.flightSeconds) })

  local lq = State.valid("linkQuality") and State.num("linkQuality") or nil
  local bars = 0
  if lq then
    bars = (lq >= 80 and 4) or (lq >= 60 and 3) or (lq >= 40 and 2)
           or (lq >= 20 and 1) or 0
  end
  local col = Theme.linkColor(lq)
  for i = 1, 4 do
    setp(V.signal[i], { color = (i <= bars) and col or Theme.rule })
  end

  local tx = State.valid("txVoltage") and State.num("txVoltage") or nil
  if tx then
    -- 2S: 7.0V empty, 8.4V full.
    local pct = math.max(0, math.min(1, (tx - 7.0) / 1.4))
    local fh = math.floor((V.txGeom.h - 4) * pct)
    setp(V.txFill, { y = V.txGeom.y + V.txGeom.h - 2 - fh,
                     h = math.max(1, fh),
                     color = pct > 0.5 and Theme.lime
                             or (pct > 0.25 and Theme.warn or Theme.crit) })
    setVisible(V.txFill, fh > 0)
    setp(V.txText, { text = string.format("%.1f", tx) })
  else
    setVisible(V.txFill, false)
    setp(V.txText, { text = "--" })
  end
end

local function updateLeftColumn()
  local cell, ok = State.get("cellVoltage")
  setp(V.cellValue, { text = ok and string.format("%.2f", cell) or "--",
                      color = ok and Theme.cellColor(cell) or Theme.dim })
  setp(V.cellMin, { text = fmtExtreme("MIN", State.min("cellVoltage"), "%.2f") })

  local pct = State.valid("batteryPercent") and State.num("batteryPercent") or nil
  if pct then
    local g = V.barGeom
    local fh = math.floor(g.h * math.max(0, math.min(100, pct)) / 100)
    setp(V.barFill, { y = g.y + g.h - fh, h = math.max(1, fh),
                      color = Theme.batteryColor(pct) })
    setVisible(V.barFill, fh > 0)
  else
    setVisible(V.barFill, false)
  end
end

local function updateHero()
  local roomy = L.class == "roomy"

  local pct = State.valid("batteryPercent") and State.num("batteryPercent") or nil
  setp(V.batValue, { text = pct and string.format("%d", math.floor(pct + 0.5)) or "--",
                     color = pct and Theme.ink or Theme.dim })
  local pack, packOk = State.get("packVoltage")
  setp(V.batPack, { text = packOk and string.format("%.1f V", pack) or "--",
                    color = packOk and Theme.ink or Theme.dim })

  local foots = {
    fmtExtreme("MIN", State.min("packVoltage"), "%.1fV"),
    fmtExtreme("SAG", cellSag(), "%.2f"),
    State.valid("capacity") and string.format("%d mAh", math.floor(State.num("capacity")))
      or "-- mAh",
    State.valid("cellCount") and string.format("%dS", math.floor(State.num("cellCount")))
      or "--S",
  }
  for i = 1, #V.batFoot do
    setp(V.batFoot[i], { text = foots[i] or "" })
  end

  local hs, hsOk = State.get("headspeed")
  setp(V.hsValue, { text = hsOk and string.format("%d", math.floor(hs + 0.5)) or "--",
                    color = hsOk and Theme.ink or Theme.dim })
  local hfoots = {
    fmtExtreme("MAX", State.max("headspeed"), "%d"),
    State.valid("tailSpeed") and string.format("TAIL %d", math.floor(State.num("tailSpeed")))
      or "TAIL --",
    State.valid("throttle") and string.format("THR %d%%", math.floor(State.num("throttle")))
      or "THR --",
  }
  for i = 1, #V.hsFoot do
    setp(V.hsFoot[i], { text = hfoots[i] or "" })
  end
end

local function updateRightColumn()
  local g = govText()
  local fg, bg, br = Theme.govColors(g)
  setPanel(V.govPanel, bg, br)
  setp(V.govState, { text = g, color = fg })

  local cur, curOk = State.get("current")
  setp(V.tiles[1].value, { text = curOk and string.format("%d", math.floor(cur + 0.5)) or "--",
                           color = curOk and Theme.ink or Theme.dim })
  setp(V.tiles[1].foot, { text = fmtExtreme("MAX", State.max("current"), "%d") })

  local esc, escOk = State.get("escTemperature")
  setp(V.tiles[2].value, { text = escOk and string.format("%d", math.floor(esc + 0.5)) or "--",
                           color = escOk and Theme.tempColor(esc) or Theme.dim })
  setp(V.tiles[2].foot, { text = fmtExtreme("MAX", State.max("escTemperature"), "%d") })

  local bec, becOk = State.get("becVoltage")
  setp(V.tiles[3].value, { text = becOk and string.format("%.1f", bec) or "--",
                           color = becOk and Theme.becColor(bec) or Theme.dim })
  setp(V.tiles[3].foot, { text = fmtExtreme("MIN", State.min("becVoltage"), "%.1f") })
end

local function updateStrip()
  setp(V.flights, { text = flightsText() })
  local text, color = "", Theme.steel
  if Dashboard.logoMissing then
    -- Name the exact path that failed: "missing" is not actionable, a path is.
    setp(V.link, { text = "NO IMAGE: " .. tostring(Dashboard.missingPath),
                   color = Theme.warn })
    return
  end
  if RF2.available() then
    if State.linkConnected == false then
      text, color = "RF2 DISCONNECTED", Theme.dim
    elseif RF2.registered then
      text = "RF2 LINKED"
    end
  end
  setp(V.link, { text = text, color = color })
end

function Dashboard.update()
  if type(lvgl) ~= "table" or mode == "toosmall" then return end
  if mode == "minimal" then
    setp(V.modelName, { text = RF2.craftName or Host.modelName() })
    local pct = State.valid("batteryPercent") and State.num("batteryPercent") or nil
    setp(V.minBat, { text = pct and (string.format("%d", math.floor(pct + 0.5)) .. "%") or "--",
                     color = pct and Theme.batteryColor(pct) or Theme.dim })
    local hs, hsOk = State.get("headspeed")
    setp(V.minHs, { text = hsOk and (string.format("%d", math.floor(hs + 0.5)) .. " RPM") or "-- RPM",
                    color = hsOk and Theme.ink or Theme.dim })
    local cv, cvOk = State.get("cellVoltage")
    setp(V.minCell, { text = cvOk and (string.format("%.2f", cv) .. " V/cell") or "-- V/cell",
                      color = cvOk and Theme.cellColor(cv) or Theme.dim })
    return
  end
  if not V.flights then return end
  if mode == "standby" then
    setp(V.modelName, { text = RF2.craftName or Host.modelName() })
    setp(V.flights, { text = flightsText() })
    setp(V.link, { text = Dashboard.logoMissing
                          and ("NO IMAGE: " .. tostring(Dashboard.missingPath))
                          or "" })
    if V.diag then
      local lines = Dashboard.logoMissing
                    and Dashboard.assetDiagLines(#V.diag) or {}
      for i = 1, #V.diag do
        setp(V.diag[i], { text = lines[i] or "" })
      end
    end
    return
  end
  updateTopBar()
  updateLeftColumn()
  updateHero()
  updateRightColumn()
  updateStrip()
end

return Dashboard

end
