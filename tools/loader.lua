-- Loads the widget's modules on desktop Lua, in the same order the build
-- script amalgamates them. Tests use this; the radio uses dist/.../main.lua.
--
-- Each src module is written as a factory: it returns function(ZD) ... end.
-- That single convention is what lets the same files run under require() here
-- and inline in a concatenated single-file build on the radio.

local Loader = {}

-- Order matters: a module may reference any module listed before it.
Loader.MODULES = {
  "host",
  "roles",
  "config",
  "profiles",
  "sensors",
  "rf2",
  "state",
  "alerts",
  "flighttime",
  "flightlog",
  "theme",
  "layout",
  "dashboard",
}

function Loader.load(root)
  root = root or "src"
  local ZD = { VERSION = "1.0.0" }
  for _, name in ipairs(Loader.MODULES) do
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

return Loader
