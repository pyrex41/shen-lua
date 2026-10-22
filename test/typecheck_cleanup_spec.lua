-- Error and nested-query contracts for the protected native checker boundary.
local shen=require('shen');shen.boot{quiet=true}
local P,R,E,TN=shen.prims,require('runtime'),require('prolog_engine'),require('typecheck_native')
if not TN.native_typecheck or os.getenv('SHEN_TYPECHECK_NATIVE')=='off' then
 print('typecheck_cleanup_spec: skipped (native dispatcher disabled)');return
end
TN.ensure_drivers()
local pass,fail=0,0
local function check(ok,label)
 if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..label) end
end
local function tops() return table.concat({E.tops()},',') end
local number=R.intern('number')
local original=P.F['shen.curry'];local marker={}
local saved=tops()
P.F['shen.curry']=function() error(marker,0) end
for _,entry in ipairs({TN.native_typecheck,P.F['shen.typecheck']}) do
 local ok,err=pcall(entry,1,number)
 check(not ok and err==marker,'preprocessing rethrows identical error object')
 check(tops()==saved,'preprocessing error leaves engine tops unchanged')
end
P.F['shen.curry']=original
-- Force an error just after query_begin; cleanup must still happen before
-- the caller catches it. This is a boundary fault injection, not a user case.
local newvar=E.newvar
E.newvar=function() error(marker,0) end
local ok,err=pcall(TN.native_typecheck,1,number)
E.newvar=newvar
check(not ok and err==marker,'query setup error retains identity')
check(tops()==saved,'query setup error restores the arena')
-- A native query reentered from preprocessing must not corrupt its caller.
local active=false;local nested=0
P.F['shen.curry']=function(x)
 if not active then
  active=true;nested=nested+1
  local got=TN.native_typecheck(2,number)
  active=false
  assert(got==number)
 end
 return original(x)
end
check(TN.native_typecheck(1,number)==number and nested==1,'nested preprocessing query succeeds')
P.F['shen.curry']=original
check(tops()==saved,'nested query restores arena tops')
-- A failed judgment remains a normal false return, and the next succeeds.
check(TN.native_typecheck(1,R.intern('string'))==false,'rejection is not an error status')
check(TN.native_typecheck(1,number)==number,'checker usable after errors and rejection')
print(string.format('typecheck_cleanup_spec: %d pass, %d fail',pass,fail))
os.exit(fail==0 and 0 or 1)
