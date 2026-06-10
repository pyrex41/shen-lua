-- prolog_compile.lua — retargets the kernel's Prolog clause compiler onto the
-- soa32 substrate (prolog_engine.lua).
--
-- STRATEGY: we do NOT re-implement shen.compile-head/compile-body. The legacy
-- `shen.compile-prolog` (klambda/prolog.kl:27) runs unchanged and produces a
-- KL `(define Name P1..Pk B L K C -> Body)` form whose Body is built from a
-- small CLOSED vocabulary (let/if/=/cons?/hd/tl/freeze/thaw/do + the engine
-- prims lazyderef/deref/pvar?/bind!/newpv/gc/unlocked?/cut/unlock/incinfs +
-- goal calls + the builtins when/is/is!/bind/var?/return/fork/findall/call).
-- We TRANSLATE that form into direct-coded Lua against the substrate ABI:
--
--   NativePred[name] = function(a1..ak, n, cont) -> result-or-false
--
-- so clause order, +m/-m modes, stpart var allocation, and the cut-counter
-- structure are inherited from the battle-tested kernel compiler instead of
-- re-derived. Continuations are DEFUNCTIONALIZED: every (freeze E) in a
-- goal-continuation position becomes a statically-lifted chunk-local Lua
-- function + an integer handle (E.newcontN) capturing free vars in the int32
-- capture buffer; let-bound freezes / GoTo lambda chains that are only
-- invoked locally are CLOSURE-CONVERTED to static functions called with their
-- free vars as extra arguments — zero allocation.
--
-- DUAL REGISTRATION: the F["shen.compile-prolog"] wrapper returns the legacy
-- define form unchanged (so the legacy curried-CPS predicate is registered
-- exactly as before) and ADDITIONALLY translates it natively. Native code is
-- only entered through native query paths (the prolog? routing below, and
-- the Phase-3 typecheck driver); anything the translator cannot handle just
-- leaves NativePred[name] unset and the legacy path serves it.
--
-- prolog? ROUTING: F["shen.call-prolog"] (the macro helper) is wrapped: when
-- every predicate named in the query body is native-compiled (and the body
-- avoids call/findall, which can dispatch closures we cannot), the query is
-- compiled AT MACRO TIME into a synthetic native predicate and the expansion
-- becomes a direct call to the native runner. Otherwise the original
-- expansion (legacy CPS) is returned. SHEN_PROLOG_NATIVE=off disables the
-- routing (translation still happens; it is inert).

local R = require("runtime")
local C = require("compiler")

-- 5.2+ compatibility shims (this module only runs under LuaJIT today — it is
-- loaded via prolog_engine.lua, which is FFI-gated — but keep it loadable).
local unpack = table.unpack or unpack
local loadstring = loadstring or load

local M = {}

local E, P, F            -- bound in install()
local NP                 -- E.NativePred

-- ---------------------------------------------------------------------------
-- KL list helpers
-- ---------------------------------------------------------------------------
local Cons, Symbol, NIL = R.Cons, R.Symbol, R.NIL
local getmt = getmetatable

local function is_cons(x) return getmt(x) == Cons end
local function is_sym(x) return getmt(x) == Symbol end
local function sname(x) return x.name end

local function lst2tbl(l)
  local t, n = {}, 0
  while is_cons(l) do n = n + 1; t[n] = l[1]; l = l[2] end
  return t, n
end

local function is_klvar(x)
  return is_sym(x) and x.name:match("^%u") ~= nil
end

local SYM = setmetatable({}, { __index = function(t, k)
  local s = R.intern(k); rawset(t, k, s); return s
end })

