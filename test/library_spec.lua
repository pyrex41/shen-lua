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

-- ---------------------------------------------------------------------------
-- Native kernel overrides (shen-scheme approach): functions the kernel ships
-- as portable-but-slow defuns, replaced after load with Lua mappings.
-- ---------------------------------------------------------------------------
checkeq("(integer? 3)", "true")
checkeq("(integer? -2)", "true")
checkeq("(integer? 1.5)", "false")
checkeq("(integer? 1.0)", "true")
checkeq("(boolean? true)", "true")
checkeq("(boolean? false)", "true")
checkeq("(boolean? 0)", "false")
checkeq("(not true)", "false")
checkeq("(not false)", "true")
checkeq("(nth 1 [a b c])", "a")
checkeq("(nth 3 [a b c])", "c")
checkeq("(concat a b)", "ab")
checkeq("(explode hello)", "(\"h\" \"e\" \"l\" \"l\" \"o\")")
checkeq("(explode \"ab\")", "(\"a\" \"b\")")
checkeq("(difference [1 2 3] [2])", "(1 3)")
checkeq("(union [1 2] [2 3])", "(1 2 3)")
checkeq("(intersection [1 2 3] [2 3 4])", "(2 3)")
checkeq("(fst (@p 1 2))", "1")
checkeq("(snd (@p 1 2))", "2")
checkeq("(tuple? (@p 1 2))", "true")
checkeq("(tuple? [1 2])", "false")
checkeq("(limit (vector 4))", "4")
checkeq("(== 1 1)", "true")
checkeq("(== [1 2] [1 2])", "true")
checkeq("(mapcan (lambda X [X X]) [1 2])", "(1 1 2 2)")
checkeq("(subst a b [b [b] c])", "(a (a) c)")

-- property store / arity / vectors / trap-error value peephole
checkeq("(arity +)", "2")
checkeq("(arity this-name-is-not-defined-xyz)", "-1")
checkeq("(vector? (vector 3))", "true")
checkeq("(vector? (@p 1 2))", "false")
checkeq("(<-vector (vector-> (vector 2) 1 9) 1)", "9")
checkeq("(bound? +)", "false")
checkeq("(set lib-spec-bound 7)", "7")
checkeq("(bound? lib-spec-bound)", "true")
checkeq("(value lib-spec-bound)", "7")
checkeq("(trap-error (value lib-spec-definitely-unbound) (lambda E 99))", "99")
checkeq("(trap-error (value lib-spec-bound) (lambda E 0))", "7")
checkeq("(@s \"ab\" \"cd\")", "\"abcd\"")
checkeq("(shen.digit? 48)", "true")
checkeq("(shen.digit? 47)", "false")
checkeq("(put lib-spec-k lib-spec-p 42 (value *property-vector*))", "42")
checkeq("(get lib-spec-k lib-spec-p (value *property-vector*))", "42")
checkeq("(trap-error (get lib-spec-k lib-spec-missing (value *property-vector*)) (lambda E 0))", "0")
checkeq("(shen.hds=? [a b] a)", "true")
checkeq("(shen.hds=? [a b] b)", "false")
checkeq("(shen.hds=? [] a)", "false")
checkeq("(shen.<-out (shen.comb [1] 2))", "2")
checkeq("(shen.in-> (shen.comb [1] 2))", "(1)")
checkeq("(shen.ccons? [[a] b])", "true")
checkeq("(shen.ccons? [a b])", "false")
checkeq("(shen.extract-vars [X [Y 1]])", "(X Y)")
checkeq("(shen.analyse-variable? \"Foo\")", "true")
checkeq("(shen.analyse-variable? \"foo\")", "false")

io.write(string.format("library_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
