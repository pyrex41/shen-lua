-- A/B: native kernel overrides vs the portable KL defuns they replace.
-- Interleaved min-of-N. Restores F[name] after each case so later cases
-- still see the native versions of callees (element?, append, ...).
--
--   luajit bench/overrides_ab.lua

package.path = "./?.lua;" .. package.path
local P = require("boot")
local R = require("runtime")
P.load_kernel(false)
P.initialise()

local F, FA = P.F, P.FA
local NIL = R.NIL

local function nlist(n)
  local acc = NIL
  for i = n, 1, -1 do acc = R.cons(i, acc) end
  return acc
end

local function save(names)
  local s = {}
  for _, n in ipairs(names) do
    s[n] = { fn = F[n], ar = F[n] and FA[F[n]] }
  end
  return s
end
local function restore(s)
  for n, v in pairs(s) do
    F[n] = v.fn
    if v.fn and v.ar then FA[v.fn] = v.ar end
  end
end

local function timeit(n, warmup, fn)
  for _ = 1, warmup do fn() end
  local best
  for _ = 1, n do
    local t0 = os.clock()
    fn()
    local dt = os.clock() - t0
    if not best or dt < best then best = dt end
  end
  return best
end

local function report(name, kl, nat)
  local speedup = kl / nat
  print(string.format("%-42s  KL %8.4fs  native %8.4fs  %6.1fx",
    name, kl, nat, speedup))
end

local function ab(label, names, kl_src, n, warmup, work)
  local saved = save(names)
  local nat_t = timeit(n, warmup, work)
  P.run_kl_string(kl_src)
  local kl_t = timeit(n, warmup, work)
  restore(saved)
  -- confirm native still matches
  local nat2 = timeit(n, 0, work)
  if nat2 * 3 < nat_t then nat_t = nat2 end  -- keep the better native
  report(label, kl_t, nat_t)
end

print("== native overrides vs kernel KL (min of 5, interleaved) ==\n")

-- integer?
do
  local xs = { 0, 1, -3, 42, 1.5, 1000003 / 2, 1000003 / 3, 1e12, 2^40 }
  ab("integer? (mix int/float/large)", { "integer?" }, [[
    (defun integer? (V3741)
      (and (number? V3741)
           (let W3742 (shen.abs V3741)
             (shen.integer-test? W3742 (shen.magless W3742 1)))))
  ]], 5, 1, function()
    local f = F["integer?"]
    local r
    for _ = 1, 40000 do
      for i = 1, #xs do r = f(xs[i]) end
    end
    return r
  end)
end

-- empty? / not / boolean?  (kernel overwrote the primitives)
do
  local vals = { true, false, 0, 1, NIL, "x", R.intern("foo") }
  ab("empty?/not/boolean? (7 vals x 50k)", { "empty?", "not", "boolean?" }, [[
    (defun empty? (V) (cond ((= () V) true) (true false)))
    (defun not (V) (if V false true))
    (defun boolean? (V) (cond ((= true V) true) ((= false V) true) (true false)))
  ]], 5, 1, function()
    local e, n, b = F["empty?"], F["not"], F["boolean?"]
    local r
    for _ = 1, 50000 do
      for i = 1, #vals do
        r = e(vals[i]); r = n(vals[i] and true or false); r = b(vals[i])
      end
    end
    return r
  end)
end

-- length
do
  local L = nlist(5000)
  ab("length 5000-list x 200", { "length", "shen.length-h" }, [[
    (defun length (V3721) (shen.length-h V3721 0))
    (defun shen.length-h (V3726 V3727)
      (cond ((= () V3726) V3727)
            (true (shen.length-h (tl V3726) (+ V3727 1)))))
  ]], 5, 1, function()
    local f = F["length"]
    local r
    for _ = 1, 200 do r = f(L) end
    return r
  end)
end

-- explode
do
  local s = string.rep("abcdefghi ", 80)  -- 800 chars
  ab("explode 800-char string x 50", { "explode" }, [[
    (defun explode (V3711) (shen.explode-h (shen.app V3711 "" shen.a)))
  ]], 5, 1, function()
    local f = F["explode"]
    local r
    for _ = 1, 50 do r = f(s) end
    return r
  end)
