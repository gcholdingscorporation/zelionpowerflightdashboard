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
--      radio's SD card, which silently diverges the moment you fly the same
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
  if RF2.registered then return end
  now = now or Host.now()
  if (now - lastAttempt) < REGISTER_RETRY then return end
  lastAttempt = now

  local rf2 = rf2Table()
  if not rf2 or type(rf2.registerWidget) ~= "function" then return end

  if not pcall(rf2.registerWidget, RF2.proxy) then return end
  RF2.registered = true

  -- RF Tool only publishes state on *change*. If the flight controller was
  -- already connected before we registered, no event is coming - so seed from
  -- the current state instead of waiting for one that never arrives.
  if tonumber(rf2.apiVersion) ~= nil then
    RF2.connected = true
    RF2.craftName = rf2.modelName
    requestFlightStats()
  end
end

function RF2.reset()
  RF2.registered = false
  RF2.linkState  = nil
  RF2.connected  = nil
  lastAttempt    = -1e9
  clearFcData()
end

return RF2

end
