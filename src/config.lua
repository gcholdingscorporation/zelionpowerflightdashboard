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

-- One reserved section name that holds settings rather than sensor overrides.
-- A model called "battery" would be an odd thing to name a helicopter, and the
-- alternative - a second file - is worse.
Config.SETTINGS_SECTION = "battery"

-- Numbers, with the range each is allowed to take. Anything outside it is a
-- typo rather than an intention, and a wrong cell voltage here would quietly
-- misreport the state of charge in the air.
local SETTINGS = {
  cellFull = { default = 4.00, min = 3.00, max = 4.50 },
  cellMin  = { default = 3.30, min = 2.50, max = 4.00 },
  -- Alert thresholds. alertCell is the one a pilot actually tunes: it is the
  -- voltage you want to hear about, not the voltage the pack dies at.
  alertCell = { default = 3.40, min = 2.80, max = 4.10 },
  alertEsc  = { default = 110,  min = 40,   max = 200 },
  -- How much pack the time-remaining estimate counts as untouchable. The
  -- timer reaches zero when the pack reaches this, not when it is flat.
  reservePct = { default = 20, min = 0, max = 60 },
}

-- Parse into { [sectionLower] = { [roleName] = sensorName } }, plus
-- Config.settings for the reserved section.
-- Returns sections, problems, settings.
-- Which settings the file actually named, as opposed to the ones sitting at
-- their defaults. Both look identical in Config.settings, and the aircraft
-- profile needs to tell them apart: it may fill in a threshold nobody set, but
-- must never overrule one a pilot wrote down.
Config.explicit = {}

function Config.parse(text)
  local sections, problems = {}, {}
  local settings = {}
  local explicit = {}
  for k, spec in pairs(SETTINGS) do settings[k] = spec.default end
  if not text or text == "" then
    Config.explicit = explicit
    return sections, problems, settings
  end

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
        -- The reserved section holds settings, so it gets no bindings table.
        if current ~= Config.SETTINGS_SECTION then
          sections[current] = sections[current] or {}
        end
      else
        local key, value = string.match(line, "^([^=]+)=(.*)$")
        key   = trim(key)
        value = trim(value)
        if key == "" or value == "" then
          problems[#problems + 1] =
            string.format("line %d: expected 'role = sensor'", lineNo)
        elseif current == Config.SETTINGS_SECTION then
          local spec = SETTINGS[key]
          local n = tonumber(value)
          if not spec then
            problems[#problems + 1] =
              string.format("line %d: unknown [battery] setting '%s'", lineNo, key)
          elseif not n or n < spec.min or n > spec.max then
            problems[#problems + 1] =
              string.format("line %d: %s must be %.2f..%.2f", lineNo, key,
                            spec.min, spec.max)
          else
            settings[key] = n
            explicit[key] = true
          end
        elseif not Roles.get(key) then
          problems[#problems + 1] =
            string.format("line %d: unknown role '%s'", lineNo, key)
        else
          sections[current][key] = value
        end
      end
    end
  end

  if settings.cellMin >= settings.cellFull then
    problems[#problems + 1] = "cellMin must be below cellFull"
    settings.cellMin  = SETTINGS.cellMin.default
    settings.cellFull = SETTINGS.cellFull.default
    explicit.cellMin, explicit.cellFull = nil, nil
  end

  Config.explicit = explicit
  return sections, problems, settings
end

Config.sections = {}
Config.problems = {}
Config.settings = {}
Config.loaded   = false
-- Whether a sensors.cfg was actually found. Absence is the normal case and not
-- a problem, but it is the difference between "my overrides did nothing" and
-- "the file the pilot thinks they wrote is not where the widget looks".
Config.present  = false

-- The reserved section is not model-scoped: one pack chemistry per radio is
-- the common case, and per-model curves would need a second lookup for a
-- setting almost nobody changes.
function Config.setting(name)
  if not Config.loaded then Config.load() end
  local v = Config.settings[name]
  if v ~= nil then return v end
  return SETTINGS[name] and SETTINGS[name].default
end

function Config.load()
  Config.sections = {}
  Config.problems = {}
  Config.loaded   = true
  Config.present  = false
  local text = Host.readFile(Config.path())
  if not text then
    -- A missing file is the normal case, not an error: everything
    -- auto-detects. Only a malformed file produces problems.
    local _, _, defaults = Config.parse(nil)
    Config.settings = defaults
    return false
  end
  Config.sections, Config.problems, Config.settings = Config.parse(text)
  Config.present = true
  return true
end

-- Which sections are actually in force for this model, and how many overrides
-- they carry between them.
--
-- Sections for OTHER models are normal and correct - a radio flies more than
-- one helicopter - so their existence is never a complaint. What is worth
-- saying is which ones applied HERE, because a section header that matches no
-- model is completely silent otherwise: the overrides simply never happen, the
-- roles fall back to guessing, and the sensor map reads (guess) where the
-- pilot expected (cfg). That has already cost a real setup - a section named
-- for the aircraft rather than for the EdgeTX model it flies on.
--
-- The widget cannot know whether that header matches some OTHER model on the
-- radio, since EdgeTX exposes only the current one. So this reports what did
-- happen rather than guessing at what was meant.
-- `craftName` is what the FLIGHT CONTROLLER calls the aircraft, as opposed to
-- the name of the radio's model slot. A pilot who flies four helicopters from
-- one EdgeTX model - deliberately, to keep the setup on the aircraft rather
-- than on the transmitter - has exactly one model name and four craft names,
-- so a section keyed on the model name can say nothing about which is flying.
function Config.appliedFor(modelName, craftName)
  if not Config.loaded then Config.load() end
  -- Counted, not merely present. The parser opens an implicit [*] for any
  -- lines before the first header, so that table exists even in a file that
  -- never mentions it - and naming a section that contributed nothing is
  -- exactly the false reassurance this row exists to avoid.
  local names, count = {}, 0
  local function take(key, shown)
    local sect = Config.sections[key]
    if not sect then return end
    local n = 0
    for _ in pairs(sect) do n = n + 1 end
    if n == 0 then return end
    names[#names + 1] = shown
    count = count + n
  end
  take(string.lower(trim(modelName or "")), tostring(modelName))
  if craftName and trim(craftName) ~= trim(modelName or "") then
    take(string.lower(trim(craftName)), tostring(craftName))
  end
  take("*", "*")

  -- [battery] counts too. It is a reserved section rather than a role table, so
  -- it lives in Config.explicit and was invisible here - and a file whose only
  -- override was a threshold or a reserve read "no section for this model", in
  -- amber, while that override was in force. That is the precise false negative
  -- this row exists to prevent, pointed the wrong way: it told a pilot their
  -- settings were doing nothing at the moment they started working.
  local n = 0
  for _ in pairs(Config.explicit) do n = n + 1 end
  if n > 0 then
    names[#names + 1] = "battery"
    count = count + n
  end
  return names, count
end

-- Overrides for one aircraft: [*] first, the radio's model section over that,
-- and the flight controller's craft name over both.
--
-- Craft last because it is the most specific thing known. A section named for
-- the model slot covers every aircraft flown from it; one named for the craft
-- covers exactly one helicopter, and that is the one whose word should win.
function Config.overridesFor(modelName, craftName)
  if not Config.loaded then Config.load() end
  local out = {}
  local function layer(key)
    local sect = key and Config.sections[string.lower(trim(key))]
    if not sect then return end
    for role, sensor in pairs(sect) do out[role] = sensor end
  end
  layer("*")
  layer(modelName)
  layer(craftName)
  return out
end

return Config

end
