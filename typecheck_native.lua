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
-- Native-path fallback reporting. SHEN_TYPECHECK_NATIVE=require turns a
-- fallback into an error (for CI and kernel bring-up); otherwise each distinct
-- cause is reported once on stderr and the kernel's KL typechecker answers.
local REQUIRE_NATIVE = os.getenv("SHEN_TYPECHECK_NATIVE") == "require"
local reported = {}
local function fallback_notice(key, lines)
  local msg = "native typechecker unavailable, using the kernel's KL "
    .. "typechecker: " .. table.concat(lines, "; ")
  if not reported[key] then
    reported[key] = true
    io.stderr:write("shen-lua: ", msg, "\n")
  end
  if REQUIRE_NATIVE then
    P.ERR("SHEN_TYPECHECK_NATIVE=require: " .. msg)
  end
end

-- the hand-ported predicates (install_handports) a driver may call by name
local HANDPORTED = {
  ["shen.lookupsig"] = true,
  ["shen.search-user-datatypes"] = true,
  ["shen.show"] = true,
}

-- the drivers native_typecheck enters directly; the kernel must define them
local ENTRY_FNS = {
  ["shen.insert-prolog-variables"] = true,
  ["shen.toplevel-forms"] = true,
}

-- t-star driver functions fed through the translator: the roots of the
-- driver closure computed in ensure_drivers (which also translates every
-- t-star.kl defun these call, e.g. a deref-hoisted kernel's
-- shen.by-hypothesis-h)
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
-- Kernel conformance
--
-- The drivers above are TRANSLATED from the kernel's own t-star.kl, so they
-- follow the kernel. Everything else on the native path is a hand-written
-- reimplementation of a kernel defun: the hand-ported drivers (shen.typecheck,
-- lookupsig/sigf, search-user-datatypes, show, maxinfexceeded?) and the
-- prolog.kl primitives and builtin goals the engine and translator implement
-- natively (prolog_engine.lua, prolog_compile.lua). If the kernel changes one
-- of those, the native typechecker would keep running the OLD semantics and
-- could answer differently from the kernel without any error. So before the
-- first native typecheck, every such defun in the loaded kernel is
-- fingerprinted and compared against the versions this port implements. A
-- mismatch turns the native typechecker off for the process: typechecks run
-- the kernel's own KL definitions (correct by construction, slower) and one
-- line on stderr names the defun. SHEN_TYPECHECK_NATIVE=require raises an
-- error instead.
--
-- The fingerprint is a hash of the defun's KL form with its gensym variables
-- (V123 / W123 / Z123) renamed in first-occurrence order, so regenerating the
-- kernel (which renumbers every later gensym) does not change it. Regenerate
-- the table with scripts/kernel-fingerprints.lua when vendoring a kernel, and
-- only after checking that the native code still implements the new defun.
-- ---------------------------------------------------------------------------
local REIMPLEMENTED = {
  -- t-star.kl hand ports
  { "t-star", "shen.typecheck" },
  { "t-star", "shen.lookupsig" },
  { "t-star", "shen.sigf" },
  { "t-star", "shen.search-user-datatypes" },
  { "t-star", "shen.search-user-datatypes-h" },   -- deref-hoisted kernels
  { "t-star", "shen.show" },
  { "t-star", "shen.maxinfexceeded?" },
  -- prolog.kl primitives the translator lowers and the engine implements
  { "prolog", "shen.deref" },
  { "prolog", "shen.lazyderef" },
  { "prolog", "shen.newpv" },
  { "prolog", "shen.gc" },
  { "prolog", "shen.pvar?" },
  { "prolog", "shen.bind!" },
  { "prolog", "shen.bindv" },
  { "prolog", "shen.unwind" },
  { "prolog", "shen.incinfs" },
  { "prolog", "shen.cut" },
  { "prolog", "shen.unlock" },
  { "prolog", "shen.unlocked?" },
  { "prolog", "shen.lock" },
  { "prolog", "shen.fits?" },
  { "prolog", "shen.lzy=" },
  { "prolog", "shen.lzy=!" },
  { "prolog", "shen.occurs-check?" },
  -- prolog.kl builtin goals (prolog_compile.lua BUILTIN_GOALS)
  { "prolog", "when" },
  { "prolog", "is" },
  { "prolog", "is!" },
  { "prolog", "bind" },
  { "prolog", "var?" },
  { "prolog", "return" },
  { "prolog", "fork" },
  { "prolog", "findall" },
  { "prolog", "call" },
}
M.REIMPLEMENTED = REIMPLEMENTED

