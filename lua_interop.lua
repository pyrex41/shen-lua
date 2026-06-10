-- lua_interop.lua : first-class Lua <-> Shen interop.
--
-- Installed from boot.lua at the END of load_kernel (after the native
-- overrides and after install_fasl), so the typed bridge's `declare` call
-- composes with both the engine's signature recorder and the fasl cache's
-- recording wrapper. All F["declare"] lookups happen at CALL time, never at
-- install time, for the same reason.
--
-- ==========================================================================
-- The Shen-side surface (every entry registered in P.F with its arity in
-- C.ARITY so compiled Shen code emits direct calls):
--
--   (lua.require "mod")           require a Lua module; tables come back as
--                                 an OPAQUE box (never auto-converted),
--                                 other values marshal normally.
--   (lua.global "a.b.c")          resolve a dotted path in _G. Tables box,
--                                 scalars/functions marshal normally.
--   (lua.call F Args)             call a Lua function. F is a string or
--                                 symbol (dotted _G path), an opaque box,
--                                 or a function value. Args is a Shen list,
--                                 one element per argument. Returns the
--                                 FIRST return value, marshaled.
--   (lua.method Obj "name" Args)  method call Obj:name(Args...). Obj is an
--                                 opaque box, a string (string methods), or
--                                 any raw Lua value passed through.
--   (lua.index Obj Key)           read Obj[Key], marshaled.
--   (lua.setindex Obj Key V)      write Obj[Key] := V (V marshaled to Lua,
--                                 () erases the key); returns V.
--   (lua.function Name Path Sig)  THE TYPED BRIDGE: registers F[Name] as a
--                                 marshaling wrapper around the Lua function
--                                 at Path (string path / box / function),
--                                 with arity = number of top-level --> in
--                                 Sig, and declares Sig via F["declare"] so
--                                 TYPECHECKED Shen code can call it.
--                                 e.g. (lua.function fmt "string.format"
--                                        [string --> string --> string])
--
-- Errors raised by Lua code inside any of these become ordinary Shen errors
-- (trappable with trap-error; error-to-string yields "lua error in ...: msg").
-- A Shen error crossing Lua frames and coming back is re-raised unchanged.
--
-- ==========================================================================
-- Marshaling rules (exact):
--
-- Shen -> Lua  (arguments of lua.call/lua.method/bridge fns; M.to_lua):
--   number / string / boolean   -> the same value
--   ()                          -> nil in argument or return position;
--                                  {} (empty table) as a LIST ELEMENT
--   symbol                      -> its print name, as a string
--   proper cons list            -> dense Lua array table {e1, ..., en},
--                                  elements converted recursively
--   improper (dotted) cons      -> error
--   opaque box                  -> the original boxed Lua value
--   function (incl. Shen closures and curried partials) -> itself,
--                                  unconverted: Lua calls it with raw Lua
--                                  values (numbers/strings/booleans line up;
--                                  use M.wrap for full marshaling)
--   absvector / stream / exception / thunk -> passed through unconverted
--
-- Lua -> Shen  (return values of lua.*; M.to_shen; arguments of M.call):
--   nil                         -> ()
--   number / string / boolean   -> the same value (a string is NEVER
--                                  auto-interned to a symbol: that is the
--                                  ambiguous direction)
--   function                    -> itself (callable from Shen)
--   values that are already Shen data (cons, symbol, (), absvector,
--     stream, exception, thunk) -> unchanged
--   PLAIN table (no metatable) that is a dense array with keys exactly
--     1..n (n may be 0)         -> proper Shen list, elements recursively
--   every other table (hash keys, holes, or any metatable), userdata,
--     cdata, thread             -> opaque box (round-trips by identity)
--   multiple return values      -> only the FIRST crosses the boundary
--
-- ==========================================================================
-- The Lua-side API (fields of this module, live after install):
--   M.to_shen(v) / M.to_lua(v)  the marshalers above
--   M.list(arr) / M.array(lst)  Lua array <-> Shen list (deep)
--   M.sym(name)                 intern a Shen symbol
--   M.box(v) / M.unbox(v)       force a value opaque / unwrap a box
--   M.call(name, ...)           call a Shen function by name with marshaled
--                               args; curry-aware: fewer args than the
--                               function's arity returns a partial (a plain
--                               Lua function you can keep calling)
--   M.fn(name)                  a Lua closure doing M.call(name, ...)
--   M.pcall(name, ...)          protected M.call: returns ok, value-or-
--                               message (Shen exceptions -> their message)
--   M.wrap(luafn [, arity])     wrap a Lua function so Shen calls it with
--                               marshaled arguments and result
--   M.eval(src)                 read+eval Shen source text through the real
--                               pipeline; returns the last value UNMARSHALED
--   M.error_message(e)          message string of a caught Shen/Lua error

