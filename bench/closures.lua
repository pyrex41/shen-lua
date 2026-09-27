-- Run from repo root: luajit bench/closures.lua [iterations]
local P,R,C=require('boot'),require('runtime'),require('compiler')
P.load_kernel(false)
local N=tonumber(arg[1]) or 100000
assert(N>=1000 and N<=1000000, 'iterations must be 1000..1000000')
local cases={
  {'immediate', '((lambda X (+ N X)) 3)'},
  {'local', '(let F (lambda X (+ N X)) (+ (F 3) (F 4)))'},
  {'escaping', '(let F (lambda X (+ N X)) (do (set cs-escape F) (F 3)))'},
  {'deferred', '(let F (lambda X (+ N X)) (thaw (freeze (F 3))))'},
}
print(jit.version..' '..jit.arch..' jit='..tostring(jit.status())..' iterations='..N)
print('case,mode,median_seconds,heap_growth_KiB_10000,retained_KiB,MKFUN_sites,trace_stops,trace_aborts,exit_events_1000')
for _,case in ipairs(cases) do
 for _,on in ipairs{false,true} do
  if not arg[2] or arg[2]==(on and "on" or "off") then
  C.CLOSURES=on
  local form=R.read_all('(defun cs-bench (N) '..case[2]..')')[1]
  local src=C.cdefun(form)
  P.eval(form)
  local fn=P.F['cs-bench']
  jit.flush()
  local stops,aborts=0,0
  local function event(what) if what=='stop' then stops=stops+1 elseif what=='abort' then aborts=aborts+1 end end
  jit.attach(event,'trace')
  local sum=0
  local function run(n) local s=0; for i=1,n do s=s+fn(i%100) end; return s end
  sum=run(20000)
  jit.attach(event)
  local times={}
  for k=1,5 do collectgarbage('collect'); local t=os.clock(); sum=run(N); times[k]=os.clock()-t end
  table.sort(times)
  collectgarbage('collect'); collectgarbage('stop')
  local before=collectgarbage('count'); run(10000)
  local growth=collectgarbage('count')-before
  collectgarbage('restart'); collectgarbage('collect')
  local retained=collectgarbage('count')-before
  local exits=0
  local function exit() exits=exits+1 end
  jit.attach(exit,'texit'); run(1000); jit.attach(exit)
  local _,sites=src:gsub('MKFUN','')
  print(string.format('%s,%s,%.6f,%.3f,%.3f,%d,%d,%d,%d',case[1],on and 'on' or 'off',times[3],growth,retained,sites,stops,aborts,exits))
  local q,r=math.floor(N/100),N%100
  local inputs=q*4950+r*(r+1)/2
  assert(sum==(case[1]=='local' and (2*inputs+7*N) or (inputs+3*N)))
  end
 end
end
