-- test/library_spec.lua — PORT-AUTHORED stdlib coverage, mirroring shen-go's
-- kl/library_test.go. Drives the kernel's standard library through shen.eval.
--
-- This is NOT the canonical kernel certification suite (run-kernel-tests.lua).
--
-- NB on scope: a handful of list functions present in some Shen distributions
-- (filter/take/drop/fold-*) are NOT defined in the kernel this port loads —
-- calling them raises "fn: <name> is undefined". We therefore cover the set
-- the port actually provides (map / reverse / append / element? / length /
-- head / tail / sum / remove / occurrences / reverse-involution / cons?/empty?)
-- and assert that the genuinely-absent ones report a clean catchable error
-- rather than crashing — that absence is itself a documented port fact.
--
--   luajit test/library_spec.lua
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
local function trap(src)
  return evs("(trap-error " .. src .. " (lambda E (error-to-string E)))")
end

-- ---------------------------------------------------------------------------
-- reverse
-- ---------------------------------------------------------------------------
checkeq("(reverse [1 2 3])", "(3 2 1)")
checkeq("(reverse [])", "()")
checkeq("(reverse [1])", "(1)")
checkeq("(reverse (reverse [1 2 3 4]))", "(1 2 3 4)")  -- involution

-- ---------------------------------------------------------------------------
-- append
-- ---------------------------------------------------------------------------
checkeq("(append [1 2] [3 4])", "(1 2 3 4)")
checkeq("(append [] [1 2])", "(1 2)")
checkeq("(append [1 2] [])", "(1 2)")

-- ---------------------------------------------------------------------------
-- map  (with a lambda)
-- ---------------------------------------------------------------------------
checkeq("(map (lambda X (* X 2)) [1 2 3])", "(2 4 6)")
checkeq("(map (lambda X (+ X 1)) [])", "()")

-- ---------------------------------------------------------------------------
-- element?
-- ---------------------------------------------------------------------------
checkeq("(element? 2 [1 2 3])", "true")
checkeq("(element? 9 [1 2 3])", "false")
checkeq("(element? 1 [])", "false")

-- ---------------------------------------------------------------------------
-- length / head / tail
-- ---------------------------------------------------------------------------
checkeq("(length [1 2 3])", "3")
checkeq("(length [])", "0")
checkeq("(head [10 20 30])", "10")
checkeq("(tail [10 20 30])", "(20 30)")

-- ---------------------------------------------------------------------------
-- sum / remove / occurrences
-- ---------------------------------------------------------------------------
checkeq("(sum [1 2 3 4])", "10")
checkeq("(sum [])", "0")
checkeq("(remove 2 [1 2 3 2])", "(1 3)")
checkeq("(remove 9 [1 2 3])", "(1 2 3)")
checkeq("(occurrences 2 [1 2 2 3 2])", "3")
checkeq("(occurrences 9 [1 2 3])", "0")

-- ---------------------------------------------------------------------------
-- cons?/empty? on list shapes
-- ---------------------------------------------------------------------------
checkeq("(cons? [1])", "true")
checkeq("(cons? [])", "false")
checkeq("(empty? [])", "true")
checkeq("(empty? [1])", "false")

-- ---------------------------------------------------------------------------
-- A user-defined recursive function over a list (factorial-style fold by hand)
-- proves the stdlib composes with user code.
-- ---------------------------------------------------------------------------
shen.eval([[(define lib-spec-sumlist
  [] -> 0
  [X | Xs] -> (+ X (lib-spec-sumlist Xs)))]])
checkeq("(lib-spec-sumlist [1 2 3 4 5])", "15")
checkeq("(lib-spec-sumlist [])", "0")

-- ---------------------------------------------------------------------------
-- DOCUMENTED ABSENCE: filter/take/drop are not provided by the loaded kernel;
-- calling them raises a clean catchable error rather than crashing the process.
-- (If a future kernel revision adds them, flip these to behavior assertions.)
-- ---------------------------------------------------------------------------
shen.eval("(define lib-spec-gt1 X -> (> X 1))")
check(trap("(filter lib-spec-gt1 [1 2 3])"):find("filter is undefined", 1, true) ~= nil,
      "absent stdlib filter reports a clean 'undefined' error (not a crash)")
check(trap("(take 2 [1 2 3])"):find("take is undefined", 1, true) ~= nil,
      "absent stdlib take reports a clean 'undefined' error (not a crash)")

io.write(string.format("library_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
