-- ZelionPerf layer 5: the screen.
--
-- Retained-mode LVGL, exactly as the dashboard does it and for the same
-- reason: a widget that declares useLvgl gets no immediate-mode drawing at
-- all - EdgeTX calls refresh(nullptr) on that path and every lcd.draw* bails
-- on the null buffer - so anything drawn with lcd.drawText appears nowhere.
--
-- The retained model matters twice as much here. Objects are created once and
-- only the properties whose values changed reach LVGL, so a frame of this
-- screen is mostly comparisons. It is not allocation-free - LVGL takes its
-- properties as a table, and the readings have to be formatted into strings -
-- but it is bounded and it does not grow with what is on screen. A profiler
-- built the naive way, tearing down and rebuilding its objects every frame,
-- would cost more frame time than most of what it is looking for and would
-- report its own garbage as the pilot's problem. Which is why the widget
-- measures its own per-frame heap use and puts it on the screen rather than
-- asking to be taken on trust.

return function(ZD)

local Host   = ZD.Host
local Theme  = ZD.Theme
local Stats  = ZD.PerfStats
local Advice = ZD.PerfAdvice

local Screen = {}
ZD.PerfScreen = Screen

local function flag(name, fallback)
  local v = rawget(_G, name)
  if v == nil then v = _G[name] end
  if v == nil then v = fallback end
  return v
end
local ALIGN_RIGHT  = flag("RIGHT", 0)
local ALIGN_CENTER = flag("CENTER", 0)

local V, SHADOW = {}, {}
local L = nil
local mode = nil

local function fh(f) return Theme.fontHeight(f) end

-- Remembers what was last written to each object so update() can skip the
-- ones that did not change. LVGL property writes are the expensive part of a
-- frame here; the comparison that avoids them is not.
local function remember(obj, props)
  if obj then SHADOW[obj] = props end
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

-- setp() builds a table for LVGL on every call, whether or not anything
-- changed. Most of what is on this screen does not move frame to frame - the
-- typical frame period, the stall count, the heap - so most of those tables
-- were garbage before LVGL had finished reading them.
--
-- setText compares first and only builds one when the value has actually
-- moved. It deliberately does not reuse a scratch table: EdgeTX's binding
-- reads the fields synchronously today, but a widget that hands a mutable
-- table to a C function and then keeps writing into it is one firmware
-- change away from a fault nobody would connect to this line.
--
-- This is half the fix for the widget reporting 10k allocated per frame
-- against its own name on hardware.
local function setText(obj, text, color)
  if not obj then return end
  local st = SHADOW[obj]
  if not st then st = {}; SHADOW[obj] = st end
  if st.text == text and (color == nil or st.color == color) then return end
  st.text = text
  if color == nil then
    obj:set({ text = text })
  else
    st.color = color
    obj:set({ text = text, color = color })
  end
end

-- Every font goes through Theme.safeFont. EdgeTX indexes its font array with
-- no bounds check, so an index it has no font for is a native fault and an
-- EMERGENCY MODE reboot rather than something pcall can catch.
local function label(x, y, w, text, font, color, align)
  local p = { x = x, y = y, w = w or 0, h = 0, text = text or "",
              font = Theme.safeFont(font or 0),
              color = color or Theme.ink, align = align or 0 }
  return remember(lvgl.label(p), p)
end

local function rectangle(x, y, w, h, color)
  local p = { x = x, y = y, w = w, h = h, color = color,
              filled = 1, rounded = 0, thickness = 0 }
  return remember(lvgl.rectangle(p), p)
end