local R = require("runtime")
local C = require("compiler")

local M = {}
local unpack = table.unpack or unpack
local P, F, FA  -- bound at install

-- ---- opaque boxes ----------------------------------------------------------
local LuaBox = {
  __tostring = function(b) return "#<lua " .. tostring(b[1]) .. ">" end,
}
local function box(v) return setmetatable({ v }, LuaBox) end
local function is_box(x) return getmetatable(x) == LuaBox end
M.box = box
M.is_box = is_box
function M.unbox(x)
  if is_box(x) then return x[1] end
  return x
end

M.sym = R.intern

-- ---- Shen -> Lua ------------------------------------------------------------
local to_lua_nested

-- boundary rule: () in argument/return position is Lua nil
local function to_lua(v)
  if v == R.NIL then return nil end
  return to_lua_nested(v)
end

to_lua_nested = function(v)
  local t = type(v)
  if t ~= "table" then return v end       -- number/string/boolean/function/nil
  if v == R.NIL then return {} end        -- () as a list ELEMENT: empty array
  local mt = getmetatable(v)
  if mt == LuaBox then return v[1] end
  if mt == R.Symbol then return v.name end
  if mt == R.Cons then
    local out, n = {}, 0
    while getmetatable(v) == R.Cons do
      n = n + 1
      out[n] = to_lua_nested(v[1])
      v = v[2]
    end
    if v ~= R.NIL then
      error("lua interop: cannot marshal an improper (dotted) list", 0)
    end
    return out
  end
  return v   -- absvector / stream / exception / thunk: opaque pass-through
end
M.to_lua = to_lua

-- ---- Lua -> Shen ------------------------------------------------------------
local function is_shen_table(v)
  if v == R.NIL then return true end
  local mt = getmetatable(v)
  return mt == R.Cons or mt == R.Symbol or mt == R.Vmt or mt == R.Excn
      or mt == P.Stream or mt == P.Thunk
end

-- n if v is a metatable-free dense array with keys exactly 1..n (n >= 0)
local function array_size(v)
  if getmetatable(v) ~= nil then return nil end
  local n, max = 0, 0
  for k in pairs(v) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return nil end
    n = n + 1
    if k > max then max = k end
  end
  if n ~= max then return nil end   -- holes
  return n
end

local function to_shen(v)
  if v == nil then return R.NIL end
  local t = type(v)
  if t == "number" or t == "string" or t == "boolean" or t == "function" then
    return v
  end
  if t == "table" then
    if is_shen_table(v) then return v end
    local n = array_size(v)
    if n then
      local acc = R.NIL
      for i = n, 1, -1 do acc = R.cons(to_shen(v[i]), acc) end
      return acc
    end
  end
  return box(v)
end
M.to_shen = to_shen

function M.list(arr)
  local acc = R.NIL
  for i = #arr, 1, -1 do acc = R.cons(to_shen(arr[i]), acc) end
  return acc
end

function M.array(lst)
  if lst == R.NIL then return {} end
  if getmetatable(lst) ~= R.Cons then
    error("lua interop: M.array expects a Shen list", 0)
  end
  return to_lua_nested(lst)
end

-- ---- error discipline -------------------------------------------------------
function M.error_message(e)
  if getmetatable(e) == R.Excn then return e.msg end
  return tostring(e)
end

-- run fn(a[1..n]); a Lua error becomes a trappable Shen error, a Shen error
-- crossing back through Lua frames is re-raised unchanged.
local function protected(what, fn, a, n)
  local ok, r = pcall(fn, unpack(a, 1, n))
  if not ok then
    if getmetatable(r) == R.Excn then error(r, 0) end
    P.ERR("lua error in " .. what .. ": " .. tostring(r))
  end
  return to_shen(r)
end

-- ---- callee resolution ------------------------------------------------------
local function resolve_path(path)
  local cur = _G
  for part in path:gmatch("[^%.]+") do
    if type(cur) ~= "table" then return nil end
    cur = cur[part]
    if cur == nil then return nil end
  end
  return cur
end

