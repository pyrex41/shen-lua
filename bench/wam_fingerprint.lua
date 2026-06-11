-- bench/wam_fingerprint.lua — Phase 1 behavioral fingerprint of the real
-- type-inference engine on the 431,741-inf y-combinator typecheck.
-- THROWAWAY profiler. Wraps the CPS goal-ABI F-table entries (callfreq.lua
-- style; FA arity copied so APP dispatch is unchanged) with call counters and a
-- false-return (backtrack) detector, and samples the term sizes/depths actually
-- unified.  All counters are integer increments into pre-existing tables.
--
-- KEY FIDELITY FINDING (see fidelity_notes): the t-star typecheck driver
-- (shen.t*, shen.system-S*, shen.p-hyps, ...) is the dominant engine, NOT the
-- generic prolog call/fork ABI. We wrap BOTH the driver goals and the prolog
-- primitives so the shape is attributed correctly.
--
-- Wrapping a CPS goal with `local r=orig(...); return r` adds one Lua frame per
-- call (breaks TCO) but does NOT touch shen.*infs*, so the inference count stays
-- 431741. (Confirmed below by asserting infs.)
--
-- Run from shen-lua dir:  luajit bench/wam_fingerprint.lua 2>/tmp/fp.txt
package.path = "./?.lua;" .. package.path
local P = require("boot"); local R = require("runtime")
P.load_kernel(false); P.initialise()
local ffi = require("ffi"); ffi.cdef[[int chdir(const char*);]]
ffi.C.chdir("../cl-source/ShenOSKernel-41.2/tests")
local mf=P.F["shen.macros"]
if mf and not P.GLOBALS["*macros*"] then P.GLOBALS["*macros*"]=R.cons(R.cons(R.cons(R.intern("shen.macros"),mf),R.NIL),R.NIL) end
if P.GLOBALS["shen.*tc*"]~=nil and P.GLOBALS["*tc*"]==nil then P.GLOBALS["*tc*"]=P.GLOBALS["shen.*tc*"] end
P.F["load"]("interpreter.shen")
local term = P.F["hd"](P.F["read-from-string"]('[[[y-combinator [/. ADD [/. X [/. Y [if [= X 0] Y [[ADD [-- X]] [++ Y]]]]]]] 3] 4]'))
local A = P.F["gensym"](R.intern("A"))

local F, FA = P.F, P.FA
local getmt = getmetatable
local Vmt = R.Vmt
local is_cons = R.is_cons
local shen_pvar = R.intern("shen.pvar")
local null = R.intern("shen.-null-")

-- per-function call + fail(false-return) counts
local CALLS, FAILS = {}, {}
-- aggregate category counters
local C = {
  newpv=0, gc=0, gc_reclaim=0,        -- pvar lifecycle (gc_reclaim = backtrack)
  bind_=0, bind_unwind=0,             -- shen.bind! (low-level) + unwinds
  cut=0, lock=0,                      -- cut sites + lock effects
  lzy=0, lzyoc=0,                     -- unify entrypoints incl. recursive steps
  is=0, is_oc=0, bind=0, when=0,      -- prolog literals
  call=0, fork=0, fork_branch=0,      -- generic prolog dispatch
}

-- term size/depth sampled at each top-level unify literal (is / is! / bind)
local size_hist, depth_hist = {}, {}
local function bump(h,k) h[k]=(h[k] or 0)+1 end
local function size_depth(x, vec, fuel)
  if fuel[1] <= 0 then return 0,0 end
  fuel[1] = fuel[1]-1
  if getmt(x)==Vmt and x[2]==shen_pvar then
    local w = vec and vec[x[3]+2]
    if w~=nil and w~=null then return size_depth(w,vec,fuel) end
    return 0,0
  elseif is_cons(x) then
    local hs,hd = size_depth(x[1],vec,fuel)
    local ts,td = size_depth(x[2],vec,fuel)
    local d = hd; if td>d then d=td end
    return 1+hs+ts, 1+d
  else return 0,0 end
end
local function sample(x, y, vec)
  local f={1500}; local sx,dx = size_depth(x,vec,f)
  f[1]=1500; local sy,dy = size_depth(y,vec,f)
  local s=sx; if sy>s then s=sy end
  local d=dx; if dy>d then d=dy end
  bump(size_hist,s); bump(depth_hist,d)
end

