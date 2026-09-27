-- Experiment: give LuaJIT an explicit loop instead of recursive tail dispatch.
local function new(P,E)
  local NP=E.NativePred
  local Symbol=require("runtime").Symbol
  local miss=require('typecheck_native').NATIVE_MISS
  local function search(goal,assum,dts,n,cont)
    while true do
      if not E.lock_is_open() then return false end
      local l=E.lazyderef(dts)
      if l<E.CONS_BASE then return false end
      local entry=E.lazyderef(E.car(l))
      local r=false
      if entry>=E.CONS_BASE then
        local nm=E.atomval(E.lazyderef(E.car(entry)))
        local fn=(getmetatable(nm)==Symbol) and NP[nm.name] or nil
        if fn==nil then error(miss,0) end
        E.incinfs(); r=fn(goal,assum,n,cont)
      end
      if r~=false then return r end
      if not E.lock_is_open() then return false end
      E.incinfs(); dts=E.cdr(l)
    end
  end
  local M={dispatch_stats={builds=1,sites=1,bytes=0}}
  function M.refresh_datatype_dispatch() NP['shen.search-user-datatypes']=search end
  M.refresh_datatype_dispatch()
  return M
end
return {new=new}
