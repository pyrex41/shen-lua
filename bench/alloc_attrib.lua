-- bench/alloc_attrib.lua — Part 1: attribute the residual ~371 B/inf in the
-- typechecker to its sources in the native unification engine.
-- THROWAWAY measurement tool. Run with the profile flag:
--    SHEN_ALLOC_PROFILE=1 luajit bench/alloc_attrib.lua
-- (the counters are installed in prims.install_native_prolog only when the env
-- var is set; without it this prints zeros.)
local P = require("boot"); local R = require("runtime")
P.load_kernel(false); P.initialise()
local ffi = require("ffi"); ffi.cdef[[int chdir(const char*);]]
ffi.C.chdir("../cl-source/ShenOSKernel-41.1/tests")
local mf=P.F["shen.macros"]
if mf and not P.GLOBALS["*macros*"] then P.GLOBALS["*macros*"]=R.cons(R.cons(R.cons(R.intern("shen.macros"),mf),R.NIL),R.NIL) end
if P.GLOBALS["shen.*tc*"]~=nil and P.GLOBALS["*tc*"]==nil then P.GLOBALS["*tc*"]=P.GLOBALS["shen.*tc*"] end
P.F["load"]("interpreter.shen")
local term = P.F["hd"](P.F["read-from-string"]('[[[y-combinator [/. ADD [/. X [/. Y [if [= X 0] Y [[ADD [-- X]] [++ Y]]]]]]] 3] 4]'))
local A = P.F["gensym"](R.intern("A"))

-- ---- measure per-object sizes (heap-growth deltas, GC stopped) ----
local function objsize(make)
  collectgarbage("collect"); collectgarbage("stop")
  local N = 200000
  local keep = {}
  local m0 = collectgarbage("count")
  for i=1,N do keep[i] = make(i) end
  local m1 = collectgarbage("count")
  collectgarbage("restart")
  keep = nil
  return (m1-m0)*1024/N
