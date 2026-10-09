-- unii/host/codec.lua -- explicit Shen/Lua and storage marshalling.
--
-- Three layers, none of which relies on shen-lua's automatic table
-- conversion:
--
-- 1. Tagged values: the host-side model of every datum that crosses the
--    boundary. Each is a table with a `t` tag:
--      {t="sym",  v="name"}        Shen symbol
--      {t="text", v="utf-8"}       Shen string (validated UTF-8)
--      {t="int",  v="-42"}         exact integer, canonical decimal TEXT
--      {t="bool", v=true}          Shen boolean
--      {t="list", v={...}}         Shen list; v={} is the empty list ()
--      {t="vec",  v={...}}         Shen vector (standard, size in slot 0)
--      {t="absent"}                no value (record fields / storage only)
--    Integers are never Lua numbers here: a Lua number may already have
--    been rounded, so int construction takes decimal text and parses it
--    through shen-lua's checked path, which rejects anything outside
--    +/-(2^53-1) before rounding can happen.
--
-- 2. Shen conversion: to_shen / from_shen map tagged values to Shen values
--    and back, bijectively on the domain above (absent has no Shen value
--    of its own; schema records encode it as [none] / [some X]).
--
-- 3. Storage encoding: encode / decode give one canonical byte string per
--    tagged value (binary safe, deterministic, used for journal payloads
--    and state hashes):
--      sym  y<len>:<bytes>     text s<len>:<bytes>     int  i<decimal>;
--      bool T | F              absent A
--      list l<items>e          vec  v<items>e
--      map  m(<text key><value>)*e   keys strictly ascending bytewise;
--                                    absent values are omitted
local checked = require("checked_integer")

local M = {}

M.ABSENT = setmetatable({ t = "absent" }, { __newindex = function() error("ABSENT is immutable", 2) end })

-- ------------------------------------------------------------------ UTF-8

-- Strict UTF-8: no overlongs, no surrogates, nothing above U+10FFFF.
function M.valid_utf8(s)
  local i, n = 1, #s
  local byte = string.byte
  while i <= n do
    local c = byte(s, i)
    if c < 0x80 then
      i = i + 1
    else
      local need, min
      if c >= 0xC2 and c <= 0xDF then need, min = 1, 0x80
      elseif c >= 0xE0 and c <= 0xEF then need, min = 2, 0x800
      elseif c >= 0xF0 and c <= 0xF4 then need, min = 3, 0x10000
      else return false, i end
      if i + need > n then return false, i end
      local cp = c % (2 ^ (6 - need))
      for k = 1, need do
        local cc = byte(s, i + k)
        if cc < 0x80 or cc > 0xBF then return false, i end
        cp = cp * 64 + (cc - 0x80)
      end
      if cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then return false, i end
      i = i + need + 1
    end
  end
  return true
end

-- Longest prefix of s with at most n bytes that ends on a code point
-- boundary (s must be valid UTF-8).
function M.utf8_prefix(s, n)
  if #s <= n then return s end
  local cut = n
  while cut > 0 do
    local c = s:byte(cut + 1)
    if c < 0x80 or c >= 0xC0 then break end
    cut = cut - 1
  end
  return s:sub(1, cut)
end

-- ------------------------------------------------------------ constructors

local SYM_PATTERN = "^[%a][%w%-%.%?%*!_+<>=/]*$"

function M.sym(s)
  if type(s) ~= "string" or not s:match(SYM_PATTERN) then
    error("codec.sym: invalid symbol name " .. tostring(s), 2)
  end
  return { t = "sym", v = s }
end

function M.text(s)
  if type(s) ~= "string" then error("codec.text: expected a Lua string", 2) end
  local ok, at = M.valid_utf8(s)
  if not ok then error("codec.text: invalid UTF-8 at byte " .. at, 2) end
  return { t = "text", v = s }
end

local function canonical_int_text(s)
  return type(s) == "string" and (s == "0" or s:match("^%-?[1-9]%d*$") ~= nil)
end

-- Exact integer from canonical decimal text. A Lua number is refused: by the
-- time it exists, rounding may already have happened.
function M.int(s)
  if type(s) ~= "string" then
    error("codec.int: integers cross the boundary as decimal text, got " .. type(s), 2)
  end
  if not canonical_int_text(s) then error("codec.int: non-canonical decimal " .. s, 2) end
  local ok, err = pcall(checked.parse, s)
  if not ok then error("codec.int: " .. tostring(err), 2) end
  return { t = "int", v = s }
