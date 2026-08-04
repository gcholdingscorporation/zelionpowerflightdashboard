-- Layer 2b: SD-card configuration.
--
-- EdgeTX widget settings screens hold about a dozen controls, mostly dropdowns.
-- That is nowhere near enough room for per-role sensor overrides, so overrides
-- live in a plain text file the pilot can edit in Notepad:
--
--   /WIDGETS/ZelionDash/sensors.cfg
--
--   # applies to every model unless overridden below
--   [*]
--   headspeed = Hspd
--   escTemperature = Tesc
--
--   [Goblin 700]
--   escTemperature = Tmp1
--
-- Section headers are model names, matched case-insensitively against the
-- radio's current model. [*] is the fallback for every model. Unknown keys are
-- collected and reported rather than silently dropped, because a typo that
-- fails quietly is exactly what makes a config file frustrating.

return function(ZD)

local Host  = ZD.Host
local Roles = ZD.Roles

local Config = {}
ZD.Config = Config

-- Resolved lazily: the widget's folder is not known at module load, and is
-- not necessarily named after the widget.
function Config.path()
  return Host.widgetDir() .. "sensors.cfg"
end

local function trim(s)
  return (string.gsub(tostring(s or ""), "^%s*(.-)%s*$", "%1"))
end

-- Parse into { [sectionLower] = { [roleName] = sensorName } }.
-- Returns sections, problems.
function Config.parse(text)
  local sections, problems = {}, {}
  if not text or text == "" then return sections, problems end

  local current = "*"
  sections[current] = sections[current] or {}
  local lineNo = 0

  for rawLine in string.gmatch(text, "[^\r\n]*") do
    lineNo = lineNo + 1
    local line = trim(rawLine)
    -- Both # and ; are accepted as comment markers; pilots coming from either
    -- INI or shell conventions should not have to guess.
    if line ~= "" and string.sub(line, 1, 1) ~= "#"
       and string.sub(line, 1, 1) ~= ";" then
      local section = string.match(line, "^%[(.+)%]$")
      if section then
        current = string.lower(trim(section))
        sections[current] = sections[current] or {}
      else
        local key, value = string.match(line, "^([^=]+)=(.*)$")
        key   = trim(key)
        value = trim(value)
        if key == "" or value == "" then
          problems[#problems + 1] =
            string.format("line %d: expected 'role = sensor'", lineNo)
        elseif not Roles.get(key) then
          problems[#problems + 1] =
            string.format("line %d: unknown role '%s'", lineNo, key)
        else
          sections[current][key] = value
        end
      end
    end
  end

  return sections, problems
end

Config.sections = {}
Config.problems = {}
Config.loaded   = false

function Config.load()
  Config.sections = {}
  Config.problems = {}
  Config.loaded   = true
  local text = Host.readFile(Config.path())
  if not text then
    -- A missing file is the normal case, not an error: everything
    -- auto-detects. Only a malformed file produces problems.
    return false
  end
  Config.sections, Config.problems = Config.parse(text)
  return true
end

-- Overrides for one model: the [*] defaults with the model's own section
-- layered on top.
function Config.overridesFor(modelName)
  if not Config.loaded then Config.load() end
  local out = {}
  local shared = Config.sections["*"]
  if shared then
    for role, sensor in pairs(shared) do out[role] = sensor end
  end
  local specific = Config.sections[string.lower(trim(modelName or ""))]
  if specific then
    for role, sensor in pairs(specific) do out[role] = sensor end
  end
  return out
end

return Config

end