end
-- a closure capturing 4 upvalues (mirrors the lzy/lzyoc tail continuation)
local sz_cont = objsize(function(i) local a,b,c,d=i,i,i,{} ; return function() return a+b+c+#d end end)
-- a 5-slot array table (the BIND-style thunk a defunctionalized cont would use)
local sz_thunk5 = objsize(function(i) return {i,i,i,i,i} end)
-- a cons cell (what deref rebuilds)
local sz_cons = objsize(function(i) return R.cons(i,i) end)

-- ---- run the measured typecheck, counters reset to isolate this one call ----
collectgarbage("collect")
local infs0 = P.GLOBALS["shen.*infs*"] or 0
local AP = P.AP or {}
for k in pairs(AP) do AP[k] = 0 end
local SLOTS, THAW = P.AP_SLOTS or {}, P.AP_THAW or {}
for k in pairs(SLOTS) do SLOTS[k] = nil end
for k in pairs(THAW)  do THAW[k]  = nil end
P.F["shen.typecheck"](term, A)
local infs = (P.GLOBALS["shen.*infs*"] or 0) - infs0

local function per(x) return (x or 0)/infs end
-- size of a BIND thunk at the workload's average slot count
local avg_slots = (AP.mkbind and AP.mkbind > 0) and (AP.mkbind_slots/AP.mkbind) or 5
local nslots = math.max(2, math.floor(avg_slots + 0.5))
local sz_thunk = objsize(function(i) local t={} for j=1,nslots do t[j]=i end return setmetatable(t, getmetatable(setmetatable({},{}))) end)
io.stderr:write(string.format("\n=== ALLOC ATTRIBUTION (infs=%d) ===\n", infs))
io.stderr:write(string.format("measured sizes: cont(4-upval closure)=%.0f B, thunk(5-slot tbl)=%.0f B, thunk(%d-slot avg)=%.0f B, cons=%.0f B\n\n", sz_cont, sz_thunk5, nslots, sz_thunk, sz_cons))
io.stderr:write(string.format("%-18s %14s %10s %12s\n", "source", "count", "/inf", "B/inf"))
local function row(name, count, size) io.stderr:write(string.format("%-18s %14d %10.3f %12.1f\n", name, count, per(count), per(count)*(size or 0))) end
row("lzy_calls",      AP.lzy_calls,   0)
row("lzyoc_calls",    AP.lzyoc_calls, 0)
row("lzy_cont",       AP.lzy_cont,    sz_cont)
row("lzyoc_cont",     AP.lzyoc_cont,  sz_cont)
row("deref_calls",    AP.deref_calls, 0)
row("deref_cons",     AP.deref_cons,  sz_cons)
row("occ_deref_calls",AP.occ_deref_calls, 0)
row("bind_calls",     AP.bind_calls,  0)
row("newpv_total",    AP.newpv_total, 0)
row("newpv_poolmiss", AP.newpv_poolmiss, 0)
row("mkbind (thunks)",AP.mkbind,      sz_thunk)
row("mkfun (closures)",AP.mkfun,      sz_cont)
local cont_binf = per((AP.lzy_cont or 0)+(AP.lzyoc_cont or 0))*sz_cont
local deref_binf = per(AP.deref_cons)*sz_cons
local bind_binf = per(AP.mkbind)*sz_thunk
local mkfun_binf = per(AP.mkfun)*sz_cont
io.stderr:write(string.format("\nSUMMARY (of 371 baseline): BIND thunks = %.1f B/inf | MKFUN closures = %.1f B/inf | deref cons = %.1f B/inf | native lzy conts = %.1f B/inf\n",
  bind_binf, mkfun_binf, deref_binf, cont_binf))
io.stderr:write(string.format("  accounted = %.1f B/inf (mkfun size is approximate; closures capture 1-5 vars)\n", bind_binf+mkfun_binf+deref_binf+cont_binf))
io.stderr:write(string.format("pool hit rate: %d/%d allocated fresh (%.2f%% pooled)\n",
  AP.newpv_poolmiss, AP.newpv_total, 100*(1-(AP.newpv_poolmiss/math.max(1,AP.newpv_total)))))

-- ---- BIND-thunk slot-count histogram (lever 1a: is there capture-fat to trim?) ----
io.stderr:write("\n=== BIND-thunk SLOT histogram (nslots = captures+1) ===\n")
local slotkeys = {}
for k in pairs(SLOTS) do slotkeys[#slotkeys+1] = k end
table.sort(slotkeys)
local totb, totslots = 0, 0
for _,k in ipairs(slotkeys) do totb = totb + SLOTS[k]; totslots = totslots + k*SLOTS[k] end
for _,k in ipairs(slotkeys) do
  io.stderr:write(string.format("  %2d slots: %9d  (%5.1f%%)\n", k, SLOTS[k], 100*SLOTS[k]/math.max(1,totb)))
end
io.stderr:write(string.format("  total thunks=%d, avg slots=%.2f (captures=%.2f)\n", totb, totslots/math.max(1,totb), totslots/math.max(1,totb)-1))

-- ---- per-thunk thaw-count histogram (lever 1b: are thunks single-shot/poolable?) ----
io.stderr:write("\n=== thunk THAW-count histogram (lever 1b viability) ===\n")
local distinct_thawed, b1, b2, b3to5, b6 = 0, 0, 0, 0, 0
for _,n in pairs(THAW) do
  distinct_thawed = distinct_thawed + 1
  if n == 1 then b1 = b1 + 1
  elseif n == 2 then b2 = b2 + 1
  elseif n <= 5 then b3to5 = b3to5 + 1
  else b6 = b6 + 1 end
end
local never = (AP.mkbind or 0) - distinct_thawed
io.stderr:write(string.format("  created=%d  total thaws=%d  (avg %.2f thaws / created thunk)\n", AP.mkbind, AP.thaw_total, (AP.thaw_total or 0)/math.max(1,AP.mkbind)))
io.stderr:write(string.format("  never thawed: %d (%.1f%%)\n", never, 100*never/math.max(1,AP.mkbind)))
io.stderr:write(string.format("  thawed once:  %d (%.1f%%)  <- single-shot (poolable iff a reclaim point exists)\n", b1, 100*b1/math.max(1,AP.mkbind)))
io.stderr:write(string.format("  thawed twice: %d (%.1f%%)\n", b2, 100*b2/math.max(1,AP.mkbind)))
io.stderr:write(string.format("  thawed 3-5x:  %d (%.1f%%)\n", b3to5, 100*b3to5/math.max(1,AP.mkbind)))
io.stderr:write(string.format("  thawed 6+x:   %d (%.1f%%)\n", b6, 100*b6/math.max(1,AP.mkbind)))