-- F designator: function | opaque box | string/symbol = dotted _G path
local function resolve_fn(f, what)
  if type(f) == "function" then return f end
  if is_box(f) then return f[1] end
  local path
  if type(f) == "string" then path = f
  elseif R.is_symbol(f) then path = f.name
  else P.ERR(what .. ": not a function designator: " .. R.to_str(f)) end
  local fn = resolve_path(path)
  if fn == nil then P.ERR(what .. ": no Lua value at path " .. path) end
  return fn
end

-- Shen args list -> Lua arg array + exact count (each element gets the
-- BOUNDARY rule, so a () argument is passed as Lua nil)
local function marshal_args(lst, what)
  local a, n = {}, 0
  while getmetatable(lst) == R.Cons do
    n = n + 1
    a[n] = to_lua(lst[1])
    lst = lst[2]
  end
  if lst ~= R.NIL then P.ERR(what .. ": argument list is improper") end
  return a, n
end

-- ---- install: the Shen-side surface -----------------------------------------

-- Shen-LEVEL registration of name/arity: the `arity` property plus the
-- shen.lambda-form entry that (fn name) and Shen's evaluator consult. NOT via
-- the kernel's update-lambda-table: in 41.1 that does
-- (set-lambda-form-entry [F | LambdaEntry]) with LambdaEntry already the
-- (name . fn) pair, so the stored lambda-form is a CONS, and any tc+ call
-- site — which compiles declare-only functions to ((fn name) A B ...) —
-- dies with "attempt to apply a non-function". We do exactly what the
-- kernel's own build-lambda-table does: put the arity, then hand
-- set-lambda-form-entry the (name . fn) entry from shen.lambda-entry.
-- Both writes go through the LIVE F entries, so the fasl wrapper sees them
-- ("p" + "lf" records) when called outside a chunk, and is correctly silent
-- when called from inside one.
local function shen_register(nm, arity)
  F["put"](nm, R.intern("arity"), arity, P.GLOBALS["*property-vector*"])
  F["shen.set-lambda-form-entry"](F["shen.lambda-entry"](nm))
end

