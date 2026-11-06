-- calls_spec.lua : calls through values and the compiled forms behind them.
-- Fixed-arity APPn, CURn over a variable, CURnP, uncurried and raw lambdas,
-- PARTIAL, closed lambdas in KC, count sinking. Each is an optimisation of the
-- curried chain, so each must behave exactly like one.
package.path = (arg[0]:gsub("test/[^/]*$", "")) .. "?.lua;" .. package.path
local shen = require("shen")
local npass, nfail = 0, 0
local R = require("runtime")
local function show(v) return R.to_str(v) end
local function check(name, src, want)
  local ok, got = pcall(function() return show(shen.eval(src)) end)
  if ok and got == want then npass = npass + 1
  else nfail = nfail + 1; print("FAIL " .. name .. ": got " .. tostring(got) .. " want " .. want) end
end
local function defs(src)
  local ok, e = pcall(shen.eval, src)
  if not ok then
    nfail = nfail + 1
    print("FAIL define: " .. src .. ": " .. tostring(type(e) == "table" and e.msg or e))
  end
end

defs("(define app1 F A -> (F A))")
defs("(define app2 F A B -> (F A B))")
defs("(define app3 F A B C -> (F A B C))")
defs("(define clog X -> (do (set call-log [X | (value call-log)]) X))")
defs("(define kx2 -> (/. X Y (cons X Y)))")
defs("(define kx3 -> (/. X Y Z [X Y Z]))")
defs("(define mkc N -> (/. X Y (+ N (+ X Y))))")
defs("(define add2 X Y -> (+ X Y))")

-- every way of applying a two-parameter lambda
check("lambda, all at once", "(app2 (kx2) 1 2)", "(1 . 2)")
check("lambda, one at a time", "((app1 (kx2) 1) 2)", "(1 . 2)")
check("lambda, partial held", "(let G ((kx2) 1) [(G 2) (G 3)])", "((1 . 2) (1 . 3))")
check("three, every split", "[(app3 (kx3) 1 2 3) ((app2 (kx3) 1 2) 3) (((app1 (kx3) 1) 2) 3) ((app1 (kx3) 1) 2 3)]",
      "((1 2 3) (1 2 3) (1 2 3) (1 2 3))")
check("capturing lambda", "(app2 (mkc 10) 1 2)", "13")
check("capturing, partial", "((app1 (mkc 10) 1) 2)", "13")
check("two evaluations capture separately", "(let A (mkc 1) B (mkc 2) [(A 0 0) (B 0 0)])", "(1 2)")
check("shadowed names in a lambda group", "(((/. X (/. X X)) 1) 2)", "2")
check("KL over-application of a 1-ary lambda",
      "(eval-kl [[lambda x [lambda y [cons x y]]] 1 2])", "(1 . 2)")
check("KL over-application via a variable",
      "(eval-kl [let f [lambda x [let z [+ x 1] [lambda y [cons z y]]]] [f 1 2]])", "(2 . 2)")
check("zero-argument application of a lambda is a partial",
      "(eval-kl [let f [lambda x [+ x 1]] [[f] 1]])", "2")

-- over-application: a 1-ary function returning a function, called with two
defs("(define k1 X -> (let Y (+ X 1) (/. Z (+ Y Z))))")
check("defun over-applied through a variable", "(app2 (function k1) 1 2)", "4")
check("symbol as the function", "(app2 add2 1 2)", "3")
check("symbol, one at a time", "((app1 add2 1) 2)", "3")
check("symbol, over-applied", "(app2 k1 1 2)", "4")
check("(fn f)", "(app2 (fn add2) 1 2)", "3")
check("unknown symbol raises", "(trap-error (app2 nosuchfn 1 2) (/. E caught))", "caught")
check("non-function raises", "(trap-error (app1 1 2) (/. E caught))", "caught")

-- redefinition is seen through every route, arity change included
defs("(define rd X Y -> (+ X Y))")
defs("(define call-rd F -> (F 1 2))")
check("before redefinition", "(call-rd rd)", "3")
defs("(define rd X Y -> (* 10 (+ X Y)))")
check("after redefinition", "(call-rd rd)", "30")
check("a binding of (fn rd) still calls the new definition", "(let G (fn rd) (do (eval [define rd X Y -> [+ X Y 1000]]) (G 1 2)))", "1003")
check("after redefinition again", "(call-rd rd)", "1003")
defs("(define rd X -> (/. Y (- X Y)))")
check("redefined to a smaller arity", "(call-rd rd)", "-1")
defs("(define rd X Y Z -> (+ X (+ Y Z)))")
check("redefined to a larger arity", "((call-rd rd) 3)", "6")

