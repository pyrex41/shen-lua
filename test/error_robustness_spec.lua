-- test/error_robustness_spec.lua — PORT-AUTHORED adversarial robustness suite,
-- mirroring shen-go's kl/error_robustness_test.go.
--
-- Freezes the error-CATCHABILITY CONTRACT: every documented kernel error path
--   (1) is catchable via (trap-error ... (lambda E ...)),
--   (2) surfaces a stable, informative message, and
--   (3) leaves the interpreter usable — the NEXT eval still succeeds.
--
-- shen-go runs each case on BOTH eval paths (tree-walker + bytecode VM). shen-lua
-- compiles every form to Lua through ONE pipeline (compiler.lua) — there is no
-- separate bytecode VM — so the "two paths" reduce to: (a) the form at top level,
-- and (b) the form inside a compiled `define` body invoked as a function. We
-- exercise both, which is the meaningful analogue here.
--
-- Messages differ from shen-go (different host, different error strings): we lock
-- in shen-lua's OWN documented messages, not shen-go's. Notable divergence:
-- shen-lua's `if` does NOT type-check its condition (any non-false value is
-- truthy), so `(if 42 1 2)` returns 1 rather than raising — asserted as the
-- port's correct behavior.
--
--   luajit test/error_robustness_spec.lua
local shen = require("shen")
shen.boot{ quiet = true }
local R = require("runtime")

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end
local function evs(src) return R.to_str(shen.eval(src)) end
-- error-to-string returns a Shen string; rendered it is quoted, so compare to
-- the quoted form.
local function trap(src)
  return evs("(trap-error " .. src .. " (lambda E (error-to-string E)))")
end

-- The documented, catchable error paths and their stable messages.
local cases = {
  { name = "apply unbound symbol", trigger = "(overflow->str)",
    want = '"not a function: overflow->str"' },
  { name = "apply non-function literal", trigger = "(42 1)",
    want = '"attempt to apply a non-function"' },
  { name = "value of unbound variable", trigger = "(value never-bound-xyz)",
    want = '"variable never-bound-xyz has no value"' },
  { name = "hd of empty list", trigger = "(hd ())",
    want = '"hd of non-cons"' },
  { name = "tl of empty list", trigger = "(tl ())",
    want = '"tl of non-cons"' },
  { name = "division by zero", trigger = "(/ 1 0)",
    want = '"division by zero"' },
  { name = "simple-error explicit", trigger = '(simple-error "oops")',
    want = '"oops"' },
}

-- (1) top-level (tree-walked) path.
for _, c in ipairs(cases) do
  local got = trap(c.trigger)
  check(got == c.want, "tree/" .. c.name .. ": got " .. got)
  -- state is clean enough for the next eval to succeed
  check(evs("(+ 40 2)") == "42", "tree/" .. c.name .. ": post-error eval works")
end

-- (2) compiled-function-body path: wrap the trigger in a define and invoke it.
-- This forces the form through the full compile-to-Lua pipeline rather than the
-- top-level evaluator.
do
  local i = 0
  for _, c in ipairs(cases) do
    i = i + 1
    local fname = "err-robust-fn-" .. i
    shen.eval(string.format("(define %s -> %s)", fname, c.trigger))
    local got = trap(string.format("(%s)", fname))
    check(got == c.want, "compiled/" .. c.name .. ": got " .. got)
    check(evs("(+ 40 2)") == "42", "compiled/" .. c.name .. ": post-error eval works")
  end
end

-- ---------------------------------------------------------------------------
-- A non-boolean test raises, for the test of if and cond and both operands of
-- and/or, wherever the form sits. Short-circuited operands are not evaluated.
-- ---------------------------------------------------------------------------
local function raises_boolean(src)
  local ok, err = pcall(evs, src)
  local msg = not ok and tostring(type(err) == "table" and (err.msg or err[1]) or err) or ""
  check(not ok, src .. " raises")
  if not ok then check(msg:find("is not a boolean", 1, true) ~= nil, src .. " says why, got: " .. msg) end