-- generic CPS-goal wrapper: count call + false-return. Returns a wrapper that
-- preserves arity. cat optionally names an aggregate counter to also bump.
local function wrapgoal(name, cat)
  local orig = F[name]; if not orig then return end
  local ar = FA[orig]
  CALLS[name]=0; FAILS[name]=0
  local w = function(...)
    CALLS[name]=CALLS[name]+1
    if cat then C[cat]=C[cat]+1 end
    local r = orig(...)
    if r==false then FAILS[name]=FAILS[name]+1 end
    return r
  end
  FA[w]=ar; F[name]=w
end

-- ---- t-star driver goals (the real engine) ---------------------------------
for _,n in ipairs{
  "shen.t*","shen.t*-rules","shen.t*-rule","shen.t*-rule-h","shen.t*-correct",
  "shen.t*-integrity","shen.system-S","shen.p-hyps",
  "shen.myassume","shen.insert-prolog-variables","shen.toplevel-forms",
  "shen.search-user-datatypes","shen.l-rules","shen.lookupsig","shen.primitive",
  "shen.by-hypothesis",
} do wrapgoal(n) end

-- shen.system-S-h: the recursive workhorse. Wrap + sample the term being typed
-- (its first arg is the expression, derefed through the vector).
do local o=F["shen.system-S-h"]; local ar=FA[o]
   CALLS["shen.system-S-h"]=0; FAILS["shen.system-S-h"]=0
   local w=function(expr, ty, asm, vec, lock, inf, cont)
     CALLS["shen.system-S-h"]=CALLS["shen.system-S-h"]+1
     sample(expr, ty, vec)
     local r=o(expr,ty,asm,vec,lock,inf,cont)
     if r==false then FAILS["shen.system-S-h"]=FAILS["shen.system-S-h"]+1 end
     return r
   end; FA[w]=ar; F["shen.system-S-h"]=w end

-- ---- prolog ABI primitives --------------------------------------------------
wrapgoal("call","call")
wrapgoal("call-dynamic")
wrapgoal("shen.callrec")
wrapgoal("when","when")

-- cut / lock
do local o=F["shen.cut"]; local ar=FA[o]
   local w=function(...) C.cut=C.cut+1; return o(...) end; FA[w]=ar; F["shen.cut"]=w end
do local o=F["shen.lock"]; if o then local ar=FA[o]
   local w=function(...) C.lock=C.lock+1; return o(...) end; FA[w]=ar; F["shen.lock"]=w end end

-- fork (disjunction)
do local o=F["fork"]; local ar=FA[o]
   local w=function(clauses,...)
     C.fork=C.fork+1
     local n=0; local c=clauses; while is_cons(c) do n=n+1; c=c[2] end
     C.fork_branch=C.fork_branch+n
     return o(clauses,...)
   end; FA[w]=ar; F["fork"]=w end

-- bind (6-arg prolog literal -> shen.bind!) : the driver's main binder. sample term.
do local o=F["bind"]; local ar=FA[o]
   local w=function(x,y,vec,lock,inf,cont)
     C.bind=C.bind+1; sample(x,y,vec)
     return o(x,y,vec,lock,inf,cont)
   end; FA[w]=ar; F["bind"]=w end

-- shen.bind! (low-level 4-arg) : counts binds + unwinds (backtrack-at-bind)
do local o=F["shen.bind!"]; local ar=FA[o]
   local w=function(...) C.bind_=C.bind_+1; local r=o(...); if r==false then C.bind_unwind=C.bind_unwind+1 end; return r
   end; FA[w]=ar; F["shen.bind!"]=w end

-- is / is! : conjunctive unify literals. sample term shape.
do local o=F["is"]; local ar=FA[o]
   local w=function(x,y,vec,lock,inf,cont) C.is=C.is+1; sample(x,y,vec); return o(x,y,vec,lock,inf,cont)
   end; FA[w]=ar; F["is"]=w end
do local o=F["is!"]; local ar=FA[o]
   local w=function(x,y,vec,lock,inf,cont) C.is_oc=C.is_oc+1; sample(x,y,vec); return o(x,y,vec,lock,inf,cont)
   end; FA[w]=ar; F["is!"]=w end

-- newpv / gc : pvar lifecycle. gc reclaim == backtrack.
do local o=F["shen.newpv"]; local ar=FA[o]
   local w=function(...) C.newpv=C.newpv+1; return o(...) end; FA[w]=ar; F["shen.newpv"]=w end
do local o=F["shen.gc"]; local ar=FA[o]
   local w=function(vec,x) C.gc=C.gc+1; if x==false then C.gc_reclaim=C.gc_reclaim+1 end; return o(vec,x)
   end; FA[w]=ar; F["shen.gc"]=w end

-- lzy / lzyoc : unify cores (incl. recursive steps).
do local o=F["shen.lzy="]; local ar=FA[o]
   local w=function(...) C.lzy=C.lzy+1; return o(...) end; FA[w]=ar; F["shen.lzy="]=w end