--------------------------------------------------------------------------
-- Word wrapping
--------------------------------------------------------------------------
--
-- Character-budget wrapping, not pixel-measured. lcd.sizeText exists, but
-- measuring every line of advice on every frame costs more than the whole
-- rest of the screen, and the text changes as findings come and go so it
-- cannot be measured once at build time either.
--
-- The budget comes from the font's line height: across all three EdgeTX font
-- sets the average glyph of the small faces is close to half their height in
-- a proportional face. Being a few characters out puts a short word on the
-- next line, which is a cosmetic result; being exact would cost frames, which
-- is the thing this screen exists to protect.
function Screen.wrap(text, cols, maxLines)
  local out = {}
  -- nil in, nothing out. tostring(nil) would put the word "nil" on screen as
  -- though it were advice.
  if text == nil then return out end
  text = tostring(text)
  cols = math.max(8, math.floor(tonumber(cols) or 40))
  maxLines = math.max(1, math.floor(tonumber(maxLines) or 2))
  local line = ""
  for word in string.gmatch(text, "%S+") do
    local candidate = (line == "") and word or (line .. " " .. word)
    if #candidate <= cols then
      line = candidate
    else
      if line ~= "" then out[#out + 1] = line end
      if #out >= maxLines then break end
      -- A single word longer than the line gets cut rather than overflowing;
      -- a path or a sensor name can legitimately be that long.
      line = (#word > cols) and string.sub(word, 1, cols) or word
    end
  end
  if line ~= "" and #out < maxLines then out[#out + 1] = line end

  -- Say that something was dropped rather than ending mid-sentence as though
  -- that were the whole of the advice.
  if #out == maxLines then
    local consumed = 0
    for _, l in ipairs(out) do consumed = consumed + #l + 1 end
    if consumed < #text then
      local last = out[maxLines]
      if #last > cols - 3 then last = string.sub(last, 1, cols - 3) end
      out[maxLines] = last .. "..."
    end
  end
  return out
end

--------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------

-- Below this the readings would overlap. Said plainly rather than rendered as
-- a mess, the same way the dashboard handles a zone too small for it.
Screen.MIN_W, Screen.MIN_H = 300, 180

local LIST_LINES = 3          -- title plus two lines of detail, per entry

local function buildTooSmall(w, h)
  local F = Theme.font
  rectangle(0, 0, w, h, Theme.bg)
  local y = math.floor(h / 2) - fh(F.small)
  label(0, y, w, "ZELIONPERF", F.small, Theme.steel, ALIGN_CENTER)
  label(0, y + fh(F.small) + 2, w, "NEEDS A FULL SCREEN WIDGET SLOT",
        F.tiny, Theme.warn, ALIGN_CENTER)
end

-- w,h are the WIDGET ZONE, not the screen. LVGL objects are children of the
-- widget, so anything laid out against LCD_W/LCD_H is clipped at the zone
-- edge and the right-hand column simply goes missing.
function Screen.build(w, h)
  if type(lvgl) ~= "table" then return end
  Theme.build()
  lvgl.clear()
  V, SHADOW = {}, {}
  Host.collect()
  w = w or Host.lcdW
  h = h or Host.lcdH
  -- Which font set the firmware was compiled with follows the RADIO's screen,
  -- not the widget's zone.
  Theme.useMetricsFor(Host.lcdW or w)

  if w < Screen.MIN_W or h < Screen.MIN_H then
    mode = "toosmall"
    buildTooSmall(w, h)
    return
  end
  mode = "perf"

  local F = Theme.font
  local roomy = w >= 700
  local pad = roomy and 12 or 6
  L = { w = w, h = h, roomy = roomy, pad = pad }

  rectangle(0, 0, w, h, Theme.bg)

  -- Header ---------------------------------------------------------------
  local headerH = fh(F.small) + (roomy and 8 or 4)
  label(pad, roomy and 4 or 2, math.floor(w * 0.5), "ZELIONPERF",
        F.small, Theme.steel)
  V.scanNote = label(w - pad - math.floor(w * 0.45), roomy and 6 or 3,
                     math.floor(w * 0.45), "", F.tiny, Theme.dim, ALIGN_RIGHT)
  lvgl.hline({ x = 0, y = headerH, w = w, h = 1, color = Theme.rule })

  -- Hero: the frame rate, and the numbers that qualify it ----------------
  local heroFont = roomy and F.huge or F.large
  local heroTop  = headerH + (roomy and 6 or 3)
  V.fps = label(pad, heroTop, math.floor(w * 0.34), "--",
                heroFont, Theme.ink)
  local unitY = heroTop + fh(heroFont) - fh(F.tiny) - (roomy and 8 or 4)
  label(pad + math.floor(w * 0.34), unitY, 60, "fps", F.tiny, Theme.dim)

  -- Six readings in two rows beside it. These are qualifications on the big
  -- number, not independent facts: an average frame rate with no spread and
  -- no stall count beside it is the statistic that hides a stutter.
  local gx = math.floor(w * 0.44)
  local gw = math.floor((w - gx - pad) / 3)
  local gRow = fh(F.tiny) + fh(F.small) + (roomy and 8 or 4)
  local KEYS = {
    { "typical", "p50" }, { "slowest 5%", "p95" }, { "worst", "worst" },
    { "stutters", "stalls" }, { "Lua load", "usage" }, { "heap free", "heap" },
  }
  V.cells = {}
  for i, spec in ipairs(KEYS) do
    local col = (i - 1) % 3
    local row = math.floor((i - 1) / 3)
    local x = gx + col * gw
    local y = heroTop + row * gRow
    label(x, y, gw - 4, spec[1], F.tiny, Theme.dim)
    V.cells[spec[2]] = label(x, y + fh(F.tiny), gw - 4, "--",
                             F.small, Theme.ink)
  end

  local heroH = math.max(fh(heroFont), gRow * 2)

  -- Baseline line --------------------------------------------------------
  local baseY = heroTop + heroH + (roomy and 4 or 2)
  V.baseline = label(pad, baseY, w - pad * 2, "", F.tiny, Theme.dim)
  local ruleY = baseY + fh(F.tiny) + (roomy and 4 or 2)
  lvgl.hline({ x = 0, y = ruleY, w = w, h = 1, color = Theme.rule })

  -- Findings list --------------------------------------------------------
  local lineH   = fh(F.tiny) + 1
  local entryH  = lineH * LIST_LINES + (roomy and 6 or 3)
  local footerH = fh(F.tiny) + (roomy and 6 or 4)
  local listTop = ruleY + (roomy and 6 or 3)
  L.visible = math.max(1, math.floor((h - listTop - footerH) / entryH))
  L.cols    = math.floor((w - pad * 2) / math.max(4, fh(F.tiny) * 0.5))

  V.entries = {}
  for i = 1, L.visible do
    local y = listTop + (i - 1) * entryH
    V.entries[i] = {
      title = label(pad, y, w - pad * 2, "", F.tiny, Theme.ink),
      detail = {
        label(pad + 6, y + lineH, w - pad * 2 - 6, "", F.tiny, Theme.dim),
        label(pad + 6, y + lineH * 2, w - pad * 2 - 6, "", F.tiny, Theme.dim),
      },
    }
  end

  local fy = h - footerH + (roomy and 2 or 1)
  V.hint = label(pad, fy, w - pad * 2 - 110, "", F.tiny, Theme.dim)
  V.page = label(w - pad - 110, fy, 110, "", F.tiny, Theme.dim, ALIGN_RIGHT)
end

Screen.mode = function() return mode end
Screen.visibleEntries = function() return L and L.visible or 0 end

-- The character budget the detail lines are wrapped to.
--
-- Exposed so the widget can wrap when it BUILDS the list - twice a second -
-- rather than here, where it happened on every frame for every visible entry.
-- Wrapping allocates a table and a string per word, so four findings of two
-- lines each was most of what this screen fed the collector. That is the
-- other half of the 10k.
Screen.cols = function() return L and L.cols or 40 end

--------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------

local function severityColor(f)
  if f.tone == "good" then return Theme.lime end
  if f.severity == Advice.HIGH then return Theme.crit end
  if f.severity == Advice.MED  then return Theme.warn end
  if f.severity == Advice.LOW  then return Theme.steel end
  return Theme.dim
end

-- Colour the frame rate itself, so the screen answers "is this bad" before it
-- is read. The thresholds are the advice engine's, not a second set.
local function fpsColor(fps)
  if fps == nil then return Theme.dim end
  if fps < Advice.FPS_BAD  then return Theme.crit end
  if fps < Advice.FPS_FAIR then return Theme.warn end
  return Theme.lime
end

-- view: { snap, findings, comparison, baselineLabel, scan, scroll, hint }
-- Returns the clamped scroll position, which the caller stores back.
function Screen.update(view)
  if mode ~= "perf" then return 0 end
  view = view or {}
  local snap = view.snap or {}
  local findings = view.findings or {}
  local scroll = math.floor(tonumber(view.scroll) or 0)
  local n = L.visible
  if scroll > #findings - n then scroll = math.max(0, #findings - n) end
  if scroll < 0 then scroll = 0 end

  setText(V.fps, Stats.fmtFps(snap.fps), fpsColor(snap.fps))

  local c = V.cells
  local stallColor = (snap.stalls or 0) > 0 and Theme.warn or Theme.ink
  setText(c.p50,   Stats.fmtMs(snap.p50))
  setText(c.p95,   Stats.fmtMs(snap.p95))
  setText(c.worst, Stats.fmtMs(snap.worst), stallColor)
  setText(c.stalls, tostring(snap.stalls or 0), stallColor)
  setText(c.usage, snap.usageMax and (math.floor(snap.usageMax) .. "%") or "n/a",
          (snap.usageMax or 0) >= Advice.USAGE_HIGH and Theme.warn or Theme.ink)
  setText(c.heap, snap.freeMemory and Stats.fmtBytes(snap.freeMemory) or "n/a",
          (snap.freeMemory or math.huge) < Advice.HEAP_LOW
          and Theme.warn or Theme.ink)

  -- Header note: how much evidence is behind the numbers. A frame rate from
  -- four frames and one from four hundred look identical otherwise.
  local note
  if snap.frames and snap.frames > 0 then
    note = string.format("%d frames", snap.frames)
    if snap.spread then
      note = note .. string.format(", +/-%s", Stats.fmtFps(snap.spread))
    end
    if (snap.gaps or 0) > 0 then
      note = note .. string.format(", %d gap%s", snap.gaps,
                                   snap.gaps == 1 and "" or "s")
    end
  else
    note = "measuring"
  end
  setText(V.scanNote, note)

  -- Baseline
  local cmp = view.comparison
  if cmp and cmp.delta then
    local sign = cmp.delta >= 0 and "+" or "-"
    local col = Theme.dim
    if cmp.verdict == "better" then col = Theme.lime
    elseif cmp.verdict == "worse" then col = Theme.crit end
    -- The noise band goes on this line, not just into the findings.
    --
    -- From hardware: a screen reading "+2.8" with the script list showing
    -- looked like a clear win, while the engine's actual verdict on 2.8
    -- against a 3.1 spread was "no measurable change" - and that verdict was
    -- on the OTHER page, where the pilot could not see it. A headline number
    -- that overstates its own certainty is the exact failure this widget was
    -- built to avoid, so the qualification travels with the number.
    local band = cmp.noise
      and string.format(", %s noise +/-%s",
                        cmp.verdict == "same" and "inside" or "beats",
                        Stats.fmtFps(cmp.noise))
      or ""
    setText(V.baseline,
            string.format("baseline %s fps -> now %s fps  (%s%s%s)",
                          Stats.fmtFps(view.baselineFps),
                          Stats.fmtFps(snap.fps), sign,
                          Stats.fmtFps(math.abs(cmp.delta)), band), col)
  else
    setText(V.baseline, "no baseline - press ENTER to mark one", Theme.dim)
  end

  for i = 1, n do
    local e = V.entries[i]
    local f = findings[i + scroll]
    if not f then
      setText(e.title, "")
      setText(e.detail[1], "")
      setText(e.detail[2], "")
    else
      setText(e.title, f.title or "", severityColor(f))
      -- Pre-wrapped by whoever built the list, which happens twice a second.
      -- Wrapping here is the fallback for a caller that did not, and for the
      -- tests that call update() directly.
      local lines = f.lines or Screen.wrap(f.detail, L.cols, 2)
      setText(e.detail[1], lines[1] or "")
      setText(e.detail[2], lines[2] or "")
    end
  end

  setText(V.hint, view.hint or "")
  -- Only formatted when the page actually turned. string.format on every
  -- frame to produce the same "1-4/5" is the cheapest thing here to stop
  -- doing, and there is no reason to keep doing it.
  local page = ""
  if #findings > n then
    local last = math.min(#findings, scroll + n)
    local st = SHADOW[V.page]
    if not (st and st.scroll == scroll and st.last == last
            and st.total == #findings) then
      page = string.format("%d-%d/%d", scroll + 1, last, #findings)
      if st then st.scroll, st.last, st.total = scroll, last, #findings end
    else
      page = st.text
    end
  end
  setText(V.page, page)
  return scroll
end

return Screen

end