function M.install(prims)
  if M.installed then return M end
  M.installed = true
  P, F, FA = prims, prims.F, prims.FA
  local ERR = P.ERR

  -- registers F entry + runtime arity + compiler arity (direct-call codegen).
  -- Shen-LEVEL metadata (the `arity` property + the shen.lambda-form entry
  -- that Shen's own evaluator/`function` consult) needs *property-vector*,
  -- which only exists after (shen.initialise); entries are queued here and
  -- flushed by M.post_initialise (called from boot.lua's initialise).
  M.pending = {}
  local function reg(name, arity, fn)
    F[name] = fn
    FA[fn] = arity
    C.ARITY[name] = arity
    M.pending[#M.pending + 1] = { name, arity }
  end

  reg("lua.require", 1, function(name)
    if R.is_symbol(name) then name = name.name end
    if type(name) ~= "string" then ERR("lua.require: module name must be a string") end
    local ok, mod = pcall(require, name)
    if not ok then ERR("lua.require: " .. tostring(mod)) end
    if type(mod) == "table" then return box(mod) end   -- modules stay opaque
    return to_shen(mod)
  end)

  reg("lua.global", 1, function(path)
    if R.is_symbol(path) then path = path.name end
    if type(path) ~= "string" then ERR("lua.global: path must be a string") end
    local v = resolve_path(path)
    if v == nil then ERR("lua.global: no Lua value at path " .. path) end
    if type(v) == "table" then return box(v) end       -- namespaces stay opaque
    return to_shen(v)
  end)

  reg("lua.call", 2, function(f, args)
    local what = "lua.call"
    local fn = resolve_fn(f, what)
    local a, n = marshal_args(args, what)
    return protected(what, fn, a, n)
  end)

  reg("lua.method", 3, function(obj, name, args)
    local what = "lua.method"
    if R.is_symbol(name) then name = name.name end
    if type(name) ~= "string" then ERR("lua.method: method name must be a string") end
    obj = to_lua(obj)
    local a, n = marshal_args(args, what .. " " .. name)
    local ok, r = pcall(function()
      return obj[name](obj, unpack(a, 1, n))
    end)
    if not ok then
      if getmetatable(r) == R.Excn then error(r, 0) end
      ERR("lua error in " .. what .. " " .. name .. ": " .. tostring(r))
    end
    return to_shen(r)
  end)

  reg("lua.index", 2, function(obj, key)
    obj = to_lua(obj)
    key = to_lua(key)
    local ok, r = pcall(function() return obj[key] end)
    if not ok then ERR("lua error in lua.index: " .. tostring(r)) end
    return to_shen(r)
  end)

  reg("lua.setindex", 3, function(obj, key, v)
    obj = to_lua(obj)
    key = to_lua(key)
    local lv = to_lua(v)
    local ok, r = pcall(function() obj[key] = lv end)
    if not ok then ERR("lua error in lua.setindex: " .. tostring(r)) end
    return v
  end)

  -- the typed bridge -----------------------------------------------------------
  local ARROW = R.intern("-->")
  local function sig_arity(sig)
    local n = 0
    while getmetatable(sig) == R.Cons do
      if sig[1] == ARROW then n = n + 1 end
      sig = sig[2]
    end
    return n
  end

  reg("lua.function", 3, function(name, path, sig)
    local nm
    if R.is_symbol(name) then nm = name
    elseif type(name) == "string" then nm = R.intern(name)
    else ERR("lua.function: name must be a symbol or string") end
    local fn = resolve_fn(path, "lua.function " .. nm.name)
    local arity = sig_arity(sig)
    if arity < 1 then
      ERR("lua.function " .. nm.name .. ": type must be a function type [A --> B]")
    end
    local what = nm.name
    local wrapper = function(...)
      local n = select("#", ...)
      local a = { ... }
      for i = 1, n do a[i] = to_lua(a[i]) end
      return protected(what, fn, a, n)
    end
    F[nm.name] = wrapper
    FA[wrapper] = arity
    C.ARITY[nm.name] = arity
    -- Shen-level arity property + lambda-form entry, so the bridged name is
    -- a first-class Shen function ((fn fmt), partial application at the
    -- REPL, and — crucially — tc+ call sites, which compile declare-only
    -- functions to ((fn name) A B ...)). lua.function only runs
    -- post-initialise, so *property-vector* exists. The puts go through the
    -- (possibly fasl-wrapped) F entries, which is exactly right: replaying
    -- the chunk that called lua.function reproduces this whole registration.
    shen_register(nm, arity)
    -- RECTIFY the signature (right-associate the arrows) before declaring.
    -- Raw `declare` stores the type as given, and a flat
    -- [string --> number --> string] never unifies with the (A --> B) goal
    -- the typechecker poses for a curried application — verified against
    -- reference shen-cl, where the flat form is a type error too and only
    -- [string --> [number --> string]] checks. rectify-type is exactly the
    -- kernel's own normalization (types.kl declare uses it for variancy).
    -- Through the LIVE F["declare"]: install_fasl and the native engine both
    -- wrap declare, and this composes with whatever is installed now.
    F["declare"](nm, F["shen.rectify-type"](sig))
    return nm
  end)

  return M
end

-- Called from boot.lua's initialise, right after (shen.initialise): registers
-- the queued lua.* entries in Shen's own tables (`arity` property +
-- shen.lambda-form) so Shen's evaluator and (function lua.call) can use them.
function M.post_initialise()
  for _, e in ipairs(M.pending or {}) do
    shen_register(R.intern(e[1]), e[2])
  end
  M.pending = {}
end

-- ---- Lua-side conveniences (need the live F table) ---------------------------
function M.call(name, ...)
  local fn = F[name]
  if fn == nil then error("no such Shen function: " .. tostring(name), 2) end
  local n = select("#", ...)
  local a = { ... }
  for i = 1, n do a[i] = to_shen(a[i]) end
  return to_lua(P.APP(fn, unpack(a, 1, n)))
end

function M.fn(name)
  return function(...) return M.call(name, ...) end
end

function M.pcall(name, ...)
  local n = select("#", ...)
  local a = { ... }
  local ok, r = pcall(function() return M.call(name, unpack(a, 1, n)) end)
  if ok then return true, r end
  return false, M.error_message(r)
end

function M.wrap(luafn, arity)
  local w = function(...)
    local n = select("#", ...)
    local a = { ... }
    for i = 1, n do a[i] = to_lua(a[i]) end
    return to_shen(luafn(unpack(a, 1, n)))
  end
  if arity then FA[w] = arity end
  return w
end

-- evaluate Shen source text (full reader + macroexpansion + typed `declare`s
-- behave exactly as at the REPL); returns the LAST form's value, unmarshaled.
function M.eval(src)
  local forms = F["read-from-string"](src)
  local last = R.NIL
  while getmetatable(forms) == R.Cons do
    last = F["eval"](forms[1])
    forms = forms[2]
  end
  return last
end

return M
