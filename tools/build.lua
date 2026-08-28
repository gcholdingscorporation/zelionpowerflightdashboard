-- Amalgamates src/*.lua into a single deployable main.lua.
--
--   lua5.4 tools/build.lua
--
-- EdgeTX can load additional Lua files at runtime, but doing so is fiddly
-- (path handling, .luac compilation, error reporting) and both reference
-- dashboards ship as one file for that reason. So: modular source for
-- development and testing, one file for the radio.
--
-- Each module is written as `return function(ZD) ... end`, which lets the same
-- text run under loadfile() in tests and inline here with no edits.

package.path = "./?.lua;./tools/?.lua;" .. package.path

local Loader = require("loader")

local OUT_DIR  = "dist/WIDGETS/ZelionDash"
local OUT_FILE = OUT_DIR .. "/main.lua"
local VERSION  = "1.0.0"

local MODULES = {}
for _, name in ipairs(Loader.MODULES) do MODULES[#MODULES + 1] = name end
MODULES[#MODULES + 1] = "widget"

local function readFile(path)
  local f = assert(io.open(path, "r"), "cannot read " .. path)
  local content = f:read("*a")
  f:close()
  return content
end

local parts = {}
local function emit(s) parts[#parts + 1] = s end

emit(string.format([[
-- ZelionDash - RC helicopter telemetry dashboard for EdgeTX
-- Version %s
--
-- GENERATED FILE - do not edit.
-- Built from src/*.lua by tools/build.lua. Edit the sources and rebuild.

local ZD = { VERSION = %q }
]], VERSION, VERSION))

for _, name in ipairs(MODULES) do
  local path = "src/" .. name .. ".lua"
  emit(string.format(
    "\n-- ======== src/%s.lua ========\ndo\n  local factory = (function()\n%s\n  end)()\n  factory(ZD)\nend\n",
    name, readFile(path)))
end

emit([[

return {
  name       = "ZelionDash",
  options    = ZD.Widget.options,
  create     = ZD.Widget.create,
  update     = ZD.Widget.update,
  refresh    = ZD.Widget.refresh,
  background = ZD.Widget.background,
  translate  = ZD.Widget.translate,
  useLvgl    = true,
}
]])

os.execute('mkdir -p "' .. OUT_DIR .. '"')
local out = assert(io.open(OUT_FILE, "w"))
out:write(table.concat(parts))
out:close()

-- Compile-check the result. A build that produces a syntactically invalid file
-- is worse than no build: on the radio it fails as an opaque widget error.
local chunk, err = loadfile(OUT_FILE)
if not chunk then
  io.stderr:write("BUILD FAILED: " .. tostring(err) .. "\n")
  os.exit(1)
end

local size = #table.concat(parts)
print(string.format("built %s (%d modules, %.1f KB)", OUT_FILE, #MODULES, size / 1024))
