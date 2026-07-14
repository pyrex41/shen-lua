-- test/library_spec.lua — PORT-AUTHORED stdlib coverage, mirroring shen-go's
-- kl/library_test.go. Drives the kernel's standard library through shen.eval.
--
-- This is NOT the canonical kernel certification suite (run-kernel-tests.lua).
--
-- NB on scope: the standard library is loaded at boot from the S-lineage
-- lib/StLib Shen sources (see boot.lua load_stdlib), so list functions like
-- filter / take / drop are present and covered here alongside the kernel-core
-- functions (map / reverse / append / element? / length / head / tail / sum /
-- remove / occurrences / cons? / empty?). See also test/stdlib_spec.lua for
-- the (fn filter) / bare-(filter …) regression that motivated loading stdlib
-- from source.
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
-- stdlib higher-order + list functions. These come from the S-lineage
-- lib/StLib sources (Lists/lists.shen etc.), loaded through the kernel's own
-- define pipeline at boot (see boot.lua load_stdlib). Before the stdlib was
-- loaded from source, filter/take/drop were absent and this block asserted a
-- clean "undefined" error; now they are present and we assert behaviour.
-- ---------------------------------------------------------------------------
shen.eval("(define lib-spec-gt1 X -> (> X 1))")
checkeq("(filter lib-spec-gt1 [1 2 3])", "(2 3)")
checkeq("(filter (/. X (> X 2)) [1 2 3 4 5])", "(3 4 5)")
checkeq("(take 2 [1 2 3])", "(1 2)")
checkeq("(drop 2 [1 2 3])", "(3)")

io.write(string.format("library_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
