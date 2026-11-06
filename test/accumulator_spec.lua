-- test/accumulator_spec.lua: a self-tail loop's accumulator (compiler.lua
-- accumulator) is computed as a double and must keep the meaning of + - *.
--   luajit test/accumulator_spec.lua
package.path = (arg[0]:gsub("test/[^/]*$", "")) .. "?.lua;" .. package.path

local shen = require("shen")
shen.boot{ quiet = true }
local ev = shen.eval

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else nfail = nfail + 1; io.write("FAIL: ", name, "\n") end
end

ev("(define ac-sum 0 _ A -> A N E A -> (ac-sum (- N 1) E (+ A E)))")
ev("(define ac-rsum 0 _ A -> A N E A -> (ac-rsum (- N 1) E (+ E A)))")
ev("(define ac-sub 0 _ A -> A N E A -> (ac-sub (- N 1) E (- A E)))")
ev("(define ac-mul 0 _ A -> A N E A -> (ac-mul (- N 1) E (* A E)))")

-- past int32, and as printed text: an integral double prints as an integer
check(ev("(ac-sum 300 10000000 0)") == 3000000000, "sum past 2^31")
check(ev("(str (ac-sum 300 10000000 0))") == "3000000000", "sum prints as an integer")
check(ev("(ac-rsum 300 10000000 0)") == 3000000000, "reversed operands")
check(ev("(ac-sub 300 10000000 0)") == -3000000000, "sub past -2^31")
check(ev("(ac-sub 3 10 100)") == 70, "sub keeps operand order")
check(ev("(ac-mul 40 2 1)") == 2^40, "mul past 2^31")
check(ev("(str (ac-sum 3 2 1))") == "7", "small sum prints as an integer")
check(ev("(str (ac-sum 2 1.5 0))") == "3", "fractions")
check(ev("(str (ac-sum 3 0.5 0))") == "1.5", "fractions kept")
-- enough iterations to compile the loop: same values under a trace
check(ev("(ac-sum 100000 100000 0)") == 10000000000, "sum under a trace")
check(ev("(ac-mul 100000 1 3)") == 3, "mul under a trace")

-- a value still indexes a vector, compares and hashes as the same number
check(ev("(let V (absvector 3) (do (address-> V (ac-sum 2 1 0) 9) (<-address V 2)))") == 9,
      "accumulated value as an index")
check(ev("(= (ac-sum 2 1 0) 2)") == true, "accumulated value compares equal")
check(ev("(do (put ac-key ac-prop 5) (get ac-key ac-prop))") == 5, "get and put unaffected")

-- operands that are not numbers are still errors, never coerced
local ok = pcall(ev, '(ac-sum 1 "3" 1)')
check(not ok, "string operand in + is an error")
ok = pcall(ev, '(ac-sub 1 "3" 1)')
check(not ok, "string operand in - is an error")
ok = pcall(ev, '(ac-mul 1 "3" 1)')
check(not ok, "string operand in * is an error")

io.write(string.format("accumulator_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
