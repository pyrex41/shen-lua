-- test/primitives_spec.lua — PORT-AUTHORED coverage of the KLambda primitive
-- surface, driven through the kernel via shen.eval (the embedding API), mirroring
-- shen-go's kl/primitives_test.go + kl/primitives_coverage_test.go.
--
-- This is NOT the canonical kernel certification suite (that is
-- run-kernel-tests.lua / `make certify`). It exercises ~50 primitives —
-- arithmetic incl. float comparisons, string ops, symbols, cons/hd/tl,
-- absvector slots, type predicates, hashing, get-time — with REAL assertions
-- on the port's documented behavior.
--
-- DIVERGENCES from shen-go locked in here (with comments at each site):
--   * floats render bare ("3.5"), not C-printf "%f" ("3.500000");
--   * an uninitialized absvector slot reads back as the `shen.fail!` symbol
--     (shen-go returns a distinguished `undefined` object);
--   * an out-of-range <-address reads back as nil rather than raising.
--
--   luajit test/primitives_spec.lua
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
-- Evaluate Shen source and render the resulting value with the port's printer.
local function evs(src)
  return R.to_str(shen.eval(src))
end
local function checkeq(src, want)
  local ok, got = pcall(evs, src)
  if not ok then
    nfail = nfail + 1
    io.write("FAIL: ", src, "  (raised: ", tostring(got), ")\n")
  elseif got == want then
    npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", src, "\n  want: ", want, "\n  got:  ", got, "\n")
  end
end
-- Evaluate the trigger inside trap-error and return the error message string.
local function trap(src)
  return evs("(trap-error " .. src .. " (lambda E (error-to-string E)))")
end

-- ---------------------------------------------------------------------------
-- arithmetic (int + float; float comparisons)
-- ---------------------------------------------------------------------------
checkeq("(+ 2 3)", "5")
checkeq("(- 5 3)", "2")
checkeq("(* 6 7)", "42")
checkeq("(/ 20 4)", "5")
checkeq("(/ 7 2)", "3.5")             -- divergence: bare float, not "3.500000"
checkeq("(- 5.5 2.0)", "3.5")
checkeq("(* 1.5 3.0)", "4.5")
checkeq("(+ -2 2)", "0")
checkeq("(= 1 1)", "true")
checkeq("(= 1 2)", "false")
checkeq("(< 1 2)", "true")
checkeq("(> 1 2)", "false")
checkeq("(<= 2 2)", "true")
checkeq("(>= 2 3)", "false")
checkeq("(< 1.5 2.5)", "true")        -- float comparison
checkeq("(<= 2.5 2.5)", "true")
checkeq("(> 3.5 2.5)", "true")

-- ---------------------------------------------------------------------------
-- cons / hd / tl  (incl. empty-list error contract)
-- ---------------------------------------------------------------------------
checkeq("(hd (cons 1 (cons 2 ())))", "1")
checkeq("(tl (cons 1 (cons 2 ())))", "(2)")
checkeq("(cons 1 (cons 2 ()))", "(1 2)")
checkeq("(cons 1 2)", "(1 . 2)")      -- improper pair renders dotted
-- trap returns the (error-to-string E) value as a Shen string; rendered with
-- the port's printer it is quoted.
check(trap("(hd ())") == '"hd of non-cons"', "hd of () raises 'hd of non-cons'")
check(trap("(tl ())") == '"tl of non-cons"', "tl of () raises 'tl of non-cons'")

-- ---------------------------------------------------------------------------
-- string ops: cn / pos / tlstr / str / string->n / n->string
-- ---------------------------------------------------------------------------
checkeq('(string->n "A")', "65")
checkeq("(n->string 65)", '"A"')
checkeq('(cn "foo" "bar")', '"foobar"')
checkeq('(tlstr "hello")', '"ello"')
checkeq('(pos "hello" 1)', '"e"')
checkeq("(str 42)", '"42"')
checkeq("(str 4.5)", '"4.5"')          -- divergence: bare float
checkeq("(str foo)", '"foo"')
checkeq("(str true)", '"true"')
checkeq('(string? "hi")', "true")
checkeq("(string? 1)", "false")
-- str on () is NOT representable in this port's kernel — it raises a clean,
-- catchable error rather than returning "()" (shen-go renders "()").
check(trap("(str ())") == '"str: cannot convert ()"', "str of () raises a clean error")

