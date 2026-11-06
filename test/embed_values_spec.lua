-- embed_values_spec.lua : a function value crossing the embedding API can be called
-- from Lua with any number of arguments, and goes back into Shen as what it was.
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
shen.eval("(define add2 X Y -> (+ X Y))")
shen.eval("(define retlam -> (/. X Y (+ X Y)))")
shen.eval("(define appl2 F X Y -> (F X Y))")
shen.eval("(define ident X -> X)")
local add = shen.eval("(/. X Y (+ X Y))")
local add3 = shen.eval("(/. X Y Z (+ X (+ Y Z)))")
local mk = shen.eval("(/. X (/. Y (cons X Y)))")
local one = shen.eval("(/. X (+ X 1))")
check("lambda of 2, curried", function() return add(1)(2) end, 3)
check("lambda of 2, whole", function() return add(1, 2) end, 3)
check("lambda of 3, curried", function() return add3(1)(2)(3) end, 6)
check("lambda of 3, 2 then 1", function() return add3(1, 2)(3) end, 6)
check("lambda of 3, 1 then 2", function() return add3(1)(2, 3) end, 6)
check("a partial is a function", function() return type(mk(1)) end, "function")
check("nested lambdas, curried", function() local c = mk(1)(2); return R.is_cons(c) and c[1] == 1 and c[2] == 2 end, true)
check("nested lambdas, whole", function() local c = mk(1, 2); return R.is_cons(c) and c[2] == 2 end, true)
check("lambda of 1", function() return one(1) end, 2)
check("(fn f), curried", function() return shen.eval("(fn add2)")(1)(2) end, 3)
check("(fn f), whole", function() return shen.eval("(fn add2)")(1, 2) end, 3)
check("partial of a defun", function() return shen.eval("(add2 1)")(2) end, 3)
check("result of shen.call", function() return shen.call("retlam")(1)(2) end, 3)
check("result of shen.fn", function() return shen.fn("retlam")()(1)(2) end, 3)
check("shen.fn partial", function() return shen.fn("add2")(1)(2) end, 3)
-- back into Shen
check("passed back and called", function() return shen.call("appl2", add, 1, 2) end, 3)
check("passed back and returned is the same value", function() return shen.call("ident", add) == add end, true)
check("the same function gives the same value", function()
  shen.eval("(set emb-f (/. X Y (+ X Y)))")
  return shen.eval("(value emb-f)") == shen.eval("(value emb-f)")
end, true)
check("stored from Lua, called in Shen", function()
  shen.call("set", R.intern("emb-g"), add)
  return shen.eval("((value emb-g) 1 2)")
end, 3)
check("passed back, Shen sees the function it made", function()
  shen.eval("(set emb-h (/. X Y (+ X Y)))")
  return shen.call("=", shen.eval("(value emb-h)"), shen.prims.GLOBALS["emb-h"])
end, true)
-- a host's own function is left alone
local mine = function(a, b) return (a or 0) + (b or 0) end
check("a host function comes back as itself", function() return shen.call("ident", mine) == mine end, true)
check("a host function with one argument, called by Shen", function()
  shen.eval("(define appl1 F X -> (F X))")
  return shen.call("appl1", function(a) return a + 1 end, 1)
end, 2)
-- inside a structure: totable and the marshaler convert; otherwise shen.apply
check("totable element", function() return shen.totable(shen.eval("[(/. X Y (+ X Y))]"))[1](1)(2) end, 3)
check("shen.apply on a raw element", function() return shen.apply(shen.eval("[(/. X Y (+ X Y))]")[1], 1, 2) end, 3)
check("shen.apply curries", function() return shen.apply(shen.eval("[(/. X Y (+ X Y))]")[1], 1)(2) end, 3)
local I = require("lua_interop")
check("to_lua", function() return I.to_lua(shen.prims.F["add2"])(1)(2) end, 3)
check("to_lua in a list", function() return I.to_lua(shen.eval("[(fn add2)]"))[1](1)(2) end, 3)
check("to_shen undoes to_lua", function() local f = shen.prims.F["add2"]; return I.to_shen(I.to_lua(f)) == f end, true)
-- errors and returns
check("an error reaches the caller", function()
  local ok = pcall(add, "a", 2); return ok
end, false)
print(("embed_values_spec: %d pass, %d fail"):format(npass, nfail))
os.exit(nfail == 0 and 0 or 1)
