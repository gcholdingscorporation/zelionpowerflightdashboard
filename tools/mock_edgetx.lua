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

  _G.fstat = function(path)
    local c = Mock.state.files[path]
    if not c then return nil end
    return { size = #c }
  end

  -- Deliberately no rename/delete API: the default mock exercises the
  -- direct-write path, matching a radio whose firmware lacks dir.*. The real
  -- os table has to be shadowed too, otherwise desktop Lua's os.rename leaks
  -- in and the widget would try to rename files on the actual disk.
  _G.dir = nil
  _G.os = { time = realOs.time, clock = realOs.clock,
            date = realOs.date, exit = realOs.exit }
  _G.mkdir = function() return true end

  -- Drawing stub. It records calls rather than rendering, which is enough to
  -- prove the draw path runs without erroring and to assert on what was drawn.
  Mock.draws = {}
  _G.SOLID = 0
  _G.SMLSIZE, _G.BOLD, _G.RIGHT = 1, 2, 4
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