end

-- For integers the host itself computed exactly (byte counts, sequence
-- numbers): checked against the safe range, then rendered as text.
function M.int_of(n)
  local ok = pcall(checked.check, n, "codec.int_of")
  if not ok then error("codec.int_of: not an exact safe integer: " .. tostring(n), 2) end
  return { t = "int", v = string.format("%.0f", n + 0.0) }
end

function M.bool(b)
  if type(b) ~= "boolean" then error("codec.bool: expected boolean", 2) end
  return { t = "bool", v = b }
end

function M.list(items)
  if type(items) ~= "table" then error("codec.list: expected an array", 2) end
  return { t = "list", v = items }
end

function M.vec(items)
  if type(items) ~= "table" then error("codec.vec: expected an array", 2) end
  return { t = "vec", v = items }
end

function M.map(fields)
  if type(fields) ~= "table" then error("codec.map: expected a table", 2) end
  return { t = "map", v = fields }
end

-- Lua number value of an int (only for bounded domain integers).
function M.to_number(v)
  assert(v.t == "int", "codec.to_number: not an int")
  return checked.parse(v.v)
end

-- ----------------------------------------------------------- equality

function M.equal(a, b)
  if a.t ~= b.t then return false end
  local t = a.t
  if t == "absent" then return true end
  if t == "list" or t == "vec" then
    if #a.v ~= #b.v then return false end
    for i = 1, #a.v do if not M.equal(a.v[i], b.v[i]) then return false end end
    return true
  end
  if t == "map" then
    for k, x in pairs(a.v) do
      local y = b.v[k]
      if x.t ~= "absent" and (y == nil or not M.equal(x, y)) then return false end
    end
    for k, y in pairs(b.v) do
      if y.t ~= "absent" and (a.v[k] == nil or a.v[k].t == "absent") then return false end
    end
    return true
  end
  return a.v == b.v
end

-- --------------------------------------------------------- Shen layer

local R, P -- bound by M.bind(shen)

function M.bind(shen)
  R, P = shen.runtime, shen.prims
  return M
end

local function need_shen()
  if not R then error("codec: call codec.bind(shen) after booting Shen", 3) end
end

function M.to_shen(v)
  need_shen()
  local t = v.t
  if t == "sym" then
    if v.v == "true" or v.v == "false" then
      error("codec.to_shen: true/false are booleans, not symbols", 2)
    end
    return R.intern(v.v)
  elseif t == "text" then
    M.text(v.v)
    return v.v
  elseif t == "int" then
    return M.to_number(M.int(v.v))
  elseif t == "bool" then
    return v.v
  elseif t == "list" then
    local acc = R.NIL
    for i = #v.v, 1, -1 do acc = R.cons(M.to_shen(v.v[i]), acc) end
    return acc
  elseif t == "vec" then
    local n = #v.v
    local vec = P.F["vector"](n)
    for i = 1, n do P.F["vector->"](vec, i, M.to_shen(v.v[i])) end
    return vec
  elseif t == "absent" then
    error("codec.to_shen: absent has no Shen value outside an optional field", 2)
  else
    error("codec.to_shen: unsupported tag " .. tostring(t), 2)
  end
end

local function is_vector(x)
  return type(x) == "table" and getmetatable(x) == R.Vmt
end

