-- Instrumentation only: do not use these timings as A/B performance evidence.
local P,R=require('boot'),require('runtime')
P.load_kernel(false); P.initialise()
P.GLOBALS['*hush*']=true
local ffi=require('ffi'); ffi.cdef'int chdir(const char*);'
assert(ffi.C.chdir('tests')==0)
local rows, calls, elems, depth, map_time, created = {},0,0,0,0,0
local mk=P.ENV.MKFUN
P.ENV.MKFUN=function(n,f) created=created+1; return mk(n,f) end
local orig=P.F.map
local wrapper=function(f,l)
  calls=calls+1
  local info=type(f)=='function' and debug.getinfo(f,'S')
  local key=info and (info.short_src..':'..info.linedefined) or tostring(f)
  local row=rows[key] or {0,0}; rows[key]=row; row[1]=row[1]+1
  local x=l; while R.is_cons(x) do elems=elems+1; row[2]=row[2]+1; x=x[2] end
  local start=depth==0 and os.clock(); depth=depth+1
  local result=orig(f,l)
  depth=depth-1; if start then map_time=map_time+os.clock()-start end
  return result
end
P.F.map=wrapper; P.FA[wrapper]=2
local function phase(label,fn)
  rows={}; calls=0; elems=0; created=0; map_time=0
  local t=os.clock(); fn(); t=os.clock()-t
  print(string.format('%s seconds=%.6f map_inclusive_seconds=%.6f calls=%d elements=%d mkfun=%d',label,t,map_time,calls,elems,created))
  local sorted={}; for key,r in pairs(rows) do sorted[#sorted+1]={key,r[1],r[2]} end
  table.sort(sorted,function(a,b)return a[3]>b[3] end)
  for i=1,math.min(12,#sorted) do print(unpack(sorted[i])) end
end
phase('load-interpreter',function() P.F.load('interpreter.shen') end)
local term=P.F.hd(P.F['read-from-string']('[[[y-combinator [/. ADD [/. X [/. Y [if [= X 0] Y [[ADD [-- X]] [++ Y]]]]]]] 3] 4]'))
phase('typecheck-y',function()
  local r=P.F['shen.typecheck'](term,P.F.gensym(R.intern('A')))
  assert(r~=false)
end)
