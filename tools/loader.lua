-- Loads the widget's modules on desktop Lua, in the same order the build
-- script amalgamates them. Tests use this; the radio uses dist/.../main.lua.
--
-- Each src module is written as a factory: it returns function(ZD) ... end.
-- That single convention is what lets the same files run under require() here
-- and inline in a concatenated single-file build on the radio.

local Loader = {}

-- Two widgets are built from this one tree. They share the host adapter and
-- the theme - the first because it is the only code allowed to touch EdgeTX,
-- the second because they should look like the same product - and nothing
-- else. ZelionPerf knows nothing about telemetry roles, and ZelionDash knows
-- nothing about frame timing.
--
-- Order matters within a list: a module may reference any module before it.

-- Shared by both widgets.
Loader.COMMON = {
  "host",
  "theme",
}

Loader.DASH_MODULES = {
  "roles",
  "config",
  "profiles",
  "sensors",
  "rf2",
  "state",
  "alerts",
  "flighttime",
  "flightlog",
  "layout",
  "dashboard",
}

Loader.PERF_MODULES = {
  "perfstats",
  "perfprobe",
  "perfscan",
  "perfadvice",
  "perfscreen",
}

local function concat(...)
  local out = {}
  for _, list in ipairs({...}) do
    for _, name in ipairs(list) do out[#out + 1] = name end
  end
  return out
end

-- theme.lua used to load after the dashboard's own layers and before the
-- renderer. It is listed in COMMON now, which moves it earlier; nothing
-- between the two positions references it at load time, so the order the
-- modules see is unchanged.
Loader.MODULES = concat(Loader.COMMON, Loader.DASH_MODULES)
Loader.PERF    = concat(Loader.COMMON, Loader.PERF_MODULES)

function Loader.load(root, modules)
  root = root or "src"
  local ZD = { VERSION = "0.1.0-dev" }
  for _, name in ipairs(modules or Loader.MODULES) do
    local path = root .. "/" .. name .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then error("failed to load " .. path .. ": " .. tostring(err)) end
    local factory = chunk()
    if type(factory) ~= "function" then
      error(path .. " must return a function(ZD)")
    end
    factory(ZD)
  end
  return ZD
end

-- Loads the analyser's modules instead of the dashboard's, entry point
-- included. The build lists the entry separately because it also has to name
-- the table to export from it; tests only want the whole thing loaded.
Loader.PERF_ENTRY = "perfwidget"
Loader.DASH_ENTRY = "widget"

function Loader.loadPerf(root)
  return Loader.load(root, concat(Loader.PERF, { Loader.PERF_ENTRY }))
end

return Loader
