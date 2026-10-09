-- Independent LuaJIT-compatible reference for the Unii memory-view rules.
-- This module deliberately has no dependency on Shen or the application core.

local M = {}

M.MAX_MESSAGES = 2147483647
M.DEFAULT_LOW_BYTES = 64000
M.DEFAULT_HIGH_BYTES = 128000

local POW2 = {}
for level = 0, 30 do
  POW2[level] = 2 ^ level
end

local function integer(name, value, minimum, maximum)
  if type(value) ~= "number" or value ~= value or value == math.huge
      or value == -math.huge or value ~= math.floor(value) then
    error(name .. " must be an exact integer", 3)
  end
  if minimum and value < minimum then
    error(name .. " is below " .. minimum, 3)
  end
  if maximum and value > maximum then
    error(name .. " exceeds " .. maximum, 3)
  end
  return value
end

local function power_of_two(value)
  for level = 0, 30 do
    if POW2[level] == value then return level end
  end
  return nil
end

function M.pow2(level)
  integer("level", level, 0, 30)
  return POW2[level]
end

function M.node(level, index)
  integer("level", level, 0, 30)
  integer("index", index, 0, M.MAX_MESSAGES - 1)
  local count = POW2[level]
  local first = index * count
  local after = first + count
  if first ~= math.floor(first) or after > M.MAX_MESSAGES then
    error("node interval exceeds the version-1 message ceiling", 2)
  end
  return {
    level = level,
    index = index,
    first = first,
    count = count,
    after = after,
    last = after - 1,
  }
end

function M.zoom(first, count)
  integer("first", first, 0, M.MAX_MESSAGES - 1)
  integer("count", count, 1, M.MAX_MESSAGES)
  local level = power_of_two(count)
  if not level then error("zoom count must be a power of two", 2) end
  if first % count ~= 0 then
    error("zoom first must be divisible by count", 2)
  end
  if first + count > M.MAX_MESSAGES then
    error("zoom interval exceeds the version-1 message ceiling", 2)
  end
  return M.node(level, first / count)
end

function M.children(value)
  local node = M.node(value.level, value.index)
  if node.level == 0 then error("a leaf has no children", 2) end
  return M.node(node.level - 1, node.index * 2),
         M.node(node.level - 1, node.index * 2 + 1)
end

function M.parent(value)
  local node = M.node(value.level, value.index)
  return M.node(node.level + 1, math.floor(node.index / 2))
end

function M.address(value)
  local node = M.node(value.level, value.index)
  return tostring(node.first) .. "+" .. tostring(node.count)
end

function M.copy_view(view)
  local out = {}
  for i, value in ipairs(view) do
    local node = M.node(value.level, value.index)
    out[i] = { level = node.level, index = node.index }
  end
  return out
end

function M.check_partition(view, message_count)
  integer("message_count", message_count, 0, M.MAX_MESSAGES)
  local cursor = 0
  for position, value in ipairs(view) do
    local ok, node = pcall(M.node, value.level, value.index)
    if not ok then
      return false, "invalid node at position " .. position .. ": " .. tostring(node)
    end
    if node.first ~= cursor then
      local relation = node.first < cursor and "overlap" or "gap"
      return false, relation .. " before position " .. position
    end
    if node.after > message_count then
      return false, "node exceeds message count at position " .. position
    end
    cursor = node.after
  end
  if cursor ~= message_count then
    return false, "partition ends at " .. cursor .. ", expected " .. message_count
  end
  return true
end

function M.assert_partition(view, message_count)
  local ok, reason = M.check_partition(view, message_count)
  if not ok then error(reason, 2) end
  return true
end

local function siblings(left, right)
  return left.level == right.level
     and left.index % 2 == 0
     and right.index == left.index + 1
end

local function parent_is_available(parent_available, parent)
  if parent_available == nil then return true end
  if type(parent_available) == "function" then
    return not not parent_available(parent)
  end
  return not not parent_available[parent.level .. ":" .. parent.index]
