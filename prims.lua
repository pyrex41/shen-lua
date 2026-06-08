-- prims.lua : build the runtime environment (function table F, apply/curry
-- machinery, KL primitives) and provide load/eval of KL forms.

local R = require("runtime")
local C = require("compiler")
local cons, is_cons, NIL = R.cons, R.is_cons, R.NIL
local Symbol, intern, is_symbol = R.Symbol, R.intern, R.is_symbol
local Excn, mkexcn = R.Excn, R.mkexcn

local P = {}

local F  = {}            -- Shen/KL function table: name -> Lua function
local FA = setmetatable({}, {__mode="k"})  -- Lua function -> arity
local GLOBALS = {}       -- KL global variable namespace: name -> value
P.F, P.FA, P.GLOBALS = F, FA, GLOBALS

-- ---- errors / exceptions -------------------------------------------------
local function ERR(msg) error(mkexcn(msg), 0) end
local function TOEXCN(e)
  if getmetatable(e) == Excn then return e end
  return mkexcn(tostring(e))
end
P.ERR = ERR

-- ---- apply / curry -------------------------------------------------------
local unpack = table.unpack or unpack
local function MKFUN(arity, fn) FA[fn] = arity; return fn end

-- Frozen-continuation thunks (from BIND / freeze) are represented as array
-- tables {fn, cap1, ..., capN} tagged with the Thunk metatable, NOT as Lua
-- closures. Reason: in LuaJIT every closed-over upvalue is a separate ~56-byte
-- GCupval box, so a freeze capturing 7 vars costs ~440 B as a closure but only
-- ~170 B as an 8-slot array table. Captures are never Lua nil (KL false/() are
-- non-nil values), so #t is a reliable length. thaw and APP's 0-arg path run a
-- thunk by calling t[1](t[2..#t]).
local Thunk = {}
local function runthunk(t) return t[1](unpack(t, 2, #t)) end
P.Thunk = Thunk

local APP  -- fwd
local function PARTIAL(f, ar, have)
  local need = ar - #have
  local g
  g = function(...)
    local extra = {...}
    local all = {}
    for i=1,#have do all[i] = have[i] end
    local m = #have
    for i=1,select("#", ...) do all[m+i] = extra[i] end
    return f(unpack(all, 1, ar))
  end
  return MKFUN(need, g)
end

APP = function(f, ...)
  -- Fast path: the operand is overwhelmingly a Lua function (a compiled Shen
  -- function or a continuation/thunk). Check that first so the common case
  -- avoids the `is_symbol` getmetatable probe entirely. APP is ~13% of the
  -- typechecker's runtime, so this branch order matters.
  if type(f) == "function" then
    local n = select("#", ...)
    local ar = FA[f]
    if ar == nil or ar == n then     -- primitive/unknown-arity fn: assume exact
      return f(...)
    elseif n < ar then
      return PARTIAL(f, ar, {...})
    else
      local args = {...}
      local first = {}
      for i=1,ar do first[i] = args[i] end
      local r = f(unpack(first, 1, ar))
      local rest = {}
      for i=ar+1,n do rest[#rest+1] = args[i] end
      return APP(r, unpack(rest, 1, #rest))
    end
  end
  -- A frozen-continuation thunk applied with no args (KL `(thaw V)` sometimes
  -- routes here): run it; if over-applied, apply the result to the rest.
  if getmetatable(f) == Thunk then
    if select("#", ...) == 0 then return runthunk(f) end
    return APP(runthunk(f), ...)
  end
  -- Slow path: a symbol naming a function, or an error.
  if is_symbol(f) then
    local fn = F[f.name]
    if fn == nil then ERR("not a function: " .. f.name) end
    return APP(fn, ...)
  end
  ERR("attempt to apply a non-function")
end
P.APP, P.MKFUN, P.PARTIAL = APP, MKFUN, PARTIAL

-- ---- equality ------------------------------------------------------------
local function equal(a, b)
  if a == b then return true end
  local ta, tb = type(a), type(b)
  if ta ~= tb then return false end
  if ta == "table" then
    if is_cons(a) and is_cons(b) then
      return equal(a[1], b[1]) and equal(a[2], b[2])
    end
    -- vectors
    if a.n ~= nil and b.n ~= nil then
      if a.n ~= b.n then return false end
      for i=0,a.n-1 do if not equal(a[i], b[i]) then return false end end
      return true
    end
  end
  return false
end
P.equal = equal

-- ---- primitive registration ---------------------------------------------
local function defprim(name, arity, fn)
  F[name] = fn
  FA[fn] = arity
  C.ARITY[name] = arity
end
P.defprim = defprim

local function tonum(x)
  if type(x) ~= "number" then ERR("not a number: " .. R.to_str(x)) end
  return x
end

-- arithmetic
defprim("+", 2, function(a,b) return tonum(a) + tonum(b) end)
defprim("-", 2, function(a,b) return tonum(a) - tonum(b) end)
defprim("*", 2, function(a,b) return tonum(a) * tonum(b) end)
defprim("/", 2, function(a,b) b=tonum(b); if b==0 then ERR("division by zero") end; return tonum(a)/b end)
defprim(">", 2, function(a,b) return tonum(a) >  tonum(b) end)
defprim("<", 2, function(a,b) return tonum(a) <  tonum(b) end)
defprim(">=",2, function(a,b) return tonum(a) >= tonum(b) end)
defprim("<=",2, function(a,b) return tonum(a) <= tonum(b) end)
defprim("=", 2, function(a,b) return equal(a,b) end)

-- lists
defprim("cons", 2, function(a,b) return cons(a,b) end)
defprim("hd", 1, function(x) if not is_cons(x) then ERR("hd of non-cons") end return x[1] end)
defprim("tl", 1, function(x) if not is_cons(x) then ERR("tl of non-cons") end return x[2] end)
defprim("cons?", 1, function(x) return is_cons(x) end)

-- predicates
defprim("number?", 1, function(x) return type(x)=="number" end)
defprim("string?", 1, function(x) return type(x)=="string" end)
defprim("symbol?", 1, function(x) return is_symbol(x) end)
defprim("boolean?",1, function(x) return type(x)=="boolean" end)
defprim("not", 1, function(x) if type(x)~="boolean" then ERR("not: not boolean") end return not x end)
defprim("integer?",1, function(x) return type(x)=="number" and x==math.floor(x) and x~=math.huge and x~=-math.huge end)

-- symbols / strings
defprim("intern", 1, function(s)
  if type(s)~="string" then ERR("intern: not a string") end
  if s=="true" then return true elseif s=="false" then return false end
  return intern(s)
end)

local function numToStr(n)
  if type(n)=="number" and n==math.floor(n) and n~=math.huge and n~=-math.huge then
    return string.format("%d", n)
  end
  return tostring(n)
end

defprim("str", 1, function(x)
  local t = type(x)
  if t=="number" then return numToStr(x)
  elseif t=="string" then return x          -- str of a string is the string (with quotes? Shen: str adds nothing here)
  elseif t=="boolean" then return x and "true" or "false"
  elseif is_symbol(x) then return x.name
  elseif x==NIL then ERR("str: cannot convert ()")
  else ERR("str: cannot convert") end
end)

defprim("cn", 2, function(a,b)
  if type(a)~="string" or type(b)~="string" then ERR("cn: not strings") end
  return a..b
end)
defprim("pos", 2, function(s,n)
  if type(s)~="string" then ERR("pos: not a string") end
  if n < 0 or n >= #s then ERR("pos: index out of range") end
  return string.sub(s, n+1, n+1)
end)
defprim("tlstr", 1, function(s)
  if type(s)~="string" then ERR("tlstr: not a string") end
  if #s == 0 then ERR("tlstr: empty string") end
  return string.sub(s, 2)
end)
defprim("string->n", 1, function(s)
  if type(s) ~= "string" or #s == 0 then ERR("string->n: empty or non-string") end
  return string.byte(s,1)
end)
defprim("n->string", 1, function(n)
  if type(n) ~= "number" then ERR("n->string: not a number") end
  return string.char(n)
end)
defprim("string->symbol", 1, function(s) return intern(s) end)

-- empty?
defprim("empty?", 1, function(x) return x==NIL end)

-- globals (dual namespace)
defprim("set", 2, function(sym, v)
  local key = is_symbol(sym) and sym.name or tostring(sym)
  GLOBALS[key] = v; return v
end)
defprim("value", 1, function(sym)
  local key = is_symbol(sym) and sym.name or tostring(sym)
  local v = GLOBALS[key]
  if v == nil then ERR("variable " .. key .. " has no value") end
  return v
end)

-- errors
defprim("simple-error", 1, function(msg) ERR(type(msg)=="string" and msg or R.to_str(msg)) end)
defprim("error-to-string", 1, function(e)
  if getmetatable(e)==Excn then return e.msg end
  return tostring(e)
end)

-- vectors (absvector: raw 0-indexed store of size n)
local FAILOBJ = intern("shen.fail!")
P.FAILOBJ = FAILOBJ
defprim("absvector", 1, function(n)
  local v = { n = n }
  for i=0,n-1 do v[i] = FAILOBJ end
  return v
end)
defprim("absvector?", 1, function(x) return type(x)=="table" and x.n~=nil and getmetatable(x)==nil end)
defprim("<-address", 2, function(v, i) return v[i] end)
defprim("address->", 3, function(v, i, x) v[i]=x; return v end)

-- freeze/thaw : thunks are 0-arity functions (kernel: (defun thaw (V) (V)))
-- Hot path in the Prolog/typechecker CPS: a thawed value is always a 0-arity
-- Lua closure (produced by `freeze` / BIND), so call it directly and skip the
-- full APP dispatch (symbol check, arity lookup, vararg packing). APP remains
-- the fallback for the rare symbol case.
defprim("thaw", 1, function(x)
  if getmetatable(x) == Thunk then return runthunk(x) end
  if type(x) == "function" then return x() end
  return APP(x)
end)

-- type : erased
defprim("type", 2, function(x, _ty) return x end)

-- eval-kl
local load_form  -- fwd (defined below)
defprim("eval-kl", 1, function(form) return P.eval(form) end)

-- get-time : (get-time Sym), Sym in {run, real, unix}
local t0_real = os.time()
defprim("get-time", 1, function(sym)
  local name = is_symbol(sym) and sym.name or tostring(sym)
  if name == "run" then return os.clock()
  else return os.time() - t0_real end   -- real / unix : wall seconds since boot
end)

-- ---- streams -------------------------------------------------------------
-- Stream objects carry a metatable so they are never confused with vectors
-- (absvector? requires getmetatable(x)==nil) or cons cells.
local Stream = {}
P.Stream = Stream
local function is_stream(x) return type(x)=="table" and getmetatable(x)==Stream end
P.is_stream = is_stream

local function mk_out_stream(writefn, closefn, name)
  return setmetatable({ kind="out", write=writefn, close=closefn, name=name }, Stream)
end
local function mk_in_stream(readfn, closefn, name)
  return setmetatable({ kind="in", readbyte=readfn, close=closefn, name=name, eof=false }, Stream)
end
P.mk_out_stream, P.mk_in_stream = mk_out_stream, mk_in_stream

-- shen.char-stoutput? : port-specific predicate referenced by `pr` to choose
-- between a fast (write-string) and a fallback (write-chars) path. Our streams
-- are byte streams, so we return false and the `write-chars` path is used.
defprim("shen.char-stoutput?", 1, function(_st) return false end)
-- shen.char-stinput? : input-side counterpart used by `read-byte` callers.
-- Our streams are byte streams.
defprim("shen.char-stinput?", 1, function(_st) return false end)

-- write-byte (N STREAM) -> N : write a single byte to an output stream
defprim("write-byte", 2, function(n, st)
  if not is_stream(st) or st.kind~="out" then ERR("write-byte: not an output stream") end
  st.write(string.char(n))
  return n
end)

-- read-byte (STREAM) -> N | -1 at EOF
defprim("read-byte", 1, function(st)
  if not is_stream(st) or st.kind~="in" then ERR("read-byte: not an input stream") end
  if st.eof then return -1 end
  local b = st.readbyte()
  if b == nil then st.eof = true; return -1 end
  return b
end)

-- open (NAME DIRECTION) -> stream ; DIRECTION is symbol `in` or `out`
defprim("open", 2, function(name, dir)
  if type(name)~="string" then ERR("open: filename not a string") end
  local d = is_symbol(dir) and dir.name or tostring(dir)
  if d == "in" then
    local fh, e = io.open(name, "rb")
    if not fh then ERR("open: cannot open "..name.." ("..tostring(e)..")") end
    return mk_in_stream(function() local c = fh:read(1); return c and string.byte(c) or nil end,
                        function() fh:close() end, name)
  elseif d == "out" then
    local fh, e = io.open(name, "wb")
    if not fh then ERR("open: cannot open "..name.." ("..tostring(e)..")") end
    return mk_out_stream(function(s) fh:write(s) end, function() fh:close() end, name)
  else
    ERR("open: bad direction "..d)
  end
end)

-- close (STREAM) -> ()
defprim("close", 1, function(st)
  if is_stream(st) and st.close then st.close() end
  return NIL
end)

-- exit
defprim("exit", 1, function(n) io.stdout:flush(); os.exit(type(n)=="number" and n or 0) end)

-- Native reimplementation of the hottest Prolog dereference primitives.
-- These run ~6x/inference in the typechecker; as compiled KL each call pays
-- function-dispatch + per-step `<-address`/`shen.pvar?` indirection. The native
-- versions are tight Lua loops over the prolog binding vector (this is what the
-- shen-c and shen-rust ports do). shen.deref additionally does STRUCTURE SHARING
-- -- returning the original cons subtree unchanged when nothing dereffed -- which
-- the native C/Rust ports do NOT do, eliminating most of deref's cons allocation.
-- Installed after the kernel loads (overriding the compiled KL defuns in F).
-- A prolog variable is an absvector {[0]=shen.pvar, [1]=ticket}; the binding for
-- ticket t lives at prolog-vector slot v[t], with shen.-null- meaning unbound.
function P.install_native_prolog()
  local shen_pvar = intern("shen.pvar")
  local shen_null = intern("shen.-null-")
  local getmt = getmetatable
  local function is_pvar(x)
    return type(x) == "table" and x.n ~= nil and getmt(x) == nil and x[0] == shen_pvar
  end
  local function lazyderef(x, v)
    while type(x) == "table" and x.n ~= nil and getmt(x) == nil and x[0] == shen_pvar do
      local w = v[x[1]]
      if w == shen_null then return x end
      x = w
    end
    return x
  end
  local function deref(x, v)
    if is_cons(x) then
      local h0, t0 = x[1], x[2]
      local h = deref(h0, v)
      local t = deref(t0, v)
      if h == h0 and t == t0 then return x end   -- structure sharing: nothing changed
      return cons(h, t)
    elseif type(x) == "table" and x.n ~= nil and getmt(x) == nil and x[0] == shen_pvar then
      local w = v[x[1]]
      if w == shen_null then return x end
      return deref(w, v)
    else
      return x
    end
  end
  F["shen.pvar?"] = is_pvar;       FA[is_pvar] = 1
  F["shen.lazyderef"] = lazyderef; FA[lazyderef] = 2
  F["shen.deref"] = deref;         FA[deref] = 2
end

-- ---- loader / eval -------------------------------------------------------
-- environment table exposed to compiled chunks
local ENV = {
  F = F, FA = FA, S = intern, NIL = NIL,
  APP = APP, PARTIAL = PARTIAL, MKFUN = MKFUN,
  ERR = ERR, TOEXCN = TOEXCN,
  KDATA = C.KDATA,
  MKLIST = function(arr, tail)
    local acc = tail
    for i=#arr,1,-1 do acc = cons(arr[i], acc) end
    return acc
  end,
  -- BIND wraps a per-defun continuation function `fn` together with a snapshot
  -- of its captures into a 0-arity thunk. The compiler hoists deep
  -- (freeze ...) bodies out to a KB table (see CTX in compiler.lua) and emits
  -- BIND(KB[i], cap1, ..., capN) at every use site, so the use site itself
  -- contains no Lua function literal -- avoiding chunk syntax-level overflow
  -- on Prolog CPS chains (einsteins-riddle, t-star).
  -- All thunks produced here are 0-arity and are invoked via `thaw` (direct
  -- call) or APP-with-0-args (whose fallback treats an unknown-arity function
  -- as exact-arity), so we no longer tag them in FA -- skipping a weak-table
  -- write on every freeze, one of the hottest ops in the typechecker.
  BIND = function(fn, ...)
    if select("#", ...) == 0 then return fn end
    return setmetatable({ fn, ... }, Thunk)
  end,
  -- MKTREE consumes a flat blueprint produced by the compiler for deep
  -- cons-trees. See compile_cons_tree in compiler.lua. ops is a sequence of
  -- 'v' followed by a leaf value (push), or 'c' (pop two, push cons).
  MKTREE = function(ops)
    local stack, sp = {}, 0
    local i, n = 1, #ops
    while i <= n do
      local tag = ops[i]
      if tag == "v" then
        sp = sp + 1
        stack[sp] = ops[i+1]
        i = i + 2
      else
        local r = stack[sp]
        local l = stack[sp-1]
        sp = sp - 1
        stack[sp] = cons(l, r)
        i = i + 1
      end
    end
    return stack[1]
  end,
  -- allow compiled code to reach a few Lua builtins safely
  pcall = pcall, select = select, error = error,
  setmetatable = setmetatable, getmetatable = getmetatable,
  math = math, string = string, table = table,
}
P.ENV = ENV

local loadstring = loadstring or load
local setfenv = setfenv

local function compile_and_load(luasrc, chunkname)
  local chunk, err
  if setfenv then
    chunk, err = loadstring(luasrc, chunkname)
    if not chunk then error("Lua load error in "..tostring(chunkname)..": "..tostring(err).."\n"..luasrc) end
    setfenv(chunk, ENV)
  else
    chunk, err = load(luasrc, chunkname, "t", ENV)
    if not chunk then error("Lua load error: "..tostring(err)) end
  end
  return chunk()
end
P.compile_and_load = compile_and_load

-- eval a single KL form (compile and run)
function P.eval(form)
  local C = require("compiler")
  -- Atoms and non-AST values self-evaluate. This includes numbers, strings,
  -- booleans, symbols, NIL, but also absvectors and streams that the macro
  -- expander may hand to (eval-kl) when walking property-vector entries.
  local t = type(form)
  if t == "number" or t == "string" or t == "boolean" then return form end
  if form == NIL then return form end
  if is_symbol(form) then
    -- Bare symbols evaluate to their value in the global var namespace if
    -- bound, otherwise to themselves (KL convention).
    local v = GLOBALS[form.name]
    if v ~= nil then return v end
    return form
  end
  if t == "table" and not is_cons(form) then
    -- absvector, stream, exception, or other opaque object: self-evaluating.
    return form
  end
  if is_cons(form) and is_symbol(form[1]) and form[1].name == "defun" then
    compile_and_load(C.compile_top(form), "defun")
    return form[2][1]   -- the function NAME symbol (car of cdr), as shen-c returns
  end
  return compile_and_load(C.compile_expr_chunk(form), "eval")
end

return P
