-- Sequential fresh-process audit; the timing region contains queries only.
local P,R=require('boot'),require('runtime')
local loop_module=os.getenv('SHEN_DATATYPE_LOOP')=='on' and require('bench.datatype_loop')
local dispatch_module=os.getenv('SHEN_DATATYPE_DISPATCH')=='on' and require('bench.datatype_dispatch')
P.load_kernel(false); P.initialise(); P.GLOBALS['*hush*']=true
local ffi=require('ffi'); ffi.cdef'int chdir(const char*);'
assert(ffi.C.chdir('tests')==0)
P.F.load('interpreter.shen')
local term=P.F.hd(P.F['read-from-string']('[[[y-combinator [/. ADD [/. X [/. Y [if [= X 0] Y [[ADD [-- X]] [++ Y]]]]]]] 3] 4]'))
local history=arg[1] or 'keep'
local count=tonumber(arg[2]) or 12
assert(count>=4 and count<=30)
local semantic,inferences
local function query()
  P.GLOBALS['shen.*infs*']=0
  local result=P.F['shen.typecheck'](term,P.F.gensym(R.intern('A')))
  local s=R.to_str(result):gsub('%s+','')
  assert(s=='(listl-formula)',s)
  local inf=P.GLOBALS['shen.*infs*']
  assert(inf==431741,'expected inference count')
  assert(not inferences or inf==inferences,'stable inference count')
  semantic,inferences=s,inf
end
local maxrecord=os.getenv('SHEN_TC_MAXRECORD')
if maxrecord then jit.opt.start('maxrecord='..assert(tonumber(maxrecord))) end
query() -- force lazy native-driver translation before controlling JIT history
local dispatch=(loop_module or dispatch_module) and (loop_module or dispatch_module).new(P,require('prolog_engine'))
if history=='flush' then jit.flush()
elseif history=='off' then jit.off(); jit.flush()
else assert(history=='keep') end
local tracepath=os.getenv('SHEN_TC_TRACE')
if tracepath then require('jit.v').start(tracepath) end
local profpath=os.getenv('SHEN_TC_PROFILE')
local profiler=profpath and require('jit.p')
if profiler then profiler.start('vf3ri1m1',profpath) end
for i=1,count do
  collectgarbage('collect')
  local t=os.clock(); query(); local dt=os.clock()-t
  print(string.format('QUERY sample=%d seconds=%.6f infs=%d jit=%s semantic=%s',i,dt,inferences,tostring(jit.status()),semantic))
end
if profiler then profiler.stop() end

local st=dispatch and dispatch.dispatch_stats or {builds=0,sites=0,bytes=0}
print(string.format('DISPATCH builds=%d sites=%d bytes=%d',st.builds,st.sites,st.bytes))
