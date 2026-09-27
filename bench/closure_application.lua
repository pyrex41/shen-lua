-- Fresh process: SHEN_FASL=off SHEN_KERNEL_CACHE=off luajit bench/closure_application.lua
local P,R,C=require('boot'),require('runtime'),require('compiler')
assert(os.getenv('SHEN_FASL')=='off', 'disable fasl for compilation measurements')
local bytes,defs=0,0
local compile=C.compile_top
C.compile_top=function(f) local s=compile(f); bytes=bytes+#s; defs=defs+1; return s end
local t=os.clock(); P.load_kernel(false); local kernel_compile=os.clock()-t
local kernel_bytes=bytes
P.initialise(); P.GLOBALS['*hush*']=true
local ffi=require('ffi'); ffi.cdef'int chdir(const char*);'
assert(ffi.C.chdir('tests')==0)
collectgarbage('collect')
local mkfun, original_mkfun=0,P.ENV.MKFUN
if os.getenv('SHEN_CALLBACK_COUNTS') then
  P.ENV.MKFUN=function(n,f) mkfun=mkfun+1; return original_mkfun(n,f) end
else mkfun=-1 end
t=os.clock(); P.F.load('interpreter.shen'); local loadtime=os.clock()-t
P.ENV.MKFUN=original_mkfun
local term=P.F.hd(P.F['read-from-string']('[[[y-combinator [/. ADD [/. X [/. Y [if [= X 0] Y [[ADD [-- X]] [++ Y]]]]]]] 3] 4]'))
local times={}; local semantic
for i=1,4 do
  P.GLOBALS["shen.*infs*"]=0
  collectgarbage('collect'); local start=os.clock()
  local result=P.F['shen.typecheck'](term,P.F.gensym(R.intern('A')))
  assert(result~=false)
  local rendered=R.to_str(result):gsub("%s+", "")
  assert(not semantic or semantic==rendered, "stable inferred type"); semantic=rendered
  if i>1 then times[#times+1]=os.clock()-start end
end
table.sort(times)
print(string.format('RESULT load=%.6f typecheck=%.6f kernel_compile=%.6f kernel_bytes=%d load_mkfun=%d semantic=%s',loadtime,times[2],kernel_compile,kernel_bytes,mkfun,semantic))
