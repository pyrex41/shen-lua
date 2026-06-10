-- test/tailcall_spec.lua — self-tail-call -> loop lowering (compiler.lua).
--   luajit test/tailcall_spec.lua
-- Covers: codegen shape (lowered vs skipped), swap semantics via simultaneous
-- assignment, the classic closure-capture-in-a-loop bug (param capture must
-- SKIP lowering; let-local capture must stay per-iteration fresh in a lowered
-- loop; freeze snapshots), deep iteration, and the not-lowered escape hatches
-- (APP/partial calls, mutual recursion, non-tail self-calls).
package.path = (arg[0]:gsub("test/[^/]*$", "")) .. "?.lua;" .. package.path

local P = require("boot")
local R = require("runtime")
local C = require("compiler")
P.load_kernel(false)

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end

local function ev(s)
  local fs = R.read_all(s)
  local r
  for _, f in ipairs(fs) do r = P.eval(f) end
  return r
end

-- render a cons list as "[a b c]" for easy comparison
local function show(x)
  if R.is_cons(x) then
    local t = {}
    while R.is_cons(x) do t[#t+1] = show(x[1]); x = x[2] end
    return "[" .. table.concat(t, " ") .. "]"
  end
  if x == R.NIL then return "[]" end
  return tostring(x)
end

local function gensrc(s)
  return C.cdefun(R.read_all(s)[1])
end

-- ---------------------------------------------------------------------------
-- codegen shape
-- ---------------------------------------------------------------------------
do
  local src = gensrc("(defun tc-len (L N) (if (cons? L) (tc-len (tl L) (+ N 1)) N))")
  check(src:find("goto tco", 1, true) and src:find("while true do", 1, true),
        "accumulator loop is lowered")

  -- non-tail self-call only (result is consumed) -> not lowered
  src = gensrc("(defun tc-tree (N) (if (= N 0) 1 (+ (tc-tree (- N 1)) 1)))")
  check(not src:find("goto", 1, true), "non-tail self-call not lowered")

  -- lambda closing over a param -> lowering must be skipped
  src = gensrc("(defun tc-cap (X Acc N) (if (= N 0) Acc (tc-cap X (cons (lambda Y X) Acc) (- N 1))))")
  check(not src:find("goto", 1, true), "lambda capturing a param skips lowering")

  -- lambda closing over a param SHADOWED by a let -> the capture is the
  -- let-local, not the param: lowering applies
  src = gensrc("(defun tc-shad (X N) (if (= N 0) X (tc-shad (let X N (lambda Y X)) (- N 1))))")
  check(src:find("goto tco", 1, true), "param shadowed by let does not block lowering")

  -- freeze capturing a param is BIND-snapshotted -> lowering applies
  src = gensrc("(defun tc-frz (N Acc) (if (= N 0) Acc (tc-frz (- N 1) (cons (freeze N) Acc))))")
  check(src:find("goto tco", 1, true), "freeze over a param does not block lowering")

  -- arity-mismatch self-call (partial application) -> not lowered
  src = gensrc("(defun tc-part (X Y) (if (= X 0) Y ((tc-part 0) (+ X Y))))")
  check(not src:find("goto", 1, true), "partial self-application not lowered")

  -- mixed (ackermann/tak shape): a tail self-call whose ARGUMENT recurses.
  -- NOT lowered at all -- pure_tail_self refuses, because a loop wrapped
  -- around residual non-tail recursion regresses LuaJIT tracing (measured:
  -- tak(24,16,8) 2.1x slower when mixed-lowered). All self-calls keep the
  -- plain F-table codegen.
  src = gensrc("(defun tc-ack (M N) (if (= M 0) (+ N 1) (if (= N 0) (tc-ack (- M 1) 1) (tc-ack (- M 1) (tc-ack M (- N 1))))))")
  check(not src:find("goto", 1, true) and src:find('F["tc-ack"]', 1, true),
        "mixed tail/non-tail (ackermann shape): not lowered")

  -- self-call in tail position of a value-position control form is NOT in the
  -- function's tail position; it must stay a call inside the hoisted KC body
  src = gensrc("(defun tc-val (N) (+ 1 (if (= N 0) 0 (tc-val (- N 1)))))")
  check(not src:find("goto", 1, true), "self-call inside value-position if not lowered")
end

-- ---------------------------------------------------------------------------
-- behavior
-- ---------------------------------------------------------------------------
do
  ev("(defun tc-len (L N) (if (cons? L) (tc-len (tl L) (+ N 1)) N))")
  check(ev("(tc-len (cons 1 (cons 2 (cons 3 ()))) 0)") == 3, "lowered accumulator result")

  -- (f Y X)-style swap: simultaneous reassignment, odd vs even iteration count
  ev("(defun tc-sw (X Y N) (if (= N 0) (cons X (cons Y ())) (tc-sw Y X (- N 1))))")
  check(show(ev("(tc-sw 1 2 3)")) == "[2 1]", "swap, odd iterations")
  check(show(ev("(tc-sw 1 2 4)")) == "[1 2]", "swap, even iterations")

  -- three-way rotation through the params
  ev("(defun tc-rot (A B C N) (if (= N 0) (cons A (cons B (cons C ()))) (tc-rot B C A (- N 1))))")
  check(show(ev("(tc-rot 1 2 3 4)")) == "[2 3 1]", "3-param rotation")

  -- THE classic bug: closures consed up while looping must see the values of
  -- THEIR iteration, not the final ones.
  -- (a) lambda over the param itself -> function is NOT lowered; still correct
  ev("(defun tc-cap (X Acc N) (if (= N 0) Acc (tc-cap (- X 1) (cons (lambda Y X) Acc) (- N 1))))")
  check(show(ev("(map (lambda F (F 0)) (tc-cap 3 () 3))")) == "[1 2 3]",
        "closures over params see per-iteration values (lowering skipped)")
  -- (b) lambda over a LET-local derived from a param -> function IS lowered;
  -- the let-local lives inside the loop block, so each iteration's closure
  -- must get a freshly-closed upvalue.
  ev("(defun tc-cap2 (X Acc N) (if (= N 0) Acc (tc-cap2 X (cons (let Z N (lambda Y Z)) Acc) (- N 1))))")
  check(gensrc("(defun tc-cap2 (X Acc N) (if (= N 0) Acc (tc-cap2 X (cons (let Z N (lambda Y Z)) Acc) (- N 1))))")
          :find("goto tco", 1, true) ~= nil,
        "let-local closure version is lowered")
  check(show(ev("(map (lambda F (F 0)) (tc-cap2 0 () 3))")) == "[1 2 3]",
        "closures over let-locals in a LOWERED loop see per-iteration values")
  -- (c) freeze over the param in a lowered loop: BIND snapshot per iteration
  ev("(defun tc-frz (N Acc) (if (= N 0) Acc (tc-frz (- N 1) (cons (freeze N) Acc))))")
  check(show(ev("(map (lambda F (thaw F)) (tc-frz 3 () ))")) == "[1 2 3]",
        "freezes in a lowered loop snapshot per-iteration values")

  -- deep iteration: 5M loop iterations, constant stack
  ev("(defun tc-count (N) (if (= N 0) 0 (tc-count (- N 1))))")
  check(ev("(tc-count 5000000)") == 0, "5M-iteration loop terminates")

  -- partial self-application still routes through APP correctly
  ev("(defun tc-part (X Y) (if (= X 0) Y ((tc-part 0) (+ X Y))))")
  check(ev("(tc-part 3 4)") == 7, "partial self-application works")

  -- mutual recursion (not self): unchanged, still proper tail calls
  ev("(defun tc-ev? (N) (if (= N 0) true (tc-od? (- N 1))))")
  ev("(defun tc-od? (N) (if (= N 0) false (tc-ev? (- N 1))))")
  check(ev("(tc-ev? 1000001)") == false, "mutual recursion still TCO")

  -- ackermann: mixed tail/non-tail -> NOT lowered (pure_tail_self), but must
  -- of course still compute correctly through the plain-call codegen
  ev("(defun tc-ack (M N) (if (= M 0) (+ N 1) (if (= N 0) (tc-ack (- M 1) 1) (tc-ack (- M 1) (tc-ack M (- N 1))))))")
  check(ev("(tc-ack 2 3)") == 9, "ackermann(2,3) = 9")
  check(ev("(tc-ack 3 3)") == 61, "ackermann(3,3) = 61")

  -- cond-based tail self-call
  ev("(defun tc-cond (N A) (cond ((= N 0) A) (true (tc-cond (- N 1) (+ A 2)))))")
  check(ev("(tc-cond 10 0)") == 20, "cond tail self-call")

  -- and/or tail positions
  ev("(defun tc-and (N) (and (cons? (cons N ())) (if (= N 0) true (tc-and (- N 1)))))")
  check(ev("(tc-and 100000)") == true, "self-call in `and` tail position")

  -- trap-error: protected self-call is value position (normal recursion)
  ev("(defun tc-tr (N) (trap-error (if (= N 0) (simple-error \"boom\") (tc-tr (- N 1))) (lambda E 99)))")
  check(ev("(tc-tr 50)") == 99, "self-call under trap-error")

  -- runtime redefinition: the F-table entry is replaced wholesale; NEW calls
  -- see the new definition (mid-loop iterations of an already-running loop do
  -- not -- documented semantic change).
  ev("(defun tc-redef (N) (if (= N 0) old (tc-redef (- N 1))))")
  check(ev("(tc-redef 5)") == R.intern("old"), "before redefinition")
  ev("(defun tc-redef (N) (if (= N 0) new (tc-redef (- N 1))))")
  check(ev("(tc-redef 5)") == R.intern("new"), "redefinition observed by new calls")
end

io.write(string.format("tailcall_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