-- ---------------------------------------------------------------------------
-- symbols: intern / value / set
-- ---------------------------------------------------------------------------
checkeq('(intern "abc")', "abc")
checkeq("(do (set the-prim-var 99) (value the-prim-var))", "99")
checkeq("(do (set the-prim-var 7) (set the-prim-var 8) (value the-prim-var))", "8")
-- value of an unbound global is a catchable error.
check(trap("(value never-bound-xyz)") == '"variable never-bound-xyz has no value"',
      "value of unbound global raises a clean error")

-- ---------------------------------------------------------------------------
-- type predicates
-- ---------------------------------------------------------------------------
checkeq("(number? 42)", "true")
checkeq("(number? foo)", "false")
checkeq("(symbol? hello)", "true")
checkeq("(symbol? 1)", "false")
checkeq("(variable? X)", "true")       -- uppercase first char => variable
checkeq("(variable? x)", "false")
checkeq("(cons? (cons 1 ()))", "true")
checkeq("(cons? 1)", "false")
checkeq("(absvector? (absvector 3))", "true")
checkeq("(absvector? 1)", "false")
checkeq("(boolean? true)", "true")
checkeq("(boolean? 1)", "false")
checkeq("(empty? ())", "true")
checkeq("(empty? (cons 1 ()))", "false")
checkeq("(not true)", "false")
checkeq("(not false)", "true")

-- ---------------------------------------------------------------------------
-- absvector / address-> / <-address (incl. uninitialized + out-of-range slots)
-- ---------------------------------------------------------------------------
-- address-> returns the (mutated) vector; <-address reads the slot back.
checkeq("(<-address (address-> (absvector 3) 1 7) 1)", "7")
-- Uninitialized slot: this port reads back the `shen.fail!` symbol (shen-go
-- returns a distinguished `undefined` object). Lock in the port's behavior.
checkeq("(<-address (absvector 3) 0)", "shen.fail!")
-- Out-of-range read does not raise here — it returns nil (Lua nil -> renders
-- as the empty string via to_str). We assert the no-raise contract directly.
do
  local ok = pcall(function() return shen.eval("(<-address (absvector 3) 99)") end)
  check(ok, "out-of-range <-address does not raise (returns nil)")
end

-- ---------------------------------------------------------------------------
-- eval-kl: its argument evaluates to a KL form, which is then evaluated.
-- (cons + (cons 3 (cons 4 ()))) builds (+ 3 4) => 7
-- ---------------------------------------------------------------------------
checkeq("(eval-kl (cons + (cons 3 (cons 4 ()))))", "7")

-- ---------------------------------------------------------------------------
-- hashing: deterministic, equal keys hash equal, stays a positive number.
-- The kernel's `hash` takes (key limit) and returns a bucket index.
-- ---------------------------------------------------------------------------
do
  local a = shen.eval('(hash "session-token-42" 256)')
  local b = shen.eval('(hash "session-token-42" 256)')
  check(type(a) == "number" and a == b, "hash is deterministic for equal keys")
  -- distinct keys shouldn't all collide into one bucket
  local seen = {}
  for i = 1, 100 do
    local h = shen.eval(string.format('(hash "distinct-%d" 256)', i))
    seen[h] = true
  end
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  -- The kernel hash clusters near-identical keys; >=20 buckets for 100 keys is
  -- enough to prove it is not collapsing everything to a single bucket.
  check(n >= 20, "hash spreads 100 distinct keys over >=20 buckets (got " .. n .. ")")
end

-- ---------------------------------------------------------------------------
-- get-time: both run and unix arms return numbers
-- ---------------------------------------------------------------------------
check(type(shen.eval("(get-time run)")) == "number", "get-time run is a number")
check(type(shen.eval("(get-time unix)")) == "number", "get-time unix is a number")

io.write(string.format("primitives_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
