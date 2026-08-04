-- A minimal EdgeTX host, good enough to exercise layers 1-4 on a desktop.
--
-- This is not a simulator. It implements exactly the API surface src/host.lua
-- consumes, which is the point: if the widget needs something this mock does
-- not have, that call belongs in the host adapter and nowhere else.

local Mock = {}

local realOs = os

Mock.state = {
  time      = 0,          -- 10ms ticks
  modelName = "Test Heli",
  lcdW      = 800,
  lcdH      = 480,
  radio     = "tx16s",
  version   = "2.11.0",
  sensors   = {},         -- ordered list of { name, unit, value, current }
  files     = {},         -- path -> string contents
  timers    = { [0] = { value = 0, start = 0 } },
  hasSourceValue = true,
  hasGetSensor   = true,
}

local byName = {}
local byId   = {}

local function reindex()
  byName, byId = {}, {}
  for i, s in ipairs(Mock.state.sensors) do
    s.id = 1000 + i
    byName[s.name] = s
    byId[s.id] = s
  end
end

--------------------------------------------------------------------------
-- Test-facing helpers
--------------------------------------------------------------------------

function Mock.addSensor(name, unit, value)
  Mock.state.sensors[#Mock.state.sensors + 1] = {
    name = name, unit = unit, value = value, current = true,
  }
  reindex()
end

function Mock.setSensor(name, value, current)
  local s = byName[name]
  if not s then return false end
  s.value = value
  if current ~= nil then s.current = current end
  return true
end

function Mock.removeSensor(name)
  for i, s in ipairs(Mock.state.sensors) do
    if s.name == name then
      table.remove(Mock.state.sensors, i)
      reindex()
      return true
    end
  end
  return false
end

function Mock.advance(ticks)
  Mock.state.time = Mock.state.time + (ticks or 1)
end

function Mock.advanceSeconds(s)
  Mock.advance(math.floor((s or 0) * 100))
end

function Mock.writeFile(path, contents)
  Mock.state.files[path] = contents
end

function Mock.reset()
  Mock.noDefaultLogos = false
  Mock.restoreConstants()
  Mock.removeLvgl()
  Mock.state.time = 0
  Mock.state.sensors = {}
  Mock.state.files = {}
  Mock.state.modelName = "Test Heli"
  Mock.state.hasSourceValue = true
  Mock.state.hasGetSensor = true
  reindex()
end

--------------------------------------------------------------------------
-- Installed globals
--------------------------------------------------------------------------

