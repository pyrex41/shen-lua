-- examples/openresty/json_shim.lua — a minimal JSON codec.
--
-- Used ONLY when the real lua-cjson is unavailable (i.e. running the example
-- off-nginx under plain luajit, e.g. selftest.lua). OpenResty bundles cjson,
-- so under the actual server this file is never loaded. It implements just
-- the surface app.lua uses: decode, encode, and an empty_array sentinel.

local json = {}

-- A unique sentinel so an empty Lua table can be encoded as [] not {}.
json.empty_array = setmetatable({}, { __tostring = function() return "[]" end })

-- ---- encode ----------------------------------------------------------------
local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
                  ['\r'] = '\\r', ['\t'] = '\\t' }
local function enc_str(s)
  return '"' .. s:gsub('[%z\1-\31"\\]', function(c)
    return escapes[c] or ('\\u%04x'):format(c:byte())
  end) .. '"'
end

local encode
local function enc_table(v, out)
  if v == json.empty_array then out[#out + 1] = "[]"; return end
  local n = #v
  local is_array = n > 0
  if is_array then
    out[#out + 1] = "["
    for i = 1, n do
      if i > 1 then out[#out + 1] = "," end
      encode(v[i], out)
    end
    out[#out + 1] = "]"
  else
    -- object (or empty table -> {})
    out[#out + 1] = "{"
    local first = true
    for k, val in pairs(v) do
      if not first then out[#out + 1] = "," end
      first = false
      out[#out + 1] = enc_str(tostring(k)); out[#out + 1] = ":"
      encode(val, out)
    end
    out[#out + 1] = "}"
  end
end

encode = function(v, out)
  local t = type(v)
  if t == "string" then out[#out + 1] = enc_str(v)
  elseif t == "number" then out[#out + 1] = tostring(v)
  elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif t == "nil" then out[#out + 1] = "null"
  elseif t == "table" then enc_table(v, out)
  else error("json: cannot encode " .. t) end
end

function json.encode(v)
  local out = {}
  encode(v, out)
  return table.concat(out)
end

-- ---- decode (small recursive-descent parser) -------------------------------
local function decode_error(s, i, msg)
  error(("json: %s at byte %d"):format(msg, i), 0)
end

local parse_value
local function skip_ws(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return (j or i - 1) + 1
end

local function parse_string(s, i)
  i = i + 1                                   -- skip opening quote
  local buf = {}
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then return table.concat(buf), i + 1
    elseif c == '\\' then
      local e = s:sub(i + 1, i + 1)
      local map = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', n = '\n',
                    t = '\t', r = '\r', b = '\b', f = '\f' }
      if map[e] then buf[#buf + 1] = map[e]; i = i + 2
      elseif e == 'u' then
        local hex = s:sub(i + 2, i + 5)
        buf[#buf + 1] = string.char(tonumber(hex, 16) % 256); i = i + 6
      else decode_error(s, i, "bad escape") end
    else buf[#buf + 1] = c; i = i + 1 end
  end
  decode_error(s, i, "unterminated string")
end

local function parse_number(s, i)
  local j = s:find("[^%d%+%-eE%.]", i) or (#s + 1)
  local num = tonumber(s:sub(i, j - 1))
  if not num then decode_error(s, i, "bad number") end
  return num, j
end

parse_value = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == '"' then return parse_string(s, i)
  elseif c == '{' then
    local obj = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == '}' then return obj, i + 1 end
    while true do
      local key; key, i = parse_string(s, skip_ws(s, i))
      i = skip_ws(s, i)
      if s:sub(i, i) ~= ':' then decode_error(s, i, "expected ':'") end
      local val; val, i = parse_value(s, i + 1)
      obj[key] = val
      i = skip_ws(s, i)
      local d = s:sub(i, i)
      if d == '}' then return obj, i + 1
      elseif d == ',' then i = skip_ws(s, i + 1)
      else decode_error(s, i, "expected ',' or '}'") end
    end
  elseif c == '[' then
    local arr = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == ']' then return arr, i + 1 end
    while true do
      local val; val, i = parse_value(s, i)
      arr[#arr + 1] = val
      i = skip_ws(s, i)
      local d = s:sub(i, i)
      if d == ']' then return arr, i + 1
      elseif d == ',' then i = i + 1
      else decode_error(s, i, "expected ',' or ']'") end
    end
  elseif s:sub(i, i + 3) == "true"  then return true, i + 4
  elseif s:sub(i, i + 4) == "false" then return false, i + 5
  elseif s:sub(i, i + 3) == "null"  then return nil, i + 4
  else return parse_number(s, i) end
end

-- cjson.safe-style: returns nil, errmsg on failure rather than throwing.
function json.decode(s)
  local ok, v = pcall(parse_value, s, 1)
  if not ok then return nil, v end
  return v
end

return json
