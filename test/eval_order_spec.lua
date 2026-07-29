-- test/eval_order_spec.lua — cross-port evaluation ORDER conformance.
--
-- Shen evaluates operands LEFT TO RIGHT. shen-go, shen-cl and shen-rust all
-- do; shen-lua used to diverge for list literals (and any nested call chain)
-- of 16 or more elements, because compiler.lua's `try_flatten_call_chain`
-- optimisation — which lowers a deep right-spine call chain into a sequence
-- of `local` bindings so Lua's ~200-level expression-nesting parser limit is
-- not hit — emitted the chain INSIDE OUT, evaluating the rightmost operand
-- first. Below 16 frames the optimisation does not fire, so the divergence
-- only appeared on long lists: `[(output "a") (output "b") ...]` printed in
-- reverse. That made any side-effecting list literal port-dependent.
--
-- These tests pin left-to-right order for:
--   * list literals in tail / argument / value position, above and below the
--     flattening threshold;
--   * deep user call chains whose frames carry effectful non-last arguments;
--   * ordinary function application arguments;
--   * let bindings, do sequences, tuples (@p) and vectors (@v);
-- and they pin that the flattening optimisation is STILL APPLIED (a fix that
-- simply disabled it would reintroduce the parser-limit bug it exists for).
--
--   luajit test/eval_order_spec.lua

package.path = (arg[0]:gsub("test/[^/]*$", "")) .. "?.lua;" .. package.path

local shen = require("shen")
local R = require("runtime")
local C = require("compiler")

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end
local function eq(got, want, name)
  if got == want then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n  want: ", tostring(want),
             "\n  got:  ", tostring(got), "\n")
  end
end

