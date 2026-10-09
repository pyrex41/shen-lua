local script = (arg and arg[0]) or "unii/eval/oracle/generate_fixtures.lua"
local root = script:match("^(.*)unii/eval/oracle/") or "./"
package.path = root .. "?.lua;" .. package.path

local oracle = require("unii.eval.oracle.oracle")
local rollback = require("unii.eval.oracle.rollback")

local FIXTURE_DIR = root .. "unii/eval/fixtures/"

local function addresses(values)
  local out = {}
  for i, value in ipairs(values) do out[i] = oracle.address(value) end
  return #out == 0 and "-" or table.concat(out, ",")
end

local function same_view(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i].level ~= b[i].level or a[i].index ~= b[i].index then
      return false
    end
  end
  return true
end

local function rollback_trace()
  local lines = {
    "# unii-oracle-fixture v1",
    "# policy=rollback-line-count steps=20001 T=1..20001",
    "# budget(T)=number of checkpoints retained by rollback push after T pushes",
    "# source-revision=3c190e06f34aba0c69f49042c526093269604935",
    "# source-sha256=12f300f760af82bc07bc5201051d1267824ded09c9def8186e4f8144368038d8",
    "# R|T|line-budget|merged-parent-addresses-or--|oldest-first-view",
  }
  local states
  local due_view = {}
  local rollback_view = {}
  for message = 0, 20000 do
    local T = message + 1
    local before = oracle.copy_view(rollback_view)
    before[#before + 1] = { level = 0, index = message }
    states = rollback.push(message, states)
    local expected = rollback.to_view(states, T)

    local old_keys, expected_merges = {}, {}
    for _, node in ipairs(before) do
      old_keys[node.level .. ":" .. node.index] = true
    end
    for _, node in ipairs(expected) do
      if not old_keys[node.level .. ":" .. node.index] then
        expected_merges[#expected_merges + 1] = node
      end
    end
    if #expected_merges > 1 then
      error("rollback push introduced multiple parents at T=" .. T)
    end

    due_view[#due_view + 1] = { level = 0, index = message }
    local merges
    due_view, merges = oracle.compact_to_count(due_view, T, #expected)
    if not same_view(due_view, expected) then
      error("due-score view diverged from rollback push at T=" .. T)
    end
    if not same_view(merges, expected_merges) then
      error("due-score merge order diverged from rollback push at T=" .. T)
    end
    lines[#lines + 1] = table.concat({
      "R", T, #expected, addresses(expected_merges), addresses(expected),
    }, "|")
    rollback_view = expected
  end
  return table.concat(lines, "\n") .. "\n"
end

-- Every tree node gets deterministic source-independent text of 420..499
-- bytes before canonical escaping. It intentionally includes a pipe, percent,
-- CRLF, precomposed UTF-8, and a combining mark.
local function synthetic_text(value)
  local node = oracle.node(value.level, value.index)
  local target = 420 + ((node.first * 17 + node.level * 31) % 80)
  local prefix = string.format(
    "kind: synthetic %d+%d | 100%% caf\195\169 e\204\129\r\n",
    node.first, node.count)
  local fill = string.char(97 + ((node.index + node.level) % 26))
  return prefix .. string.rep(fill, target - #prefix)
end

local function byte_trace()
  local lines = {
    "# unii-oracle-fixture v1",
    "# policy=byte-hysteresis steps=700 low=64000 high=128000",
    "# text(node)=420+((first*17+level*31)%80) input bytes; see generator",
    "# trigger is strict rendered_bytes>128000; batch exits at <=64000",
    "# B|T|batch-active|entered-batch|bytes-before|bytes-after|merged-parents-or--|oldest-first-view",
  }
  local state = oracle.new_hysteresis {
    low_bytes = 64000,
    high_bytes = 128000,
    text_for = synthetic_text,
  }
  for _ = 1, 700 do
    local result = oracle.hysteresis_append(state)
    lines[#lines + 1] = table.concat({
      "B",
      state.message_count,
      result.batch and 1 or 0,
      result.entered_batch and 1 or 0,
      result.bytes_before,
      result.bytes,
      addresses(result.merges),
      addresses(state.view),
    }, "|")
  end
  return table.concat(lines, "\n") .. "\n"
end

local fixtures = {
  ["rollback-20001.trace"] = rollback_trace(),
  ["byte-hysteresis.trace"] = byte_trace(),
}

local check = arg and arg[1] == "--check"
local failed = false
for name, content in pairs(fixtures) do
  local path = FIXTURE_DIR .. name
  if check then
    local file = io.open(path, "rb")
    local actual = file and file:read("*a") or nil
    if file then file:close() end
    if actual ~= content then
      io.stderr:write(path, ": fixture differs; regenerate it\n")
      failed = true
    end
  else
    local file, reason = io.open(path, "wb")
    if not file then error("cannot write " .. path .. ": " .. tostring(reason)) end
    assert(file:write(content))
    assert(file:close())
    io.write(path, "\n")
  end
end
if failed then os.exit(1) end
