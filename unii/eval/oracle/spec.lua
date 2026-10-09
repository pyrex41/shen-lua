local script = (arg and arg[0]) or "unii/eval/oracle/spec.lua"
local root = script:match("^(.*)unii/eval/oracle/") or "./"
package.path = root .. "?.lua;" .. package.path

local oracle = require("unii.eval.oracle.oracle")
local rollback = require("unii.eval.oracle.rollback")

local passed, failed = 0, 0

local function test(name, body)
  local ok, reason = pcall(body)
  if ok then
    passed = passed + 1
    io.write("ok - ", name, "\n")
  else
    failed = failed + 1
    io.write("not ok - ", name, ": ", tostring(reason), "\n")
  end
end

local function equal(actual, expected, context)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s",
      context or "value", tostring(expected), tostring(actual)), 2)
  end
end

local function rejects(body, fragment)
  local ok, reason = pcall(body)
  if ok then error("expected rejection", 2) end
  if fragment and not tostring(reason):find(fragment, 1, true) then
    error("wrong rejection: " .. tostring(reason), 2)
  end
end

local function view_string(view)
  local out = {}
  for i, value in ipairs(view) do out[i] = oracle.address(value) end
  return table.concat(out, ",")
end

test("node and zoom addresses are inverse", function()
  for level = 0, 20 do
    local index = 37
    local node = oracle.node(level, index)
    local zoom = oracle.zoom(node.first, node.count)
    equal(zoom.level, level)
    equal(zoom.index, index)
    equal(node.first, index * 2 ^ level)
    equal(node.after, (index + 1) * 2 ^ level)
  end
end)

test("version-1 integer edges near 2^31-1", function()
  local max = oracle.MAX_MESSAGES
  equal(oracle.node(0, max - 1).last, max - 1)
  equal(oracle.zoom(max - 1, 1).index, max - 1)
  equal(oracle.node(30, 0).count, 1073741824)
  rejects(function() oracle.node(0, max) end, "exceeds")
  rejects(function() oracle.zoom(max - 1, 2) end, "ceiling")
  rejects(function() oracle.node(30, 1) end, "ceiling")
  rejects(function() oracle.node(0, 0.5) end, "exact integer")
end)

test("zoom rejects unaligned and non-power-of-two ranges", function()
  rejects(function() oracle.zoom(2, 4) end, "divisible")
  rejects(function() oracle.zoom(0, 3) end, "power of two")
  rejects(function() oracle.zoom(-1, 1) end, "below")
end)

test("children and parent preserve intervals", function()
  local parent = oracle.zoom(40, 8)
  local left, right = oracle.children(parent)
  equal(oracle.address(left), "40+4")
  equal(oracle.address(right), "44+4")
  equal(oracle.address(oracle.parent(left)), "40+8")
  equal(oracle.address(oracle.parent(right)), "40+8")
  rejects(function() oracle.children(oracle.node(0, 0)) end, "no children")
end)

test("partition detects gap, overlap, and overrun", function()
  local valid = { oracle.zoom(0, 4), oracle.zoom(4, 2), oracle.zoom(6, 1) }
  local ok = oracle.check_partition(valid, 7)
  equal(ok, true)
  local gap, why_gap = oracle.check_partition(
    { oracle.zoom(0, 2), oracle.zoom(4, 2) }, 6)
  equal(gap, false)
  assert(why_gap:find("gap", 1, true))
  local overlap, why_overlap = oracle.check_partition(
    { oracle.zoom(0, 4), oracle.zoom(2, 2) }, 4)
  equal(overlap, false)
  assert(why_overlap:find("overlap", 1, true))
  local overrun = oracle.check_partition({ oracle.zoom(0, 4) }, 3)
  equal(overrun, false)
end)

test("due comparison uses exact cross-products and tie breaks", function()
  local early = {
    numerator = 4, level = 1, last = 3,
    parent = { level = 2, index = 0 },
  }
  local late = {
    numerator = 2, level = 0, last = 5,
    parent = { level = 1, index = 2 },
  }
  equal(oracle.compare_due(early, late), 1, "equal score chooses oldest")
  local huge = {
    numerator = oracle.MAX_MESSAGES, level = 0, last = 0,
    parent = { level = 1, index = 0 },
  }
  local tiny = {
    numerator = 1, level = 30, last = 1,
    parent = { level = 30, index = 0 },
  }
  equal(oracle.compare_due(huge, tiny), 1, "61-bit exact product")
end)

