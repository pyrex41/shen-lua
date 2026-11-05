-- test/contract_spec.lua: PORT-AUTHORED regressions for bugs found by running
-- Shen/JIT's contract examples (contract/examples.shen in that repo) on
-- shen-lua. Those examples are one author's rules, not a conformance suite, so
-- only the cases judged real bugs are locked in here.
--
--   luajit test/contract_spec.lua
local shen = require("shen")
shen.boot{ quiet = true }

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end

local function eval(src) return shen.eval(src) end
-- The error message of a caught error, or nil when nothing was raised.
local function caught(src)
  local ok, res = pcall(shen.eval, '(trap-error (do ' .. src .. ' no-error) (/. E (error-to-string E)))')
  if not ok then return "UNCAUGHT: " .. tostring(res) end
  if type(res) == "string" then return res end
  return nil
end

-- absvector validates its length ---------------------------------------------
for _, bad in ipairs({ "-1", "1.5", "a", '"1"', "[]" }) do
  local msg = caught("(absvector " .. bad .. ")")
  check(msg and msg:find("not a valid vector length", 1, true) ~= nil,
        "(absvector " .. bad .. ") raises a catchable length error, got " .. tostring(msg))
end
check(eval("(absvector? (absvector 0))") == true, "(absvector 0) is still legal")
check(eval("(absvector? (absvector 2))") == true, "(absvector 2) is still legal")

-- A form the compiler rejects leaves the compiler usable ------------------------
eval("(defun contract-g (x) x)")
for _, bad in ipairs({
  "[defun contract-g [x] [lambda]]",   -- inside a defun
  "[defun contract-g [x y] [lambda]]", -- with a different arity
  "[lambda]",                          -- outside any defun
}) do
  check(caught("(eval-kl " .. bad .. ")") ~= nil, bad .. " is an error")
  -- Forms that hoist a control form (KC) or need a depth counter (NT) referred
  -- to names the chunk does not declare, once the state was left behind.
  check(eval('(eval-kl [let v [absvector 1] [do [address-> v 0 2.5] [vector? v]]])') == true,
        "after " .. bad .. ": a do in a let compiles")
  check(eval("(= [1 2] (eval-kl [[fn append] [cons 1 []] [cons 2 []]]))") == true,
        "after " .. bad .. ": a closure call compiles")
  check(eval("(contract-g 5)") == 5, "after " .. bad .. ": the old definition still runs")
  check(eval("(eval-kl [contract-g 5])") == 5,
        "after " .. bad .. ": a new call compiles with the old arity")
  eval("(define contract-h X -> (+ X 1))")
  check(eval("(contract-h 1)") == 2, "after " .. bad .. ": define still works")
end

io.write(string.format("contract_spec: %d passed, %d failed\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
