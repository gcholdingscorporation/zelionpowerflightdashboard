-- Tiny test harness. No dependencies, so `lua5.4 tests/run.lua` just works.

local H = { passed = 0, failed = 0, failures = {}, current = "?" }

function H.group(name)
  H.currentGroup = name
  print("\n== " .. name)
end

function H.test(name, fn)
  H.current = name
  local ok, err = pcall(fn)
  if ok then
    H.passed = H.passed + 1
    print("  ok   " .. name)
  else
    H.failed = H.failed + 1
    H.failures[#H.failures + 1] = { name = name, err = tostring(err) }
    print("  FAIL " .. name .. "\n       " .. tostring(err))
  end
end

local function fmt(v)
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

function H.eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%sexpected %s, got %s",
      msg and (msg .. ": ") or "", fmt(expected), fmt(actual)), 2)
  end
end

function H.near(actual, expected, tol, msg)
  tol = tol or 1e-6
  if type(actual) ~= "number" or math.abs(actual - expected) > tol then
    error(string.format("%sexpected ~%s, got %s",
      msg and (msg .. ": ") or "", fmt(expected), fmt(actual)), 2)
  end
end

function H.truthy(v, msg)
  if not v then error((msg or "expected truthy") .. ", got " .. fmt(v), 2) end
end

function H.falsy(v, msg)
  if v then error((msg or "expected falsy") .. ", got " .. fmt(v), 2) end
end

function H.nilv(v, msg)
  if v ~= nil then error((msg or "expected nil") .. ", got " .. fmt(v), 2) end
end

function H.report()
  print(string.format("\n%d passed, %d failed", H.passed, H.failed))
  return H.failed == 0
end

return H
