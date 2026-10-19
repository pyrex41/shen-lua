-- test/prolog_semantics_spec.lua — cross-port Prolog semantics.
--
--   luajit test/prolog_semantics_spec.lua
--
-- shen-lua does not run the kernel's compiled-KL CPS Prolog by default: it
-- runs an independent native engine (prolog_engine.lua + prolog_compile.lua).
-- That engine is a performance substitute, not a dialect, so every observable
-- Prolog result must equal what the kernel's own engine produces — which is
-- also what shen-go, shen-cl and shen-rust produce, since those three run the
-- kernel Prolog directly.
--
-- Every expectation below was MEASURED on shen-go, shen-cl and shen-rust
-- (pinned checkouts, kernel 42) and was byte-identical on all three. The
-- probe methodology is urdr's four-port portability spike,
-- spikes/m1-prolog-portability: results are rendered by a printer defined
-- here, never by a port's own value writer, so runtime variable naming and
-- print formatting cannot leak into the comparison; a query that raises
-- renders as the fixed token "<error>"; a query that fails renders "failed".

local shen = require("shen")
shen.boot{ quiet = true }
local R = require("runtime")

local pass, fail = 0, 0
local function check(desc, got, want)
  if got == want then pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL %s: got %s want %s",
                        desc, tostring(got), tostring(want)))
  end
end

