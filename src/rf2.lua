-- Layer 2.5: Rotorflight RF Tool integration (optional).
--
-- Rotorflight's RF Tool widget publishes a single global table, `rf2`, which
-- other widgets may use. It gives us two things telemetry alone cannot:
--
--   1. Authoritative connection state. Without this we can only infer "is the
--      link up" from link quality plus a guess about whether any sensor looks
--      alive. RF Tool actually knows.
--   2. The flight controller's own flight statistics - total flights and total
--      airtime, maintained by the FC itself. That beats a counter kept on the
--      radio's storage, which silently diverges the moment you fly the same
--      heli with a second radio.
--
-- This module is strictly additive. `rf2` only exists when RF Tool is
-- installed and loaded, so every access is guarded and every value it provides
-- is optional. The dashboard must be fully usable with RF Tool absent.
--
-- MSP is request/response over the telemetry link, not a free local read. It
-- is issued only on state transitions, never per frame - the same discipline
-- Rotorflight's own RfStats example widget follows.

return function(ZD)

local Host = ZD.Host

local RF2 = {}
ZD.RF2 = RF2

-- MSP_FLIGHT_STATS was introduced in MSP API 12.9. Asking an older flight
-- controller produces no reply, so gate on the version rather than waiting on
-- a request that will never come back.
local FLIGHT_STATS_MIN_API = 12.09

-- How often to retry registering while RF Tool has not loaded yet. Its widget
-- may initialise after ours, so absence at startup is not permanent.
local REGISTER_RETRY = Host.seconds(5)

RF2.registered   = false
RF2.linkState    = nil    -- "connected" | "disconnected" | "armed" | "disarmed"
RF2.connected    = nil    -- true/false, or nil when RF Tool is unavailable
RF2.apiVersion   = nil
RF2.craftName    = nil

RF2.totalFlights       = nil
RF2.totalFlightSeconds = nil
RF2.totalDistanceM     = nil

-- none | pending | ok | unsupported | error
RF2.statsStatus = "none"

local lastAttempt = -1e9

-- What rf2.apiVersion read the last time we looked. The poll below acts on a
-- *change* in that field rather than on its value, so that an explicit
-- disconnect event - which RF Tool does deliver, and which is authoritative -
-- cannot be immediately undone by a poll seeing a field RF Tool has not
-- bothered to clear.
local polledApi = nil

local function rf2Table()
  local t = rawget(_G, "rf2")
  if type(t) ~= "table" then return nil end
  return t
end

function RF2.available()
  return rf2Table() ~= nil
end

--------------------------------------------------------------------------
-- Flight statistics
--------------------------------------------------------------------------

local function statValue(stats, field)
  local entry = stats and stats[field]
  if type(entry) ~= "table" then return nil end
  return tonumber(entry.value)
end

local function onReceivedStats(_, stats)
  local flights = statValue(stats, "stats_total_flights")
  if flights == nil then
    -- A reply we cannot parse is a real failure, not a zero.
    RF2.statsStatus = "error"
    return
  end
  RF2.totalFlights       = flights
  RF2.totalFlightSeconds = statValue(stats, "stats_total_time_s")
  RF2.totalDistanceM     = statValue(stats, "stats_total_dist_m")
  RF2.statsStatus        = "ok"
end

local function requestFlightStats()
  local rf2 = rf2Table()
  if not rf2 then return end

  local api = tonumber(rf2.apiVersion)
  RF2.apiVersion = api
  if api == nil then
    -- Not yet handshaked with the flight controller; a later state event will
    -- bring us back here.
    return
  end
  if api < FLIGHT_STATS_MIN_API then
    RF2.statsStatus = "unsupported"
    return
  end

  local ok, api_module = pcall(rf2.useApi, "mspFlightStats")
  if not ok or type(api_module) ~= "table"
     or type(api_module.read) ~= "function" then
    RF2.statsStatus = "error"
    return
  end

  RF2.statsStatus = "pending"
  if not pcall(api_module.read, onReceivedStats, nil) then
    RF2.statsStatus = "error"
  end
end

RF2.requestFlightStats = requestFlightStats

--------------------------------------------------------------------------
-- State events
--------------------------------------------------------------------------

local function clearFcData()
  RF2.totalFlights       = nil
  RF2.totalFlightSeconds = nil
  RF2.totalDistanceM     = nil
  RF2.craftName          = nil
  RF2.apiVersion         = nil
  RF2.statsStatus        = "none"
end

