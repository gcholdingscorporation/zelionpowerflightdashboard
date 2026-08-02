-- Test entry point.  Run from the repo root:  lua5.4 tests/run.lua

package.path = "./?.lua;./tools/?.lua;./tests/?.lua;" .. package.path

local H      = require("harness")
local Mock   = require("mock_edgetx")
local Loader = require("loader")

local SUITES = {
  "test_config_host",
  "test_sensors",
  "test_state",
  "test_rf2",
  "test_build",
}

for _, name in ipairs(SUITES) do
  local suite = require(name)
  suite(H, Mock, Loader)
end

os.exit(H.report() and 0 or 1)