test("canonical rendering is UTF-8, escaped, and LF-only", function()
  local rendered, bytes = oracle.render_view(
    { oracle.node(0, 0) },
    function() return "a\r\nb\rc|d%\t\195\169" end)
  equal(rendered, "0+1|a b c%7Cd%25%09\195\169\n")
  equal(bytes, #rendered)
  rejects(function()
    oracle.render_line(oracle.node(0, 0), "\192\175")
  end, "valid UTF-8")
  rejects(function()
    oracle.render_line(oracle.node(0, 0), "\237\160\128")
  end, "valid UTF-8")
  rejects(function()
    oracle.render_line(oracle.node(0, 0), "\128")
  end, "valid UTF-8")
  rejects(function()
    oracle.render_line(oracle.node(0, 0), "\240\159\146")
  end, "valid UTF-8")
  rejects(function()
    oracle.render_line(oracle.node(0, 0), "\244\144\128\128")
  end, "valid UTF-8")
end)

test("rollback push matches due merges for all 20,001 steps", function()
  local states
  local view = {}
  local rollback_view = {}
  for message = 0, 20000 do
    local T = message + 1
    local before = oracle.copy_view(rollback_view)
    before[#before + 1] = { level = 0, index = message }
    states = rollback.push(message, states)
    local expected = rollback.to_view(states, T)
    view[#view + 1] = { level = 0, index = message }
    local merges
    view, merges = oracle.compact_to_count(view, T, #expected)
    equal(view_string(view), view_string(expected), "T=" .. T)

    local old_keys, rollback_merges = {}, {}
    for _, node in ipairs(before) do
      old_keys[node.level .. ":" .. node.index] = true
    end
    for _, node in ipairs(expected) do
      if not old_keys[node.level .. ":" .. node.index] then
        rollback_merges[#rollback_merges + 1] = node
      end
    end
    equal(view_string(merges), view_string(rollback_merges),
      "merge order T=" .. T)
    rollback_view = expected
  end
end)

local function random_trace(seed)
  local state = seed
  local function random(limit)
    state = (state * 48271) % 2147483647
    return state % limit
  end
  local view, trace = {}, {}
  for message = 0, 299 do
    local T = message + 1
    view[#view + 1] = { level = 0, index = message }
    local target = math.max(1, #view - random(7))
    local merges
    view, merges = oracle.compact_to_count(view, T, target)
    oracle.assert_partition(view, T)
    trace[#trace + 1] = T .. ":" .. view_string(merges)
      .. ":" .. view_string(view)
  end
  return table.concat(trace, ";")
end

test("random append/merge sequences preserve and monotonically extend coverage",
  function()
    for seed = 1, 30 do
      local first = random_trace(seed)
      local second = random_trace(seed)
      equal(first, second, "deterministic seed " .. seed)
    end
  end)

test("unavailable parents keep byte batch mode active", function()
  local available = false
  local state = oracle.new_hysteresis {
    low_bytes = 5,
    high_bytes = 10,
    text_for = function() return "abcdefghijklmnopqrst" end,
    parent_available = function() return available end,
  }
  local first = oracle.hysteresis_append(state)
  equal(first.entered_batch, true)
  equal(first.batch, true)
  equal(#first.merges, 0)
  local second = oracle.hysteresis_append(state)
  equal(second.batch, true)
  equal(#second.merges, 0)
  oracle.assert_partition(state.view, 2)
  available = true
  local resumed = oracle.hysteresis_resume(state)
  equal(#resumed.merges, 1)
  equal(resumed.batch, true, "parent text is still above tiny low target")
  oracle.assert_partition(state.view, 2)
end)

test("hysteresis threshold equality is exact", function()
  local exact_high = oracle.new_hysteresis {
    low_bytes = 5,
    high_bytes = 15,
    text_for = function() return string.rep("x", 10) end,
  }
  local first = oracle.hysteresis_append(exact_high)
  equal(first.bytes, 15)
  equal(first.entered_batch, false)

  local exact_low = oracle.new_hysteresis {
    low_bytes = 15,
    high_bytes = 29,
    text_for = function() return string.rep("x", 10) end,
  }
  oracle.hysteresis_append(exact_low)
  local second = oracle.hysteresis_append(exact_low)
  equal(second.bytes_before, 30)
  equal(second.bytes, 15)
  equal(second.entered_batch, true)
  equal(second.batch, false)
end)

test("byte hysteresis triggers strictly above high and reaches low", function()
  local function text(value)
    local node = oracle.node(value.level, value.index)
    return string.rep("x", 90 + node.level)
  end
  local state = oracle.new_hysteresis {
    low_bytes = 500,
    high_bytes = 1000,
    text_for = text,
  }
  local entries = 0
  for _ = 1, 80 do
    local result = oracle.hysteresis_append(state)
    if result.entered_batch then
      entries = entries + 1
      assert(result.bytes_before > state.high_bytes)
      assert(result.bytes <= state.low_bytes)
    elseif not result.batch then
      assert(result.bytes_before <= state.high_bytes
        or result.bytes <= state.low_bytes)
    end
  end
  assert(entries >= 2)
end)

test("checked-in fixtures have complete terminal records", function()
  local function inspect(name, prefix, final_T)
    local file = assert(io.open(root .. "unii/eval/fixtures/" .. name, "rb"))
    local count, last = 0
    for line in file:lines() do
      if line:sub(1, 2) == prefix .. "|" then
        count = count + 1
        last = tonumber(line:match("^" .. prefix .. "|(%d+)|"))
      end
    end
    file:close()
    equal(count, final_T)
    equal(last, final_T)
  end
  inspect("rollback-20001.trace", "R", 20001)
  inspect("byte-hysteresis.trace", "B", 700)
end)

io.write(string.format("unii oracle: %d passed / %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
