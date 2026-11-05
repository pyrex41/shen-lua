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

-- A global is named by a symbol, nothing else ------------------------------------
for _, bad in ipairs({ '1', '"contract-v"', '[]', '(absvector 1)' }) do
  check((caught("(set " .. bad .. " 2)") or ""):find("is not a symbol", 1, true) ~= nil,
        "(set " .. bad .. " 2) raises")
  check((caught("(value " .. bad .. ")") or ""):find("is not a symbol", 1, true) ~= nil,
        "(value " .. bad .. ") raises")
end
check((caught("(value contract-v)") or ""):find("has no value", 1, true) ~= nil,
      "a rejected (set \"contract-v\" 2) did not bind the symbol contract-v")
eval("(set contract-v 3)")
check(eval("(value contract-v)") == 3, "(set sym v) still works")
check(eval("(let S contract-v (value S))") == 3, "(value S) through a variable still works")

-- A symbol is self-evaluating, whether or not it names a global -------------------
eval("(set contract-sym 7)")
check(eval("(= (eval-kl contract-sym) contract-sym)") == true, "(eval-kl sym) is sym")
check(eval("(= (eval contract-sym) contract-sym)") == true, "(eval sym) is sym")
check(eval("(= (eval-kl [if true contract-sym 1]) contract-sym)") == true, "a compiled symbol is sym")
check(eval("(eval-kl [value contract-sym])") == 7, "(value sym) still reads the global")

-- hash takes a positive integer bound; these used to hang or return NaN -----------
for _, key in ipairs({ "1", "a", '"a"' }) do
  for _, bound in ipairs({ "0", "-1", "0.5", "a" }) do
    local src = "(hash " .. key .. " " .. bound .. ")"
    check((caught(src) or ""):find("not a positive integer", 1, true) ~= nil, src .. " raises")
  end
  local h = eval("(hash " .. key .. " 10)")
  check(h >= 1 and h <= 10, "(hash " .. key .. " 10) is in range")
end

-- close is idempotent, and a closed stream is an error -----------------------------
do
  local tmp = os.tmpname()
  local q = '"' .. tmp .. '"'
  eval("(close (open " .. q .. " out))")
  check(caught("(let S (open " .. q .. " in) (do (close S) (close S)))") == nil, "close twice on input")
  check(caught("(let S (open " .. q .. " out) (do (close S) (close S)))") == nil, "close twice on output")
  check((caught("(let S (open " .. q .. " in) (do (close S) (read-byte S)))") or ""):find("stream is closed", 1, true) ~= nil,
        "read-byte on a closed stream")
  check((caught("(let S (open " .. q .. " in) (do (read-byte S) (close S) (read-byte S)))") or ""):find("stream is closed", 1, true) ~= nil,
        "read-byte on a closed stream that had reached EOF")
  check((caught("(let S (open " .. q .. " out) (do (close S) (write-byte 65 S)))") or ""):find("stream is closed", 1, true) ~= nil,
        "write-byte on a closed stream")
  check((caught("(close 1)") or ""):find("not a stream", 1, true) ~= nil, "(close 1) raises")
  os.remove(tmp)
end

io.write(string.format("contract_spec: %d passed, %d failed\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