end
for _, src in ipairs({
  "(if 42 1 2)", '(if "a" 1 2)', "(if [] 1 2)", "(if a 1 2)",
  "(and 1 true)", "(and true 1)", "(or 1 false)", "(or false 1)",
  "(cond (1 a) (true b))", "(cond (false a) (2 b))",
  "(let X 1 (if X a b))", "(let F (/. X (if X a b)) (F 1))", "(do 1 (if 3 a b))",
  "(let X (and true 1) X)", "(if (and true 1) a b)", "(and true (if true 1 false))",
  "(and true (let Y 1 Y))", "(and true (do 0 1))", "(or false (cond (true 1)))",
}) do raises_boolean(src) end
evs("(define rob-id X -> X)")
raises_boolean("(if (rob-id 1) a b)")
raises_boolean("(and (rob-id true) (rob-id 1))")
check(evs("(if (rob-id true) 1 2)") == "1", "a call that gives true passes")
check(evs("(if (rob-id false) 1 2)") == "2", "a call that gives false passes")
check(evs("(and false 1)") == "false", "and does not evaluate past false")
check(evs("(or true 1)") == "true", "or does not evaluate past true")
check(evs("(and true (rob-id false))") == "false", "and gives its last operand")
check(evs("(or false (rob-id true))") == "true", "or gives its last operand")
check(evs("(if (and true (and (rob-id true) (or false (rob-id true)))) 1 2)") == "1", "nested tests")
-- a loop through and/or stays a loop, and still reaches a bad element
evs("(define rob-all [] -> true [X | Xs] -> (and (rob-id X) (rob-all Xs)))")
evs("(define rob-none [] -> false [X | Xs] -> (or (rob-id X) (rob-none Xs)))")
evs("(define rob-iota 0 V A -> A N V A -> (rob-iota (- N 1) V [V | A]))")
check(evs("(rob-all (rob-iota 3000000 true []))") == "true", "and: a tail call to itself keeps its frame")
check(evs("(rob-none (rob-iota 3000000 false []))") == "false", "or: a tail call to itself keeps its frame")
raises_boolean("(rob-all [true 1 true])")
-- so does one through another function, however deep
evs("(define rob-ev? 0 -> true N -> (and (number? N) (rob-od? (- N 1))))")
evs("(define rob-od? 0 -> false N -> (and (number? N) (rob-ev? (- N 1))))")
evs("(define rob-ev2? 0 -> false N -> (or (not (number? N)) (rob-od2? (- N 1))))")
evs("(define rob-od2? 0 -> false N -> (or (not (number? N)) (rob-ev2? (- N 1))))")
local function deep(src, want, name)
  local ok, got = pcall(evs, src)
  check(ok and got == want, name .. ", got " .. tostring(ok and got or "an error"))
end
deep("(rob-ev? 5000000)", "true", "and: a tail call to another function keeps its frame")
deep("(rob-ev2? 5000000)", "false", "or: a tail call to another function keeps its frame")
for name, src in pairs({
  ["and"] = "(define rob-%s 0 -> true N -> (and (number? N) (rob-%s (- N 1))))",
  ["and-if-then"] = "(define rob-%s 0 -> true N -> (and (number? N) (if (> N 0) (rob-%s (- N 1)) false)))",
  ["and-if-else"] = "(define rob-%s 0 -> true N -> (and (number? N) (if (= N 0) false (rob-%s (- N 1)))))",
  ["and-cond"] = "(define rob-%s 0 -> true N -> (and (number? N) (cond ((> N 0) (rob-%s (- N 1))) (true false))))",
  ["and-let"] = "(define rob-%s 0 -> true N -> (and (number? N) (let M (- N 1) (rob-%s M))))",
  ["and-do"] = "(define rob-%s 0 -> true N -> (and (number? N) (do 1 (rob-%s (- N 1)))))",
  ["and-and"] = "(define rob-%s 0 -> true N -> (and (number? N) (and (integer? N) (rob-%s (- N 1)))))",
  ["and-or"] = "(define rob-%s 0 -> true N -> (and (number? N) (or (string? N) (rob-%s (- N 1)))))",
  ["if-and"] = "(define rob-%s 0 -> true N -> (if (> N 0) (and (number? N) (rob-%s (- N 1))) false))",
  ["or"] = "(define rob-%s 0 -> true N -> (or (string? N) (rob-%s (- N 1))))",
  ["or-if"] = "(define rob-%s 0 -> true N -> (or (string? N) (if (> N 0) (rob-%s (- N 1)) false)))",
  ["or-cond"] = "(define rob-%s 0 -> true N -> (or (string? N) (cond ((> N 0) (rob-%s (- N 1))) (true false))))",
  ["freeze-and"] = "(define rob-%s 0 -> true N -> (thaw (freeze (and (number? N) (rob-%s (- N 1))))))",
  ["lambda-and"] = "(define rob-%s 0 -> true N -> ((/. M (and (number? M) (rob-%s M))) (- N 1)))",
}) do
  local a, b = "a-" .. name, "b-" .. name
  evs(src:format(a, b)); evs(src:format(b, a))
  local ok, got = pcall(evs, "(rob-" .. a .. " 5000000)")
  check(ok and got == "true", "mutual tail recursion, depth 5M, through " .. name .. ", got " .. tostring(ok and got or "an error"))
