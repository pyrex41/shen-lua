-- runtime.lua : Shen/KLambda runtime core for the LuaJIT port.
-- Data representation (chosen for trace-JIT friendliness):
--   numbers  -> Lua numbers
--   strings  -> Lua strings (Shen strings; immutable)
--   booleans -> Lua true/false (KL symbols `true`/`false` map here)
--   symbols  -> interned tables {name=..} with metatable Symbol (identity ==)
--   ()       -> the unique value NIL (empty list)
--   cons     -> {h, t} with metatable Cons
--   vectors  -> pure-array table, metatable Vmt: [1]=size, [i+2]=KL elt i
--              (KL absvector, 0-indexed raw store; no `n` hash key)
--   functions-> Lua functions (with .arity attached where known)
--   exception-> {msg=string} with metatable Excn

local M = {}

----------------------------------------------------------------------
-- Symbols
----------------------------------------------------------------------
local Symbol = {}
Symbol.__index = Symbol
local symtab = {}
local function intern(name)
  local s = symtab[name]
  if s then return s end
  s = setmetatable({ name = name }, Symbol)
  symtab[name] = s
  return s
end
function Symbol.__tostring(s) return s.name end
M.Symbol = Symbol
M.intern = intern

----------------------------------------------------------------------
-- Empty list / cons
----------------------------------------------------------------------
local NIL = setmetatable({ name = "()" }, { __tostring = function() return "()" end })
M.NIL = NIL

local Cons = {}
Cons.__index = Cons
local function cons(h, t) return setmetatable({ h, t }, Cons) end
local function is_cons(x) return getmetatable(x) == Cons end
M.Cons = Cons
M.cons = cons
M.is_cons = is_cons

----------------------------------------------------------------------
-- Vectors (KL absvector): pure-array table discriminated by Vmt.
--   [1] = size n ; [i+2] = KL element i (for i in 0..n-1)
-- A dedicated metatable (a POSITIVE discriminator) keeps cons/symbol/
-- stream/exception from ever being mistaken for a vector, and avoids the
-- hash part the old `n` string key forced. Owned here, shared into
-- prims.lua via R.Vmt so the metatable identity is the SAME object in both.
----------------------------------------------------------------------
local Vmt = {}
M.Vmt = Vmt

----------------------------------------------------------------------
-- Exceptions (Shen `exception` objects)
----------------------------------------------------------------------
local Excn = {}
Excn.__index = Excn
local function mkexcn(msg) return setmetatable({ msg = msg }, Excn) end
M.Excn = Excn
M.mkexcn = mkexcn

----------------------------------------------------------------------
-- Predicates / helpers
----------------------------------------------------------------------
local function is_symbol(x) return getmetatable(x) == Symbol end
M.is_symbol = is_symbol

-- Lua list <-> KL list
local function from_table(arr, i)
  i = i or 1
  local acc = NIL
  for k = #arr, i, -1 do acc = cons(arr[k], acc) end
  return acc
end
M.from_table = from_table

----------------------------------------------------------------------
-- Reader : KLambda S-expressions -> runtime values
----------------------------------------------------------------------
local byte = string.byte
local sub = string.sub
local TRUE = true
local FALSE = false

local function is_number_token(t)
  -- integer or float, optional leading sign; but a lone sign is NOT a number
  return t:match("^[%+%-]?%d+$") or t:match("^[%+%-]?%d*%.%d+$")
      or t:match("^[%+%-]?%d+%.%d*$") or t:match("^[%+%-]?%d+[eE][%+%-]?%d+$")
      or t:match("^[%+%-]?%d*%.%d+[eE][%+%-]?%d+$")
end

-- Returns an iterator producing successive top-level forms from `src`.
local function reader(src)
  local pos = 1
  local len = #src
  local function peek() return byte(src, pos) end

  local function skipws()
    while pos <= len do
      local c = byte(src, pos)
      if c == 32 or c == 9 or c == 10 or c == 13 or c == 12 then
        pos = pos + 1
      elseif c == 92 and byte(src, pos+1) == 92 then
        -- (KL has no comments; nothing to skip) -- keep placeholder
        break
      else
        break
      end
    end
  end

  local read_form  -- fwd

  local function read_list()
    pos = pos + 1 -- consume '('
    local items = {}
    while true do
      skipws()
      if pos > len then error("KL reader: unexpected EOF in list") end
      if byte(src, pos) == 41 then -- ')'
        pos = pos + 1
        break
      end
      items[#items+1] = read_form()
    end
    if #items == 0 then return NIL end
    -- build proper list
    local acc = NIL
    for k = #items, 1, -1 do acc = cons(items[k], acc) end
    return acc
  end

  local function read_string()
    pos = pos + 1 -- consume opening quote
    local start = pos
    while pos <= len and byte(src, pos) ~= 34 do pos = pos + 1 end
    if pos > len then error("KL reader: unterminated string") end
    local s = sub(src, start, pos - 1)
    pos = pos + 1 -- consume closing quote
    return s
  end

  local function read_atom()
    local start = pos
    while pos <= len do
      local c = byte(src, pos)
      if c == 32 or c == 9 or c == 10 or c == 13 or c == 12
         or c == 40 or c == 41 or c == 34 then break end
      pos = pos + 1
    end
    local t = sub(src, start, pos - 1)
    if is_number_token(t) then return tonumber(t) end
    if t == "true" then return TRUE end
    if t == "false" then return FALSE end
    return intern(t)
  end

  read_form = function()
    skipws()
    if pos > len then return nil, true end
    local c = byte(src, pos)
    if c == 40 then return read_list()
    elseif c == 34 then return read_string()
    elseif c == 41 then error("KL reader: unexpected )")
    else return read_atom() end
  end

  return function()
    skipws()
    if pos > len then return nil end
    return read_form()
  end
end
M.reader = reader

-- read all forms in a string into a Lua array
local function read_all(src)
  local it = reader(src)
  local forms = {}
  while true do
    local f = it()
    if f == nil then break end
    forms[#forms+1] = f
  end
  return forms
end
M.read_all = read_all

----------------------------------------------------------------------
-- Printer (for debugging / REPL)
----------------------------------------------------------------------
local function to_str(x, seen)
  local t = type(x)
  if t == "number" then
    if x == math.floor(x) and x == x and x ~= math.huge and x ~= -math.huge then
      return string.format("%d", x)
    end
    return tostring(x)
  elseif t == "boolean" then return x and "true" or "false"
  elseif t == "string" then return '"' .. x .. '"'
  elseif x == NIL then return "()"
  elseif is_symbol(x) then return x.name
  elseif is_cons(x) then
    local parts = {}
    local cur = x
    while is_cons(cur) do parts[#parts+1] = to_str(cur[1]); cur = cur[2] end
    if cur == NIL then
      return "(" .. table.concat(parts, " ") .. ")"
    else
      return "(" .. table.concat(parts, " ") .. " . " .. to_str(cur) .. ")"
    end
  elseif getmetatable(x) == Excn then
    return "#<exception: " .. tostring(x.msg) .. ">"
  elseif t == "function" then return "#<function>"
  elseif getmetatable(x) == Vmt then return "#<vector " .. tostring(x[1]) .. ">"
  else return tostring(x) end
end
M.to_str = to_str

return M
