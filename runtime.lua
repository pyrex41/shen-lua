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
-- mtoint: PUC 5.3+ %d-format guard (string.format("%d", x) errors there for
-- an integral float outside int64 range). nil under LuaJIT/5.1: path unchanged.
local mtoint = math.tointeger
-- Shortest round-trippable decimal for a non-integer float. LuaJIT's tostring
-- (and %g) default to 14 significant digits, which is lossy: (+ 0.1 0.2) would
-- print "0.3" instead of the actual double "0.30000000000000004". Emit the
-- smallest %.<p>g (p = 1..17) that parses back to exactly the same double, so
-- the output round-trips and matches the shen-cl/shen-rust/shen-go/ShenScript
-- reference (issue #24).
local function shortest_float(n)
  for p = 1, 17 do
    local s = string.format("%." .. p .. "g", n)
    if tonumber(s) == n then return s end
  end
  return string.format("%.17g", n)
end

-- TWO63: 2^63, exact as a double. The %d path is only sound for integral
-- values inside int64; on LuaJIT/5.1 it SATURATES outside that range instead
-- of erroring, so everything from 2^63 up printed as 9223372036854775807 and
-- everything from -2^63 down as -9223372036854775808 (issue: rendering half of
-- the int64-saturation class that c83c40e fixed for numeric literals).
local TWO63 = 9223372036854775808.0

-- Positional decimal for a finite integral double at or beyond int64 range.
-- %.17g / tostring would give exponent form, which is not what any reference
-- port prints; %d cannot represent the value at all. So: take the SHORTEST
-- round-trippable scientific form (same rule shortest_float applies to
-- non-integral values, issue #24) and expand its digits positionally.
--
--   1e19  -> "1e+19"                  -> 1  + 19 zeros
--   2^63  -> "9.223372036854776e+18"  -> 9223372036854776 + 3 zeros
--
-- Shortest-round-trip rather than the double's exact value (%.0f) on purpose:
-- it round-trips, it is what shen-rust prints for the same double (verified
-- byte-for-byte), and it is the rule this printer already follows everywhere
-- else. Sign-symmetric, so -2^63 renders as the negation of 2^63 rather than
-- exposing the two's-complement asymmetry of %d.
local function positional_integral(n)
  local s
  for p = 0, 17 do
    s = string.format("%." .. p .. "e", n)
    if tonumber(s) == n then break end
  end
  local sign, lead, frac, e = s:match("^(%-?)(%d)%.?(%d*)[eE]([-+]?%d+)$")
  if not sign then return shortest_float(n) end   -- unrecognised: degrade, don't lie
  local zeros = tonumber(e) - #frac
  if zeros < 0 then return shortest_float(n) end  -- not actually integral
  return sign .. lead .. frac .. string.rep("0", zeros)
end

-- The single number-rendering rule for the whole port. runtime.to_str (the
-- printer) and the `str` primitive in prims.lua BOTH go through this: they are
-- two surfaces on one rule and have diverged before, so there is exactly one
-- implementation. Non-finite values (+-inf, NaN) fall through to
-- shortest_float unchanged -- overflow policy is deliberately not decided here.
local function num_to_str(x)
  if x == math.floor(x) and x == x and x ~= math.huge and x ~= -math.huge then
    if x > -TWO63 and x < TWO63 then
      if mtoint then
        local i = mtoint(x)
        if i then return string.format("%d", i) end
        return string.format("%.17g", x)
      end
      return string.format("%d", x)
    end
    return positional_integral(x)
  end
  return shortest_float(x)
end

local function to_str(x, seen)
  local t = type(x)
  if t == "number" then
    return num_to_str(x)
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
M.shortest_float = shortest_float
M.num_to_str = num_to_str

----------------------------------------------------------------------
-- Lua stack segments (pyrex41/shen-lua#93)
----------------------------------------------------------------------
-- LuaJIT's Lua stack is a fixed ~65500 slots per coroutine (LJ_STACK_MAX,
-- a compile-time constant), so non-tail recursion in compiled KL -- the
-- kernel's own tree walkers (shen.curry, shen.find-types,
-- shen.process-applications) and user code alike -- overflowed after about
-- 12k frames, where shen-go grows its stack. Every coroutine has its own
-- stack, so deep recursion continues on a fresh one (a segment), as the
-- Prolog engine already does for deep proofs (#85).
--
-- SD[1] counts the compiled functions on the current stack that are waiting
-- on a non-tail call (compiler.lua NT_SRC: such a function counts itself on
-- entry and restores the count before it returns or tail-calls). Once
-- SEG_FRAMES of them are open, the next one runs on a new coroutine instead
-- (M.seg.run). Tail calls are never counted, so a loop that runs in constant
-- stack never opens a segment. NTV is the trampoline form for code outside
-- a defun; natives that call back into Shen code count inline.
--
-- An error unwinds past the restores, so the catch points restore the count
-- by assignment: M.seg.pcall / .xpcall (the compiled trap-error and the
-- runtime's own pcalls use them), M.seg.call (host entry points, so an error
-- a host catches does not leak the count) and the segment runner itself.
do
  local co_create, co_resume, co_status, co_yield =
    coroutine.create, coroutine.resume, coroutine.status, coroutine.yield
  local unpack = unpack or table.unpack
  local SEG_FRAMES = 160      -- counted calls per segment (C.SEG_FRAMES)
  local SEG_MAX = 10000       -- nested segments: each costs ~200 bytes of C stack
  local SD = { 0 }            -- counted calls open on the current stack
  local nseg, total = 0, 0
  local ERR = function(msg) error(msg, 0) end
  local function pack(...) return { n = select("#", ...), ... } end
  local S = { SD = SD, FRAMES = SEG_FRAMES }

  -- Run f(...) on a fresh coroutine stack and return its value. Errors are
  -- rethrown unchanged (Shen exception objects included); a yield from
  -- inside (an embedding host's) is passed through to the enclosing
  -- coroutine.
  function S.run(f, ...)
    if nseg >= SEG_MAX then
      ERR("Lua stack depth limit exceeded (" .. SEG_MAX .. " stack segments)")
    end
    local saved, saved_n = SD[1], nseg
    nseg = nseg + 1; SD[1] = 0
    total = total + 1
    local co = co_create(f)
    local res = pack(co_resume(co, ...))
    while res[1] and co_status(co) ~= "dead" do
      local up = pack(pcall(co_yield, unpack(res, 2, res.n)))
      if not up[1] then res = up; break end   -- no coroutine to yield to
      res = pack(co_resume(co, unpack(up, 2, up.n)))
    end
    -- assign, not decrement: segments abandoned while suspended never return
    SD[1], nseg = saved, saved_n
    if not res[1] then error(res[2], 0) end
    return res[2]
  end
  local run = S.run
  -- S.run for the function that called it (a lambda has no name to pass)
  local getinfo = debug and debug.getinfo
  function S.runself(...)
    return run(getinfo(2, "f").func, ...)
  end

  -- the trampoline outside a defun (vararg: a FUNCV entry never starts a
  -- root trace of its own)
  function S.NTV(f, ...)
    local d = SD[1]
    if d < SEG_FRAMES then SD[1] = d + 1; local r = f(...); SD[1] = d; return r end
    return run(f, ...)
  end

  local function restore(d, ok, ...)
    if not ok then SD[1] = d end
    return ok, ...
  end
  local function rethrow(d, ok, ...)
    if not ok then SD[1] = d; error((...), 0) end
    return ...
  end
  function S.pcall(f, ...) return restore(SD[1], pcall(f, ...)) end
  function S.xpcall(f, h) return restore(SD[1], xpcall(f, h)) end
  -- f(...) for a host entry point
  function S.call(f, ...) return rethrow(SD[1], pcall(f, ...)) end

  -- segments ever opened, nested now, counted calls open on this stack
  function S.stats() return total, nseg, SD[1] end
  -- set the nesting cap (tests); returns the previous value
  function S.limit(max)
    local m0 = SEG_MAX
    SEG_MAX = max or m0
    return m0
  end
  function S.set_error(fn) ERR = fn end
  M.seg = S
end

return M