local function handleStateChange(newState)
  RF2.linkState = newState

  if newState == "disconnected" then
    RF2.connected = false
    clearFcData()
    -- Adopt whatever the field says now, so the poll treats this as the
    -- current state rather than as a fresh connection to react to.
    local tbl = rf2Table()
    polledApi = tbl and tonumber(tbl.apiVersion) or nil
    return
  end

  RF2.connected = true
  local rf2 = rf2Table()
  if rf2 then
    RF2.craftName  = rf2.modelName
    RF2.apiVersion = tonumber(rf2.apiVersion)
  end

  -- Re-read on connect and after every landing. Stats only change when a
  -- flight ends, so disarm is exactly when the numbers become stale.
  if newState == "connected" or newState == "disarmed" then
    requestFlightStats()
  end
end

-- A stable proxy is registered rather than the widget instance itself. EdgeTX
-- may call create() again (resize, settings change), and RF Tool's registry is
-- append-only - registering a fresh table each time would leave stale
-- duplicates receiving events forever.
RF2.proxy = {
  onStateChanged = function(_, newState)
    handleStateChange(newState)
  end,
}

--------------------------------------------------------------------------
-- Service
--------------------------------------------------------------------------

-- Called from the normal service pass. Cheap once registered, and retries on a
-- slow timer while RF Tool has not appeared.
function RF2.service(now)
  now = now or Host.now()

  if not RF2.registered then
    if (now - lastAttempt) < REGISTER_RETRY then return end
    lastAttempt = now
    local tbl = rf2Table()
    if not tbl or type(tbl.registerWidget) ~= "function" then return end
    if not pcall(tbl.registerWidget, RF2.proxy) then return end
    RF2.registered = true
  end

  -- Then keep watching RF Tool's own fields, every pass, for as long as we
  -- run. Events alone are not enough and this is the bug that proved it:
  -- RF Tool publishes state only on *change*, and on a radio that boots before
  -- the heli is powered we register while nothing is connected, hear no event
  -- when the flight controller later appears, and sit on "waiting" forever
  -- while RF Tool's own screen says Connected.
  --
  -- Seeding once at registration - which is what this used to do - only covers
  -- the case where the FC was already up at that instant. Reading two table
  -- fields per pass is a local lookup, not MSP, so there is no reason to be
  -- clever about when to do it.
  local rf2 = rf2Table()
  if not rf2 then return end

  local api = tonumber(rf2.apiVersion)
  if api == polledApi then return end
  polledApi = api

  if api ~= nil then
    RF2.apiVersion = api
    RF2.connected  = true
    RF2.craftName  = rf2.modelName
    requestFlightStats()
  else
    -- RF Tool lost its handshake with the flight controller.
    RF2.connected = false
    clearFcData()
  end
end

--------------------------------------------------------------------------
-- Diagnostics
--------------------------------------------------------------------------
--
-- This whole module is invisible when it works and invisible when it does not.
-- The only outward sign was the sensor map footer quietly showing the flight
-- controller's craft name instead of the EdgeTX model name, which is not
-- enough to tell "RF Tool is not installed" from "installed but never
-- registered" from "registered but the FC never handshaked" - four different
-- problems with four different fixes.
--
-- Returns detail, verdict, status. Same shape as FlightLog.status().
function RF2.status()
  if not RF2.available() then
    -- Not a fault. The dashboard is fully usable without RF Tool, and most
    -- radios will never have it.
    return "not installed", "optional", "unbound"
  end
  if not RF2.registered then
    return "found, not registered", "waiting", "insane"
  end

  local detail = RF2.craftName or "registered"
  if RF2.apiVersion then
    detail = detail .. string.format("  api %.2f", RF2.apiVersion)
  end

  if RF2.connected == false then return detail, "no link", "unbound" end
  if RF2.connected == nil then return detail, "waiting", "unbound" end
  return detail, RF2.linkState or "connected", "ok"
end

-- The flight controller's own totals, which is the point of the integration:
-- a counter kept on the radio diverges the moment you fly the same heli with
-- a second radio.
function RF2.statsText()
  if not RF2.available() then return "--", "off", "unbound" end
  if RF2.statsStatus == "unsupported" then
    return "needs MSP API 12.09", "too old", "unbound"
  end
  if RF2.statsStatus == "ok" then
    local s = string.format("%d flights", RF2.totalFlights or 0)
    local secs = tonumber(RF2.totalFlightSeconds)
    if secs then
      s = s .. string.format(", %dh %02dm",
                             math.floor(secs / 3600),
                             math.floor((secs % 3600) / 60))
    end
    return s, "ok", "ok"
  end
  if RF2.statsStatus == "error" then return "no usable reply", "FAILED", "insane" end
  return "--", RF2.statsStatus, "unbound"
end

function RF2.reset()
  RF2.registered = false
  RF2.linkState  = nil
  RF2.connected  = nil
  lastAttempt    = -1e9
  polledApi      = nil
  clearFcData()
end

return RF2

end
