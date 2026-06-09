-- typecheck_native.lua — the t-star.kl typecheck driver on the soa32 engine.
--
-- STRATEGY: the ~16 CPS driver functions in klambda/t-star.kl are written in
-- the SAME closed goal vocabulary as compiled defprolog output (they were
-- hand-written to the identical ABI), so we do not hand-port them — we run
-- prolog_compile's translate_core directly over their defun source, read
-- from klambda/t-star.kl at install time. Clause order, cut structure, and
-- guard semantics are inherited mechanically from the kernel source.
--
-- Four functions need native hand-ports because they escape the vocabulary:
--   shen.typecheck             — query entry/exit (engine lifecycle, boundary
--                                conversion, infs flush, error restore)
--   shen.lookupsig / shen.sigf — the legacy path applies an opaque curried
--                                closure stored in *sigf* by `declare`; we
--                                wrap F["declare"] to record name -> raw
--                                type expr and re-implement: freshen type
--                                vars to arena vars + unify_oc (exactly what
--                                shen.prolog-abstraction's closure does)
--   shen.search-user-datatypes — applies the curried datatype closure from
--                                *datatypes*; natively we dispatch
--                                NativePred[TypeName] (entries are
--                                (TypeName . fn) assocs; rules->prolog
--                                defines the predicate under TypeName)
--   shen.show                  — spy display path (plain side-effects;
--                                materialize + legacy helpers)
--
-- WHOLE-QUERY FALLBACK: F["shen.typecheck"] checks that every driver fn and
-- every current datatype predicate is native before entering the engine;
-- otherwise it delegates to the captured legacy typecheck. Correctness never
-- depends on native coverage.

local R = require("runtime")

local M = {}

local P, E, F, NP, PC

local Symbol, Cons, NIL = R.Symbol, R.Cons, R.NIL
local getmt = getmetatable

-- t-star driver functions fed through the translator
local DRIVER_FNS = {
  ["shen.insert-prolog-variables"] = true,
  ["shen.toplevel-forms"] = true,
  ["shen.signal-def"] = true,
  ["shen.system-S"] = true,
  ["shen.system-S-h"] = true,
  ["shen.primitive"] = true,
  ["shen.by-hypothesis"] = true,
  ["shen.l-rules"] = true,
  ["shen.t*"] = true,
  ["shen.t*-rules"] = true,
  ["shen.t*-rule"] = true,
  ["shen.t*-rule-h"] = true,
  ["shen.t*-correct"] = true,
  ["shen.t*-integrity"] = true,
  ["shen.p-hyps"] = true,
  ["shen.myassume"] = true,
}

-- ---------------------------------------------------------------------------
-- NativeSig: declare wrapper
-- ---------------------------------------------------------------------------
local NativeSig = {}   -- function-name Symbol -> raw type expr (Shen value)
M.NativeSig = NativeSig

-- freshen a declared type: uppercase-symbol type variables -> fresh arena
-- vars (one per distinct name per invocation); everything else as atoms/cells.
-- Mirrors shen.prolog-abstraction: stpart over extract-vars, then the
-- rcons_form body referencing the let-bound fresh pvars.
local function is_typevar(x)
  if getmt(x) ~= Symbol then return false end
  local c = x.name:byte(1)
  return c ~= nil and c >= 65 and c <= 90
end

local function import_fresh(x, fresh)
  if getmt(x) == Cons then
    return E.cons(import_fresh(x[1], fresh), import_fresh(x[2], fresh))
  elseif is_typevar(x) then
    local v = fresh[x]
    if not v then v = E.newvar(); fresh[x] = v end
    return v
  else
    return E.atom(x)
  end
end

-- ---------------------------------------------------------------------------
-- kernel signature extraction (init.kl)
-- ---------------------------------------------------------------------------
-- The 162 kernel signatures are not declared at runtime; init.kl's
-- shen.initialise-signedfuncs assocs raw curried CPS lambdas into *sigf*.
-- Every one has the uniform shape
--   (lambda V (lambda B (lambda L (lambda Key (lambda C
--     [let X (shen.newpv B) (shen.gc B ...)]*  (is! V TYPE B L Key C))))))
-- where TYPE is an rcons constructor tree over the let-bound type variables.
-- We symbolically evaluate TYPE back into a Shen type expr (vars stay as
-- their uppercase symbols, which import_fresh re-freshens per lookup).
local SYM_lambda, SYM_let, SYM_cons, SYM_intern, SYM_isbang
local function init_syms()
  SYM_lambda = R.intern("lambda")
  SYM_let = R.intern("let")
  SYM_cons = R.intern("cons")
  SYM_intern = R.intern("intern")
  SYM_isbang = R.intern("is!")
end

local function evalrcons(e)
  if getmt(e) == Cons then
    local h = e[1]
    if h == SYM_cons then
      return R.cons(evalrcons(e[2][1]), evalrcons(e[2][2][1]))
    elseif h == SYM_intern and type(e[2][1]) == "string" then
      return R.intern(e[2][1])
    end
    error("unrecognized rcons form")
  end
  return e   -- symbol (type var or constant), number, string, boolean, NIL
end

local function extract_sig(lam)
  -- unwrap the 5 lambdas
  local body = lam
  for _ = 1, 5 do
    if not (getmt(body) == Cons and body[1] == SYM_lambda) then return nil end
    body = body[2][2][1]
  end
  -- unwrap (let X (shen.newpv B) (shen.gc B E)) chains -> E
  while getmt(body) == Cons and body[1] == SYM_let do
    local letbody = body[2][2][2][1]          -- (shen.gc B E)
    if getmt(letbody) == Cons and getmt(letbody[2]) == Cons
       and getmt(letbody[2][2]) == Cons then
      body = letbody[2][2][1]                 -- E
    else
      return nil
    end
  end
  if getmt(body) == Cons and body[1] == SYM_isbang then
    local ok, t = pcall(evalrcons, body[2][2][1])
    if ok then return t end
  end
  return nil
end

local function harvest_init_sigs(kldir)
  init_syms()
  local fh = io.open(kldir .. "/init.kl", "r")
  if not fh then return false end
  local src = fh:read("*a"); fh:close()
  local SYM_assoc = R.intern("shen.assoc->")
  local total, got = 0, 0
  local function walk(e)
    if getmt(e) ~= Cons then return end
    if e[1] == SYM_assoc and getmt(e[2]) == Cons then
      local name = e[2][1]
      local lam = e[2][2][1]
      if getmt(name) == Symbol then
        total = total + 1
        local t = extract_sig(lam)
        if t ~= nil then
          NativeSig[name] = t
          got = got + 1
        end
        return
      end
    end
    local l = e
    while getmt(l) == Cons do
      walk(l[1])
      l = l[2]
    end
  end
  local SYM_defun = R.intern("defun")
  local target = R.intern("shen.initialise-signedfuncs")
  for _, form in ipairs(R.read_all(src)) do
    if getmt(form) == Cons and form[1] == SYM_defun and form[2][1] == target then
      walk(form[2][2][2][1])
    end
  end
  M.sig_total, M.sig_got = total, got
  return total > 0 and total == got
end

-- ---------------------------------------------------------------------------
-- hand-ported drivers
-- ---------------------------------------------------------------------------
local function install_handports()
  -- shen.lookupsig (t-star.kl:52) + shen.sigf (t-star.kl:54) fused:
  -- assoc miss -> false; hit -> unify_oc(goal type, freshened raw sig type)
  NP["shen.lookupsig"] = function(name_t, type_t, n, cont)
    if not E.lock_is_open() then return false end
    E.incinfs()
    local nm = E.atomval(E.lazyderef(name_t))
    if getmt(nm) ~= Symbol then return false end
    local sig = NativeSig[nm]
    if sig == nil then return false end
    -- the closure body: per-var newpv (stpart) then (is! Type SigType).
    -- is! = lzy=! = occurs-checked unify, goal type first.
    E.incinfs()
    return E.unify_oc(type_t, import_fresh(sig, {}), cont)
  end

  -- shen.search-user-datatypes (t-star.kl:60): walk the (TypeName . fn)
  -- assoc list in order, dispatching NativePred[TypeName] with the goal ABI
  -- ((fn goal) assumptions) vec lock count cont -> fn(goal, assum, n, cont).
  local sud
  sud = function(goal_t, assum_t, dts_t, n, cont)
    if not E.lock_is_open() then return false end
    local l = E.lazyderef(dts_t)
    if l < E.CONS_BASE then return false end
    local entry = E.lazyderef(E.car(l))
    local r = false
    if entry >= E.CONS_BASE then
      local nm = E.atomval(E.lazyderef(E.car(entry)))
      local fn = (getmt(nm) == Symbol) and NP[nm.name] or nil
      if fn == nil then
        -- untranslated datatype predicate mid-query: cannot continue natively
        error("native typecheck: datatype predicate not native: " ..
              tostring(nm), 0)
      end
      E.incinfs()
      r = fn(goal_t, assum_t, n, cont)
    end
    if r ~= false then return r end
    if not E.lock_is_open() then return false end
    -- clause 2: recurse on the tail
    E.incinfs()
    return sud(goal_t, assum_t, E.cdr(l), n, cont)
  end
  NP["shen.search-user-datatypes"] = sud

  -- shen.show (t-star.kl:25): spy display; materialize and reuse the plain
  -- (non-CPS) legacy display helpers, then fail (it always returns false).
  NP["shen.show"] = function(goal_t, assum_t, n, cont)
    F["shen.line"]()
    F["shen.show-p"](E.materialize(goal_t))
    F["nl"](2)
    F["shen.show-assumptions"](E.materialize(assum_t), 1)
    F["shen.pause-for-user"]()
    return false
  end
end

-- ---------------------------------------------------------------------------
-- coverage check: can this typecheck run natively right now?
-- ---------------------------------------------------------------------------
local datatypes_ok_cache, datatypes_cache_key = false, nil
local function datatypes_all_native()
  local dts = P.GLOBALS["shen.*datatypes*"]
  if dts == datatypes_cache_key then return datatypes_ok_cache end
  local l = dts
  local ok = true
  while getmt(l) == Cons do
    local entry = l[1]
    if getmt(entry) == Cons and getmt(entry[1]) == Symbol then
      if not NP[entry[1].name] then ok = false; break end
    else
      ok = false; break
    end
    l = l[2]
  end
  datatypes_cache_key, datatypes_ok_cache = dts, ok
  return ok
end

-- ---------------------------------------------------------------------------
-- the typecheck entry (t-star.kl:1)
-- ---------------------------------------------------------------------------
local function native_typecheck(expr, type_)
  -- pre-processing identical to the legacy entry (plain helpers via F)
  local vars = F["shen.extract-vars"](type_)
  local rect = F["shen.rectify-type"](type_)
  local curried = F["shen.curry"](expr)

  local q = E.query_begin()
  E.setinfs(P.GLOBALS["shen.*infs*"] or 0)

  local A = E.newvar()
  local toplevel = NP["shen.toplevel-forms"]
  local insertpv = NP["shen.insert-prolog-variables"]
  local imp = E.import_cached

  local ok, result = pcall(function()
    E.incinfs()
    local kret = E.newcont1(function(base)
      return E.materialize(E.capref(base, 0))
    end, A)
    local ktop = E.newcont_spill(function(_, h)
      local sp = E.spill(h)
      return toplevel(sp[1], sp[2], sp[3], sp[4])
    end, { imp(curried), A, 0, kret })
    return insertpv(imp(vars), imp(rect), A, 0, ktop)
  end)

  P.GLOBALS["shen.*infs*"] = E.getinfs()
  E.query_end(q)
  if not ok then
    -- popvar bookkeeping past query_end is already restored; rethrow
    error(result, 0)
  end
  return result
end

-- ---------------------------------------------------------------------------
-- install
-- ---------------------------------------------------------------------------
function M.install(Pmod, Emod)
  P, E = Pmod, Emod
  F, NP = P.F, E.NativePred
  PC = require("prolog_compile")

  -- 1) translate the driver defuns straight out of klambda/t-star.kl
  local kldir = os.getenv("SHEN_KL_DIR") or "klambda"
  local fh = io.open(kldir .. "/t-star.kl", "r")
  if not fh then
    -- vendored kernel not found relative to cwd; try boot's other candidates
    for _, c in ipairs({ "../cl-source/ShenOSKernel-41.1/klambda" }) do
      fh = io.open(c .. "/t-star.kl", "r")
      if fh then kldir = c; break end
    end
  end
  if not fh then
    error("typecheck_native: cannot locate t-star.kl")
  end
  local src = fh:read("*a"); fh:close()

  -- kernel signatures from init.kl; incomplete harvest forces legacy fallback
  M.sigs_complete = harvest_init_sigs(kldir)

  M.translate_errors = {}
  local n_ok, n_fail = 0, 0
  for _, form in ipairs(R.read_all(src)) do
    if getmt(form) == Cons and getmt(form[2][1]) == Symbol
       and DRIVER_FNS[form[2][1].name] then
      local fn, err = PC.translate_defun(form)
      local name = form[2][1].name
      if fn then
        NP[name] = fn
        n_ok = n_ok + 1
      else
        M.translate_errors[name] = err
        n_fail = n_fail + 1
      end
    end
  end
  M.n_ok, M.n_fail = n_ok, n_fail

  -- 2) hand-ports
  install_handports()

  -- 3) declare wrapper: record raw type exprs for native lookupsig.
  --    boot.lua installs the engine before initialise(), so every kernel
  --    declare is captured. Delegates unconditionally (legacy *sigf* stays
  --    the source of truth for the legacy engine).
  local orig_declare = F["declare"]
  if orig_declare then
    F["declare"] = function(name, type_)
      NativeSig[name] = type_
      return orig_declare(name, type_)
    end
    P.FA[F["declare"]] = 2
  end

  -- destroy (sys.kl:246) unassocs from *sigf*; mirror in NativeSig so the
  -- native lookupsig agrees that the signature is gone
  local orig_destroy = F["destroy"]
  if orig_destroy then
    F["destroy"] = function(name)
      NativeSig[name] = nil
      return orig_destroy(name)
    end
    P.FA[F["destroy"]] = 1
  end

  -- 4) typecheck override with whole-query fallback. Native requires: all
  --    drivers translated, and every registered datatype predicate native.
  local orig_typecheck_ref = nil  -- resolved lazily: t-star loads before us
  local function typecheck_dispatch(expr, type_)
    if n_fail == 0 and M.sigs_complete and datatypes_all_native()
       and P.GLOBALS["shen.*spy*"] ~= true then
      return native_typecheck(expr, type_)
    end
    return orig_typecheck_ref(expr, type_)
  end
  orig_typecheck_ref = F["shen.typecheck"]
  if not orig_typecheck_ref then
    error("typecheck_native: shen.typecheck not loaded")
  end
  if os.getenv("SHEN_TYPECHECK_NATIVE") ~= "off" then
    F["shen.typecheck"] = typecheck_dispatch
    P.FA[F["shen.typecheck"]] = 2
  end
  M.native_typecheck = native_typecheck
end

return M
