-- A literal colon comparison observes only the dereferenced term root.
local shen=require('shen');shen.boot{quiet=true}
local R,E,PC,C= require('runtime'),require('prolog_engine'),require('prolog_compile'),require('compiler')
if not E.query_begin or not PC.NP then
 print('atom_guard_spec: skipped (native engine disabled)');return
end
local pass,fail=0,0
local function check(ok,label) if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..label) end end
local function translated(test)
 return PC.translate_defun(R.read_all('(defun spec.colon (V1 V2 V3 V4 V5) (when '..test..' V2 V3 V4 (freeze true)))')[1])
end
local fn,err,src=translated('(= (shen.deref V1 V2) (intern ":"))')
check(fn~=nil,'exact literal guard translates: '..tostring(err))
check(src and not src:find('MAT(',1,true),'literal atom comparison avoids materialization')
local bare,why,bsrc=translated('(= V1 (intern ":"))')
check(bare~=nil and bsrc:find('LZD(a1) ==',1,true),'bare term compares root: '..tostring(why))
local q=E.query_begin();local v=E.newvar();local chain=E.newvar()
local samples={E.import(R.intern(':'),{}),E.import(R.intern('x'),{}),E.import(':',{}),E.import(R.NIL,{}),E.import(1,{}),
 E.import(false,{}),E.import(true,{}),E.import(shen.prims.F.vector(0),{}),E.import(R.read_all('(: (a) . b)')[1],{}),v,chain,E.atom(R.cons(R.intern(':'),R.NIL))}
for _,term in ipairs(samples) do
 local want=shen.prims.F['='](E.materialize(term),R.intern(':'))
 check(fn(term,0,nil)==want and bare(term,0,nil)==want,'equivalent complete result for term '..term)
end
E.bind1(chain,E.atom(R.intern(':')),function()
 return E.bind1(v,chain,function() check(fn(v,0,nil)==true,'bound variable chain resolves to colon');return false end)
end)
check(fn(v,0,nil)==false,'rollback restores unbound root')
local list=v;for i=1,10000 do list=E.cons(v,list) end
check(fn(list,0,nil)==false,'long open list rejects without walking children')
E.query_end(q)
for _,name in ipairs({'=','intern'}) do
 local old=C.ARITY[name];C.ARITY[name]=2+(name=='=' and 1 or 0)
 local fallback,e,code=translated('(= (shen.deref V1 V2) (intern ":"))');C.ARITY[name]=old
 check(fallback~=nil and code:find('MAT(',1,true),name..' other arity keeps ordinary dispatch: '..tostring(e))
end
for _,test in ipairs({'(= (shen.deref V1 V1) (intern ":"))','(= (shen.deref V1 V2) (intern ":" true))'}) do
 local _,_,code=translated(test)
 check(not code or code:find('MAT(',1,true),'non-exact deref/intern is not optimized')
end
print(string.format('atom_guard_spec: %d pass, %d fail',pass,fail));os.exit(fail==0 and 0 or 1)