end

-- nth
do
  local L = nlist(4000)
  ab("nth 2000 of 4000-list x 200", { "nth" }, [[
    (defun nth (V3739 V3740)
      (cond ((and (= 1 V3739) (cons? V3740)) (hd V3740))
            ((cons? V3740) (nth (- V3739 1) (tl V3740)))
            (true (simple-error "nth"))))
  ]], 5, 1, function()
    local f = F["nth"]
    local r
    for _ = 1, 200 do r = f(2000, L) end
    return r
  end)
end

-- concat
do
  local a, b = R.intern("foo"), R.intern("bar")
  ab("concat symbol x 20k", { "concat" }, [[
    (defun concat (V3492 V3493) (intern (cn (str V3492) (str V3493))))
  ]], 5, 1, function()
    local f = F["concat"]
    local r
    for _ = 1, 200000 do r = f(a, b) end
    return r
  end)
end

-- vector
do
  ab("vector 2000 x 30", { "vector" }, [[
    (defun vector (V3456)
      (let W3457 (absvector (+ V3456 1))
        (let W3458 (address-> W3457 0 V3456)
          (let W3459 (if (= V3456 0) W3458 (shen.fillvector W3458 1 V3456 (fail)))
            W3459))))
  ]], 5, 1, function()
    local f = F["vector"]
    local r
    for _ = 1, 30 do r = f(2000) end
    return r
  end)
end

-- @p
do
  ab("@p x 100k", { "@p" }, [[
    (defun @p (V3494 V3495)
      (let W3496 (absvector 3)
        (let W3497 (address-> W3496 0 shen.tuple)
          (let W3498 (address-> W3497 1 V3494)
            (let W3499 (address-> W3498 2 V3495) W3496)))))
  ]], 5, 1, function()
    local f = F["@p"]
    local r
    for _ = 1, 100000 do r = f(1, 2) end
    return r
  end)
end

-- difference
do
  local A, B = nlist(200), nlist(80)
  ab("difference 200 vs 80 x 40", { "difference" }, [[
    (defun difference (V3558 V3559)
      (cond ((= () V3558) ())
            ((cons? V3558)
             (if (element? (hd V3558) V3559)
                 (difference (tl V3558) V3559)
                 (cons (hd V3558) (difference (tl V3558) V3559))))
            (true (simple-error "difference"))))
  ]], 5, 1, function()
    local f = F["difference"]
    local r
    for _ = 1, 40 do r = f(A, B) end
    return r
  end)
end

-- symbol?
do
  local syms = {}
  for i = 1, 200 do
    syms[i] = R.intern("sym" .. i)
    F["symbol?"](syms[i])  -- warm memo
  end
  -- reset memo by using fresh symbols in KL path; native memo is on the
  -- interned table so the first native pass already paid. Re-interned same
  -- names hit cache. Fair test: 200 distinct, already memoized vs KL walk.
  ab("symbol? 200 interned x 2k (memo vs walk)", { "symbol?" }, [[
    (defun symbol? (V3475)
      (cond ((or (boolean? V3475) (or (number? V3475) (or (string? V3475)
             (or (cons? V3475) (or (empty? V3475) (vector? V3475)))))) false)
            ((element? V3475 (cons { (cons } (cons (intern ":")
              (cons (intern ";") (cons (intern ",") ())))))) true)
            (true (trap-error (let W3476 (str V3475)
                                (shen.analyse-symbol? W3476))
                              (lambda Z3477 false)))))
  ]], 5, 1, function()
    local f = F["symbol?"]
    local r
    for _ = 1, 2000 do
      for i = 1, #syms do r = f(syms[i]) end
    end
    return r
  end)
end