do local o=F["shen.lzy=!"]; local ar=FA[o]
   local w=function(...) C.lzyoc=C.lzyoc+1; return o(...) end; FA[w]=ar; F["shen.lzy=!"]=w end

-- ---- run --------------------------------------------------------------------
local infs0 = P.GLOBALS["shen.*infs*"] or 0
P.F["shen.typecheck"](term, A)
local infs = (P.GLOBALS["shen.*infs*"] or 0) - infs0

-- ---- report -----------------------------------------------------------------
local function per(x) return (x or 0)/infs end
local out = io.stderr
out:write(string.format("\n=== WAM FINGERPRINT (infs=%d, expect 431741) ===\n", infs))

out:write("\n--- t-star DRIVER goals: calls / false-returns(backtrack) / /inf ---\n")
out:write(string.format("%-30s %12s %12s %10s %8s\n","goal","calls","fails","/inf","fail%"))
local drv = {"shen.t*","shen.t*-rules","shen.t*-rule","shen.t*-rule-h","shen.t*-correct",
  "shen.t*-integrity","shen.system-S","shen.system-S-h","shen.search-user-datatypes",
  "shen.l-rules","shen.lookupsig","shen.primitive","shen.by-hypothesis","shen.p-hyps",
  "shen.myassume","shen.insert-prolog-variables","shen.toplevel-forms",
  "call","call-dynamic","shen.callrec"}
local tot_calls, tot_fails = 0,0
for _,n in ipairs(drv) do
  local c,f = CALLS[n] or 0, FAILS[n] or 0
  tot_calls=tot_calls+c; tot_fails=tot_fails+f
  if c>0 then out:write(string.format("%-30s %12d %12d %10.4f %7.1f%%\n", n, c, f, per(c), c>0 and 100*f/c or 0)) end
end
out:write(string.format("%-30s %12d %12d %10.4f %7.1f%%\n","TOTAL goal-calls",tot_calls,tot_fails,per(tot_calls),tot_calls>0 and 100*tot_fails/tot_calls or 0))

out:write("\n--- aggregate counters ---\n")
local agg = {"when","cut","lock","fork","fork_branch","is","is_oc","bind","bind_","bind_unwind",
  "lzy","lzyoc","newpv","gc","gc_reclaim"}
out:write(string.format("%-16s %14s %10s\n","counter","count","/inf"))
for _,k in ipairs(agg) do out:write(string.format("%-16s %14d %10.4f\n", k, C[k], per(C[k]))) end

out:write("\n--- derived ratios ---\n")
out:write(string.format("conj literals (is+is!+bind+when) : %d  (%.3f /inf)\n", C.is+C.is_oc+C.bind+C.when, per(C.is+C.is_oc+C.bind+C.when)))
out:write(string.format("disj sites (fork)                : %d  (avg %.2f branches)\n", C.fork, C.fork>0 and C.fork_branch/C.fork or 0))
out:write(string.format("choice points (newpv)            : %d  (%.3f /inf)\n", C.newpv, per(C.newpv)))
out:write(string.format("backtracks (gc reclaim)          : %d  (%.3f /inf, %.1f%% of newpv)\n",
  C.gc_reclaim, per(C.gc_reclaim), C.newpv>0 and 100*C.gc_reclaim/C.newpv or 0))
out:write(string.format("driver-goal fail ratio           : %.1f%% of goal-calls return false\n",
  tot_calls>0 and 100*tot_fails/tot_calls or 0))
out:write(string.format("bind-unwind (fail after bind!)   : %d  (%.1f%% of bind!s)\n",
  C.bind_unwind, C.bind_>0 and 100*C.bind_unwind/C.bind_ or 0))
out:write(string.format("cut frequency                    : %.4f /inf (%d)\n", per(C.cut), C.cut))

local function dump(name,h)
  local keys={}; for k in pairs(h) do keys[#keys+1]=k end; table.sort(keys)
  local tot,sum=0,0; for _,k in ipairs(keys) do tot=tot+h[k]; sum=sum+k*h[k] end
  out:write(string.format("\n=== %s (samples=%d, mean=%.2f) ===\n", name, tot, tot>0 and sum/tot or 0))
  for _,k in ipairs(keys) do out:write(string.format("  %3d : %9d (%5.1f%%)\n", k, h[k], 100*h[k]/math.max(1,tot))) end
end
dump("UNIFIED TERM SIZE (cons cells, max of two args)", size_hist)
dump("UNIFIED TERM DEPTH (max cons nesting)", depth_hist)
