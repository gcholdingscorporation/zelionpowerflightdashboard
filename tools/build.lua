-- Amalgamates src/*.lua into deployable single-file widgets.
--
--   lua5.4 tools/build.lua
--
-- EdgeTX can load additional Lua files at runtime, but doing so is fiddly
-- (path handling, .luac compilation, error reporting) and both reference
-- dashboards ship as one file for that reason. So: modular source for
-- development and testing, one file per widget for the radio.
--
-- Each module is written as `return function(ZD) ... end`, which lets the same
-- text run under loadfile() in tests and inline here with no edits.
--
-- Two widgets come out of this tree. They share the host adapter and the
-- theme and are otherwise independent, so each build takes only the modules
-- its own widget needs - ZelionPerf carrying the flight log and the alert
-- engine around would be dead weight in a fixed Lua heap, which is one of the
-- things it exists to complain about.

package.path = "./?.lua;./tools/?.lua;" .. package.path

local Loader = require("loader")

local VERSION = "0.1.0-dev"

local WIDGETS = {
  {
    name    = "ZelionDash",
    outDir  = "dist/WIDGETS/ZelionDash",
    modules = Loader.MODULES,
    entry   = "widget",
    banner  = "ZelionDash - RC helicopter telemetry dashboard for EdgeTX",
    export  = "ZD.Widget",
    useLvgl = true,
  },
  {
    name    = "ZelionPerf",
    outDir  = "dist/WIDGETS/ZelionPerf",
    modules = Loader.PERF,
    entry   = "perfwidget",
    banner  = "ZelionPerf - EdgeTX UI frame rate analyser",
    export  = "ZD.PerfWidget",
    useLvgl = true,
  },
}

local function readFile(path)
  local f = assert(io.open(path, "r"), "cannot read " .. path)
  local content = f:read("*a")
  f:close()
  return content
end

local function build(spec)
  local modules = {}
  for _, name in ipairs(spec.modules) do modules[#modules + 1] = name end
  modules[#modules + 1] = spec.entry

  local parts = {}
  local function emit(s) parts[#parts + 1] = s end

  emit(string.format([[
-- %s
-- Version %s
--
-- GENERATED FILE - do not edit.
-- Built from src/*.lua by tools/build.lua. Edit the sources and rebuild.

local ZD = { VERSION = %q }
]], spec.banner, VERSION, VERSION))

  for _, name in ipairs(modules) do
    local path = "src/" .. name .. ".lua"
    emit(string.format(
      "\n-- ======== src/%s.lua ========\ndo\n  local factory = (function()\n%s\n  end)()\n  factory(ZD)\nend\n",
      name, readFile(path)))
  end

  emit(string.format([[

return {
  name       = %q,
  options    = %s.options,
  create     = %s.create,
  update     = %s.update,
  refresh    = %s.refresh,
  background = %s.background,
  translate  = %s.translate,
  useLvgl    = %s,
}
]], spec.name, spec.export, spec.export, spec.export, spec.export,
    spec.export, spec.export, tostring(spec.useLvgl)))

  os.execute('mkdir -p "' .. spec.outDir .. '"')
  local outFile = spec.outDir .. "/main.lua"
  local out = assert(io.open(outFile, "w"))
  local body = table.concat(parts)
  out:write(body)
  out:close()

  -- Compile-check the result. A build that produces a syntactically invalid
  -- file is worse than no build: on the radio it fails as an opaque widget
  -- error with no line number worth reading.
  local chunk, err = loadfile(outFile)
  if not chunk then
    io.stderr:write("BUILD FAILED (" .. spec.name .. "): " .. tostring(err) .. "\n")
    os.exit(1)
  end

  print(string.format("built %s (%d modules, %.1f KB)",
                      outFile, #modules, #body / 1024))
end

for _, spec in ipairs(WIDGETS) do build(spec) end