function M.from_shen(x)
  need_shen()
  local tx = type(x)
  if x == R.NIL then return M.list({}) end
  if tx == "string" then return M.text(x) end
  if tx == "boolean" then return M.bool(x) end
  if tx == "number" then
    if x ~= x or x % 1 ~= 0 or x > checked.MAX or x < -checked.MAX then
      error("codec.from_shen: number is not an exact safe integer: " .. tostring(x), 2)
    end
    return M.int_of(x)
  end
  if R.is_symbol(x) then return M.sym(x.name) end
  if R.is_cons(x) then
    local items = {}
    while R.is_cons(x) do
      items[#items + 1] = M.from_shen(x[1])
      x = x[2]
    end
    if x ~= R.NIL then error("codec.from_shen: improper list", 2) end
    return M.list(items)
  end
  if is_vector(x) then
    local n = P.F["<-address"](x, 0)
    if type(n) ~= "number" then
      error("codec.from_shen: absvector is not a standard vector (tuple?)", 2)
    end
    local items = {}
    for i = 1, n do items[i] = M.from_shen(P.F["<-vector"](x, i)) end
    return M.vec(items)
  end
  error("codec.from_shen: unsupported Shen value " .. R.to_str(x), 2)
end

-- ------------------------------------------------------- storage layer

local function enc(v, out)
  local t = v.t
  if t == "sym" then
    out[#out + 1] = "y" .. #v.v .. ":" .. v.v
  elseif t == "text" then
    out[#out + 1] = "s" .. #v.v .. ":" .. v.v
  elseif t == "int" then
    if not canonical_int_text(v.v) then error("codec.encode: bad int " .. tostring(v.v)) end
    out[#out + 1] = "i" .. v.v .. ";"
  elseif t == "bool" then
    out[#out + 1] = v.v and "T" or "F"
  elseif t == "absent" then
    out[#out + 1] = "A"
  elseif t == "list" or t == "vec" then
    out[#out + 1] = t == "list" and "l" or "v"
    for i = 1, #v.v do enc(v.v[i], out) end
    out[#out + 1] = "e"
  elseif t == "map" then
    local keys = {}
    for k, x in pairs(v.v) do
      if type(k) ~= "string" then error("codec.encode: map keys must be strings") end
      if x.t ~= "absent" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    out[#out + 1] = "m"
    for _, k in ipairs(keys) do
      out[#out + 1] = "s" .. #k .. ":" .. k
      enc(v.v[k], out)
    end
    out[#out + 1] = "e"
  else
    error("codec.encode: unsupported tag " .. tostring(t))
  end
end

function M.encode(v)
  local out = {}
  enc(v, out)
  return table.concat(out)
end

local function dec(s, i)
  local c = s:sub(i, i)
  if c == "y" or c == "s" then
    local colon = s:find(":", i + 1, true)
    if not colon then error("codec.decode: truncated length at " .. i) end
    local lenstr = s:sub(i + 1, colon - 1)
    if not lenstr:match("^%d+$") or (lenstr ~= "0" and lenstr:sub(1, 1) == "0") then
      error("codec.decode: bad length at " .. i)
    end
    local len = tonumber(lenstr)
    local body = s:sub(colon + 1, colon + len)
    if #body ~= len then error("codec.decode: truncated string at " .. i) end
    return (c == "y" and M.sym or M.text)(body), colon + len + 1
  elseif c == "i" then
    local semi = s:find(";", i + 1, true)
    if not semi then error("codec.decode: truncated int at " .. i) end
    return M.int(s:sub(i + 1, semi - 1)), semi + 1
  elseif c == "T" then return M.bool(true), i + 1
  elseif c == "F" then return M.bool(false), i + 1
  elseif c == "A" then return M.ABSENT, i + 1
  elseif c == "l" or c == "v" then
    local items = {}
    i = i + 1
    while s:sub(i, i) ~= "e" do
      if i > #s then error("codec.decode: unterminated sequence") end
      items[#items + 1], i = dec(s, i)
    end
    return (c == "l" and M.list or M.vec)(items), i + 1
  elseif c == "m" then
    local fields, last = {}, nil
    i = i + 1
    while s:sub(i, i) ~= "e" do
      if i > #s then error("codec.decode: unterminated map") end
      local k
      k, i = dec(s, i)
      if k.t ~= "text" then error("codec.decode: map key is not text") end
      if last ~= nil and not (last < k.v) then error("codec.decode: map keys not strictly ascending") end
      last = k.v
      fields[k.v], i = dec(s, i)
      if fields[k.v].t == "absent" then error("codec.decode: absent map value must be omitted") end
    end
    return M.map(fields), i + 1
  end
  error("codec.decode: unknown tag byte at " .. i)
end

function M.decode(s)
  local v, i = dec(s, 1)
  if i ~= #s + 1 then error("codec.decode: trailing bytes after value") end
  return v
end

-- Display form for diagnostics (not a storage format).
function M.show(v)
  local t = v.t
  if t == "sym" then return v.v end
  if t == "text" then return string.format("%q", v.v) end
  if t == "int" then return v.v end
  if t == "bool" then return tostring(v.v) end
  if t == "absent" then return "<absent>" end
  if t == "list" or t == "vec" then
    local parts = {}
    for i = 1, #v.v do parts[i] = M.show(v.v[i]) end
    return (t == "list" and "[" or "<") .. table.concat(parts, " ") .. (t == "list" and "]" or ">")
  end
  if t == "map" then
    local keys = {}
    for k in pairs(v.v) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. M.show(v.v[k]) end
    return "{" .. table.concat(parts, " ") .. "}"
  end
  return "?"
end

return M
