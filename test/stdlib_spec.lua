-- test/stdlib_spec.lua — regression for loading the standard library from its
-- S-lineage Shen sources (lib/StLib) instead of a precompiled stlib.kl.
--
-- The motivating bug: the pre-refresh port booted klambda/stlib.kl as raw KL
-- defuns, which put functions in F but NEVER registered their `arity` property
-- or shen.*lambdatable* entry (stlib.initialise was never called). So a bare
-- top-level `(filter ...)` or a first-class `(fn filter)` — both of which
-- resolve through the lambda table — died with "fn: filter is undefined",
-- even though the function existed. Loading the stdlib through the kernel's own
-- (load)/define pipeline (boot.lua load_stdlib) registers the arity + lambda
-- entry, so these now work. This spec locks that behaviour in.
--
--   luajit test/stdlib_spec.lua
local shen = require("shen")
shen.boot{ quiet = true }
local R = require("runtime")

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else nfail = nfail + 1; io.write("FAIL: ", name, "\n") end
end
local function evs(src) return R.to_str(shen.eval(src)) end
local function checkeq(src, want)
  local ok, got = pcall(evs, src)
  if not ok then nfail = nfail + 1; io.write("FAIL: ", src, "  (raised: ", tostring(got), ")\n")
  elseif got == want then npass = npass + 1
  else nfail = nfail + 1; io.write("FAIL: ", src, "\n  want: ", want, "\n  got:  ", got, "\n") end
end

-- ---- the exact regression: arity is registered, (fn ...) resolves ----------
check(shen.call("arity", shen.sym("filter")) == 2,
      "filter has a registered runtime arity (not -1)")

-- bare top-level application (compiles through the (fn filter) lambda-table path)
checkeq("(filter (/. X (> X 2)) [1 2 3 4 5])", "(3 4 5)")

-- first-class function reference: (fn filter) must resolve to a callable value,
-- not raise "fn: filter is undefined"
check((pcall(shen.eval, "(fn filter)")), "(fn filter) resolves to a value")
checkeq("(map (fn filter) [])", "()")   -- map over [] just exercises (fn filter) eval

-- higher-order use of a stdlib function passed by name
checkeq("((fn filter) (/. X (> X 0)) [-1 2 -3 4])", "(2 4)")

-- ---- coverage across the stdlib modules the install loads ------------------
checkeq("(take 2 [a b c d])", "(a b)")
checkeq("(drop 2 [a b c d])", "(c d)")
checkeq("(reverse (take 3 [1 2 3 4 5]))", "(3 2 1)")
checkeq("(map (/. X (* X X)) [1 2 3])", "(1 4 9)")     -- kernel-core, sanity

io.write(string.format("stdlib_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
