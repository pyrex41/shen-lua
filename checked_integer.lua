-- Explicit exact-integer boundary for LuaJIT's double-valued Shen numbers.
-- Parse the ORIGINAL decimal text: converting it with tonumber first destroys
-- evidence of rounding (9007199254740993 and 9007199254740992 alias).
local M = {}
M.MAX = 9007199254740991.0  -- 2^53 - 1; float even on Lua 5.3+

local function check(x, where)
  if type(x) ~= "number" or x ~= x or x == math.huge or x == -math.huge
      or x % 1 ~= 0 or x < -M.MAX or x > M.MAX then
    error(where .. ": expected an integer in [-9007199254740991, 9007199254740991]", 2)
  end
  return x + 0.0  -- avoid PUC Lua's wrapping int64 arithmetic in callers
end
M.check = check

function M.parse(text)
  if type(text) ~= "string" or not text:match("^[+-]?%d+$") then
    error("checked integer: expected signed decimal text", 2)
  end
  local negative = text:sub(1, 1) == "-"
  local start = (text:sub(1, 1) == "-" or text:sub(1, 1) == "+") and 2 or 1
  local n = 0.0
  for i = start, #text do
    local digit = text:byte(i) - 48
    -- Test before multiplying; neither intermediate nor final value rounds.
    if n > math.floor((M.MAX - digit) / 10) then
      error("checked integer: outside exact range", 2)
    end
    n = n * 10 + digit
  end
  return negative and -n or n
end

function M.add(a, b)
  a = check(a, "checked add")
  b = check(b, "checked add")
  return check(a + b, "checked add")
end

function M.sub(a, b)
  a = check(a, "checked sub")
  b = check(b, "checked sub")
  return check(a - b, "checked sub")
end

function M.mul(a, b)
  a = check(a, "checked mul")
  b = check(b, "checked mul")
  return check(a * b, "checked mul")
end

return M
