local P = require("boot"); local R = require("runtime")
P.load_kernel(false); P.initialise()
local ffi = require("ffi"); ffi.cdef[[int chdir(const char*);]]
ffi.C.chdir("../cl-source/ShenOSKernel-41.2/tests")
local mf=P.F["shen.macros"]
if mf and not P.GLOBALS["*macros*"] then P.GLOBALS["*macros*"]=R.cons(R.cons(R.cons(R.intern("shen.macros"),mf),R.NIL),R.NIL) end
if P.GLOBALS["shen.*tc*"]~=nil and P.GLOBALS["*tc*"]==nil then P.GLOBALS["*tc*"]=P.GLOBALS["shen.*tc*"] end
P.F["load"]("interpreter.shen")
local term = P.F["hd"](P.F["read-from-string"]('[[[y-combinator [/. ADD [/. X [/. Y [if [= X 0] Y [[ADD [-- X]] [++ Y]]]]]]] 3] 4]'))
local A = P.F["gensym"](R.intern("A"))
collectgarbage("collect")
local infs0 = P.GLOBALS["shen.*infs*"] or 0
collectgarbage("stop")          -- no collection: heap growth = total allocated
local m0 = collectgarbage("count")
local t0 = os.clock()
P.F["shen.typecheck"](term, A)
local dt = os.clock()-t0
local m1 = collectgarbage("count")
local infs1 = P.GLOBALS["shen.*infs*"] or 0
local infs = infs1 - infs0
io.stderr:write(string.format("typecheck: %.3fs  inferences=%d  allocated=%.1f MB  = %.0f bytes/inference\n",
  dt, infs, (m1-m0)/1024, (m1-m0)*1024/infs))