end

-- The cross-products are n*2^level. n has at most 31 significant bits and
-- level is at most 30, so IEEE-754 binary64 represents each product exactly:
-- scaling an exact <=31-bit integer by a power of two does not add bits.
local function exact_scaled_integer(n, level)
  integer("score numerator", n, 0, M.MAX_MESSAGES)
  integer("score level", level, 0, 30)
  local product = n * POW2[level]
  if product / POW2[level] ~= n or product ~= math.floor(product) then
    error("score cross-product was not represented exactly", 3)
  end
  return product
end

function M.compare_due(a, b)
  local left_cross = exact_scaled_integer(a.numerator, b.level)
  local right_cross = exact_scaled_integer(b.numerator, a.level)
  if left_cross > right_cross then return 1 end
  if left_cross < right_cross then return -1 end

  -- Equal scores: the pair with the earlier final message is oldest.
  if a.last < b.last then return 1 end
  if a.last > b.last then return -1 end

  -- Final stable node-key order is lexicographic (level, index).
  if a.parent.level < b.parent.level then return 1 end
  if a.parent.level > b.parent.level then return -1 end
  if a.parent.index < b.parent.index then return 1 end
  if a.parent.index > b.parent.index then return -1 end
  return 0
end

function M.merge_candidates(view, message_count, parent_available)
  M.assert_partition(view, message_count)
  local candidates = {}
  for position = 1, #view - 1 do
    local left = M.node(view[position].level, view[position].index)
    local right = M.node(view[position + 1].level, view[position + 1].index)
    if siblings(left, right) then
      local parent = M.node(left.level + 1, left.index / 2)
      if parent_is_available(parent_available, parent) then
        candidates[#candidates + 1] = {
          position = position,
          level = left.level,
          numerator = message_count - right.last,
          first = left.first,
          last = right.last,
          left = left,
          right = right,
          parent = parent,
        }
      end
    end
  end
  return candidates
end

function M.select_merge(view, message_count, parent_available)
  local best
  for _, candidate in ipairs(M.merge_candidates(
      view, message_count, parent_available)) do
    if not best or M.compare_due(candidate, best) > 0 then
      best = candidate
    end
  end
  return best
end

function M.apply_merge(view, candidate)
  if not candidate then error("merge candidate is required", 2) end
  local out = {}
  for position = 1, #view do
    if position == candidate.position then
      out[#out + 1] = {
        level = candidate.parent.level,
        index = candidate.parent.index,
      }
    elseif position ~= candidate.position + 1 then
      out[#out + 1] = {
        level = view[position].level,
        index = view[position].index,
      }
    end
  end
  return out
end

