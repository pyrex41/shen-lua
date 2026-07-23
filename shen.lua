-- shen.lua : the public embedding API for shen-lua.
--
--   local shen = require("shen")
--   shen.boot{quiet=true}
--   shen.eval('(define square X -> (* X X))')
--   print(shen.call("square", 9))            --> 81
--
-- A thin facade over boot.lua (kernel loader / initialise), prims.lua
-- (function table F + apply/curry machinery) and runtime.lua (data rep).
-- Everything here delegates to the kernel's own entry points: the reader is
-- (read-from-string), evaluation is (eval), application is P.APP — no
-- machinery is reimplemented.

local R = require("runtime")
local P = require("boot")   -- boot.lua returns the prims module P, fully wired

local shen = {}

-- Expose the underlying layers for advanced embedding (function table P.F,
-- globals P.GLOBALS, reader R.read_all, printer R.to_str, ...).
shen.prims   = P
shen.runtime = R

-- ---- boot ------------------------------------------------------------------
-- Load the kernel (bytecode cache / embedded bundle payload make this fast)
-- and run (shen.initialise). Idempotent. opts:
--   quiet   = true  -> hush anything printed DURING boot (banner/echo);
--                      *hush* is restored afterwards. For a permanently
--                      silent session do shen.eval("(hush +)") — in 41.2 the
--                      *hush* global gates `pr` itself, i.e. ALL output.
--   verbose = true  -> log each kernel file to stderr as it loads
--   jit     = false -> disable the LuaJIT compiler before loading the kernel
--                      (jit.off()). Mitigates the aarch64 boot-time trace
--                      compiler SIGSEGV (issue #43); equivalent to setting
--                      SHEN_JIT=off in the environment. No-op on PUC Lua / when
--                      the JIT is already off. Leave unset to keep the JIT on.
local booted = false
function shen.boot(opts)
  if booted then return shen end
  opts = opts or {}
  if opts.jit == false then P.disable_jit() end
  local hush0
  if opts.quiet then
    hush0 = P.GLOBALS["*hush*"]
    P.GLOBALS["*hush*"] = true
  end
  P.load_kernel(opts.verbose or false)
  P.initialise()   -- (shen.initialise-environment) resets *hush* to false
  if opts.quiet and hush0 ~= nil then P.GLOBALS["*hush*"] = hush0 end
  booted = true
  return shen
end

local function ensure_boot()
  if not booted then shen.boot() end
end

-- ---- eval ------------------------------------------------------------------
-- Evaluate a string of SHEN source (full Shen syntax, not KLambda): read it
-- with the kernel's own reader (read-from-string -> list of forms) and (eval)
-- each form through the real macroexpand/shen->kl pipeline. Returns the value
-- of the last form (a Shen value: number/string/boolean/symbol/cons/...).
function shen.eval(src)
  ensure_boot()
  local forms = P.F["read-from-string"](src)
  local last
  while R.is_cons(forms) do
    last = P.F["eval"](forms[1])
    forms = forms[2]
  end
  return last
end

-- ---- call / fn ------------------------------------------------------------
-- Call the Shen function `name` with Lua values as arguments. Arity is
-- handled by the existing P.APP machinery: fewer args than the function's
-- arity returns a curried partial application; more args applies the result
-- to the rest.
function shen.call(name, ...)
  ensure_boot()
  local fn = P.F[name]
  if fn == nil then error("shen.call: undefined function: " .. tostring(name), 2) end
  return P.APP(fn, ...)
end

-- A plain Lua callable for the Shen function `name`. The F-table lookup is
-- per-call, so the callable tracks redefinitions (and may be taken before the
-- function is defined).
function shen.fn(name)
  return function(...)
    ensure_boot()
    local fn = P.F[name]
    if fn == nil then error("shen.fn: undefined function: " .. tostring(name), 2) end
    return P.APP(fn, ...)
  end
end

-- ---- typecheck --------------------------------------------------------------
-- Ask the kernel's sequent-calculus typechecker whether `expr` inhabits the
-- type `ty`. Returns the inferred type (a Shen value — symbol or cons tree)
-- on success, false on failure. Both arguments are STRINGS of Shen source:
-- the expression is READ, never evaluated (the typechecker judges syntax —
-- `shen.typecheck("[1 2]", "(list number)")`, not an evaluated list value).
-- `ty` may use type variables: shen.typecheck("[1 2]", "A") infers.
--
-- Three kernel traps this helper absorbs, all learned in production embeds:
--   1. (shen.typecheck X A) takes the SYNTAX TREE of X — the form the reader
--      produces — not X's value. Passing an evaluated value silently returns
--      false for anything non-atomic.
--   2. The reader cooks expression and type positions DIFFERENTLY, so the
--      two strings must be read together as one "EXPR : TYPE" triple — the
--      shape (load)'s work-through consumes. In expression position a
--      compound form of three or more elements is curried into application
--      syntax: (may alice read doc1) read standalone becomes
--      ((((fn may) alice) read) doc1), and a type in that shape makes every
--      check silently return false. Only the form after : is kept as raw
--      type syntax. ((list number) survives standalone reading — currying
--      starts at two arguments — which is how this bug hid behind simple
--      list types.)
--   3. The kernel's inference counter (shen.*infs*) is GLOBAL and cumulative,
--      and shen.typecheck never resets it; only the REPL's toplevel does.
--      A long-lived embedder calling the kernel entry point directly crosses
--      *maxinferences* (default 1,000,000) after enough checks, after which
--      EVERY check fails (the native engine throws maxinfexceeded). This
--      helper resets the counter per call, making *maxinferences* a
--      per-check inference budget: a check that exceeds it returns false.
--      Override the budget with shen.eval("(set shen.*maxinferences* N)").
function shen.typecheck(expr, ty)
  ensure_boot()
  local forms = P.F["read-from-string"](expr .. " : " .. ty)
  local elems, n = {}, 0
  while R.is_cons(forms) do
    n = n + 1
    elems[n] = forms[1]
    forms = forms[2]
  end
  if n ~= 3 or elems[2] ~= R.intern(":") then
    error("shen.typecheck: expected one expression and one type in \""
          .. tostring(expr) .. " : " .. tostring(ty) .. "\"", 2)
  end
  P.GLOBALS["shen.*infs*"] = 0
  local ok, res = pcall(P.F["shen.typecheck"], elems[1], elems[3])
  if not ok then return false end   -- budget exhausted or kernel error: fail closed
  return res
end

-- ---- marshaling helpers -----------------------------------------------------
-- Lua array -> Shen cons list (shallow; elements are passed through as-is).
function shen.list(arr)
  return R.from_table(arr)
end

-- Shen cons list -> Lua array (shallow). Errors on an improper list tail.
function shen.totable(l)
  local out, i = {}, 0
  while R.is_cons(l) do
    i = i + 1
    out[i] = l[1]
    l = l[2]
  end
  if l ~= R.NIL then error("shen.totable: improper list (tail " .. R.to_str(l) .. ")", 2) end
  return out
end

-- Interned Shen symbol for the string s (identity-eq with kernel symbols).
function shen.sym(s)
  return R.intern(s)
end

-- Value of the Shen global `name` (e.g. "*version*"), via the (value) prim —
-- errors like Shen does if the global is unbound.
function shen.value(name)
  ensure_boot()
  return P.F["value"](R.intern(name))
end

-- Render any Shen value as a display string (the port's printer).
function shen.tostring(x)
  return R.to_str(x)
end

return shen
