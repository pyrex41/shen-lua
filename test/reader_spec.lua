-- test/reader_spec.lua — PORT-AUTHORED reader coverage, mirroring shen-go's
-- kl/reader_test.go + kl/reader_fuzz_test.go.
--
-- Two parts:
--   (1) reader edge cases: atoms, lists, booleans, nested forms, strings with
--       embedded newlines, the [a b c] bracket-list rewrite (-> nested cons),
--       line comments (\\ ...), and multi-form input.
--   (2) a SEEDED malformed-input no-crash loop: each seed is fed through the
--       reader+evaluator and must NEVER crash the Lua process — it may only
--       return a value or raise a CATCHABLE error (Lua pcall always returns).
--       This is the property shen-go fuzzes; here it is a deterministic,
--       fixed-corpus loop (no randomness), so the run is reproducible.
--
-- read-from-string returns a LIST of top-level forms; we render it with the
-- port's printer for comparison.
--
--   luajit test/reader_spec.lua
local shen = require("shen")
shen.boot{ quiet = true }
local R = require("runtime")
local P = shen.prims

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end
local function checkeq(got, want, name)
  if got == want then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n  want: ", tostring(want), "\n  got:  ", tostring(got), "\n")
  end
end

-- read one source string into the list-of-forms and render it.
local function rd(src) return R.to_str(P.F["read-from-string"](src)) end

-- ---------------------------------------------------------------------------
-- (1) reader edge cases
-- ---------------------------------------------------------------------------
checkeq(rd("1234"), "(1234)", "integer atom")
checkeq(rd('"string"'), '("string")', "string atom")
checkeq(rd("symbol"), "(symbol)", "symbol atom")
checkeq(rd("()"), "(())", "empty list")
checkeq(rd("(1 2)"), "((1 2))", "two-element list")
checkeq(rd("true"), "(true)", "boolean true")
checkeq(rd("false"), "(false)", "boolean false")
checkeq(rd("(if true (if false 1 2) 3)"),
        "((if true (if false 1 2) 3))", "nested form")
-- string spanning a newline preserves the newline
checkeq(rd('"abc\nde"'), '("abc\nde")', "string with embedded newline")
-- the [a b c] bracket-list reader rewrites to nested (cons ...) forms
checkeq(rd("[a b c]"), "((cons a (cons b (cons c ()))))", "bracket list -> nested cons")
checkeq(rd("[]"), "(())", "empty bracket list -> ()")
-- line comments (\\) are skipped; reading continues with the next form
checkeq(rd("\\\\ a comment\n42"), "(42)", "line comment skipped")
-- multiple top-level forms come back as multiple list elements
checkeq(rd("(if true 1 false) 2"), "((if true 1 false) 2)", "multiple top-level forms")
-- nested lists round-trip structurally. NB: the port's printer renders a cons
-- whose head is a (non-special) symbol in curried-application form ((fn a) ...),
-- so we assert structure with NUMBER-headed lists, which print literally.
checkeq(rd("(1 (2 3) 4)"), "((1 (2 3) 4))", "nested sublist")

-- a single read form is a cons whose head is the form
do
  local forms = P.F["read-from-string"]("(+ 1 2)")
  check(R.is_cons(forms), "read-from-string returns a cons list")
  check(R.is_cons(forms[1]) and forms[1][1] == R.intern("+"),
        "first form is (+ ...) with + as head symbol")
end

-- ---------------------------------------------------------------------------
-- (2) seeded malformed-input no-crash loop.
-- Contract: for EVERY seed, reader+eval terminates without crashing the Lua
-- process. pcall must always return — either ok (a value) or a caught error.
-- Seeds are biased toward malformed Shen, in the shape of the bug that
-- triggered shen-go's fuzzer (`(/. _ false)` from layout proofs), plus
-- reader edge cases and unbalanced/garbage input.
-- ---------------------------------------------------------------------------
do
  local seeds = {
    -- golden path
    "(+ 1 2)",
    "(let X 1 (+ X 1))",
    "(if true 1 2)",
    -- error paths that must surface as CATCHABLE errors
    "(trap-error (overflow->str) (lambda E (error-to-string E)))",
    "(trap-error (value never-bound) (lambda E (error-to-string E)))",
    '(trap-error (simple-error "x") (lambda E (error-to-string E)))',
    "(trap-error (42 1) (lambda E (error-to-string E)))",
    "(trap-error (hd ()) (lambda E (error-to-string E)))",
    -- malformed-but-parseable, in the shape of the shen-go fuzzer's trophy:
    -- `_` as a lambda parameter is illegal Shen, must not crash the process.
    "(/. _ false)",
    "(lambda _ false)",
    -- dollar/garbage tokens
    "($ junk )",
    "(@p 1)",
    -- reader edge cases: must at minimum not crash
    "",
    " ",
    "()",
    "(",
    ")",
    '"unterminated',
    "#\\",
    "[a b",
    ")))",
    "(((",
    "\\\\ only a comment",
    "[a b . c]",
  }

  local crashed = nil
  for _, s in ipairs(seeds) do
    -- A belt-and-braces pcall: ANY uncaught Lua error out of reader/eval would
    -- be captured here. The contract is that pcall RETURNS (no longjmp out of
    -- the process, no hang) — the boolean ok value itself is irrelevant.
    local ok, err = pcall(function()
      local forms = P.F["read-from-string"](s)
      while R.is_cons(forms) do
        P.F["eval"](forms[1])
        forms = forms[2]
      end
    end)
    -- ok==false is fine (catchable error). The only failure is a thrown error
    -- whose object is itself unrenderable — verify we can stringify whatever
    -- came back, the same renderability clause shen-go's fuzzer asserts.
    if not ok then
      local rok = pcall(function()
        if type(err) == "table" and getmetatable(err) == R.Excn then
          return tostring(err.msg)
        end
        return tostring(err)
      end)
      if not rok then crashed = s end
    end
  end
  check(crashed == nil,
        "no seed produced an unrenderable crash" ..
        (crashed and (" (offender: " .. crashed .. ")") or ""))
  -- And the kernel is still alive after the whole storm.
  check(R.to_str(shen.eval("(+ 40 2)")) == "42",
        "kernel still evaluates after the malformed-input storm")
end

io.write(string.format("reader_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