function M.compact_to_count(view, message_count, target, parent_available)
  integer("target", target, 0, M.MAX_MESSAGES)
  local current = M.copy_view(view)
  local merged = {}
  while #current > target do
    local candidate = M.select_merge(current, message_count, parent_available)
    if not candidate then break end
    merged[#merged + 1] = candidate.parent
    current = M.apply_merge(current, candidate)
  end
  M.assert_partition(current, message_count)
  return current, merged
end

local function valid_utf8(text)
  local i, length = 1, #text
  while i <= length do
    local a = text:byte(i)
    if a <= 0x7f then
      i = i + 1
    else
      local needed, minimum, code
      if a >= 0xc2 and a <= 0xdf then
        needed, minimum, code = 1, 0x80, a - 0xc0
      elseif a >= 0xe0 and a <= 0xef then
        needed, minimum, code = 2, 0x800, a - 0xe0
      elseif a >= 0xf0 and a <= 0xf4 then
        needed, minimum, code = 3, 0x10000, a - 0xf0
      else
        return false
      end
      if i + needed > length then return false end
      for offset = 1, needed do
        local byte = text:byte(i + offset)
        if byte < 0x80 or byte > 0xbf then return false end
        code = code * 64 + byte - 0x80
      end
      if code < minimum or code > 0x10ffff
          or (code >= 0xd800 and code <= 0xdfff) then
        return false
      end
      i = i + needed + 1
    end
  end
  return true
end

function M.canonical_text(text)
  if type(text) ~= "string" then error("summary text must be a string", 2) end
  if not valid_utf8(text) then error("summary text is not valid UTF-8", 2) end

  -- Each line break becomes one ASCII space: CRLF as a pair, then NEL
  -- (U+0085), LS (U+2028) and PS (U+2029); then every remaining C0 control
  -- (lone CR and LF included) and DEL. Nothing is escaped: "|" and "%" stay
  -- verbatim because the address ends at the first "|" and the line at LF.
  text = text:gsub("\r\n", " ")
  text = text:gsub("\194\133", " "):gsub("\226\128\168", " "):gsub("\226\128\169", " ")
  text = text:gsub("[%z\1-\31\127]", " ")
  return text
end

function M.render_line(value, text)
  local node = M.node(value.level, value.index)
  return tostring(node.first) .. "+" .. tostring(node.count) .. "|"
      .. M.canonical_text(text) .. "\n"
end

function M.render_view(view, text_for)
  local lines = {}
  for position, value in ipairs(view) do
    local text
    if text_for then
      text = text_for(value)
    else
      text = value.text
    end
    if text == nil then
      error("missing summary text at view position " .. position, 2)
    end
    lines[#lines + 1] = M.render_line(value, text)
  end
  local rendered = table.concat(lines)
  return rendered, #rendered
end

function M.new_hysteresis(options)
  options = options or {}
  local low = integer("low_bytes",
    options.low_bytes or M.DEFAULT_LOW_BYTES, 0, M.MAX_MESSAGES)
  local high = integer("high_bytes",
    options.high_bytes or M.DEFAULT_HIGH_BYTES, 1, M.MAX_MESSAGES)
  if low >= high then error("low_bytes must be below high_bytes", 2) end
  if type(options.text_for) ~= "function" then
    error("text_for callback is required", 2)
  end
  return {
    low_bytes = low,
    high_bytes = high,
    text_for = options.text_for,
    parent_available = options.parent_available,
    batch = false,
    view = {},
    message_count = 0,
  }
end

local function continue_hysteresis(state, allow_entry)
  local _, bytes_before = M.render_view(state.view, state.text_for)
  local entered_batch = false
  if allow_entry and not state.batch and bytes_before > state.high_bytes then
    state.batch = true
    entered_batch = true
  end

  local merged = {}
  if state.batch then
    while true do
      local _, bytes = M.render_view(state.view, state.text_for)
      if bytes <= state.low_bytes then
        state.batch = false
        break
      end
      local candidate = M.select_merge(
        state.view, state.message_count, state.parent_available)
      if not candidate then break end
      merged[#merged + 1] = candidate.parent
      state.view = M.apply_merge(state.view, candidate)
    end
  end

  M.assert_partition(state.view, state.message_count)
  local rendered, bytes = M.render_view(state.view, state.text_for)
  return {
    entered_batch = entered_batch,
    batch = state.batch,
    bytes_before = bytes_before,
    bytes = bytes,
    merges = merged,
    rendered = rendered,
  }
end

function M.hysteresis_append(state)
  local next_count = state.message_count + 1
  if next_count > M.MAX_MESSAGES then
    error("message count exceeds the version-1 ceiling", 2)
  end
  state.view[#state.view + 1] = { level = 0, index = next_count - 1 }
  state.message_count = next_count
  M.assert_partition(state.view, state.message_count)
  return continue_hysteresis(state, true)
end

-- Parent publication is a policy event too: an oversize batch that was
-- blocked must continue immediately rather than waiting for another message.
function M.hysteresis_resume(state)
  M.assert_partition(state.view, state.message_count)
  return continue_hysteresis(state, false)
end

return M
