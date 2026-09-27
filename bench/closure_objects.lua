-- Stateful closures escaping to the host and sharing mutable configuration.
-- luajit bench/closure_objects.lua ordinary|optimized|manual
local P,R,C=require('boot'),require('runtime'),require('compiler')
P.load_kernel(false)
local mode=arg[1] or 'ordinary'
assert(mode=='ordinary' or mode=='optimized' or mode=='manual')
C.MAP_CLOSURES=mode=='optimized'
local effect='(do (address-> S 1 (+ (<-address S 1) X)) (* X (<-address S 2)))'
local method=mode=='manual' and '(sc-manual S L ())' or '(map (lambda X '..effect..') L)'
local src='(defun sc-new (Factor) (let S (absvector 3) (do (address-> S 1 0) (do (address-> S 2 Factor) (cons (lambda L '..method..') (cons (lambda Unused (<-address S 1)) (cons (lambda Factor (address-> S 2 Factor)) ())))))))'
local manual='(defun sc-manual (S L Acc) (if (= L ()) (reverse Acc) (let X (hd L) (sc-manual S (tl L) (cons '..effect..' Acc)))))'
local t=os.clock()
local manual_code=mode=='manual' and C.cdefun(R.read_all(manual)[1]) or ''
if mode=='manual' then P.load_chunk(manual_code, 'object-manual')() end
local generated=C.cdefun(R.read_all(src)[1]); P.load_chunk(generated, 'object-factory')()
local compile_time=os.clock()-t
assert(mode~='optimized' or generated:find('MAP_BASE',1,true), 'specialization reached')
local input=R.NIL; for i=32,1,-1 do input=R.cons(i,input) end
for i=1,64 do P.F['sc-new'](i) end
collectgarbage('collect'); collectgarbage('collect'); local before=collectgarbage('count')
local objects={}
for i=1,1024 do objects[i]=P.F['sc-new'](i%7+1) end
collectgarbage('collect'); local retained=collectgarbage('count')-before
local invocations=0
local function run(n)
  local checksum=0
  for i=1,n do
    local o=objects[i%#objects+1]
    local factor=i%7+1
    P.APP(o[2][2][1],factor)
    local result=P.APP(o[1],input)
    assert(result[1]==factor)
    checksum=checksum+result[1]
  end
  invocations=invocations+n
  return checksum
end
if os.getenv('SHEN_TRACE_MARKERS') then io.stderr:write('WORKLOAD_BEGIN\n') end
run(5000)
local times={}
for i=1,5 do collectgarbage('collect'); t=os.clock(); run(20000); times[i]=os.clock()-t end
table.sort(times)
local probe_mkfun, original_mkfun=0,P.ENV.MKFUN
if os.getenv('SHEN_CALLBACK_COUNTS') then
  P.ENV.MKFUN=function(n,f) probe_mkfun=probe_mkfun+1; return original_mkfun(n,f) end
else probe_mkfun=-1 end
collectgarbage('collect'); collectgarbage('stop'); before=collectgarbage('count'); run(1000)
local growth=collectgarbage('count')-before; collectgarbage('restart'); P.ENV.MKFUN=original_mkfun
local total=0; for _,o in ipairs(objects) do total=total+P.APP(o[2][1],0) end
assert(total==invocations*528, 'shared state history')
if os.getenv('SHEN_TRACE_MARKERS') then io.stderr:write('WORKLOAD_END\n') end
print(string.format('RESULT mode=%s seconds=%.6f growth_kib=%.3f retained_kib=%.3f code_bytes=%d compile_seconds=%.6f total=%d probe_mkfun=%d',mode,times[3],growth,retained,#generated+#manual_code,compile_time,total,probe_mkfun))
