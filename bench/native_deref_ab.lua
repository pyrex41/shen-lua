local P = require("boot"); local R = require("runtime")
P.load_kernel(false); P.initialise()
local ffi=require("ffi"); ffi.cdef[[int chdir(const char*);]]; ffi.C.chdir("../cl-source/ShenOSKernel-41.1/tests")
local mf=P.F["shen.macros"]; if mf and not P.GLOBALS["*macros*"] then P.GLOBALS["*macros*"]=R.cons(R.cons(R.cons(R.intern("shen.macros"),mf),R.NIL),R.NIL) end
if P.GLOBALS["shen.*tc*"]~=nil and P.GLOBALS["*tc*"]==nil then P.GLOBALS["*tc*"]=P.GLOBALS["shen.*tc*"] end
P.F["load"]("interpreter.shen")

local mode = arg[1] or "native"
if mode == "native" then
  local intern, Cons = R.intern, R.Cons
  local cons = R.cons
  local shen_pvar = intern("shen.pvar")
  local shen_null = intern("shen.-null-")
  local function native_pvar(x) return type(x)=="table" and x.n~=nil and getmetatable(x)==nil and x[0]==shen_pvar end
  local function native_lazyderef(x, v)
    while type(x)=="table" and x.n~=nil and getmetatable(x)==nil and x[0]==shen_pvar do
      local w = v[x[1]]; if w == shen_null then return x end; x = w
    end
    return x
  end
  local function native_deref(x, v)
    local mt = getmetatable(x)
    if mt == Cons then
      local h0,t0 = x[1],x[2]
      local h = native_deref(h0,v); local t = native_deref(t0,v)
      if h==h0 and t==t0 then return x end
      return cons(h,t)
    end
    if type(x)=="table" and x.n~=nil and mt==nil and x[0]==shen_pvar then
      local w = v[x[1]]; if w==shen_null then return x end; return native_deref(w,v)
    end
    return x
  end
  P.F["shen.pvar?"]=native_pvar; P.FA[native_pvar]=1
  P.F["shen.lazyderef"]=native_lazyderef; P.FA[native_lazyderef]=2
  P.F["shen.deref"]=native_deref; P.FA[native_deref]=2
end

local term=P.F["hd"](P.F["read-from-string"]('[[[y-combinator [/. ADD [/. X [/. Y [if [= X 0] Y [[ADD [-- X]] [++ Y]]]]]]] 3] 4]'))
local A=P.F["gensym"](R.intern("A"))
collectgarbage("collect"); local i0=P.GLOBALS["shen.*infs*"] or 0
collectgarbage("stop"); local m0=collectgarbage("count")
local t0=os.clock(); local ok,res = pcall(function() return P.F["shen.typecheck"](term, A) end); local dt=os.clock()-t0
local m1=collectgarbage("count"); local infs=(P.GLOBALS["shen.*infs*"] or 0)-i0
io.stderr:write(string.format("mode=%s ok=%s infs=%d  %.3fs  alloc=%.0f B/inf  result=%s\n",
  mode, tostring(ok), infs, dt, (m1-m0)*1024/infs, tostring(res)))
