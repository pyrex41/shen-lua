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
-- long let chains: past a local budget the rest of the chain continues in a
-- separate KC function (Lua caps a function at 200 locals). Order, value and
-- tail calls must be unaffected. Each binding feeds the next, as in the
-- kernel's pattern-matching code, so few are live across a split point.
-- ---------------------------------------------------------------------------
do
  -- past Lua's 200-local cap; kept shallow otherwise, since the Shen reader
  -- recurses several frames per nesting level
  local n = 210
  -- L1 = Z + log(1), Li = L(i-1) + log(i); every binding is a local
  local function chain(step, final)
    local src = final
    for i = n, 2, -1 do
      src = "(let L" .. i .. " (+ L" .. (i - 1) .. " " .. step(i) .. ") " .. src .. ")"
    end
    return "(let L1 (+ Z " .. step(1) .. ") " .. src .. ")"
  end
  local logged = function(i) return "(eo-log " .. i .. ")" end
  local Ln = "L" .. n
  local total = n * (n + 1) / 2

  local kl = R.read_all("(defun eo-lets-kl (Z) " .. chain(logged, Ln) .. ")")[1]
  check((loadstring or load)(C.cdefun(kl)) ~= nil, "210-let KL defun compiles to loadable Lua")

  shen.eval("(define eo-lets Z -> " .. chain(logged, Ln) .. ")")
  eq(trace("(eo-lets 0)"), upto(n), "210-let chain evaluates in source order")
  eq(shen.eval("(eo-lets 0)"), total, "210-let chain value")
  -- a binding from before the split, read after it
  shen.eval("(define eo-lets-early Z -> " .. chain(logged, "(+ L1 " .. Ln .. ")") .. ")")
  eq(shen.eval("(eo-lets-early 5)"), 5 + 1 + 5 + total, "binding from before a let split is visible after it")

  -- the same chain in value position (hoisted as a control form first)
  shen.eval("(define eo-lets-val Z -> (+ 1 " .. chain(logged, Ln) .. "))")
  eq(shen.eval("(eo-lets-val 0)"), total + 1, "210-let chain in value position")

  -- a self-tail call that ends up in the split-off part stays a tail call
  local plain = function(i) return tostring(i) end
  shen.eval("(define eo-lets-rec 0 Acc -> Acc N Acc -> "
            .. chain(plain, "(eo-lets-rec (- N 1) (+ Acc " .. Ln .. "))")
            :gsub("%(%+ Z ", "(+ 0 ") .. ")")
  eq(shen.eval("(eo-lets-rec 20000 0)"), 20000 * total,
     "self tail call past a let split does not grow the stack")
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

-- ---------------------------------------------------------------------------
-- curried call chains ((((fn f) a) b) c): what Shen 42 emits for a call into
-- a function whose arity was unknown when the form was translated (a
-- library the same file loads). compiler.lua curried_call turns the chain
-- into one CURn call; order, errors and arity mismatches must not change.
-- ---------------------------------------------------------------------------
do
  local F = shen.prims.F
  local function kl(src)            -- compile+run one KL form
    return F["eval-kl"](R.read_all(src)[1])
  end
  local function klsrc(src)
    return C.compile_expr_chunk(R.read_all(src)[1])
  end

  shen.eval("(define eo-c3 A B C -> [A B C])")
  eq(show(kl("((((fn eo-c3) 1) 2) 3)")), "1 2 3", "curried chain, exact arity")
  check(klsrc("((((fn eo-c3) 1) 2) 3)"):find("CUR3(", 1, true),
        "curried chain compiles to CUR3")

  -- operands still evaluate left to right
  shen.eval("(set eo-trace [])")
  kl("((((fn eo-c3) (eo-log 1)) (eo-log 2)) (eo-log 3))")
  eq(show(shen.eval("(reverse (value eo-trace))")), "1 2 3",
     "curried chain: operands left to right")

  -- shorter chain than the arity: still a partial application
  eq(show(kl("(((((fn eo-c3) 1) 2)) 3)")), "1 2 3", "curried chain shorter than arity -> partial")

  -- runtime arity smaller than the chain: over-application through the
  -- original nested APPs (order-free args, so the rewrite applies)
  shen.eval("(define eo-c1 A -> (/. B (/. C [A B C])))")
  eq(show(kl("((((fn eo-c1) x) y) z)")), "x y z", "curried chain over-applies a 1-ary function")

  -- effectful later operands + a compile-time arity that does not match the
  -- chain: left as nested APPs, so intermediate calls keep their place
  check(not klsrc("((((fn eo-c1) (eo-log 1)) (eo-log 2)) (eo-log 3))"):find("CUR3(", 1, true),
        "mismatched arity + effectful operands: not rewritten")
  shen.eval("(set eo-trace [])")
  shen.eval("(define eo-c1l A -> (do (eo-log f) (/. B (/. C [A B C]))))")
  kl("((((fn eo-c1l) (eo-log 1)) (eo-log 2)) (eo-log 3))")
  eq(show(shen.eval("(reverse (value eo-trace))")), "1 f 2 3",
     "mismatched arity: the call runs before later operands")

  -- A matching compile-time arity is not permanent: an already-compiled
  -- caller must preserve intermediate calls and errors after redefinition.
  shen.eval("(define eo-redef A B -> [A B])")
  kl("(defun eo-redef-call () (((fn eo-redef) (eo-log 1)) (eo-log 2)))")
  shen.eval("(define eo-redef A -> (do (eo-log f) (/. B [A B])))")
  shen.eval("(set eo-trace [])")
  eq(show(kl("(eo-redef-call)")), "1 2", "redefined curried callee: result")
  eq(show(shen.eval("(reverse (value eo-trace))")), "1 f 2",
     "redefined curried callee runs before the later operand")
  shen.eval('(define eo-redef A -> (simple-error "eo stop"))')
  shen.eval("(set eo-trace [])")
  local redef_ok, redef_err = pcall(kl, "(eo-redef-call)")
  check(not redef_ok, "redefined curried callee raises")
  eq(F["error-to-string"](redef_err), "eo stop", "redefined callee error preserved")
  eq(show(shen.eval("(reverse (value eo-trace))")), "1",
     "redefined curried callee error prevents the later operand")

  -- an undefined function raises before any operand is evaluated
  shen.eval("(set eo-trace [])")
  local ok = pcall(kl, "((((fn eo-undefined-fn) (eo-log 1)) 2) 3)")
  check(not ok, "curried chain to an undefined function raises")
  eq(show(shen.eval("(reverse (value eo-trace))")), "",
     "undefined function: no operand evaluated first")

  -- the real shape: a file that loads a library and calls it
  local dir = os.tmpname()
  os.remove(dir)
  local lib, main = dir .. "-eo-lib.shen", dir .. "-eo-main.shen"
  local fh = assert(io.open(lib, "w"))
  fh:write("(define eo-lib3 A B C -> (+ A (* B C)))\n"); fh:close()
  fh = assert(io.open(main, "w"))
  fh:write('(load "' .. lib .. '")\n(define eo-use X -> (eo-lib3 X 2 3))\n'); fh:close()
  shen.prims.GLOBALS["*hush*"] = true
  shen.eval('(load "' .. main .. '")')
  shen.prims.GLOBALS["*hush*"] = false
  os.remove(lib); os.remove(main)
  eq(shen.eval("(eo-use 1)"), 7, "library call from a loading file")
end

io.write(string.format("eval_order_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
