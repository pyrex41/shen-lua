-- embed_values_spec.lua : a compiled function value can be called raw from Lua with
-- fewer arguments than it takes, wherever the host got it, and gives a partial: never
-- a body run with nil. Its identity is unchanged, so passing it back into Shen, storing
-- it and comparing it with = all behave as for any other value.
package.path = (arg[0]:gsub("test/[^/]*$", "")) .. "?.lua;" .. package.path
local shen = require("shen")
shen.boot{quiet = true}
local R = shen.runtime
local npass, nfail = 0, 0
local function check(name, f, want)
  local ok, got = pcall(f)
  if ok and got == want then npass = npass + 1
  else nfail = nfail + 1; print("FAIL " .. name .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
end
local function pair(c) return R.is_cons(c) and R.is_cons(c[2]) and c[1] == 1 and c[2][1] == 2 end
shen.eval("(define add2 X Y -> (+ X Y))")
shen.eval("(define retlam -> (/. X Y (+ X Y)))")
shen.eval("(define appl2 F X Y -> (F X Y))")
-- from shen.eval
local add = shen.eval("(/. X Y (+ X Y))")
local add3 = shen.eval("(/. X Y Z (+ X (+ Y Z)))")
local mk = shen.eval("(/. X (/. Y [X Y]))")
check("lambda of 2, curried", function() return add(1)(2) end, 3)
check("lambda of 2, whole", function() return add(1, 2) end, 3)
check("lambda of 3, curried", function() return add3(1)(2)(3) end, 6)
check("lambda of 3, 2 then 1", function() return add3(1, 2)(3) end, 6)
check("lambda of 3, 1 then 2", function() return add3(1)(2, 3) end, 6)
check("nested lambdas, one argument gives a function", function() return type(mk(1)) end, "function")
check("nested lambdas, curried", function() return pair(mk(1)(2)) end, true)
check("lambda of 1", function() return shen.eval("(/. X (+ X 1))")(1) end, 2)
-- through other routes
check("(fn f), curried", function() return shen.eval("(fn add2)")(1)(2) end, 3)
check("shen.call result, curried", function() return shen.call("retlam")(1)(2) end, 3)
shen.eval("(set stored (/. X Y (+ X Y)))")
check("shen.value, curried", function() return shen.value("stored")(1)(2) end, 3)
check("totable element, curried", function() return shen.totable(shen.eval("[(/. X Y (+ X Y))]"))[1](1)(2) end, 3)
check("nested in a list, curried", function() return shen.call("hd", shen.eval("[(/. X Y (+ X Y))]"))(1)(2) end, 3)
shen.eval("(define givecb F -> (F (/. A B (+ A B))))")
check("a lambda Shen passes to a host callback", function()
  return shen.call("givecb", function(g) return g(1)(2) end)
end, 3)
check("lua.call style: given to Lua and called with one", function()
  return shen.call("givecb", function(g) local h = g(1); return h(2) end)
end, 3)
-- identity and equality
local st = shen.eval("(value stored)")
check("the same value each time", function() return st == shen.eval("(value stored)") end, true)
local l = shen.list({ st, 5 })
shen.eval("(define memberq X [] -> false X [Y | Z] -> (if (= X Y) true (memberq X Z)))")
check("a host-built list holds the same function", function() return shen.call("memberq", shen.eval("(value stored)"), l) end, true)
check("= across the boundary", function() return shen.call("=", shen.call("hd", l), shen.eval("(value stored)")) end, true)
check("passed back and called", function() return shen.call("appl2", add, 1, 2) end, 3)
-- thaw of a function that takes arguments gives a partial
check("thaw of a two-parameter lambda", function() return pair(shen.eval("(let F (thaw (/. X Y [X Y])) (F 1 2))")) end, true)
check("thaw of a one-parameter lambda", function() return shen.eval("(let F (thaw (/. X (+ X 1))) (F 2))") end, 3)
check("thaw of (fn f)", function() return shen.eval("(let F (thaw (fn add2)) (F 1 2))") end, 3)
check("thaw in a defun", function()
  shen.eval("(define th-of F -> (thaw F))")
  return pair(shen.eval("((th-of (/. X Y [X Y])) 1 2)"))
end, true)
check("thaw of a freeze", function() return shen.eval("(thaw (freeze (+ 1 2)))") end, 3)
-- a host's own function is left alone
check("a host function with one argument, called by Shen", function()
  shen.eval("(define appl1 F X -> (F X))")
  return shen.call("appl1", function(a) return a + 1 end, 1)
end, 2)
print(("embed_values_spec: %d pass, %d fail"):format(npass, nfail))
os.exit(nfail == 0 and 0 or 1)
