local H=require('bench.typecheck_harness')
H.run('time')
local P=require('boot'); local R=require('runtime'); local TN=require('typecheck_native')
TN.track_routes=false
local queries={}
for _,stage in ipairs(require('bench.typecheck_corpus')) do
 for _,case in ipairs(stage.cases) do
  if case[1]~='interpreter-y-inferred' then
   local forms=P.F['read-from-string'](case[2]..' : '..case[3])
   queries[#queries+1]={forms[1],forms[2][2][1]}
  end
 end
end
local jp=require('jit.p'); jp.start('fl', '.work/gap-profile/small.profile')
for i=1,2000 do
 for _,q in ipairs(queries) do
  P.GLOBALS['shen.*infs*']=0
  R.seg.call(P.F['shen.typecheck'],q[1],q[2])
 end
end
jp.stop()
print('diagnostic smaller-19: 38000 judgments complete')