end
evs("(define rob-va _ 0 -> true F N -> (and (number? N) (F F (- N 1))))")
evs("(define rob-vgo N -> (rob-va (/. F M (rob-va F M)) N))")
deep("(rob-vgo 5000000)", "true", "depth 5M through a variable under and")
evs("(define rob-apply F X -> (and true (F X)))")
check(evs("(rob-apply (/. X (rob-ev? X)) 2)") == "true", "and: a tail call through a variable")
-- the tail call is unchecked; a test of its result, here or in the caller, is not
evs("(define rob-last X -> (and true (rob-id X)))")
evs("(define rob-test X -> (if (rob-last X) yes no))")
evs("(define rob-inner X -> (if (and true (rob-id X)) yes no))")
evs("(define rob-let X -> (let Y (and true (rob-id X)) Y))")
evs("(define rob-prim X -> (and true (+ X 1)))")
-- the hole, on purpose: Shen/JIT and Shen/Scheme raise on these, shen-go gives 5
evs("(define rob-lastif X -> (and true (if true (rob-id X) false)))")
evs("(define rob-lastor X -> (or false (rob-id X)))")
evs("(define rob-lastfz X -> (thaw (freeze (and true (rob-id X)))))")
evs("(define rob-lastlam X -> ((/. Y (and true (rob-id Y))) X))")
check(evs("(rob-lastif 1)") == "1", "unchecked: a tail call under if under and")
check(evs("(rob-lastor 1)") == "1", "unchecked: a tail call under or")
check(evs("(rob-lastfz 1)") == "1", "unchecked: a freeze body's tail call")
check(evs("(rob-lastlam 1)") == "1", "unchecked: a lambda body's tail call")
check(evs("(rob-last 1)") == "1", "a defun's tail call through and returns its value")
raises_boolean("(rob-test 1)")
raises_boolean("(rob-inner 1)")
raises_boolean("(rob-let 1)")
raises_boolean("(rob-prim 1)")
check(evs("(rob-test true)") == "yes", "a test of a boolean tail result passes")
check(evs("(rob-inner false)") == "no", "and in a test passes false")

-- ---------------------------------------------------------------------------
-- Adversarial sequence: drive several errors in a row through the SAME booted
-- kernel, interleaved with a valid form, asserting state never gets poisoned.
-- (The shen-go regression only surfaced when an error cascaded into the next
-- eval; this end-to-end loop keeps that class of regression visible.)
-- ---------------------------------------------------------------------------
do
  local seq = {
    { "(overflow->str)",          '"not a function: overflow->str"' },
    { "(value not-bound-1)",       '"variable not-bound-1 has no value"' },
    { "(hd ())",                   '"hd of non-cons"' },
    { '(simple-error "boom")',     '"boom"' },
    { "(/ 1 0)",                   '"division by zero"' },
  }
  for i, step in ipairs(seq) do
    local got = trap(step[1])
    check(got == step[2], "sequence[" .. i .. "] " .. step[1] .. ": got " .. got)
  end
  -- after all those errors, a plain form still evaluates correctly
  check(evs("(* 6 7)") == "42", "sequence: valid form still works after error storm")
end

-- ---------------------------------------------------------------------------
-- The handler receives the actual error object; the simplest catchable contract
-- is that trap-error returns the HANDLER's value, not the error, on a caught
-- error, and returns the BODY's value when no error fires.
-- ---------------------------------------------------------------------------
check(evs("(trap-error (+ 1 2) (lambda E 99))") == "3",
      "trap-error returns body value when no error")
check(evs("(trap-error (hd ()) (lambda E 99))") == "99",
      "trap-error returns handler value when error fires")
-- nested trap-error: inner catches, outer never sees it
check(evs("(trap-error (trap-error (hd ()) (lambda E (simple-error \"inner\"))) (lambda E (error-to-string E)))")
        == '"inner"',
      "nested trap-error: handler may re-raise and be caught by the outer trap")
-- Operand of <-vector raises: must NOT leak through the trap-error peephole.
check(evs("(trap-error (<-vector (simple-error \"boom\") 1) (lambda E 42))") == "42",
      "trap-error catches errors while evaluating <-vector operands")

io.write(string.format("error_robustness_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
