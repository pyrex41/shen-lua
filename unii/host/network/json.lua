-- Minimal JSON codec for request bodies and OpenAI SSE payloads.
--
-- A table is encoded as an array when it has a json.array metatable, or when
-- it is non-empty and every key is a contiguous 1..n integer. An empty table
-- encodes as an object {}. Use json.array({}) for an empty array.
-- json.null is the null sentinel (Lua nil cannot live in a table).

local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end })

local ARRAY = {}
local OBJECT = {}

function M.array(list)
  return setmetatable(list or {}, ARRAY)
end

function M.object(map)
  return setmetatable(map or {}, OBJECT)
end

local function is_array(t)
  local mt = getmetatable(t)
  if mt == ARRAY then return true end
  if mt == OBJECT then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
      return false
    end
    n = n + 1
  end
  if n == 0 then return false end
  return n == #t
end

local escape_map = {
  ["\\"] = "\\\\",
  ['"'] = '\\"',
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function escape_char(c)
  local known = escape_map[c]
  if known then return known end
  return string.format("\\u%04x", c:byte())
end

local function encode_string(s)
  return '"' .. s:gsub('[%z\1-\31\\"]', escape_char) .. '"'
end

local function encode(value, depth)
  if depth > 32 then error("json nesting limit") end
  local tv = type(value)
  if value == M.null then return "null" end
  if tv == "nil" then return "null" end
  if tv == "boolean" then return value and "true" or "false" end
  if tv == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      error("json cannot encode non-finite number")
    end
    if value % 1 == 0 and value >= -2^53 and value <= 2^53 then
      return string.format("%d", value)
    end
    return string.format("%.16g", value)
  end
  if tv == "string" then return encode_string(value) end
  if tv ~= "table" then
    error("json cannot encode " .. tv)
  end
  if is_array(value) then
    local parts = {}
    for i = 1, #value do
      parts[i] = encode(value[i], depth + 1)
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local parts = {}
  local keys = {}
  for k in pairs(value) do
    if type(k) ~= "string" then
      error("json object key must be a string")
    end
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for i = 1, #keys do
    local k = keys[i]
    parts[i] = encode_string(k) .. ":" .. encode(value[k], depth + 1)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.encode(value)
  return encode(value, 0)
end

local function utf8_encode(cp)
  if cp < 0 then error("bad code point") end
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40))
  elseif cp <= 0x10FFFF then
    return string.char(
      0xF0 + math.floor(cp / 0x40000),
      0x80 + (math.floor(cp / 0x1000) % 0x40),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40))
  end
  error("bad code point")
end

local function parser(s)
  local i = 1
  local n = #s

  local function peek()
    return s:sub(i, i)
  end

  local function skip()
    while true do
      local c = peek()
      if c ~= " " and c ~= "\t" and c ~= "\r" and c ~= "\n" then break end
      i = i + 1
    end
  end

  local parse_value

  local function parse_string()
    i = i + 1 -- opening quote
    local out = {}
    while i <= n do
      local c = s:sub(i, i)
      if c == '"' then
        i = i + 1
        return table.concat(out)
      elseif c == "\\" then
        local e = s:sub(i + 1, i + 1)
        if e == '"' or e == "\\" or e == "/" then
          out[#out + 1] = e
          i = i + 2
        elseif e == "b" then out[#out + 1] = "\b"; i = i + 2
        elseif e == "f" then out[#out + 1] = "\f"; i = i + 2
        elseif e == "n" then out[#out + 1] = "\n"; i = i + 2
        elseif e == "r" then out[#out + 1] = "\r"; i = i + 2
        elseif e == "t" then out[#out + 1] = "\t"; i = i + 2
        elseif e == "u" then
          local hex = s:sub(i + 2, i + 5)
          if not hex:match("^%x%x%x%x$") then error("bad unicode escape") end
          local cp = tonumber(hex, 16)
          i = i + 6
          if cp >= 0xD800 and cp <= 0xDBFF then
            local lowhex = s:sub(i, i + 5)
            if lowhex:sub(1, 2) ~= "\\u" then error("lone surrogate") end
            local low = tonumber(lowhex:sub(3), 16)
            if not low or low < 0xDC00 or low > 0xDFFF then error("bad surrogate") end
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
            i = i + 6
          elseif cp >= 0xDC00 and cp <= 0xDFFF then
            error("lone surrogate")
          end
          out[#out + 1] = utf8_encode(cp)
        else
          error("bad string escape")
        end
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
    error("unterminated string")
  end

  local function parse_number()
    local start = i
    if peek() == "-" then i = i + 1 end
    if peek() == "0" then
      i = i + 1
    elseif peek():match("%d") then
      while peek():match("%d") do i = i + 1 end
    else
      error("bad number")
    end
    if peek() == "." then
      i = i + 1
      if not peek():match("%d") then error("bad number") end
      while peek():match("%d") do i = i + 1 end
    end
    if peek() == "e" or peek() == "E" then
      i = i + 1
      if peek() == "+" or peek() == "-" then i = i + 1 end
      if not peek():match("%d") then error("bad number") end
      while peek():match("%d") do i = i + 1 end
    end
    return tonumber(s:sub(start, i - 1))
  end

  local function parse_array()
    i = i + 1
    skip()
    local arr = M.array({})
    if peek() == "]" then
      i = i + 1
      return arr
    end
    while true do
      arr[#arr + 1] = parse_value()
      skip()
      local c = peek()
      if c == "]" then
        i = i + 1
        return arr
      elseif c == "," then
        i = i + 1
        skip()
      else
        error("bad array")
      end
    end
  end

  local function parse_object()
    i = i + 1
    skip()
    local obj = {}
    if peek() == "}" then
      i = i + 1
      return obj
    end
    while true do
      skip()
      if peek() ~= '"' then error("bad object key") end
      local key = parse_string()
      skip()
      if peek() ~= ":" then error("expected colon") end
      i = i + 1
      obj[key] = parse_value()
      skip()
      local c = peek()
      if c == "}" then
        i = i + 1
        return obj
      elseif c == "," then
        i = i + 1
      else
        error("bad object")
      end
    end
  end

  function parse_value()
    skip()
    local c = peek()
    if c == '"' then return parse_string() end
    if c == "{" then return parse_object() end
    if c == "[" then return parse_array() end
    if c == "-" or c:match("%d") then return parse_number() end
    if s:sub(i, i + 3) == "true" then i = i + 4; return true end
    if s:sub(i, i + 4) == "false" then i = i + 5; return false end
    if s:sub(i, i + 3) == "null" then i = i + 4; return M.null end
    error("bad json at " .. tostring(i))
  end

  return function()
    local value = parse_value()
    skip()
    if i <= n then error("trailing json") end
    return value
  end
end

function M.decode(s)
  if type(s) ~= "string" then
    return nil, "json input must be a string"
  end
  local ok, value = pcall(parser(s))
  if not ok then return nil, value end
  return value
end

return M