function Mock.install()
  _G.LCD_W = Mock.state.lcdW
  _G.LCD_H = Mock.state.lcdH

  -- EdgeTX telemetry unit enum, as used by the real firmware.
  _G.UNIT_VOLTS   = 1
  _G.UNIT_AMPS    = 2
  _G.UNIT_CELSIUS = 11
  _G.UNIT_PERCENT = 13
  _G.UNIT_MAH     = 14
  _G.UNIT_RPMS    = 18

  function _G.getTime() return Mock.state.time end

  function _G.getVersion()
    return Mock.state.radio, Mock.state.version
  end

  function _G.getFieldInfo(name)
    local s = byName[name]
    if not s then return nil end
    return { id = s.id, name = s.name, unit = s.unit }
  end

  function _G.getValue(source)
    local s = byId[source] or byName[source]
    if not s then return 0 end
    return s.value
  end

  if Mock.state.hasSourceValue then
    function _G.getSourceValue(source)
      local s = byId[source] or byName[source]
      if not s then return nil, false, false end
      if not s.current then return nil, false, false end
      return s.value, true, true
    end
  else
    _G.getSourceValue = nil
  end

  function _G.getSourceName(id)
    local s = byId[id]
    return s and s.name or nil
  end

  _G.model = {
    getInfo = function() return { name = Mock.state.modelName } end,
    getTimer = function(i) return Mock.state.timers[i] end,
  }
  if Mock.state.hasGetSensor then
    _G.model.getSensor = function(i)
      local s = Mock.state.sensors[i + 1]
      if not s then return nil end
      return { name = s.name, unit = s.unit, prec = 0 }
    end
  end

  -- Virtual filesystem. Handles are tables so io.read/io.write can carry a
  -- cursor without touching the real disk.
  local realIo = io
  _G.io = {
    open = function(path, mode)
      mode = mode or "r"
      if mode == "r" then
        local content = Mock.state.files[path]
        if not content then return nil end
        return { path = path, mode = "r", pos = 1, content = content }
      end
      return { path = path, mode = "w", parts = {} }
    end,
    read = function(f, n)
      if not f or f.mode ~= "r" then return nil end
      if f.pos > #f.content then return "" end
      local chunk = string.sub(f.content, f.pos, f.pos + n - 1)
      f.pos = f.pos + #chunk
      return chunk
    end,
    write = function(f, s)
      if not f or f.mode ~= "w" then return nil end
      f.parts[#f.parts + 1] = s
      return true
    end,
    close = function(f)
      if f and f.mode == "w" then
        Mock.state.files[f.path] = table.concat(f.parts)
      end
      return true
    end,
    lines = realIo and realIo.lines or nil,
  }

  -- EdgeTX's bitmap loader. imageExists() prefers this over fstat because it
  -- answers the question that actually matters: will this image render.
  _G.Bitmap = {
    open = function(path)
      if Mock.state.files[path] == nil then return nil end
      return { path = path }
    end,
    getSize = function(bmp)
      if not bmp then return 0, 0 end
      return 100, 100
    end,
  }

  _G.fstat = function(path)
    local c = Mock.state.files[path]
    if not c then return nil end
    return { size = #c }
  end

  -- Deliberately no rename/delete API: the default mock exercises the
  -- direct-write path, matching a radio whose firmware lacks dir.*. The real
  -- os table has to be shadowed too, otherwise desktop Lua's os.rename leaks
  -- in and the widget would try to rename files on the actual disk.
  -- EdgeTX's dir() is an iterator over a folder's filenames.
  _G.dir = function(path)
    local names, i = {}, 0
    for full in pairs(Mock.state.files) do
      local name = string.match(full, "^" .. path:gsub("%-", "%%-") .. "([^/]+)$")
      if name then names[#names + 1] = name end
    end
    table.sort(names)
    return function()
      i = i + 1
      return names[i]
    end
  end
  _G.os = { time = realOs.time, clock = realOs.clock,
            date = realOs.date, exit = realOs.exit }
  _G.mkdir = function() return true end

  -- Drawing stub. It records calls rather than rendering, which is enough to
  -- prove the draw path runs without erroring and to assert on what was drawn.
  Mock.draws = {}
  _G.SOLID = 0
  -- Distinct non-zero values so a constant that failed to resolve (and so
  -- collapsed to 0) is visible in an assertion rather than blending in.
  _G.LEFT,    _G.CENTER,  _G.RIGHT   = 0, 0x0800, 0x1000
  _G.SMLSIZE, _G.MIDSIZE             = 0x0020, 0x0040
  _G.DBLSIZE, _G.XXLSIZE             = 0x0060, 0x0080
  _G.BOLD                            = 0x2000
  _G.EVT_VIRTUAL_NEXT, _G.EVT_VIRTUAL_PREV = 100, 101
  _G.SOURCE, _G.BOOL = 1, 2
  _G.lcd = {
    RGB = function(r, g, b) return (r or 0) * 65536 + (g or 0) * 256 + (b or 0) end,
    drawText = function(x, y, text, flags)
      Mock.draws[#Mock.draws + 1] = { op = "text", x = x, y = y,
                                      text = tostring(text), flags = flags }
    end,
    drawFilledRectangle = function(x, y, w, h, c)
      Mock.draws[#Mock.draws + 1] = { op = "rect", x = x, y = y, w = w, h = h }
    end,
    drawLine = function(x1, y1, x2, y2)
      Mock.draws[#Mock.draws + 1] = { op = "line", x = x1, y = y1 }
    end,
  }
end

--------------------------------------------------------------------------
-- Read-only constant lookup
--------------------------------------------------------------------------

-- The real radio does NOT expose its constants as raw entries in _G; they come
-- through a read-only lookup table, so rawget() returns nil for all of them.
-- Installing them raw - which is the convenient thing for a mock to do - hides
-- an entire class of bug that only appears on hardware. This reproduces the
-- real exposure.
local HIDDEN_CONSTANTS = {
  "SMLSIZE", "BOLD", "MIDSIZE", "DBLSIZE", "XXLSIZE", "CENTER", "CENTERED",
  "RIGHT", "LEFT", "SOLID", "SOURCE", "BOOL", "VALUE", "STRING", "COLOR",
  "EVT_VIRTUAL_NEXT", "EVT_VIRTUAL_PREV", "EVT_VIRTUAL_ENTER", "PLAY_NOW",
  "UNIT_VOLTS", "UNIT_AMPS", "UNIT_CELSIUS", "UNIT_PERCENT", "UNIT_MAH",
  "UNIT_RPMS", "LCD_W", "LCD_H",
}

function Mock.hideConstants()
  local hidden = {}
  for _, n in ipairs(HIDDEN_CONSTANTS) do
    hidden[n] = rawget(_G, n)
    rawset(_G, n, nil)
  end
  Mock._hidden = hidden
  setmetatable(_G, { __index = function(_, k) return hidden[k] end })
end

function Mock.restoreConstants()
  setmetatable(_G, nil)
  for n, v in pairs(Mock._hidden or {}) do rawset(_G, n, v) end
  Mock._hidden = nil
end

--------------------------------------------------------------------------
-- Rotorflight RF Tool mock
--------------------------------------------------------------------------

-- Installs a global `rf2` matching the real RF Tool contract. Omit the call
-- entirely to simulate RF Tool not being installed, which is the default and
-- the case the widget must survive.
--
-- opts: apiVersion (number|nil), modelName (string), stats (table), failUseApi
function Mock.installRf2(opts)
  opts = opts or {}
  Mock.rf2Widgets = {}
  Mock.rf2Reads = 0

  local stats = opts.stats or {
    stats_total_flights = { value = 137 },
    stats_total_time_s  = { value = 41230 },
    stats_total_dist_m  = { value = 0 },
  }

  _G.rf2 = {
    rfToolApiVersion = 1.00,
    apiVersion = opts.apiVersion,
    modelName  = opts.modelName,
    clock      = function() return Mock.state.time / 100 end,
    registerWidget = function(widget)
      Mock.rf2Widgets[#Mock.rf2Widgets + 1] = widget
    end,
    useApi = function(name)
      if opts.failUseApi then error("no such api: " .. tostring(name)) end
      if name ~= "mspFlightStats" then return nil end
      return {
        read = function(callback, param)
          Mock.rf2Reads = Mock.rf2Reads + 1
          -- The real API replies asynchronously over MSP. Calling back inline
          -- is the strictest case for the caller's state handling.
          if callback then callback(param, stats) end
        end,
      }
    end,
  }
  return _G.rf2
end

function Mock.removeRf2()
  _G.rf2 = nil
  Mock.rf2Widgets = nil
end

-- Deliver a state change to every registered widget, exactly as RF Tool does.
function Mock.rf2Fire(newState)
  for _, widget in ipairs(Mock.rf2Widgets or {}) do
    if widget.onStateChanged then widget.onStateChanged(widget, newState) end
  end
end


--------------------------------------------------------------------------
-- LVGL mock
--------------------------------------------------------------------------

-- Records objects and their property writes rather than rendering. That is
-- enough to assert what the dashboard built, what it wrote, and - importantly
-- - that a repeated frame writes nothing at all.
function Mock.installLvgl()
  Mock.lv = { objects = {}, cleared = 0, sets = 0 }

  local function make(kind, props)
    local o = { kind = kind, props = {}, visible = true, setCount = 0 }
    for k, v in pairs(props or {}) do o.props[k] = v end
    function o:set(p)
      self.setCount = self.setCount + 1
      Mock.lv.sets = Mock.lv.sets + 1
      for k, v in pairs(p) do self.props[k] = v end
    end
    function o:show() self.visible = true end
    function o:hide() self.visible = false end
    Mock.lv.objects[#Mock.lv.objects + 1] = o
    return o
  end

  _G.lvgl = {
    clear = function()
      Mock.lv.objects = {}
      Mock.lv.cleared = Mock.lv.cleared + 1
    end,
    label     = function(p) return make("label", p) end,
    rectangle = function(p) return make("rect", p) end,
    image     = function(p) return make("image", p) end,
    hline     = function(p) return make("hline", p) end,
    vline     = function(p) return make("vline", p) end,
    isFullScreen = function() return true end,
    isAppMode    = function() return false end,
  }
end

-- The widget loads its artwork from the SD card. Tests that expect the real
-- image path need those files to exist in the virtual filesystem.
function Mock.installLogos()
  if Mock.noDefaultLogos then return end
  for _, f in ipairs({"logo_panel.png", "logo_small.png", "logo_standby.png"}) do
    Mock.state.files["/WIDGETS/ZelionDash/" .. f] = "PNG"
  end
end

function Mock.removeLvgl()
  _G.lvgl = nil
  Mock.lv = nil
end

-- Every label's text in creation order, joined.
function Mock.lvglText()
  local out = {}
  for _, o in ipairs((Mock.lv or {}).objects or {}) do
    if o.kind == "label" and o.props.text and o.props.text ~= "" then
      out[#out + 1] = tostring(o.props.text)
    end
  end
  return table.concat(out, "|")
end

function Mock.lvglImages()
  local out = {}
  for _, o in ipairs((Mock.lv or {}).objects or {}) do
    if o.kind == "image" then out[#out + 1] = tostring(o.props.file or "") end
  end
  return out
end

-- All text drawn in the last frame, joined - convenient for assertions.
function Mock.drawnText()
  local out = {}
  for _, d in ipairs(Mock.draws or {}) do
    if d.op == "text" then out[#out + 1] = d.text end
  end
  return table.concat(out, "|")
end

function Mock.enableAtomicWrites()
  _G.dir = {
    rename = function(from, to)
      local c = Mock.state.files[from]
      if c == nil then return false end
      Mock.state.files[to] = c
      Mock.state.files[from] = nil
      return true
    end,
    del = function(path)
      Mock.state.files[path] = nil
      return true
    end,
  }
end

return Mock