-- evaluation order: (F A B) is ((F A) B), so a partial that does something
-- runs before B, and an error from it comes before B runs at all.
defs("(define eff1 X -> (do (clog [ran X]) (/. Y [X Y])))")
defs("(define app-impure F -> (F 1 (clog [arg])))")
check("over-application runs before an impure last argument",
      "(do (set call-log []) (let R (app-impure (function eff1)) [R (reverse (value call-log))]))",
      "((1 (arg)) ((ran 1) (arg)))")
defs("(define raise1 X -> (error \"first\"))")
check("an error in the partial comes before the last argument",
      "(do (set call-log []) [(trap-error (app-impure (function raise1)) (/. E (error-to-string E))) (value call-log)])",
      '("first" ())')
check("exact arity: arguments first, then the call",
      "(do (set call-log []) (let R (app-impure (/. X Y [X Y])) [R (value call-log)]))",
      "((1 (arg)) ((arg)))")
defs("(define hd-last F L -> (F 1 (hd L)))")
check("an impure last argument that raises", "(trap-error (hd-last (/. X Y [X Y]) 5) (/. E caught))", "caught")

-- tail calls stay proper through every helper: two million would overflow any
-- Lua stack if one of these held a frame
defs("(define tc1 F 0 -> done F N -> (F F (- N 1)))")
defs("(define tc-direct F N -> (tc1 F N))")
check("tail call through APPn / CURn", "(tc1 (/. F N (tc-direct F N)) 2000000)", "done")
defs("(define tc2 F [] -> done F [X | Xs] -> (F F Xs))")
defs("(define nlist 0 A -> A N A -> (nlist (- N 1) [N | A]))")
check("tail call through CURnP", "(let L (nlist 1000000 []) (tc2 (/. F Xs (tc2 F Xs)) L))", "done")
defs("(define tc-lam 0 -> done N -> ((/. X (tc-lam X)) (- N 1)))")
check("tail call out of a closed lambda", "(tc-lam 2000000)", "done")

-- deep non-tail recursion keeps working, counted or sunk
defs("(define deep-sum 0 -> 0 N -> (+ N (deep-sum (- N 1))))")
check("sunk count, deep", "(deep-sum 300000)", "45000150000")
defs("(define deep-via F 0 -> 0 F N -> (+ 1 (F F (- N 1))))")
check("through a two-parameter lambda, deep", "(deep-via (/. F N (deep-via F N)) 200000)", "200000")
defs("(define deep-1 0 -> 0 N -> (+ 1 ((/. X (deep-1 X)) (- N 1))))")
check("through a closed lambda, deep", "(deep-1 200000)", "200000")
-- A segment restarts its function from the top. Everything a sunk count
-- skips must run once: count what the body does.
defs("(define counted 0 -> 0 N -> (let I (set frames (+ 1 (value frames))) (+ 1 (counted (- N 1)))))")
check("body effects run once per frame across segments",
      "(do (set frames 0) (counted 5000) (value frames))", "5000")
defs("(define counted-if N -> (if (= N 0) 0 (do (set frames (+ 1 (value frames))) (+ 1 (counted-if (- N 1))))))")
check("the same under if", "(do (set frames 0) (counted-if 5000) (value frames))", "5000")

-- a host function has no recorded arity and is called as given
local P = require("prims")
P.F["host-count"] = function(...) return select("#", ...) end
check("host function through a symbol", "(app1 host-count 1)", "1")
-- fn and function go through the kernel's arity table, which a host function is
-- not in. They raise, as they did before the fixed-arity helpers.
for _, src in ipairs({ "(function host-count)", "(fn host-count)" }) do
  local ok, err = pcall(shen.eval, src)
  local msg = not ok and tostring(type(err) == "table" and err.msg or err) or ""
  local raised = not ok and msg:find("host-count is undefined", 1, true) ~= nil
  if raised then npass = npass + 1
  else nfail = nfail + 1; print("FAIL " .. src .. ": " .. msg) end
end

print(("calls_spec: %d pass, %d fail"):format(npass, nfail))
os.exit(nfail == 0 and 0 or 1)