-- Render a Shen cons list as "a b c" (space separated) for easy comparison.
local function show(x)
  local t = {}
  while R.is_cons(x) do t[#t+1] = tostring(x[1]); x = x[2] end
  return table.concat(t, " ")
end

-- The probe: (eo-log X) appends X to a global trace and returns X, so an
-- expression's operand order is directly readable off the trace.
shen.eval("(define eo-log X -> (do (set eo-trace [X | (value eo-trace)]) X))")

-- Evaluate SRC with a fresh trace; return the trace in evaluation order.
local function trace(src)
  shen.eval("(set eo-trace [])")
  shen.eval(src)
  return show(shen.eval("(reverse (value eo-trace))"))
end

-- Evaluate SRC with a fresh trace; return its VALUE rendered by `show`.
local function traced_value(src)
  shen.eval("(set eo-trace [])")
  return show(shen.eval(src))
end

-- "1 2 ... n"
local function upto(n)
  local t = {}
  for i = 1, n do t[i] = tostring(i) end
  return table.concat(t, " ")
end

-- "[(eo-log 1) (eo-log 2) ... (eo-log n)]"
local function lit(n)
  local t = {}
  for i = 1, n do t[i] = "(eo-log " .. i .. ")" end
  return "[" .. table.concat(t, " ") .. "]"
end

-- ---------------------------------------------------------------------------
-- list literals: left-to-right in every position, on both sides of the
-- 16-frame flattening threshold and of the 60-node MKTREE threshold.
-- ---------------------------------------------------------------------------
do
  for _, n in ipairs({ 3, 15, 16, 20, 70 }) do
    -- tail position: the function's body IS the list
    shen.eval("(define eo-tail Z -> " .. lit(n) .. ")")
    eq(trace("(eo-tail 0)"), upto(n),
       "list literal of " .. n .. " in tail position is left-to-right")
    eq(traced_value("(eo-tail 0)"), upto(n),
       "list literal of " .. n .. " in tail position has the right value")

    -- argument position: the list is an operand of another call
    shen.eval("(define eo-arg Z -> (length " .. lit(n) .. "))")
    eq(trace("(eo-arg 0)"), upto(n),
       "list literal of " .. n .. " in argument position is left-to-right")

    -- value (non-tail) position: bound by a let, body is something else
    shen.eval("(define eo-val Z -> (let L " .. lit(n) .. " done))")
    eq(trace("(eo-val 0)"), upto(n),
       "list literal of " .. n .. " in value position is left-to-right")
  end
end

-- ---------------------------------------------------------------------------
-- deep user call chains. The flattener walks the LAST-argument spine of any
-- call, not just `cons`, so a chain of two-argument user functions whose
-- first argument has an effect is the general form of the same bug.
-- ---------------------------------------------------------------------------
do
  shen.eval("(define eo-pair X Y -> [X | Y])")
  local n = 20
  local src = "[]"
  for i = n, 1, -1 do
    src = "(eo-pair (eo-log " .. i .. ") " .. src .. ")"
  end
  shen.eval("(define eo-chain Z -> " .. src .. ")")
  eq(trace("(eo-chain 0)"), upto(n),
     "deep user call chain evaluates non-last arguments left-to-right")
  eq(traced_value("(eo-chain 0)"), upto(n),
     "deep user call chain still computes the right value")

  -- Same chain, but the effect is in the LAST-but-one position of a
  -- three-argument function, i.e. two effectful prev args per frame.
  shen.eval("(define eo-tri X Y Z -> [X Y | Z])")
  local src3 = "[]"
  for i = n, 1, -2 do
    src3 = "(eo-tri (eo-log " .. (i - 1) .. ") (eo-log " .. i .. ") " .. src3 .. ")"
  end
  shen.eval("(define eo-chain3 Z -> " .. src3 .. ")")
  eq(trace("(eo-chain3 0)"), upto(n),
     "deep chain with two effectful prev args per frame is left-to-right")
end

-- ---------------------------------------------------------------------------
-- the flattening optimisation must still fire (it exists to dodge Lua's
-- expression-nesting parser limit; a fix that disabled it would regress that).
-- ---------------------------------------------------------------------------
do
  local loadchunk = loadstring or load
  -- 150 frames is comfortably past Lua's ~200-level expression-nesting limit
  -- when compiled as nested F["cons"](...) calls, and comfortably inside the
  -- 200-local ceiling of the flattened form. Assert the emitted chunk LOADS.
  local deep = "()"
  for i = 150, 1, -1 do deep = "(cons " .. i .. " " .. deep .. ")" end
  local src = C.cdefun(R.read_all("(defun eo-deep (Z) " .. deep .. ")")[1])
  check(loadchunk(src) ~= nil, "150-deep cons spine still compiles to loadable Lua")

  -- The effectful chain must not cost extra LOCALS (hoisting every operand
  -- into `local` bindings would halve the depth the flattener can handle);
  -- it must still load at the same depth.
  local eff = "()"
  for i = 150, 1, -1 do eff = "(cons (eo-log " .. i .. ") " .. eff .. ")" end
  local esrc = C.cdefun(R.read_all("(defun eo-deep-eff (Z) " .. eff .. ")")[1])
  check(loadchunk(esrc) ~= nil,
        "150-deep effectful cons spine still compiles to loadable Lua")

  -- The pure chain's codegen must be untouched by the fix: the hot Prolog
  -- CPS chains have only variable/atom prev args, and must not gain a
  -- scratch table.
  check(not src:find("= {};", 1, true),
        "pure chain codegen allocates no scratch table")
end

-- ---------------------------------------------------------------------------
-- collateral: constructs whose order must NOT have changed.
-- ---------------------------------------------------------------------------
do
  -- ordinary function application arguments
  shen.eval("(define eo-3 X Y Z -> [X Y Z])")
  eq(trace("(eo-3 (eo-log 1) (eo-log 2) (eo-log 3))"), "1 2 3",
     "function application arguments are left-to-right")

  -- nested applications
  eq(trace("(eo-3 (eo-log 1) (eo-3 (eo-log 2) (eo-log 3) (eo-log 4)) (eo-log 5))"),
     "1 2 3 4 5", "nested application arguments are left-to-right")

  -- let bindings, sequential
  eq(trace("(let A (eo-log 1) (let B (eo-log 2) (let C (eo-log 3) [A B C])))"),
     "1 2 3", "let bindings evaluate in source order")

  -- let value before body
  eq(trace("(let A (eo-log 1) (eo-log 2))"), "1 2",
     "let value evaluates before its body")

  -- do sequencing
  eq(trace("(do (eo-log 1) (do (eo-log 2) (eo-log 3)))"), "1 2 3",
     "do sequences left-to-right")

  -- arithmetic operands
  eq(trace("(+ (eo-log 1) (+ (eo-log 2) (eo-log 3)))"), "1 2 3",
     "arithmetic operands are left-to-right")

  -- tuples
  eq(trace("(@p (eo-log 1) (@p (eo-log 2) (eo-log 3)))"), "1 2 3",
     "tuple (@p) components are left-to-right")

  -- vectors
  eq(trace("(@v (eo-log 1) (@v (eo-log 2) (@v (eo-log 3) (vector 0))))"), "1 2 3",
     "vector (@v) elements are left-to-right")

  -- cons operator spelled out, below and above the threshold
  eq(trace("(cons (eo-log 1) (cons (eo-log 2) (cons (eo-log 3) [])))"), "1 2 3",
     "explicit cons spine is left-to-right (short)")

  -- string append operands
  eq(trace('(@s (eo-log "1") (@s (eo-log "2") (eo-log "3")))'), "1 2 3",
     "string append (@s) operands are left-to-right")

  -- if: test before the taken branch, untaken branch never evaluated
  eq(trace("(if (do (eo-log 1) true) (eo-log 2) (eo-log 3))"), "1 2",
     "if evaluates test then the taken branch only")

  -- freeze/thaw: the body must NOT run until thawed
  eq(trace("(let F (freeze (eo-log 2)) (do (eo-log 1) (thaw F)))"), "1 2",
     "freeze defers its body until thaw")
end

-- ---------------------------------------------------------------------------
-- a long list literal built from side-effecting elements is the exact urdr
-- shape: value AND order must both match the other three ports.
-- ---------------------------------------------------------------------------
do
  shen.eval("(define eo-mixed Z -> [(eo-log 1) 2 (eo-log 3) 4 (eo-log 5) 6 "
            .. "(eo-log 7) 8 (eo-log 9) 10 (eo-log 11) 12 (eo-log 13) 14 "
            .. "(eo-log 15) 16 (eo-log 17) 18 (eo-log 19) 20])")
  eq(trace("(eo-mixed 0)"), "1 3 5 7 9 11 13 15 17 19",
     "mixed literal/effect list literal is left-to-right")
  eq(traced_value("(eo-mixed 0)"), upto(20),
     "mixed literal/effect list literal has the right value")
end

io.write(string.format("eval_order_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
