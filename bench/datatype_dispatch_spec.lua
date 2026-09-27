local TN=require('typecheck_native')
local variant=arg[1] or 'dispatch'
assert(variant=='dispatch' or variant=='loop')
local P,R,E=require('boot'),require('runtime'),require('prolog_engine')
P.load_kernel(false); P.initialise()
TN.native_typecheck(1,R.intern('number')) -- force lazy driver installation
local NP=E.NativePred
local generic=NP['shen.search-user-datatypes']
local original=P.GLOBALS['shen.*datatypes*']
local D=require('bench.datatype_'..variant).new(P,E)
local n, calls=0,{}
local function check(x,label) assert(x,label); n=n+1 end
local function root(names)
  local t={}; for _,name in ipairs(names) do t[#t+1]=R.cons(R.intern(name),function() end) end
  return R.from_table(t)
end
local function setup(names)
  P.GLOBALS['shen.*datatypes*']=root(names)
  D.refresh_datatype_dispatch()
  return NP['shen.search-user-datatypes'],P.GLOBALS['shen.*datatypes*']
end
local function invoke(fn,list)
  calls={}; local q=E.query_begin(); E.setinfs(0)
  local ok,r=pcall(fn,0,0,E.import_cached(list),0,function() return true end)
  local inf=E.getinfs(); E.query_end(q)
  return {ok,r,inf,table.concat(calls,',')}
end
local function pred(name,result)
  return function() calls[#calls+1]=name; return result end
end
local function equivalent(worker,list,reset,label)
  reset(); local a=invoke(generic,list)
  reset(); local b=invoke(worker,list)
  for i=1,4 do check(a[i]==b[i],label..' field '..i) end
  return b
end
local worker,list=setup{'dd-a','dd-b'}
if variant=='dispatch' then check(D.dispatch_stats.sites==2,'two sites') end
local function ordinary() NP['dd-a']=pred('a',false); NP['dd-b']=pred('b',99) end
local r=equivalent(worker,list,ordinary,'ordered success')
check(r[2]==99 and r[3]==3 and r[4]=='a,b','exact order and infs')
equivalent(worker,list,function() NP['dd-a']=pred('a',false); NP['dd-b']=pred('b',false) end,'all fail')
equivalent(worker,list,function()
  NP['dd-a']=function() calls[#calls+1]='a'; NP['dd-b']=pred('new',17); return false end
  NP['dd-b']=pred('old',99)
end,'mid-dispatch redefinition')
equivalent(worker,root{'dd-a','dd-c'},function() ordinary(); NP['dd-c']=pred('c',18) end,'suffix mismatch')
local bad=R.cons(R.intern('malformed'),root{'dd-b'})
equivalent(worker,bad,ordinary,'malformed entry')
equivalent(worker,list,function()
  NP['dd-a']=function() calls[#calls+1]='cut'; return E.cut(1,function() return false end) end
  NP['dd-b']=pred('unreachable',99)
end,'cut prevents later callbacks')
local sentinel={}
equivalent(worker,list,function() NP['dd-a']=function() error(sentinel,0) end end,'error propagates')
worker,list=setup{'dd-a','dd-missing'}
equivalent(worker,list,function() NP['dd-a']=pred('a',77); NP['dd-missing']=nil end,'unreached missing predicate')
equivalent(worker,list,function() NP['dd-a']=pred('a',false); NP['dd-missing']=nil end,'reached missing predicate')
local names={}; for i=1,40 do names[i]='dd-'..i; NP[names[i]]=pred(tostring(i),i==40 and 40 or false) end
worker,list=setup(names)
if variant=='dispatch' then check(D.dispatch_stats.sites==32 and D.dispatch_stats.bytes<32000,'bounded code generation') end
r=equivalent(worker,list,function() end,'long list suffix')
check(r[2]==40 and r[3]==79,'long list count')
P.GLOBALS['shen.*datatypes*']=R.NIL; D.refresh_datatype_dispatch()
if variant=='dispatch' then check(NP['shen.search-user-datatypes']==generic,'empty list restores generic') end
P.GLOBALS['shen.*datatypes*']=original
local cases={{'1','number',true},{'"x"','number',false},{'[1 2]','(list number)',true},
 {'(+ 1 "x")','number',false},{'(/. X X)','(number --> number)',true},
 {'(if true 1 "x")','number',false}}
for _,enabled in ipairs{false,true} do
  if not enabled then NP['shen.search-user-datatypes']=generic else D.refresh_datatype_dispatch() end
  for _,c in ipairs(cases) do
    P.GLOBALS['shen.*infs*']=0
    local result=TN.native_typecheck(P.F['read-from-string'](c[1])[1],P.F['read-from-string'](c[2])[1])
    check((result~=false)==c[3],'typing '..c[1])
  end
end
print('datatype_'..variant..'_spec: '..n..' pass, 0 fail')
