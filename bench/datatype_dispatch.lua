-- Rejected runtime candidate, retained for reproducible experiments only.
local function new(P,E)
local R=require('runtime')
local Cons,Symbol,getmt=R.Cons,R.Symbol,getmetatable
local NP=E.NativePred
local generic_sud=assert(NP['shen.search-user-datatypes'])
local dispatch_root,dispatch_worker
local M={dispatch_stats={builds=0,sites=0,bytes=0},NATIVE_MISS=require('typecheck_native').NATIVE_MISS}
-- Bounded callback specialization for the ordered datatype list. Each site
-- keeps its live NP lookup (so redefinitions are observed) but has a distinct
-- Lua call instruction. Guards fall back at the current suffix, never replaying
-- predicates already tried. No predicate is translated merely to build this.
function M.refresh_datatype_dispatch()
  local root = P.GLOBALS["shen.*datatypes*"]
  if root == dispatch_root and dispatch_worker then return end
  local names, rest = {}, root
  while getmt(rest) == Cons and #names < 32 do
    local entry = rest[1]
    if getmt(entry) ~= Cons or getmt(entry[1]) ~= Symbol then break end
    names[#names+1] = entry[1]
    rest = rest[2]
  end
  if #names == 0 then
    NP["shen.search-user-datatypes"] = generic_sud
    dispatch_root, dispatch_worker = root, nil
    return
  end
  local code = { "local E,NP,names,generic,miss = ...; return function(goal,assum,l,n,cont) local r" }
  for i,nm in ipairs(names) do
    code[#code+1] = ([=[
      do
        if not E.lock_is_open() then return false end
        l = E.lazyderef(l)
        if l < E.CONS_BASE then return false end
        local entry = E.lazyderef(E.car(l))
        if entry < E.CONS_BASE or E.atomval(E.lazyderef(E.car(entry))) ~= names[%d] then
          return generic(goal,assum,l,n,cont)
        end
        local fn = NP[%q]
        if fn == nil then error(miss,0) end
        E.incinfs()
        r = fn(goal,assum,n,cont)
        if r ~= false then return r end
        if not E.lock_is_open() then return false end
        E.incinfs()
        l = E.cdr(l)
      end
    ]=]):format(i,nm.name)
  end
  code[#code+1] = "return generic(goal,assum,l,n,cont) end"
  local src = table.concat(code, "\n")
  local make = assert((loadstring or load)(src, "@datatype-dispatch"))
  dispatch_worker = make(E,NP,names,generic_sud,M.NATIVE_MISS)
  dispatch_root = root
  NP["shen.search-user-datatypes"] = dispatch_worker
  M.dispatch_stats.builds = M.dispatch_stats.builds + 1
  M.dispatch_stats.sites, M.dispatch_stats.bytes = #names, #src
end

M.refresh_datatype_dispatch()
return M
end
return {new=new}