-- name -> { [fingerprint] = kernel label }. "absent" = the defun may be
-- missing. Generated by scripts/kernel-fingerprints.lua.
local KNOWN = {
  -- 43.1 = ShenOSKernel 43.1 as vendored (klambda/PROVENANCE.md).
  -- 43.1+deref-hoist = 43.1 with shen-sources perf/typecheck-deref-hoist
  -- (5596445): search-user-datatypes / by-hypothesis dereference once,
  -- outside their loops, through new -h helpers. The native
  -- search-user-datatypes hand port implements both shapes (it never
  -- copies on deref); by-hypothesis(-h) are translated, not hand-ported.
  -- ec16a9f adds an empty-list guard before deref in the wrappers. sud
  -- rejects an empty alternatives list without touching goal/assumptions.
  -- Review and exact 23-file fixture: test/fixtures/kernel-ec16a9f/README.md.
  ["shen.typecheck"] = { ["53f17a8525d2d3ab"] = "43.1, 43.1+deref-hoist" },
  ["shen.lookupsig"] = { ["7613493146348a37"] = "43.1, 43.1+deref-hoist" },
  ["shen.sigf"] = { ["9224dc17fb22e027"] = "43.1, 43.1+deref-hoist" },
  ["shen.search-user-datatypes"] = { ["f19996b77935e2cd"] = "43.1", ["bbdfd9a9f7dfc457"] = "43.1+deref-hoist", ["483d69ab4d98d601"] = "ec16a9f" },
  ["shen.search-user-datatypes-h"] = { ["absent"] = "43.1", ["a3924a95ecff6737"] = "43.1+deref-hoist" },
  ["shen.show"] = { ["832effe9caab5eb7"] = "43.1, 43.1+deref-hoist" },
  ["shen.maxinfexceeded?"] = { ["effe20ceadf236e0"] = "43.1, 43.1+deref-hoist" },
  ["shen.deref"] = { ["108e6076d2b40cf4"] = "43.1, 43.1+deref-hoist" },
  ["shen.lazyderef"] = { ["6a71db925c09d82a"] = "43.1, 43.1+deref-hoist" },
  ["shen.newpv"] = { ["6b2ec5d6d1a0740e"] = "43.1, 43.1+deref-hoist" },
  ["shen.gc"] = { ["8bf58e06257f6ea8"] = "43.1, 43.1+deref-hoist" },
  ["shen.pvar?"] = { ["b9f8c2027d513bc8"] = "43.1, 43.1+deref-hoist" },
  ["shen.bind!"] = { ["a437a03592eeb09d"] = "43.1, 43.1+deref-hoist" },
  ["shen.bindv"] = { ["2dc4d6612453b0d5"] = "43.1, 43.1+deref-hoist" },
  ["shen.unwind"] = { ["6115d9d8ec8dff1a"] = "43.1, 43.1+deref-hoist" },
  ["shen.incinfs"] = { ["459195177ce076d3"] = "43.1, 43.1+deref-hoist" },
  ["shen.cut"] = { ["85bd1959adc59183"] = "43.1, 43.1+deref-hoist" },
  ["shen.unlock"] = { ["ab83443a7ddbe39e"] = "43.1, 43.1+deref-hoist" },
  ["shen.unlocked?"] = { ["0dc9377a64641254"] = "43.1, 43.1+deref-hoist" },
  ["shen.lock"] = { ["3f48989f248f0795"] = "43.1, 43.1+deref-hoist" },
  ["shen.fits?"] = { ["fa91134c44360b8c"] = "43.1, 43.1+deref-hoist" },
  ["shen.lzy="] = { ["07e5f098a2073b4a"] = "43.1, 43.1+deref-hoist" },
  ["shen.lzy=!"] = { ["19816edf8fae10a9"] = "43.1, 43.1+deref-hoist" },
  ["shen.occurs-check?"] = { ["7ed05eb3e8bc6b2b"] = "43.1, 43.1+deref-hoist" },
  ["when"] = { ["792bf299343da335"] = "43.1, 43.1+deref-hoist" },
  ["is"] = { ["5d0db39f0969e1b5"] = "43.1, 43.1+deref-hoist" },
  ["is!"] = { ["46de12012a59edad"] = "43.1, 43.1+deref-hoist" },
  ["bind"] = { ["2235ce58a13b088c"] = "43.1, 43.1+deref-hoist" },
  ["var?"] = { ["ed30fbf8c4b400a8"] = "43.1, 43.1+deref-hoist" },
  ["return"] = { ["8fec19a7c421b3f1"] = "43.1, 43.1+deref-hoist" },
  ["fork"] = { ["fb09c42dd1e554ad"] = "43.1, 43.1+deref-hoist" },
  ["findall"] = { ["ffb1cd75749d0cf1"] = "43.1, 43.1+deref-hoist" },
  ["call"] = { ["1a08e4ad48d6c247"] = "43.1, 43.1+deref-hoist" },
}
M.KNOWN = KNOWN