-- Canonical rendering, matching the spike probes' self-contained printer.
local function render(v)
  if v == R.NIL then return "[]" end
  if getmetatable(v) == R.Cons then
    local parts, x = {}, v
    while getmetatable(x) == R.Cons do
      parts[#parts + 1] = render(x[1]); x = x[2]
    end
    if x ~= R.NIL then parts[#parts + 1] = "| " .. render(x) end
    return "[" .. table.concat(parts, " ") .. "]"
  end
  return R.to_str(v)
end

local function q(src)
  local ok, v = pcall(shen.eval, src)
  if not ok then return "<error>" end
  if v == false then return "failed" end
  return render(v)
end

-- ---------------------------------------------------------------------------
-- fixtures
-- ---------------------------------------------------------------------------
shen.eval([[
(defprolog tparent
  abe homer <--;
  homer bart <--;
  homer lisa <--;
  abe herb <--;)

(defprolog tmember
  X [X | _] <--;
  X [_ | Y] <-- (tmember X Y);)

(defprolog tappend
  [] X X <--;
  [X | Xs] Y [X | Zs] <-- (tappend Xs Y Zs);)

\\ Negation as failure over a GENERIC goal, via the kernel's call/1. The
\\ kernel passes the goal as a partially applied predicate; the native engine
\\ dispatches on a goal structure. Both must accept (tparent abe homer).
(defprolog tnot
  G <-- (call G) ! (when false);
  _ <--;)

(defprolog tand
  P Q <-- (call P) (tnot Q);)

\\ forall/2 in terms of call/1: no P-solution for which Q fails.
(defprolog tforall
  P Q <-- (tnot (tand P Q)) ;)

\\ Varhood test. Reports a classification so no runtime variable is printed.
(defprolog tvarness
  X unbound <-- (var? X) !;
  _ bound <--;)

\\ var? deep inside a recursive predicate rather than as the whole body.
(defprolog tfirstvar
  [X | _] yes <-- (var? X) !;
  [_ | Y] R <-- (tfirstvar Y R);
  [] no <--;)

\\ One fresh Prolog variable per level of recursion: the standard way to walk
\\ into the per-query bindings-vector ceiling.
(defprolog tdown
  0 done <-- !;
  N R <-- (when (> N 0)) (is M (- N 1)) (tdown M R);)
]])

-- ---------------------------------------------------------------------------
-- D-1: call/1, generic goal invocation
--
-- shen-lua raised "native call: goal is not a structure" for every case where
-- the goal arrived as a predicate argument rather than as a call/1 literal.
-- ---------------------------------------------------------------------------
check("call/1 direct, true goal",
      q("(prolog? (call (tparent abe homer)) (return holds))"), "holds")
check("call/1 direct, false goal",
      q("(prolog? (call (tparent abe zzz)) (return holds))"), "failed")

check("naf over generic goal that holds",
      q("(prolog? (tnot (tparent abe homer)) (return holds))"), "failed")
check("naf over generic goal that fails",
      q("(prolog? (tnot (tparent abe zzz)) (return holds))"), "holds")

check("call/1 goal with a nested list argument",
      q("(prolog? (call (tmember b [a b c])) (return holds))"), "holds")
check("call/1 goal that fails, nested list argument",
      q("(prolog? (call (tmember z [a b c])) (return holds))"), "failed")

-- call/1 must bind through: the goal's variables are the caller's variables.
check("call/1 binds the caller's variable",
      q("(prolog? (call (tparent abe W)) (return W))"), "homer")
check("call/1 under findall enumerates every solution",
      q("(prolog? (findall W (call (tparent abe W)) L) (return L))"),
      "[herb homer]")

-- Nested call/1: a goal invoked through two layers of generic dispatch.
check("naf composed with naf",
      q("(prolog? (tnot (tnot (tparent abe homer))) (return holds))"), "holds")

check("forall over a generic pair of goals",
      q("(prolog? (tforall (tparent abe X) (tparent X bart)) (return holds))"),
      "failed")

-- ---------------------------------------------------------------------------
-- D-2: var?/1
--
-- shen-lua crashed inside the engine ("attempt to call local 'h' (a nil
-- value)") because the clause compiler emitted g_var with the continuation
-- sitting in the inference-counter parameter.
-- ---------------------------------------------------------------------------
check("var? on an unbound query variable",
      q("(prolog? (tvarness X R) (return R))"), "unbound")
check("var? on a bound query variable",
      q("(prolog? (is X 3) (tvarness X R) (return R))"), "bound")
check("var? on a fresh variable left by append/3",
      q("(prolog? (tappend [1] X Y) (tvarness X R) (return R))"), "unbound")
check("var? on a ground structure",
      q("(prolog? (tvarness [a b] R) (return R))"), "bound")
check("var? on a partially instantiated structure",
      q("(prolog? (is X [a Y]) (tvarness X R) (return R))"), "bound")
check("var? inside a recursive predicate",
      q("(prolog? (is L [a b Z]) (tfirstvar L R) (return R))"), "yes")
check("var? inside a recursive predicate, all ground",
      q("(prolog? (tfirstvar [a b c] R) (return R))"), "no")
check("var? under findall",
      q("(prolog? (findall R (tvarness X R) L) (return L))"), "[unbound]")
-- var? must FAIL (not raise) on a bound argument, so the next clause runs.
check("var? failure backtracks into the next clause",
      q("(prolog? (is X 1) (tvarness X R) (return R))"), "bound")

-- ---------------------------------------------------------------------------
-- Proof depth (pyrex41/shen-lua#85). The native engine is CPS on the Lua
-- stack, and LuaJIT's stack is a fixed ~65500 slots: a typecheck overflowed
-- at ~375 nested peano rules (legacy engine ~1000; shen-go has no limit). A
-- deep proof now continues on fresh coroutine stacks ("segments"). These
-- check the depth, that backtracking and cut undo bindings across segment
-- boundaries, and that errors cross them unchanged.
-- ---------------------------------------------------------------------------
do
  local E = require("prolog_engine")
  local seg0 = E.segments()
  shen.eval([==[
(datatype dpeano
  ____________
  z : dpeano;

  N : dpeano;
  ____________
  [s N] : dpeano;)
(define dmk N Acc -> (if (= N 0) Acc (dmk (- N 1) [cons s [cons Acc []]])))
(define dlist N Acc -> (if (= N 0) Acc (dlist (- N 1) [cons N Acc])))
(defprolog dchain
  0 R <-- (is R bottom) (when false);
  N R <-- (when (> N 0)) (is M (- N 1)) (dchain M R);
  _ R <-- (is R top);)
(defprolog dcut
  0 <-- ! (when false);
  0 <--;
  N <-- (when (> N 0)) (is M (- N 1)) ! (dcut M);)
(defprolog derr
  0 <-- (when (= (/ 1 0) 0));
  N <-- (when (> N 0)) (is M (- N 1)) (derr M);)]==])
  check("#85: typecheck of a 1500-deep peano term",
        R.to_str(shen.eval("(shen.typecheck (dmk 1500 z) dpeano)")), "dpeano")
  check("#85: typecheck of a 3000-element (list number)",
        R.to_str(shen.eval("(shen.typecheck (dlist 3000 []) [list number])")), "(list number)")
  check("#85: the deep typechecks ran on more than one stack segment",
        E.segments() > seg0, true)
  local seg1 = E.segments()
  check("#85: a shallow typecheck opens no segment",
        R.to_str(shen.eval("(shen.typecheck (dmk 3 z) dpeano)")) == "dpeano"
        and E.segments() == seg1, true)
  -- the leaf binds R, fails, and every level's next clause is tried on the
  -- way back up: R must be unbound again before (is R top)
  check("#85: backtracking out of a 3000-deep failing branch undoes its bindings",
        q("(prolog? (dchain 3000 R) (return R))"), "top")
  check("#85: cut 3000 levels deep still prunes (no second clause for 0)",
        q("(prolog? (dcut 3000))"), "failed")
  local shallow = shen.eval("(trap-error (prolog? (derr 1)) (/. E (error-to-string E)))")
  local deep = shen.eval("(trap-error (prolog? (derr 3000)) (/. E (error-to-string E)))")
  check("#85: an error 3000 levels deep crosses segments unchanged",
        type(deep) == "string" and deep == shallow, true)
  check("#85: the engine is usable after an error inside a segment",
        q("(prolog? (dchain 50 R) (return R))"), "top")
  local _, nested = E.segments()
  check("#85: no segment is left open", nested, 0)
  -- a host coroutine.yield from inside a segment reaches the host's
  -- coroutine and the proof resumes where it left off
  do
    local P = shen.prims
    P.F["dyield"] = function() return coroutine.yield("paused") == "go" end
    P.FA[P.F["dyield"]] = 0
    shen.eval([==[(defprolog dyc
  0 R <-- (when (dyield)) (is R bottom);
  N R <-- (when (> N 0)) (is M (- N 1)) (dyc M R);)]==])
    local co = coroutine.create(function()
      return shen.eval("(prolog? (dyc 3000 R) (return R))")
    end)
    local ok1, v1 = coroutine.resume(co)
    local ok2, v2 = coroutine.resume(co, "go")
    check("#85: a yield from 3000 levels deep reaches the host and resumes",
          tostring(ok1) .. " " .. tostring(v1) .. " " .. tostring(ok2) .. " "
          .. R.to_str(v2), "true paused true bottom")
    -- with no host coroutine the yield is an error, and abandoning the
    -- suspended segments must not leak the nesting count
    local okn = pcall(shen.eval, "(prolog? (dyc 3000 R) (return R))")
    local _, nested2 = E.segments()
    check("#85: a yield with no host coroutine raises and leaves no segment open",
          tostring(okn) .. " " .. nested2, "false 0")
  end
  -- past the cap: a trappable Shen error, not a crash
  local f0, m0 = E.segment_limits(8, 2)
  local capped = shen.eval("(trap-error (prolog? (dchain 3000 R) (return R)) (/. E (error-to-string E)))")
  E.segment_limits(f0, m0)
  check("#85: past the segment cap the query raises a Shen error",
        type(capped) == "string" and capped:find("Prolog depth limit exceeded", 1, true) ~= nil, true)
  check("#85: and the next query runs normally",
        q("(prolog? (dchain 3000 R) (return R))"), "top")
end

-- ---------------------------------------------------------------------------
-- D-3: per-query variable capacity
--
-- shen.*prolog-memory* is the size of the bindings vector the kernel's
-- call-prolog allocates per query (macros.shen shen.prolog-vector), so it is
-- a hard ceiling on how many Prolog variables one query may allocate.
-- ShenOSKernel 42.2's shen.initialise-environment (init.kl) ends with
-- (prolog-memory 10000); slots 0 and 1 hold the printer and the next-index
-- counter. shen-lua's native engine grew its variable arena without bound, so
-- queries that raise on the other ports returned a value here.
--
-- The ceiling checks below lower the budget to 1000 with (prolog-memory 1000)
-- (the S42 default): a 10000-deep tdown would overflow the LuaJIT stack before
-- it reached the variable ceiling, which is a different error.
-- ---------------------------------------------------------------------------
check("shen.*prolog-memory* is the kernel default",
      shen.eval("(value shen.*prolog-memory*)"), 10000)
check("prolog-memory sets and reads back the budget",
      shen.eval("(prolog-memory 1000)"), 1000)
check("prolog-memory reads the current value back",
      shen.eval("(value shen.*prolog-memory*)"), 1000)

check("query under the ceiling succeeds",
      q("(prolog? (tdown 900 R) (return R))"), "done")
check("query over the ceiling raises",
      q("(prolog? (tdown 1200 R) (return R))"), "<error>")
check("shallow query still succeeds after an overflow",
      q("(prolog? (tdown 100 R) (return R))"), "done")
check("the ceiling is per query, not cumulative",
      q("(prolog? (tdown 900 R) (return R))"), "done")

-- ---------------------------------------------------------------------------
-- regression guard: the divergences above were only visible on the NATIVE
-- path, so assert the native path is the one under test.
-- ---------------------------------------------------------------------------
do
  local okc, PC = pcall(require, "prolog_compile")
  local native = okc and PC.NP ~= nil and PC.NP["tnot"] ~= nil
  check("native prolog engine is the path under test", native, true)
end

-- The ceiling lives in TWO places, because shen-lua has two Prolog engines
-- and both allocate their own variables: prolog_engine.lua's newvar for the
-- native path and prims.lua's shen.newpv for the compiled-KL CPS path.
-- SHEN_PROLOG_ENGINE=legacy selects the second, so probe it out of process.
do
  local root = arg[0]:gsub("test/[^/]*$", "")
  if root == "" then root = "./" end
  local prog = [[
(prolog-memory 1000)
(defprolog ldown
  0 done <-- !;
  N R <-- (when (> N 0)) (is M (- N 1)) (ldown M R);)
(output "SHALLOW=~A|DEEP=~A~%"
        (trap-error (prolog? (ldown 900 R) (return R)) (/. E caught))
        (trap-error (prolog? (ldown 1200 R) (return R)) (/. E caught)))]]
  local f = os.tmpname() .. ".shen"
  local fh = io.open(f, "w"); fh:write(prog); fh:close()
  local h = io.popen("SHEN_PROLOG_ENGINE=legacy " .. root .. "bin/shen " ..
                     f .. " 2>/dev/null", "r")
  local out = h:read("*a") or ""
  h:close()
  os.remove(f)
  os.remove("./.shen-kernel-cache.bin")
  check("legacy engine honours the same ceiling",
        out:match("SHALLOW=%a+|DEEP=%a+"), "SHALLOW=done|DEEP=caught")
end

print(string.format("prolog_semantics_spec: %d pass, %d fail", pass, fail))
os.exit(fail == 0 and 0 or 1)