-- ---------------------------------------------------------------------------
-- free-variable computation (first-occurrence order)
-- ---------------------------------------------------------------------------
local function fv_walk(e, bound, out, seen)
  if is_klvar(e) then
    local n = e.name
    if not bound[n] and not seen[n] then
      seen[n] = true; out[#out + 1] = n
    end
  elseif is_cons(e) then
    local h = e[1]
    if h == SYM["let"] and is_cons(e[2]) and is_cons(e[2][2]) then
      -- single- or multi-binding let: (let V1 E1 [V2 E2 ...] Body)
      local v, ex = e[2][1], e[2][2][1]
      local rest = e[2][2][2]
      local body
      if rest[2] == NIL then
        body = rest[1]
      else
        body = R.cons(SYM["let"], rest)
      end
      fv_walk(ex, bound, out, seen)
      local saved = bound[v.name]
      bound[v.name] = true
      fv_walk(body, bound, out, seen)
      bound[v.name] = saved
    elseif h == SYM["lambda"] and is_cons(e[2]) and is_cons(e[2][2]) then
      local v, body = e[2][1], e[2][2][1]
      local saved = bound[v.name]
      bound[v.name] = true
      fv_walk(body, bound, out, seen)
      bound[v.name] = saved
    else
      while is_cons(e) do
        fv_walk(e[1], bound, out, seen)
        e = e[2]
      end
    end
  end
end

local function freevars(e)
  local out = {}
  fv_walk(e, {}, out, {})
  return out
end

-- ---------------------------------------------------------------------------
-- the translator
-- ---------------------------------------------------------------------------
-- ctx = {
--   buf      : chunk-level lines (lifted static fns / conts)
--   nlift    : lifted-fn counter
--   nlocal   : local counter
--   fail     : error escape (translation refused)
-- }
-- env maps KL var name -> { lua = <local name>, kind = "term"|"count"|"cont"
--                           |"result", or kind = "static" with .fn/.params/.fvs }
--
-- Emission is ANF-ish: compile_* appends statements to `out` and returns a
-- Lua expression string for the value.

local BUILTIN_GOALS = {
  ["when"] = true, ["is"] = true, ["is!"] = true, ["bind"] = true,
  ["var?"] = true, ["return"] = true, ["fork"] = true, ["findall"] = true,
  ["call"] = true,
}

local function refuse(ctx, why)
  ctx.failed = why
  error(ctx.fail, 0)
end

local function newlocal(ctx, pfx)
  ctx.nlocal = ctx.nlocal + 1
  return (pfx or "v") .. ctx.nlocal
end

local function indent(d) return string.rep("  ", d) end

local compile_value  -- fwd: control/result position
local compile_term   -- fwd: term-construction position

-- atom constant: interned at translate time, inlined as a number literal
local function atomconst(x)
  return tostring(E.atom(x))
end

-- lift an embedded Shen expression (a when-test / is-RHS / computed goal arg)
-- into a KL defun called with materialized term arguments. Returns the Lua
-- call expression.
local guard_n = 0
local function lift_guard(ctx, e, env, out, d)
  -- replace (shen.deref X B) / (shen.lazyderef X B) with fresh params
  local params, args = {}, {}
  local seen = {}   -- engine var -> param (dedupe repeated references)
  local function mkparam(luaname)
    if seen[luaname] then return seen[luaname] end
    local i = #params + 1
    params[i] = R.intern("GP" .. i)
    args[i] = luaname
    seen[luaname] = params[i]
    return params[i]
  end
  local function strip(x)
    if is_cons(x) then
      local h = x[1]
      if (h == SYM["shen.deref"] or h == SYM["shen.lazyderef"])
         and is_cons(x[2]) and is_klvar(x[2][1]) then
        local vn = x[2][1].name
        local b = env[vn]
        if not b or b.kind ~= "term" then refuse(ctx, "guard derefs non-term " .. vn) end
        return mkparam(b.lua)
      end
      return R.cons(strip(x[1]), strip(x[2]))
    end
    if is_klvar(x) then
      -- bare engine-value variables (the t-star drivers pass raw terms to
      -- helpers like subst) are materialized like deref'd ones; full deref
      -- and materialize agree on everything a Shen helper can observe
      local b = env[x.name]
      if b then
        if b.kind ~= "term" then refuse(ctx, "non-term var in guard: " .. x.name) end
        return mkparam(b.lua)
      end
    end
    return x
  end
  local stripped = strip(e)
  guard_n = guard_n + 1
  local gname = "shen.lua-guard-" .. guard_n
  -- (defun gname (GP1..GPk) stripped)
  local plist = NIL
  for i = #params, 1, -1 do plist = R.cons(params[i], plist) end
  P.eval(R.cons(SYM["defun"], R.cons(R.intern(gname),
           R.cons(plist, R.cons(stripped, NIL)))))
  local call = 'F[' .. string.format("%q", gname) .. ']('
  for i = 1, #args do
    call = call .. (i > 1 and ", " or "") .. "MAT(" .. args[i] .. ")"
  end
  return call .. ")"
end

-- compile a term-construction expression
compile_term = function(ctx, e, env, out, d)
  if is_cons(e) then
    local h = e[1]
    if h == SYM["cons"] and is_cons(e[2]) and is_cons(e[2][2]) then
      local a = compile_term(ctx, e[2][1], env, out, d)
      local b = compile_term(ctx, e[2][2][1], env, out, d)
      return "CONS(" .. a .. ", " .. b .. ")"
    elseif h == SYM["shen.lazyderef"] and is_cons(e[2]) then
      local a = compile_term(ctx, e[2][1], env, out, d)
      return "LZD(" .. a .. ")"
    elseif (h == SYM["hd"] or h == SYM["tl"]) and is_cons(e[2]) then
      local a = compile_term(ctx, e[2][1], env, out, d)
      return (h == SYM["hd"] and "CAR(" or "CDR(") .. a .. ")"
    elseif h == SYM["shen.newpv"] then
      return "NEWVAR()"
    elseif h == SYM["shen.deref"] and is_cons(e[2]) then
      -- a full deref in term position: identity in the native engine
      return compile_term(ctx, e[2][1], env, out, d)
    else
      -- embedded Shen computation producing a value -> guard-lift + import
      local call = lift_guard(ctx, e, env, out, d)
      local r = newlocal(ctx)
      out[#out + 1] = indent(d) .. "local " .. r .. " = IMP(" .. call .. ")"
      return r
    end
  elseif is_klvar(e) then
    local b = env[e.name]
    if not b then refuse(ctx, "unbound var in term: " .. e.name) end
    if b.kind ~= "term" then refuse(ctx, "non-term var in term position: " .. e.name) end
    return b.lua
  else
    -- literal atom: symbol / number / string / boolean / ()
    return atomconst(e)
  end
end

-- compile a continuation argument: C-var (handle), let-bound freeze (already
-- a static), or an inline (freeze E) -> lifted cont + newcontN
local function compile_cont(ctx, e, env, out, d)
  if is_klvar(e) then
    local b = env[e.name]
    if not b then refuse(ctx, "unbound cont var " .. e.name) end
    if b.kind == "cont" or b.kind == "result" then return b.lua end
    if b.kind == "static" then
      -- a let-bound freeze passed onward as a continuation: wrap as handle
      if #b.params > 0 then refuse(ctx, "parameterized GoTo used as cont") end
      return ctx:mkhandle(b, out, d)
    end
    refuse(ctx, "bad cont var kind: " .. e.name)
  elseif is_cons(e) and e[1] == SYM["freeze"] and is_cons(e[2]) then
    local body = e[2][1]
    return ctx:lift_cont(body, env, out, d)
  else
    refuse(ctx, "unsupported cont expression")
  end
end

-- compile in control/value position
compile_value = function(ctx, e, env, out, d)
  if e == true then return "true" end
  if e == false then return "false" end
  if is_klvar(e) then
    local b = env[e.name]
    if not b then refuse(ctx, "unbound var: " .. e.name) end
    if b.kind == "static" then refuse(ctx, "static escapes as value") end
    return b.lua
  end
  if not is_cons(e) then
    if e == NIL then return atomconst(e) end
    if type(e) == "number" then return tostring(e) end   -- counter arithmetic
    refuse(ctx, "literal in value position: " .. tostring(e))
  end

  local h = e[1]
  local args = e[2]

  -- (let V Expr Body) — including the kernel's multi-binding form
  -- (let V1 E1 V2 E2 ... Body), which the Shen macro pipeline would desugar
  if h == SYM["let"] and is_cons(args) and is_cons(args[2]) then
    local v, ex = args[1], args[2][1]
    local rest = args[2][2]
    local body
    if rest[2] == NIL then
      body = rest[1]
    else
      -- more bindings follow: re-wrap as a nested let
      body = R.cons(SYM["let"], rest)
    end
    local nenv = setmetatable({}, { __index = env })
    if is_cons(ex) and (ex[1] == SYM["freeze"] or ex[1] == SYM["lambda"]) then
      -- closure-convert: a let-bound freeze/lambda-chain becomes a static
      -- chunk-level function with its free vars as trailing parameters
      local params, inner = {}, ex
      while is_cons(inner) and inner[1] == SYM["lambda"] do
        params[#params + 1] = inner[2][1]
        inner = inner[2][2][1]
      end
      if is_cons(inner) and inner[1] == SYM["freeze"] then
        -- (freeze E) possibly under lambdas (shen.goto emits one or the other)
        inner = inner[2][1]
      end
      local st = ctx:lift_static(v.name, params, inner, env)
      nenv[v.name] = st
    else
      -- term-producing initializers compile in term mode; everything else
      -- (goal calls, if-chains) is a result
      local kind, ex_lua = "result", nil
      if is_cons(ex) then
        local eh = ex[1]
        if eh == SYM["shen.lazyderef"] or eh == SYM["hd"] or eh == SYM["tl"]
           or eh == SYM["shen.newpv"] or eh == SYM["cons"]
           or eh == SYM["shen.deref"] then
          kind = "term"
          ex_lua = compile_term(ctx, ex, nenv, out, d)
        end
      elseif is_klvar(ex) then
        local b = env[ex.name]
        kind = b and b.kind or "result"
      end
      if not ex_lua then
        ex_lua = compile_value(ctx, ex, nenv, out, d)
      end
      local lv = newlocal(ctx)
      out[#out + 1] = indent(d) .. "local " .. lv .. " = " .. ex_lua
      nenv[v.name] = { lua = lv, kind = kind }
    end
    return compile_value(ctx, body, nenv, out, d)
  end

  -- (if T A B)
  if h == SYM["if"] and is_cons(args) and is_cons(args[2]) then
    local t, a, b = args[1], args[2][1], args[2][2][1]
    local tl = compile_value(ctx, t, env, out, d)
    local r = newlocal(ctx)
    out[#out + 1] = indent(d) .. "local " .. r
    out[#out + 1] = indent(d) .. "if " .. tl .. " then"
    local abuf = {}
    local av = compile_value(ctx, a, env, abuf, d + 1)
    for _, l in ipairs(abuf) do out[#out + 1] = l end
    out[#out + 1] = indent(d + 1) .. r .. " = " .. av
    out[#out + 1] = indent(d) .. "else"
    local bbuf = {}
    local bv = compile_value(ctx, b, env, bbuf, d + 1)
    for _, l in ipairs(bbuf) do out[#out + 1] = l end
    out[#out + 1] = indent(d + 1) .. r .. " = " .. bv
    out[#out + 1] = indent(d) .. "end"
    return r
  end

  -- (= A B)
  if h == SYM["="] and is_cons(args) and is_cons(args[2]) then
    local a, b = args[1], args[2][1]
    local akind = is_klvar(a) and env[a.name] and env[a.name].kind
    local bkind = is_klvar(b) and env[b.name] and env[b.name].kind
    if akind == "term" or bkind == "term" then
      local al = compile_term(ctx, a, env, out, d)
      local bl = compile_term(ctx, b, env, out, d)
      return "(" .. al .. " == " .. bl .. ")"
    else
      local al = compile_value(ctx, a, env, out, d)
      local bl = compile_value(ctx, b, env, out, d)
      return "(" .. al .. " == " .. bl .. ")"
    end
  end

  -- term tests / accessors in control positions
  if h == SYM["cons?"] and is_cons(args) then
    return "(" .. compile_term(ctx, args[1], env, out, d) .. " >= CONS_BASE)"
  end
  if h == SYM["shen.pvar?"] and is_cons(args) then
    local a = compile_term(ctx, args[1], env, out, d)
    return "(" .. a .. " >= VAR_BASE and " .. a .. " < CONS_BASE)"
  end
  if h == SYM["shen.unlocked?"] then return "LOCKOPEN()" end

  -- (do (shen.incinfs) E)
  if h == SYM["do"] and is_cons(args) and is_cons(args[2]) then
    if is_cons(args[1]) and args[1][1] == SYM["shen.incinfs"] then
      out[#out + 1] = indent(d) .. "INCINFS()"
    else
      compile_value(ctx, args[1], env, out, d)
    end
    return compile_value(ctx, args[2][1], env, out, d)
  end
  if h == SYM["shen.incinfs"] then
    out[#out + 1] = indent(d) .. "INCINFS()"
    return "true"
  end

  -- (thaw X)
  if h == SYM["thaw"] and is_cons(args) then
    local x = args[1]
    if is_klvar(x) then
      local b = env[x.name]
      if b and b.kind == "static" then
        if #b.params > 0 then refuse(ctx, "thaw of parameterized static") end
        return ctx:callstatic(b, {}, env, out, d)
      end
    end
    return "THAW(" .. compile_value(ctx, x, env, out, d) .. ")"
  end

  -- (shen.gc B E): LIFO-pop the var allocated by the paired shen.newpv when
  -- E fails (stpart structure guarantees pairing)
  if h == SYM["shen.gc"] and is_cons(args) and is_cons(args[2]) then
    local el = compile_value(ctx, args[2][1], env, out, d)
    local r = newlocal(ctx)
    out[#out + 1] = indent(d) .. "local " .. r .. " = " .. el
    out[#out + 1] = indent(d) .. "if " .. r .. " == false then POPVAR() end"
    return r
  end

  -- (shen.bind! X Y B Cont)
  if h == SYM["shen.bind!"] and is_cons(args) then
    local a = lst2tbl(args)
    local x = compile_term(ctx, a[1], env, out, d)
    local y = compile_term(ctx, a[2], env, out, d)
    local k = compile_cont(ctx, a[4], env, out, d)
    return "BIND1(" .. x .. ", " .. y .. ", " .. k .. ")"
  end

  -- (shen.cut B L K C)
  if h == SYM["shen.cut"] and is_cons(args) then
    local a = lst2tbl(args)
    local n = compile_value(ctx, a[3], env, out, d)
    local k = compile_cont(ctx, a[4], env, out, d)
    return "CUT(" .. n .. ", " .. k .. ")"
  end

  -- (shen.unlock L K)
  if h == SYM["shen.unlock"] and is_cons(args) then
    local a = lst2tbl(args)
    local n = compile_value(ctx, a[2], env, out, d)
    return "UNLOCK(" .. n .. ")"
  end

  -- (+ K 1) — the hascut? counter bump
  if h == SYM["+"] and is_cons(args) and is_cons(args[2]) then
    local al = compile_value(ctx, args[1], env, out, d)
    local bl = compile_value(ctx, args[2][1], env, out, d)
    return "(" .. al .. " + " .. bl .. ")"
  end

  -- static invocation: (GoTo a1..ak)
  if is_klvar(h) then
    local b = env[h.name]
    if b and b.kind == "static" then
      local a, an = lst2tbl(args)
      local call_args = {}
      for i = 1, an do
        call_args[i] = compile_term(ctx, a[i], env, out, d)
      end
      return ctx:callstatic(b, call_args, env, out, d)
    end
    refuse(ctx, "application of variable " .. h.name)
  end

  -- curried static application: ((F a) b) ... — the t-star drivers apply
  -- multi-param GoTo lambdas one argument at a time
  if is_cons(h) then
    local arglists = { args }
    local cur = h
    while is_cons(cur) and is_cons(cur[1]) do
      arglists[#arglists + 1] = cur[2]
      cur = cur[1]
    end
    if is_cons(cur) and is_klvar(cur[1]) then
      local b = env[cur[1].name]
      if b and b.kind == "static" then
        arglists[#arglists + 1] = cur[2]
        local call_args = {}
        for i = #arglists, 1, -1 do
          local at = lst2tbl(arglists[i])
          for j = 1, #at do
            call_args[#call_args + 1] = compile_term(ctx, at[j], env, out, d)
          end
        end
        if #call_args == #b.params then
          return ctx:callstatic(b, call_args, env, out, d)
        end
        refuse(ctx, "curried static arity mismatch: " .. cur[1].name)
      end
    end
    refuse(ctx, "application of non-static expression")
  end

  -- goal calls + builtins: (name args... B L K C)
  if is_sym(h) then
    local a, an = lst2tbl(args)
    local nm = sname(h)
    if BUILTIN_GOALS[nm] then
      if nm == "when" then
        -- (when Test B L K C): Test is an embedded Shen expression
        local t = a[1]
        local tl
        if t == true then tl = "true"
        elseif t == false then tl = "false"
        elseif is_cons(t) and t[1] == SYM["shen.maxinfexceeded?"] then
          tl = "MAXINF()"   -- hot path: runs once per system-S call
        elseif is_cons(t) then tl = lift_guard(ctx, t, env, out, d)
        else refuse(ctx, "when test shape") end
        local k = compile_cont(ctx, a[an], env, out, d)
        local r = newlocal(ctx)
        out[#out + 1] = indent(d) .. "local " .. r .. " = false"
        out[#out + 1] = indent(d) .. "if " .. tl .. " then " .. r .. " = THAW(" .. k .. ") end"
        return r
      elseif nm == "is" or nm == "is!" or nm == "bind" then
        local x = compile_term(ctx, a[1], env, out, d)
        local y = compile_term(ctx, a[2], env, out, d)
        local k = compile_cont(ctx, a[an], env, out, d)
        local op = (nm == "is") and "UNIFY" or (nm == "is!") and "UNIFYOC" or "BIND1"
        return op .. "(" .. x .. ", " .. y .. ", " .. k .. ")"
      elseif nm == "var?" then
        local x = compile_term(ctx, a[1], env, out, d)
        local k = compile_cont(ctx, a[an], env, out, d)
        return "GVAR(" .. x .. ", " .. k .. ")"
      elseif nm == "return" then
        local x = compile_term(ctx, a[1], env, out, d)
        return "MAT(" .. x .. ")"
      elseif nm == "fork" then
        -- (fork (cons goal1 (cons goal2 ...)) B L K C): unroll statically.
        -- each goali is a call form (name args...) without the BLKC suffix
        local nk = compile_value(ctx, a[an - 1], env, out, d)
        local k = compile_cont(ctx, a[an], env, out, d)
        local kv = newlocal(ctx, "fk")
        out[#out + 1] = indent(d) .. "local " .. kv .. " = " .. k
        local r = newlocal(ctx)
        out[#out + 1] = indent(d) .. "local " .. r .. " = false"
        local lst = a[1]
        local first = true
        while is_cons(lst) and lst[1] == SYM["cons"] and is_cons(lst[2]) do
          local g = lst[2][1]
          lst = lst[2][2][1]
          if not (is_cons(g) and is_sym(g[1])) then refuse(ctx, "fork goal shape") end
          local guard = first and "" or ("if " .. r .. " == false then ")
          local gb = {}
          local gargs, gn = lst2tbl(g[2])
          local parts = {}
          for i = 1, gn do parts[i] = compile_term(ctx, gargs[i], env, gb, d + 1) end
          for _, l in ipairs(gb) do out[#out + 1] = l end
          local gname = sname(g[1])
          if BUILTIN_GOALS[gname] then refuse(ctx, "builtin inside fork") end
          out[#out + 1] = indent(d) .. guard .. r .. " = NP[" ..
            string.format("%q", gname) .. "](" ..
            table.concat(parts, ", ") .. (gn > 0 and ", " or "") ..
            nk .. ", " .. kv .. ")" .. (first and "" or " end")
          first = false
        end
        return r
      elseif nm == "findall" or nm == "call" then
        local nk = compile_value(ctx, a[an - 1], env, out, d)
        local k = compile_cont(ctx, a[an], env, out, d)
        if nm == "call" then
          local g = compile_term(ctx, a[1], env, out, d)
          return "GCALL(" .. g .. ", " .. nk .. ", " .. k .. ")"
        else
          local t = compile_term(ctx, a[1], env, out, d)
          local g = compile_term(ctx, a[2], env, out, d)
          local rr = compile_term(ctx, a[3], env, out, d)
          return "GFINDALL(" .. t .. ", " .. g .. ", " .. rr .. ", " ..
                 nk .. ", " .. k .. ")"
        end
      end
    end
    -- plain goal call: last 4 args are B L K C -> (terms..., n, cont)
    if an < 4 then refuse(ctx, "goal call with <4 args: " .. nm) end
    local parts = {}
    for i = 1, an - 4 do
      parts[#parts + 1] = compile_term(ctx, a[i], env, out, d)
    end
    local n = compile_value(ctx, a[an - 1], env, out, d)
    local k = compile_cont(ctx, a[an], env, out, d)
    parts[#parts + 1] = n
    parts[#parts + 1] = k
    return "NP[" .. string.format("%q", nm) .. "](" .. table.concat(parts, ", ") .. ")"
  end

  refuse(ctx, "unsupported form")
end

-- ---------------------------------------------------------------------------
-- lifting machinery (methods on ctx)
-- ---------------------------------------------------------------------------
local CtxMT = {}
CtxMT.__index = CtxMT

local function liftname(ctx, pfx)
  ctx.nlift = ctx.nlift + 1
  local fname = pfx .. ctx.nlift
  ctx.liftnames[#ctx.liftnames + 1] = fname
  return fname
end

-- closure-convert a let-bound freeze / lambda chain into a chunk-level fn.
-- A static referencing another static is fine (both are chunk-level fns):
-- the inner static's free vars are folded into THIS static's free vars so
-- they are in scope at the inner call sites.
function CtxMT.lift_static(ctx, name, params, body, env)
  local fname = liftname(ctx, "LF")
  local bound = {}
  for _, p in ipairs(params) do bound[p.name] = true end
  local fvs, fvseen = {}, {}
  local function addfv(vn)
    if bound[vn] or fvseen[vn] then return end
    fvseen[vn] = true
    local outer = env[vn]
    if not outer then return end
    if outer.kind == "static" then
      for _, f in ipairs(outer.fvs) do addfv(f) end
    elseif outer.kind == "vec" or outer.kind == "lock" then
      -- engine-implicit, dropped at use sites
    else
      fvs[#fvs + 1] = vn
    end
  end
  for _, vn in ipairs(freevars(body)) do addfv(vn) end
  local st = { kind = "static", fn = fname, params = params, fvs = fvs,
               body = body, env = env }
  -- emit the lifted definition; statics resolve through to chunk scope
  local penv = setmetatable({}, { __index = function(_, k)
    local b = env[k]
    if b and b.kind == "static" then return b end
    return nil
  end })
  local sig = {}
  for i, p in ipairs(params) do
    sig[#sig + 1] = "p" .. i
    penv[p.name] = { lua = "p" .. i, kind = "term" }
  end
  for i, vn in ipairs(fvs) do
    sig[#sig + 1] = "fv" .. i
    penv[vn] = { lua = "fv" .. i, kind = env[vn].kind }
  end
  local fbuf = {}
  local fval = compile_value(ctx, body, penv, fbuf, 1)
  local def = { fname .. " = function(" .. table.concat(sig, ", ") .. ")" }
  for _, l in ipairs(fbuf) do def[#def + 1] = l end
  def[#def + 1] = "  return " .. fval
  def[#def + 1] = "end"
  ctx.buf[#ctx.buf + 1] = table.concat(def, "\n")
  return st
end

-- direct invocation of a static (thaw GoTo / (GoTo a b))
function CtxMT.callstatic(ctx, st, call_args, env, out, d)
  local parts = {}
  for _, a in ipairs(call_args) do parts[#parts + 1] = a end
  for _, vn in ipairs(st.fvs) do
    local b = env[vn]
    if not b then refuse(ctx, "static fv out of scope: " .. vn) end
    parts[#parts + 1] = b.lua
  end
  return st.fn .. "(" .. table.concat(parts, ", ") .. ")"
end

-- (freeze E) in continuation position -> lifted cont fn + newcontN handle.
-- All captures must be numbers (term/count/cont/result-kind locals).
function CtxMT.lift_cont(ctx, body, env, out, d)
  local fname = liftname(ctx, "LK")
  local fvs = {}
  for _, vn in ipairs(freevars(body)) do
    if env[vn] then fvs[#fvs + 1] = vn end
  end
  -- statics referenced from the cont body are chunk-level fns whose OWN free
  -- vars must also be captured
  local capture, statics, seen = {}, {}, {}
  local function addcap(vn)
    if seen[vn] then return end
    seen[vn] = true
    local b = env[vn]
    if b.kind == "static" then
      statics[vn] = b
      for _, f in ipairs(b.fvs) do addcap(f) end
    elseif b.kind == "vec" or b.kind == "lock" then
      -- the prolog vector / lock vector are engine-implicit: dropped at
      -- every use site, so never captured
    else
      capture[#capture + 1] = vn
    end
  end
  for _, vn in ipairs(fvs) do addcap(vn) end

  local penv = setmetatable({}, { __index = function(_, k)
    -- statics resolve through to chunk scope
    local b = env[k]
    if b and b.kind == "static" then return b end
    return nil
  end })
  local fbuf = {}
  local decls = {}
  for i, vn in ipairs(capture) do
    local lv = "c" .. i
    decls[#decls + 1] = "local " .. lv .. " = CAPREF(base, " .. (i - 1) .. ")"
    penv[vn] = { lua = lv, kind = env[vn].kind }
  end
  local fval = compile_value(ctx, body, penv, fbuf, 1)
  local def = { fname .. " = function(base, h)" }
  for _, l in ipairs(decls) do def[#def + 1] = "  " .. l end
  for _, l in ipairs(fbuf) do def[#def + 1] = l end
  def[#def + 1] = "  return " .. fval
  def[#def + 1] = "end"
  ctx.buf[#ctx.buf + 1] = table.concat(def, "\n")

  local parts = { fname }
  for _, vn in ipairs(capture) do parts[#parts + 1] = env[vn].lua end
  local mk = (#capture <= 16) and ("NEWCONT" .. #capture) or "NEWCONTV"
  return mk .. "(" .. table.concat(parts, ", ") .. ")"
end

-- a zero-param static used as a continuation value: wrap into a handle
function CtxMT.mkhandle(ctx, st, out, d)
  -- captures = the static's free vars (numbers)
  if #st.fvs > 16 then refuse(ctx, "handle captures > 16") end
  local fname = liftname(ctx, "LH")
  local decls, parts = {}, { fname }
  local penv = setmetatable({}, { __index = st.env })
  local args = {}
  for i, vn in ipairs(st.fvs) do
    decls[#decls + 1] = "  local c" .. i .. " = CAPREF(base, " .. (i - 1) .. ")"
    args[#args + 1] = "c" .. i
    parts[#parts + 1] = st.env[vn].lua
  end
  local def = { fname .. " = function(base, h)" }
  for _, l in ipairs(decls) do def[#def + 1] = l end
  def[#def + 1] = "  return " .. st.fn .. "(" .. table.concat(args, ", ") .. ")"
  def[#def + 1] = "end"
  ctx.buf[#ctx.buf + 1] = table.concat(def, "\n")
  return "NEWCONT" .. #st.fvs .. "(" .. table.concat(parts, ", ") .. ")"
end

-- ---------------------------------------------------------------------------
-- top-level: translate a (define Name P1..Pk B L K C -> Body) form
-- ---------------------------------------------------------------------------
local CHUNK_PREAMBLE = [[
local E, NP, F, MAT, IMP = ...
local CONS, CAR, CDR, LZD = E.cons, E.car, E.cdr, E.lazyderef
local NEWVAR, POPVAR = E.newvar, E.popvar
local UNIFY, UNIFYOC, BIND1 = E.unify, E.unify_oc, E.bind1
local CUT, UNLOCK, LOCKOPEN = E.cut, E.unlock, E.lock_is_open
local INCINFS, THAW, CAPREF = E.incinfs, E.thawH, E.capref
local GVAR, GCALL, GFINDALL = E.g_var, E.g_call, E.g_findall
local NEWCONT0, NEWCONT1, NEWCONT2, NEWCONT3, NEWCONT4 =
  E.newcont0, E.newcont1, E.newcont2, E.newcont3, E.newcont4
local NEWCONT5, NEWCONT6, NEWCONT7, NEWCONT8 =
  E.newcont5, E.newcont6, E.newcont7, E.newcont8
local NEWCONT9, NEWCONT10, NEWCONT11, NEWCONT12 =
  E.newcont9, E.newcont10, E.newcont11, E.newcont12
local NEWCONT13, NEWCONT14, NEWCONT15, NEWCONT16 =
  E.newcont13, E.newcont14, E.newcont15, E.newcont16
local NEWCONTV = E.newcontV
local MAXINF = E.maxinf_exceeded
local VAR_BASE, CONS_BASE = E.VAR_BASE, E.CONS_BASE
]]

-- translate_core: shared by defprolog define-forms and the t-star driver
-- defuns. `allparams` is the full parameter list whose LAST FOUR entries are
-- the Vec / Lock / Count / Cont gensyms (the uniform CPS goal ABI).
local function translate_core(name, allparams, body)
  local np = #allparams
  assert(np >= 4, "prolog fn must have at least the B L K C params")
  local nparams = np - 4
  local Bv, Lv, Kv, Cv = allparams[np - 3], allparams[np - 2],
                         allparams[np - 1], allparams[np]

  local ctx = setmetatable({
    buf = {}, nlift = 0, nlocal = 0, fail = {}, liftnames = {},
  }, CtxMT)

  local env = {}
  local sig = {}
  for i = 1, nparams do
    local pv = allparams[i]
    sig[#sig + 1] = "a" .. i
    env[pv.name] = { lua = "a" .. i, kind = "term" }
  end
  sig[#sig + 1] = "n"
  sig[#sig + 1] = "cont"
  env[Bv.name] = { lua = "B_UNUSED", kind = "vec" }
  env[Lv.name] = { lua = "L_UNUSED", kind = "lock" }
  env[Kv.name] = { lua = "n", kind = "count" }
  env[Cv.name] = { lua = "cont", kind = "cont" }

  local mainbuf = {}
  local ok, val = pcall(compile_value, ctx, body, env, mainbuf, 1)
  if not ok then
    if val == ctx.fail then
      return nil, ctx.failed
    end
    return nil, tostring(val)
  end

  if #ctx.liftnames > 150 then
    return nil, "too many lifted functions (" .. #ctx.liftnames .. ")"
  end
  local src = { CHUNK_PREAMBLE }
  if #ctx.liftnames > 0 then
    src[#src + 1] = "local " .. table.concat(ctx.liftnames, ", ")
  end
  for _, def in ipairs(ctx.buf) do src[#src + 1] = def end
  src[#src + 1] = "return function(" .. table.concat(sig, ", ") .. ")"
  for _, l in ipairs(mainbuf) do src[#src + 1] = l end
  src[#src + 1] = "  return " .. val
  src[#src + 1] = "end"
  local source = table.concat(src, "\n")

  local chunk, err = loadstring(source, "@prolog:" .. name)
  if not chunk then
    return nil, "luagen: " .. tostring(err) .. "\n" .. source
  end
  local fn = chunk(E, NP, F, E.materialize, E.import_cached)
  return fn, nil, source
end
M.translate_core = translate_core

-- translate a (define Name P1..Pk B L K C -> Body) form (defprolog output)
local function translate(name, defineForm)
  local parts = lst2tbl(defineForm)
  assert(parts[1] == SYM["define"], "not a define form")
  local arrow
  for i = 3, #parts do
    if parts[i] == SYM["->"] then arrow = i; break end
  end
  assert(arrow and arrow >= 7, "malformed prolog define")
  local body = parts[arrow + 1]
  local allparams = {}
  for i = 3, arrow - 1 do allparams[#allparams + 1] = parts[i] end
  return translate_core(name, allparams, body)
end

-- translate a (defun name (p1..pk V L K C) body) form (the t-star drivers)
function M.translate_defun(defunForm)
  local parts = lst2tbl(defunForm)
  assert(parts[1] == SYM["defun"], "not a defun")
  local name = sname(parts[2])
  local allparams = lst2tbl(parts[3])
  local body = parts[4]
  local fn, err, src = translate_core(name, allparams, body)
  return fn, err, src, name
end

-- ---------------------------------------------------------------------------
-- runtime support: import with identity pvar mapping (materialize . import
-- must be the identity on arena terms)
-- ---------------------------------------------------------------------------
function M.import_value(x)
  return E.import(x, E.identity_varmap)
end

-- ---------------------------------------------------------------------------
-- registry + wrapper
-- ---------------------------------------------------------------------------
M.registry = {}     -- name -> { form=..., fn=..., err=..., src=... }

-- LAZY translation: registration just records the define form; the actual
-- KL->Lua translation (incl. guard-defun evals) runs on FIRST NativePred
-- dispatch via NP's __index. The suite compiles hundreds of datatypes it
-- never typechecks with — eager translation made the full suite slower.
local function register(namesym, defineForm)
  local name = sname(namesym)
  M.registry[name] = { form = defineForm }
  rawset(NP, name, nil)   -- invalidate any previous (re)definition
end

local function force_translate(name)
  local r = M.registry[name]
  if not r or r.done then return r and r.fn end
  r.done = true
  local fn, err, src = translate(name, r.form)
  r.fn, r.err, r.src = fn, err, src
  if not fn and os.getenv("SHEN_PROLOG_DEBUG") then
    io.stderr:write("native prolog compile failed for ", name, ": ",
                    tostring(err), "\n")
  end
  return fn
end
M.force_translate = force_translate

-- ---------------------------------------------------------------------------
-- native query routing for prolog?
-- ---------------------------------------------------------------------------
local function body_pred_names(body)
  -- returns list of predicate-name strings, or nil if the body is not
  -- natively routable (call/findall present, or non-cons literal)
  local names = {}
  local l = body
  while is_cons(l) do
    local lit = l[1]
    if lit == SYM["!"] then
      -- fine
    elseif is_cons(lit) and is_sym(lit[1]) then
      local nm = sname(lit[1])
      if nm == "call" or nm == "findall" then return nil end
      if not BUILTIN_GOALS[nm] then names[#names + 1] = nm end
    else
      return nil
    end
    l = l[2]
  end
  return names
end

local query_runners = {}   -- arity -> F name

local function native_query_expansion(body)
  local names = body_pred_names(body)
  if not names then return nil end
  for _, nm in ipairs(names) do
    if not NP[nm] then return nil end
  end
  local received = lst2tbl(F["shen.received"](body))
  if #received > 3 then return nil end
  -- synthetic one-clause predicate:  qname Rec1..Reck <-- body ;
  local qsym = F["gensym"](SYM["shen.lua-query"])
  local toks = NIL
  toks = R.cons(SYM[";"], toks)
  local bl = lst2tbl(body)
  for i = #bl, 1, -1 do toks = R.cons(bl[i], toks) end
  toks = R.cons(SYM["<--"], toks)
  for i = #received, 1, -1 do toks = R.cons(received[i], toks) end
  -- run the legacy compiler (through the wrapper -> native registration)
  F["shen.compile-prolog"](qsym, toks)
  local qname = sname(qsym)
  if not NP[qname] then return nil end
  -- expansion: (shen.lua-run-queryK "qname" Rec1 .. Reck)
  local runner = query_runners[#received]
  local form = NIL
  for i = #received, 1, -1 do form = R.cons(received[i], form) end
  form = R.cons(qname, form)
  form = R.cons(R.intern(runner), form)
  return form
end

local function run_query(qname, ...)
  local fn = NP[qname]
  if not fn then error("native prolog query lost: " .. qname) end
  local q = E.query_begin()
  local done = E.newcont0(function() return true end)
  local nargs = select("#", ...)
  local ok, r
  if nargs == 0 then
    ok, r = pcall(fn, 0, done)
  elseif nargs == 1 then
    ok, r = pcall(fn, M.import_value((...)), 0, done)
  elseif nargs == 2 then
    local x, y = ...
    ok, r = pcall(fn, M.import_value(x), M.import_value(y), 0, done)
  else
    local x, y, z = ...
    ok, r = pcall(fn, M.import_value(x), M.import_value(y),
                  M.import_value(z), 0, done)
  end
  E.query_end(q)
  if not ok then error(r, 0) end
  return r
end

-- ---------------------------------------------------------------------------
-- engine builtins that need the dispatch table: call / findall
-- ---------------------------------------------------------------------------
local function install_dispatch_builtins()
  -- (call G ...): G derefs to a list term (pred a1..ak) -> NativePred dispatch
  function E.g_call(g, n, cont)
    local d = E.lazyderef(g)
    if not (d >= E.CONS_BASE) then
      error("native call: goal is not a structure")
    end
    local head = E.lazyderef(E.car(d))
    local hv = E.atomval(head)
    if getmt(hv) ~= Symbol then
      error("native call: goal head is not a symbol")
    end
    local fn = NP[hv.name]
    if not fn then
      error("native call: no native predicate " .. hv.name)
    end
    local args, an = {}, 0
    local rest = E.lazyderef(E.cdr(d))
    while rest >= E.CONS_BASE do
      an = an + 1; args[an] = E.car(rest)
      rest = E.lazyderef(E.cdr(rest))
    end
    E.incinfs()
    if an == 0 then return fn(n, cont)
    elseif an == 1 then return fn(args[1], n, cont)
    elseif an == 2 then return fn(args[1], args[2], n, cont)
    elseif an == 3 then return fn(args[1], args[2], args[3], n, cont)
    elseif an == 4 then return fn(args[1], args[2], args[3], args[4], n, cont)
    else return fn(unpack(args, 1, an), n, cont) end
  end

  -- (findall Template Goal Result ...): enumerate all solutions of Goal,
  -- collecting (materialized) Template instances in reverse discovery order
  -- (matching legacy shen.overbind's prepend), then is! Result.
  function E.g_findall(tmpl, goal, result, n, cont)
    local sols, ns = {}, 0
    local collector = E.newcont0(function()
      ns = ns + 1
      sols[ns] = E.materialize(tmpl)
      return false   -- force backtracking to enumerate everything
    end)
    E.g_call(goal, n, collector)
    -- build the (reversed) solution list as a Shen value, import, unify
    local acc = NIL
    for i = 1, ns do acc = R.cons(sols[i], acc) end
    return E.unify_oc(result, M.import_value(acc), cont)
  end
end

-- ---------------------------------------------------------------------------
-- install
-- ---------------------------------------------------------------------------
function M.install(Pmod, Emod)
  P, E = Pmod, Emod
  F = P.F
  NP = E.NativePred
  M.NP = NP

  -- popvar for the translated shen.gc
  if not E.popvar then
    error("prolog_engine must expose popvar")
  end

  install_dispatch_builtins()

  -- NP lazily translates registered predicates on first dispatch
  setmetatable(NP, { __index = function(t, name)
    local fn = force_translate(name)
    rawset(t, name, fn)   -- cache (nil stays a miss; registry marks done)
    return fn
  end })

  -- wrapper: dual registration (record only; translation deferred)
  local orig_cp = F["shen.compile-prolog"]
  if not orig_cp then error("shen.compile-prolog not loaded yet") end
  F["shen.compile-prolog"] = function(namesym, clauses)
    local defineForm = orig_cp(namesym, clauses)
    register(namesym, defineForm)
    return defineForm
  end
  P.FA[F["shen.compile-prolog"]] = 2

  -- query runners (arity-specific so KL call sites compile to direct calls)
  for k = 0, 3 do
    local fname = "shen.lua-run-query" .. k
    query_runners[k] = fname
    F[fname] = function(qname, ...) return run_query(qname, ...) end
    P.FA[F[fname]] = k + 1
    C.ARITY[fname] = k + 1
  end

  -- prolog? routing (unless disabled)
  if os.getenv("SHEN_PROLOG_NATIVE") ~= "off" then
    local orig_callp = F["shen.call-prolog"]
    if orig_callp then
      F["shen.call-prolog"] = function(body)
        local ok, expansion = pcall(native_query_expansion, body)
        if ok and expansion then return expansion end
        return orig_callp(body)
      end
      P.FA[F["shen.call-prolog"]] = 1
    end
  end

  M.run_query = run_query
end

return M
