-- Experimental lexical closure pass. No runtime representation changes.
local R = require('runtime')
local M = {}
local function array(x)
  local a = {}
  while R.is_cons(x) do a[#a+1] = x[1]; x = x[2] end
  return a
end
local function list(a)
  local x = R.NIL
  for i = #a, 1, -1 do x = R.cons(a[i], x) end
  return x
end
local function name(x) return R.is_symbol(x) and x.name end
local function copy(t) local u = {}; for k,v in pairs(t) do u[k]=v end; return u end
local specials = {['let']=true, ['lambda']=true, ['freeze']=true,
  ['defun']=true, ['if']=true, ['cond']=true, ['do']=true,
  ['trap-error']=true, ['and']=true, ['or']=true, ['type']=true}

function M.optimize(form, params)
  local original, changed = form, false
  local records, used, unsafe = {}, {}, false
  local function scan(x)
    if R.is_symbol(x) then used[x.name] = true
    elseif R.is_cons(x) then
      local a = array(x)
      if (name(a[1]) == 'let' or name(a[1]) == 'lambda') and specials[name(a[2])] then unsafe = true end
      for _,v in ipairs(a) do scan(v) end
    end
  end
  scan(form)
  for _,p in ipairs(params or {}) do used[p.name]=true; if specials[p.name] then unsafe=true end end
  if unsafe then return form, records end
  local serial = 0
  local function fresh()
    local n
    repeat serial=serial+1; n='ClosureSpike'..serial until not used[n]
    used[n]=true
    return R.intern(n)
  end
  -- Unique lexical names prevent both argument capture and definition-site
  -- captures being rebound by lets at the call site. Input trees are immutable.
  local function alpha(x, env)
    if R.is_symbol(x) then return env[x.name] or x end
    if not R.is_cons(x) then return x end
    local a=array(x); local op=name(a[1])
    if op=='let' or op=='lambda' then
      local e=copy(env); local v=fresh(); e[name(a[2])]=v
      if op=='let' then return list{a[1],v,alpha(a[3],env),alpha(a[4],e)} end
      return list{a[1],v,alpha(a[3],e)}
    end
    for i,v in ipairs(a) do a[i]=alpha(v,env) end
    return list(a)
  end
  form=alpha(form,{})
  local function uses(x, target, deferred, r)
    if R.is_symbol(x) then if x.name==target then r.escapes=true end; return end
    if not R.is_cons(x) then return end
    local a=array(x); local op=name(a[1])
    if op==target then
      if #a~=2 or deferred then r.escapes=true else r.calls=r.calls+1 end
      for i=2,#a do uses(a[i],target,deferred,r) end
      return
    end
    local d=deferred or op=='lambda' or op=='freeze' or op=='defun'
    for _,v in ipairs(a) do uses(v,target,d,r) end
  end
  local function replace(x,target,lam)
    if not R.is_cons(x) then return x end
    local a=array(x)
    if name(a[1])==target then
      return list{R.intern('let'),lam[2],replace(a[2],target,lam),lam[3]}
    end
    for i,v in ipairs(a) do a[i]=replace(v,target,lam) end
    return list(a)
  end
  local function walk(x, scope)
    if not R.is_cons(x) then return x end
    local a=array(x); local op=name(a[1])
    if op=='lambda' then
      local s=copy(scope); s[name(a[2])]=true
      a[3]=walk(a[3],s); return list(a)
    elseif op=='let' then
      a[3]=walk(a[3],scope)
      local s=copy(scope); s[name(a[2])]=true
      a[4]=walk(a[4],s)
      local lam=R.is_cons(a[3]) and array(a[3])
      if lam and name(lam[1])=='lambda' then
        local r={kind='closure', binding=name(a[2]), calls=0, escapes=false, captures={}}
        local seen={}; local size=0
        local function captures(v)
          size=size+1
          if R.is_symbol(v) and scope[v.name] then seen[v.name]=true
          elseif R.is_cons(v) then for _,w in ipairs(array(v)) do captures(w) end end
        end
        captures(lam[3]); for n in pairs(seen) do r.captures[#r.captures+1]=n end
        table.sort(r.captures); uses(a[4],r.binding,false,r)
        r.eliminated=not r.escapes and r.calls<=4 and size<=80
        records[#records+1]=r
        if r.eliminated then changed=true; return replace(a[4],r.binding,lam) end
      end
      return list(a)
    end
    for i,v in ipairs(a) do a[i]=walk(v,scope) end
    if R.is_cons(a[1]) and #a==2 then
      local lam=array(a[1])
      if name(lam[1])=='lambda' then
        changed=true
        records[#records+1]={kind='immediate',calls=1,escapes=false,eliminated=true}
        return list{R.intern('let'),lam[2],a[2],lam[3]}
      end
    end
    return list(a)
  end
  local scope={}; for _,p in ipairs(params or {}) do scope[p.name]=true end
  local result=walk(form,scope)
  return changed and result or original, records
end
return M