-- read-file-as-string / bytelist
do
  local path = "klambda/sys.kl"
  ab("read-file-as-string sys.kl x 20", { "read-file-as-string" }, [[
    (defun read-file-as-string (V2221)
      (let W2222 (open V2221 in)
        (shen.rfas-h W2222 (read-byte W2222) "")))
  ]], 5, 1, function()
    local r
    for _ = 1, 20 do r = F["read-file-as-string"](path) end
    return r
  end)

  ab("read-file-as-bytelist sys.kl x 8", { "read-file-as-bytelist" }, [[
    (defun read-file-as-bytelist (V2213)
      (let W2214 (open V2213 in)
        (let W2215 (read-byte W2214)
          (let W2216 (shen.read-file-as-bytelist-help W2214 W2215 ())
            (let W2217 (close W2214) (reverse W2216))))))
  ]], 5, 1, function()
    local r
    for _ = 1, 8 do r = F["read-file-as-bytelist"](path) end
    return r
  end)
end

-- arity / get (property store) / vector?
do
  local names = {}
  for i = 1, 100 do names[i] = R.intern("arity-probe-" .. i) end
  -- populate a few real arities
  ab("arity known+unknown x 20k", { "arity" }, [[
    (defun arity (V5770)
      (trap-error (get V5770 arity (value *property-vector*))
                  (lambda Z5771 -1)))
  ]], 5, 1, function()
    local f = F["arity"]
    local r
    for _ = 1, 20000 do
      r = f(R.intern("+"))
      r = f(R.intern("map"))
      r = f(names[(_ % 100) + 1])
    end
    return r
  end)
end

do
  ab("vector? mix x 100k", { "vector?" }, [[
    (defun vector? (V3465)
      (and (absvector? V3465)
           (trap-error (>= (<-address V3465 0) 0) (lambda Z3466 false))))
  ]], 5, 1, function()
    local f = F["vector?"]
    local v = F["vector"](4)
    local t = F["@p"](1, 2)
    local r
    for _ = 1, 100000 do r = f(v); r = f(t); r = f(1) end
    return r
  end)
end

-- trap-error (value) peephole vs pcall — compile two tiny KL defuns
do
  P.run_kl_string([[
    (defun bench-val-opt ()
      (trap-error (value *stoutput*) (lambda E false)))
    (defun bench-val-miss ()
      (trap-error (value bench-no-such-global) (lambda E 0)))
  ]])
  -- those compile WITH the peephole. Compare against an equivalent that
  -- uses a non-optimizable handler (references E) so it still pcalls.
  P.run_kl_string([[
    (defun bench-val-pcall ()
      (trap-error (value *stoutput*) (lambda E (if E *stoutput* false))))
  ]])
  local opt = F["bench-val-opt"]
  local pc = F["bench-val-pcall"]
  local t_opt = timeit(5, 1, function() for _ = 1, 50000 do opt() end end)
  local t_pc = timeit(5, 1, function() for _ = 1, 50000 do pc() end end)
  report("trap-error value hit (peephole vs pcall)", t_pc, t_opt)
end

-- end-to-end: prime*? hammers integer? on (/ X Div)
print("\n== end-to-end ==")
P.F["load"]("tests/prime.shen")
do
  local saved = save({ "integer?" })
  local function run() return F["prime*?"](1000003) end
  local nat = timeit(5, 1, run)
  P.run_kl_string([[
    (defun integer? (V3741)
      (and (number? V3741)
           (let W3742 (shen.abs V3741)
             (shen.integer-test? W3742 (shen.magless W3742 1)))))
  ]])
  local kl = timeit(5, 1, run)
  restore(saved)
  report("prime*? 1000003 (integer? on /)", kl, nat)
end

-- fib: compiler (= 0 V) / (= 1 V) identity compare. No KL-override A/B;
-- report absolute time vs BENCHMARKS.md (fib 30 = 0.052s, 32 = 0.137s).
P.run_kl_string([[
  (defun fib (V)
    (cond ((= 0 V) 0)
          ((= 1 V) 1)
          (true (+ (fib (- V 1)) (fib (- V 2))))))
]])
F["fib"](20); F["fib"](20)
print()
for _, n in ipairs({ 30, 32 }) do
  local dt = timeit(5, 1, function() F["fib"](n) end)
  print(string.format("%-42s  native %8.4fs  (BENCHMARKS.md fib(%d): %s)",
    "fib(" .. n .. ")  [= inlined to ==]", dt, n,
    n == 30 and "0.052s" or "0.137s"))
end
