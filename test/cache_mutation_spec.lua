-- File-contained mutations are part of the supported FASL replay contract.
-- Interactive mutation between loads remains excluded; see performance docs.
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
if arg[1] == '--child' then
  local s=require('shen'); s.boot{quiet=true,hush_load=true}
  local P,R=s.prims,require('runtime')
  local dir=arg[2]
  P.TRACK_FASL=true
  s.eval('(set cache.fail-count 0) (set cache.nested-count 0)')
  local loaded, problem = R.seg.pcall(P.F.load,dir..'/state.shen')
  assert(loaded, type(problem) == 'table' and problem.msg or tostring(problem))
  local status=P.LAST_FASL_STATUS or 'off'
  local function emit(k,v) print('STATE',k,s.tostring(v)) end
  emit('macro',s.eval('(cache-token)'))
  emit('datatype-new',s.typecheck('["ok"]','cache-box'))
  emit('datatype-old',s.typecheck('[1]','cache-box'))
  emit('destroyed',s.typecheck('(cache.dead 1)','number'))
  emit('dead-arity',P.F.arity(R.intern('cache.dead')))
  emit('bridge',s.eval('(cache.upper "abc")'))
  emit('bridge-type',s.typecheck('(cache.upper "abc")','string'))
  emit('bridge-arity',P.F.arity(R.intern('cache.upper')))
  for _=1,2 do
    local ok,e=R.seg.pcall(P.F.load,dir..'/failed.shen')
    assert(not ok and e.msg == 'cache-failure', 'failed load must retain its error')
  end
  emit('failed-effects',P.GLOBALS['cache.fail-count'])
  emit('nested-effects',P.GLOBALS['cache.nested-count'])
  print('CACHE',status)
  print('DONE')
  return
end
local tmp=os.tmpname(); os.remove(tmp); assert(os.execute('mkdir -p '..quote(tmp)) == 0)
local function write(name,src)
  local f=assert(io.open(tmp..'/'..name,'wb'));f:write(src);f:close()
end
write('dependency.shen','(set cache.nested-count (+ 1 (value cache.nested-count)))\n')
write('state.shen', [[
(defmacro cache-replace [cache-token] -> 1)
(defmacro cache-replace [cache-token] -> 2)
(datatype cache-box X : number; ================ [X] : cache-box;)
(datatype cache-box X : string; ================ [X] : cache-box;)
(declare cache.dead [number --> number])
(define cache.dead X -> X)
(destroy cache.dead)
(lua.function cache.upper "string.upper" [string --> string])
]] .. '(load "' .. tmp .. '/dependency.shen")\n')
write('failed.shen', [[
(set cache.fail-count (+ 1 (value cache.fail-count)))
(simple-error "cache-failure")
]])
local lua=os.getenv('LUA') or 'luajit'
local function run(state)
  local cmd='env SHEN_KERNEL_CACHE=off SHEN_FASL='..(state=='off' and 'off' or 'on')
    ..' SHEN_FASL_DIR='..quote(tmp..'/fasl')..' '..lua..' test/cache_mutation_spec.lua --child '..quote(tmp)
  local h=assert(io.popen(cmd..' 2>&1'));local out=h:read('*a');h:close()
  assert(out:find('DONE',1,true),'private failed fixture: '..tmp..'\n'..out)
  local fingerprint={}
  for line in out:gmatch('[^\n]+') do if line:match('^STATE') then fingerprint[#fingerprint+1]=line end end
  return table.concat(fingerprint,'\n'),out
end
local ref,off=run('off')
local cold,coldout=run('cold');local hit,hitout=run('hit')
assert(cold == ref and hit == ref,'off/cold/hit mutation state differs\n'..off..coldout..hitout)
assert(coldout:find('CACHE\tmiss',1,true) and hitout:find('CACHE\thit',1,true),coldout..hitout)
assert(ref:find('STATE\tmacro\t2',1,true),ref)
assert(ref:find('STATE\tdatatype-new\tcache-box',1,true),ref)
assert(ref:find('STATE\tdatatype-old\tfalse',1,true),ref)
assert(ref:find('STATE\tdestroyed\tfalse',1,true),ref)
assert(ref:find('STATE\tfailed-effects\t2',1,true),ref)
assert(ref:find('STATE\tnested-effects\t1',1,true),ref)
-- Changing a nested dependency must update effects through its enclosing replay.
write('dependency.shen','(set cache.nested-count (+ 7 (value cache.nested-count)))\n')
local changed,changedout=run('cold')
assert(changed:find('STATE\tnested-effects\t7',1,true),changedout)
os.execute('rm -rf '..quote(tmp))
print('cache_mutation_spec: 10 pass, 0 fail')