local function canon(form)
  local rename, n, out = {}, 0, {}
  local function walk(x)
    if getmt(x) == Cons then
      out[#out + 1] = "("
      while getmt(x) == Cons do walk(x[1]); x = x[2] end
      if x ~= NIL then out[#out + 1] = "."; walk(x) end
      out[#out + 1] = ")"
    elseif getmt(x) == Symbol then
      local nm = x.name
      if nm:find("^[VWZ]%d+$") then
        local r = rename[nm]
        if not r then n = n + 1; r = "_" .. n; rename[nm] = r end
        nm = r
      end
      out[#out + 1] = nm
    elseif type(x) == "string" then
      out[#out + 1] = string.format("%q", x)
    elseif type(x) == "number" then
      out[#out + 1] = string.format("%.17g", x)
    elseif x == NIL then
      out[#out + 1] = "()"
    else
      out[#out + 1] = tostring(x)
    end
  end
  walk(form)
  return table.concat(out, " ")
end

-- two independent 32-bit polynomial hashes (plain doubles, no bit library)
local function digest(str)
  local h1, h2 = 5381, 7
  for i = 1, #str do
    local b = str:byte(i)
    h1 = (h1 * 33 + b) % 4294967296
    h2 = (h2 * 131 + b) % 4294967296
  end
  return string.format("%08x%08x", h1, h2)
end

function M.fingerprint(form) return digest(canon(form)) end

-- name -> defun form, for every (defun ...) in a KL source string
local function defuns_of(src)
  local defs = {}
  local SYM_defun = R.intern("defun")
  for _, form in ipairs(R.read_all(src)) do
    if getmt(form) == Cons and form[1] == SYM_defun and getmt(form[2]) == Cons
       and getmt(form[2][1]) == Symbol then
      defs[form[2][1].name] = form
    end
  end
  return defs
end
M.defuns_of = defuns_of

-- fingerprint of `name` in `defs`, or "absent"
function M.fingerprint_in(defs, name)
  local form = defs[name]
  return form and M.fingerprint(form) or "absent"
end

-- problems (list of strings) for the reimplemented defuns of a kernel whose
-- sources are given as { ["t-star"] = defs, prolog = defs }
local function conformance_problems(defsets)
  local problems = {}
  for _, e in ipairs(REIMPLEMENTED) do
    local file, name = e[1], e[2]
    local fp = M.fingerprint_in(defsets[file], name)
    local known = KNOWN[name]
    if not (known and known[fp]) then
      problems[#problems + 1] = string.format(
        "kernel defun %s (%s.kl) does not match any version the native "
        .. "typechecker implements (fingerprint %s)", name, file, fp)
    end
  end
  return problems
end
M.conformance_problems = conformance_problems

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

local function harvest_init_sigs(src)
  init_syms()
  if not src then return false end
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

-- Refreshed-kernel (S42 2026-07-11) signature harvest, from types.kl.
-- The refresh dropped init.kl/shen.initialise-signedfuncs; the 161 kernel
-- signatures now live as top-level (declare NAME TYPEFORM) forms in types.kl,
-- where TYPEFORM is the same rcons tree — e.g. (cons (cons list (cons A ()))
-- (cons --> ...)) — that `declare` evaluates into the type list at load. That
-- is exactly what evalrcons decodes, so we read the declare's type argument
-- directly (no CPS-lambda unwrapping). This yields the same raw, pre-rectify
-- signatures the init.kl harvest produced, which import_fresh + unify_oc
-- consume unchanged.
local function harvest_types_sigs(src)
  init_syms()
  if not src then return false end
  local SYM_declare = R.intern("declare")
  local total, got = 0, 0
  for _, form in ipairs(R.read_all(src)) do
    if getmt(form) == Cons and form[1] == SYM_declare and getmt(form[2]) == Cons
       and getmt(form[2][2]) == Cons then
      local name = form[2][1]
      local typeform = form[2][2][1]
      if getmt(name) == Symbol then
        total = total + 1
        local ok, t = pcall(evalrcons, typeform)
        if ok and t ~= nil then
          NativeSig[name] = t
          got = got + 1
        end
      end
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
  -- NP[name] lazily translates on first dispatch; a predicate the translator
  -- refuses raises NATIVE_MISS, which the typecheck entry catches to retry
  -- the whole query on the legacy engine (whole-query ABI fallback).
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
        error(M.NATIVE_MISS, 0)
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

-- sentinel raised by sud when a datatype predicate cannot be translated;
-- caught by the dispatcher to retry the whole query on the legacy engine
M.NATIVE_MISS = setmetatable({}, { __tostring = function()
  return "native typecheck: untranslatable datatype predicate"
end })

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

  -- 1) translate the driver defuns straight out of klambda/t-star.kl.
  -- A single-file bundle embeds the .kl sources as P.KL_SOURCES (no files
  -- on disk); otherwise read from SHEN_KL_DIR / the vendored klambda/.
  local function read_kl(name)
    if P.KL_SOURCES and P.KL_SOURCES[name] then return P.KL_SOURCES[name] end
    local dirs = {
      P.KLDIR,                                        -- boot's resolved dir
      (os.getenv("SHEN_KL_DIR") or "klambda") .. "/",
      "../cl-source/ShenOSKernel-42/klambda/",      -- boot's other candidate
    }
    for _, d in ipairs(dirs) do
      local fh = d and io.open(d .. name .. ".kl", "r")
      if fh then
        local s = fh:read("*a"); fh:close()
        return s
      end
    end
    return nil
  end
  -- Kernel signatures: Tarver S41.2/S42 kernels carry them as (declare ...)
  -- forms in types.kl; ShenOSKernel 42.2 (vendored) carries them as
  -- shen.initialise-signedfuncs CPS lambdas in init.kl (164 harvested). Try
  -- types.kl first (it has no declares on 42.2, so it reports incomplete),
  -- then init.kl. An incomplete harvest (missing source
  -- or an unrecognised form) leaves sigs_complete false, which forces the
  -- legacy in-kernel typecheck path — slower, but identical verdicts.
  M.sigs_complete = harvest_types_sigs(read_kl("types"))
    or harvest_init_sigs(read_kl("init"))

  -- Driver TRANSLATION is DEFERRED to the first typecheck; the t-star.kl READ
  -- stays eager. Walking the 16 driver defuns through the KL->Lua prolog
  -- compiler and loadstring'ing the emitted source is ~32ms — the bulk of the
  -- engine's boot cost — and a plain boot never typechecks anything, so none
  -- of it is needed until the first (shen.typecheck ...) call. But the *source
  -- read* must happen now: read_kl resolves against the relative P.KLDIR, and a
  -- caller may chdir between boot and its first typecheck (run-kernel-tests
  -- does exactly this), which would leave a deferred read unable to find the
  -- file. So we slurp the source string here — cheap, ~8ms — and defer only the
  -- CPU-bound parse+translate, which needs nothing but the in-memory string.
  -- ensure_drivers() runs that once, on demand; typecheck_dispatch calls it
  -- before deciding native-vs-legacy (n_fail is only known after translation).
  -- The drivers land in NP, the handports in NP too; both are consulted only
  -- along the native typecheck path, so deferring them is behaviour-preserving.
  -- Harvest and the declare/destroy wrappers below stay eager: they must
  -- observe every kernel declare that initialise() issues after install.
  local tstar_src = read_kl("t-star")
  if not tstar_src then
    error("typecheck_native: cannot locate t-star.kl")
  end
  local prolog_src = read_kl("prolog")
  M.translate_errors = {}
  local n_ok, n_fail = 0, 0
  M.n_ok, M.n_fail = 0, 0   -- 0 until ensure_drivers runs on the first typecheck
  local drivers_ready = false
  -- Native-path problems found by ensure_drivers (nil = none): a kernel
  -- defun the port reimplements has changed, or a driver calls a predicate
  -- with no native definition. Either one routes every typecheck to the
  -- kernel's KL typechecker (see typecheck_dispatch).
  local native_problems = nil
  local function ensure_drivers()
    if drivers_ready then return end
    -- Translate into FRESH accumulators and commit `drivers_ready` (plus the
    -- n_fail the dispatch consults) only AFTER the whole pass and the
    -- hand-ports succeed. If R.read_all or an unexpected translator error
    -- throws partway, drivers_ready stays false and n_fail stays 0-but-uncommitted,
    -- so the next typecheck re-runs this from scratch rather than dispatching to
    -- native_typecheck over a half-filled NP. Re-running is safe: the driver
    -- source is fixed, so NP[name] writes are idempotent and the counters are
    -- local, not accumulated across attempts.
    local ok, fail, errors, problems = 0, 0, {}, {}
    local tdefs = defuns_of(tstar_src)
    local pdefs = prolog_src and defuns_of(prolog_src) or {}
    if not prolog_src then
      problems[#problems + 1] = "cannot locate prolog.kl to check the kernel"
    end
    for _, msg in ipairs(conformance_problems({ ["t-star"] = tdefs, prolog = pdefs })) do
      problems[#problems + 1] = msg
    end

    -- The driver set is the closure of DRIVER_FNS under "calls by name":
    -- every predicate a translated driver calls must be a t-star.kl defun
    -- (translated here too) or a hand port. So a kernel that splits a driver
    -- into helpers (43.1 with the deref hoist adds shen.by-hypothesis-h) is
    -- followed automatically, and one that calls something the port cannot
    -- run is caught here, before any query, instead of as nil(...) mid-search.
    local queue, queued = {}, {}
    local function enqueue(name)
      if not queued[name] then queued[name] = true; queue[#queue + 1] = name end
    end
    local roots = {}
    for name in pairs(DRIVER_FNS) do roots[#roots + 1] = name end
    table.sort(roots)
    for _, name in ipairs(roots) do
      if tdefs[name] then enqueue(name)
      elseif ENTRY_FNS[name] then
        problems[#problems + 1] = "t-star.kl has no defun " .. name
      end
    end
    local added = {}
    local qi = 1
    while qi <= #queue do
      local name = queue[qi]; qi = qi + 1
      local fn, err, _, _, callees = PC.translate_defun(tdefs[name])
      if fn then
        NP[name] = fn
        ok = ok + 1
      else
        errors[name] = err
        fail = fail + 1
      end
      local cs = {}
      for c in pairs(callees or {}) do cs[#cs + 1] = c end
      table.sort(cs)
      for _, c in ipairs(cs) do
        if not (HANDPORTED[c] or queued[c]) then
          if tdefs[c] then
            enqueue(c)
            if not DRIVER_FNS[c] then added[#added + 1] = c end
          else
            problems[#problems + 1] = string.format(
              "driver %s calls %s, which is neither a t-star.kl defun nor a "
              .. "native hand port", name, c)
          end
        end
      end
    end
    -- hand-ports (shen.lookupsig / shen.sigf, ...): also native-path only.
    install_handports()
    M.translate_errors = errors
    for name, err in pairs(errors) do
      problems[#problems + 1] = "cannot translate driver " .. name .. ": "
                                .. tostring(err):sub(1, 200)
    end
    M.drivers = queue
    M.drivers_added = added
    native_problems = (#problems > 0) and problems or nil
    M.native_problems = native_problems
    n_ok, n_fail = ok, fail
    M.n_ok, M.n_fail = ok, fail
    drivers_ready = true
  end
  M.ensure_drivers = ensure_drivers

  -- 3) declare wrapper: record raw type exprs for native lookupsig.
  --    boot.lua installs the engine before initialise(), so every kernel
  --    declare is captured. Delegates unconditionally (legacy *sigf* stays
  --    the source of truth for the legacy engine).
  -- boot.lua replays cached stdlib signatures without calling `declare`;
  -- this keeps the native signature table in step with shen.*sigf*.
  M.record_sig = function(name, type_) NativeSig[name] = type_ end
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

  -- 4) typecheck override with whole-query fallback: run native; if the
  --    search hits an untranslatable datatype predicate (NATIVE_MISS), the
  --    engine state is already restored by native_typecheck's pcall path —
  --    rerun the whole query on the legacy engine.
  --    The same fallback covers a call to a predicate with no native
  --    definition (E.native_miss) and a kernel that fails the conformance
  --    check (native_problems): the answer then comes from the kernel's own
  --    KL typechecker, and stderr says why, once per cause.
  --    SHEN_TYPECHECK_NATIVE=require raises an error instead of falling back.
  local orig_typecheck_ref = nil  -- resolved lazily: t-star loads before us
  -- Opt-in last-query receipt for benchmarks/embedders (#72). No counters or
  -- term materialization on the normal path. A receipt describes dispatch,
  -- including a native attempt followed by a whole-query legacy retry.
  local function route(engine, reason, attempted)
    if M.track_routes then
      M.last_route = { engine = engine, reason = reason,
                       native_attempted = attempted or false }
      -- Optional ordered dispatch transitions for a whole source load. Unlike
      -- last_route, this retains earlier fallbacks and errors in that load.
      if M.route_log then M.route_log[#M.route_log+1] = M.last_route end
    end
  end
  local function typecheck_dispatch(expr, type_)
    route("preparing", "driver translation")
    ensure_drivers()
    local reason, attempted
    if native_problems then
      reason = table.concat(native_problems, "; ")
      route("unavailable", reason)
      fallback_notice("problems", native_problems)
    elseif n_fail == 0 and M.sigs_complete
       and P.GLOBALS["shen.*spy*"] ~= true then
      attempted = true
      route("native", "eligible", true)
      local ok, r = pcall(native_typecheck, expr, type_)
      if ok then return r end
      if E.is_native_miss(r) then
        reason = tostring(r)
        route("unavailable", reason, true)
        fallback_notice("miss:" .. tostring(r.name), { reason })
      elseif r == M.NATIVE_MISS then
        reason = "unsupported datatype predicate"
      else
        route("native-error", tostring(r), true)
        error(r, 0)
      end
    else
      reason = P.GLOBALS["shen.*spy*"] == true and "spy enabled"
        or (not M.sigs_complete and "incomplete signatures" or "driver translation failed")
    end
    -- Strict mode must also reject spy/incomplete-signature/ABI fallbacks.
    if REQUIRE_NATIVE then
      route("unavailable", reason, attempted)
      fallback_notice("route:" .. reason, { reason })
    end
    route("legacy", reason, attempted)
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
  -- Export a GUARDED entry: the drivers are translated lazily, so a caller that
  -- reaches native_typecheck directly (embedders/tests) must trigger that first,
  -- or it reads nil driver predicates out of NP and crashes. The internal
  -- dispatch path already calls ensure_drivers(), so it uses the raw local.
  M.native_typecheck = function(expr, type_)
    ensure_drivers()
    return native_typecheck(expr, type_)
  end
end

return M
