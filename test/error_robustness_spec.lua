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
-- DIVERGENCE: shen-lua's `if` does not require a boolean condition. A non-false
-- value is truthy, so (if 42 1 2) returns 1 (shen-go raises "if requires a
-- boolean"). Lock in the port's behavior.
-- ---------------------------------------------------------------------------
check(evs("(if 42 1 2)") == "1", "if with non-boolean condition is truthy (port divergence)")

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

io.write(string.format("error_robustness_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
