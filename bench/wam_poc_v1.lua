-- bench/wam_poc_v1.lua — Phase 2 PoC engine v1: PURE-LUA iterative mini-engine.
--
-- Tests the hypothesis: an iterative (WAM-style) engine with explicit goal /
-- choice-point / trail stacks and NO per-step CPS closures, using pure-Lua
-- preallocated/reused buffers (NO FFI), can drop per-inference allocation toward
-- zero versus the current CPS-closure shape.
--
-- This file contains BOTH:
--   * BaselineEngine — the CPS-closure shape (variant a), == M.RefEngine in
--     bench/wam_workload.lua, the number to beat.
--   * WamEngine      — pure-Lua iterative engine: explicit goal stack +
--     choice-point stack + trail (plain Lua arrays), values as the existing Lua
--     reps (cons tables, pvars as small tables), continuations as slots in a
--     preallocated frame pool that is bump-allocated and pointer-reset on
--     backtrack instead of GC-allocated closures.
--
-- It runs the SAME synthetic workload (bench/wam_workload.lua) through both,
-- asserts the WAM engine computes the SAME unify success/fail sequence as the
-- baseline (correctness gate), then measures alloc bytes/inference (min-of-5)
-- for both, plus a rough wall number.
--
-- Honors infs counting like shen.incinfs: every unify step / goal pop bumps an
-- inference counter, mirroring the kernel.

local M = require("wam_workload")

-- ===========================================================================
-- deref helper shared by both engines (pvar = {var=true, bound=, val=}).
-- ===========================================================================
local function deref(x)
  while type(x) == "table" and x.var and x.bound do x = x.val end
  return x
end

-- ===========================================================================
-- BaselineEngine — CPS-closure shape (== M.RefEngine). Re-declared here (not
-- aliased) so the A/B is self-contained and the closure allocation is explicit.
-- ===========================================================================
local Base = {}
Base.__index = Base
function Base.new()
  return setmetatable({vars = {}, vn = 0, locked = false, infs = 0}, Base)
end
function Base:reset() self.vn = 0; self.locked = false end
function Base:newpv()
  self.vn = self.vn + 1
  local v = {var = true, bound = false}
  self.vars[self.vn] = v
  return v
end
function Base:reclaim(n)
  for _ = 1, n do
    local v = self.vars[self.vn]; if v then v.bound = false; v.val = nil end
    self.vn = self.vn - 1
    if self.vn < 0 then self.vn = 0 end
  end
end
function Base:cut() self.locked = true end
function Base:guard_fail() return false end
function Base:build_term(size, depth, rand)
  if size == 0 then return math.floor(rand() * 1000) end
  local function build(n)
    if n <= 0 then return (rand() < 0.3) and self:newpv() or math.floor(rand() * 1000) end
    return {n % 3 == 0 and self:newpv() or n, build(n - 1), cons = true}
  end
  return build(size)
end
function Base:make_cont(caps, body)
  return function() local _ = caps; return body() end   -- CPS closure
end
function Base:run_cont(cont) return cont() end
function Base:unify(a, b, cont)
  self.infs = self.infs + 1
  a, b = deref(a), deref(b)
  if a == b then return cont() and true or false end
  if type(a) == "table" and a.var then
    a.bound = true; a.val = b
    local r = cont()
    if not r then a.bound = false; a.val = nil; return false end
    return true
  elseif type(b) == "table" and b.var then
    b.bound = true; b.val = a
    local r = cont()
    if not r then b.bound = false; b.val = nil; return false end
    return true
  elseif type(a) == "table" and a.cons and type(b) == "table" and b.cons then
    return self:unify(a[1], b[1], function() return self:unify(a[2], b[2], cont) end)
  else
    return false
  end
end

-- ===========================================================================
-- WamEngine — PURE-LUA iterative engine.
--
-- Key allocation-avoidance moves:
--  * unify is ITERATIVE over an explicit goal stack (gA[], gB[]) + a trail[]
--    (plain Lua arrays, reused across calls, never re-created). No per-cons
--    closure continuation is allocated (the baseline allocates one closure per
--    interior cons node).
--  * pvars come from a pool (newpv reuses table objects; reclaim just rewinds a
--    cursor and clears the binding), so the choice-point churn is alloc-free.
--  * continuations (make_cont) do NOT allocate a closure. The driver hands us a
--    caps table + body fn; we record them into a preallocated FRAME POOL (cont
--    cursor + parallel arrays), returning a small integer handle. run_cont looks
--    the body up by handle and calls it. The frame pool grows once to high-water
--    mark, then is pointer-reset on reset()/backtrack — bump-allocated, not GC'd.
--    NOTE: the `body` fn itself is allocated by the WORKLOAD driver (the
--    `function() ... end` literal in wam_workload.lua make_cont call site), which
--    is OUTSIDE the engine and identical for both engines, so it does not
--    distinguish them; what we avoid is the engine's OWN per-cont closure wrap
--    (Base:make_cont wraps body in another closure) and the per-cons unify
--    continuation closures.
-- ===========================================================================
local Wam = {}
Wam.__index = Wam
function Wam.new()
  local self = setmetatable({}, Wam)
  -- pvar pool
  self.pool = {}       -- all ever-allocated pvars (reused)
  self.pn = 0          -- live pvar count (cursor)
  -- trail of bound pvars to unwind
  self.trail = {}
  self.tn = 0
  -- explicit unify goal stacks (reused buffers)
  self.gA = {}
  self.gB = {}
  -- continuation frame pool (bodies + caps), bump-allocated
  self.cbody = {}
  self.ccaps = {}
  self.cn = 0
  self.locked = false
  self.infs = 0
  return self
end

function Wam:reset()
  self.pn = 0
  self.tn = 0
  self.cn = 0
  self.locked = false
end

function Wam:newpv()
  self.pn = self.pn + 1
  local v = self.pool[self.pn]
  if v == nil then
    v = {var = true, bound = false, val = nil}
    self.pool[self.pn] = v
  else
    v.bound = false; v.val = nil
  end
  return v
end

function Wam:reclaim(n)
  for _ = 1, n do
    local v = self.pool[self.pn]
    if v then v.bound = false; v.val = nil end
    self.pn = self.pn - 1
    if self.pn < 0 then self.pn = 0 end
  end
end

function Wam:cut() self.locked = true end
function Wam:guard_fail() return false end

-- build_term: same structural shape as baseline (uses self:newpv from the pool).
function Wam:build_term(size, depth, rand)
  if size == 0 then return math.floor(rand() * 1000) end
  local function build(n)
    if n <= 0 then return (rand() < 0.3) and self:newpv() or math.floor(rand() * 1000) end
    return {n % 3 == 0 and self:newpv() or n, build(n - 1), cons = true}
  end
  return build(size)
end

-- make_cont: record into the frame pool; return an integer handle. NO closure
-- allocation inside the engine.
function Wam:make_cont(caps, body)
  self.cn = self.cn + 1
  self.cbody[self.cn] = body
  self.ccaps[self.cn] = caps
  return self.cn          -- integer handle (no alloc)
end

function Wam:run_cont(handle)
  local body = self.cbody[handle]
  return body()
end

-- ITERATIVE occurs-check-free* unify over explicit stacks.
-- (*the baseline RefEngine does NOT occurs-check either — it binds var->term
-- directly — so to match results exactly we mirror that: bind on var, no occurs
-- check. The workload's occurs_check flag is not consulted by RefEngine, so we
-- stay bit-identical to the baseline.)
--
-- Returns true on full success (and then runs the cont once), false on failure
-- (and unwinds all bindings made during THIS unify, mirroring the baseline's
-- trail-unwind-on-fail through the closure chain).
function Wam:unify(a, b, cont_fn)
  local gA, gB = self.gA, self.gB
  local trail = self.trail
  local n = 1
  gA[1] = a; gB[1] = b
  local trail_mark = self.tn   -- unwind point for THIS unify
  local ok = true
  while n > 0 do
    self.infs = self.infs + 1
    local x = gA[n]; local y = gB[n]
    gA[n] = nil; gB[n] = nil; n = n - 1
    x = deref(x); y = deref(y)
    if x == y then
      -- success at this goal, continue
    elseif type(x) == "table" and x.var then
      x.bound = true; x.val = y
      self.tn = self.tn + 1; trail[self.tn] = x
    elseif type(y) == "table" and y.var then
      y.bound = true; y.val = x
      self.tn = self.tn + 1; trail[self.tn] = y
    elseif type(x) == "table" and x.cons and type(y) == "table" and y.cons then
      -- push tail goal, then head goal (head solved first — matches baseline
      -- left-to-right recursion order)
      n = n + 1; gA[n] = x[2]; gB[n] = y[2]
      n = n + 1; gA[n] = x[1]; gB[n] = y[1]
    else
      ok = false
      break
    end
  end
  if not ok then
    -- unwind bindings made during this unify
    for i = self.tn, trail_mark + 1, -1 do
      local v = trail[i]; v.bound = false; v.val = nil; trail[i] = nil
    end
    self.tn = trail_mark
    -- clear any leftover goal-stack entries
    while n > 0 do gA[n] = nil; gB[n] = nil; n = n - 1 end
    return false
  end
  -- full structural success: run the continuation. The baseline runs cont at
  -- the deepest success; if cont returns false the baseline unwinds. Mirror it.
  local r = cont_fn()
  if not r then
    for i = self.tn, trail_mark + 1, -1 do
      local v = trail[i]; v.bound = false; v.val = nil; trail[i] = nil
    end
    self.tn = trail_mark
    return false
  end
  return true
end

-- ===========================================================================
-- Correctness gate: drive BOTH engines through the same workload (same seed)
-- and compare the success/fail sequence + the stats. We capture the unify
-- ok-sequence by recording into a side array via a wrapper.
-- ===========================================================================
local function run_capture(EngineClass, params, capture)
  local eng = EngineClass.new()
  -- Wrap unify to record the TOP-LEVEL ok sequence only. The baseline's unify is
  -- recursive (calls itself for cons cells), while the WAM unify is iterative
  -- (one call per top-level unify). To compare the same observable — the result
  -- the WORKLOAD sees per goal-unify — we record only calls made from depth 0
  -- (i.e. invoked by the workload driver, not reentrantly by unify itself).
  local real_unify = eng.unify
  local seq = capture and {} or nil
  local sn = 0
  local depth = 0
  eng.unify = function(self, a, b, cont)
    depth = depth + 1
    local ok = real_unify(self, a, b, cont)
    if seq and depth == 1 then sn = sn + 1; seq[sn] = ok and 1 or 0 end
    depth = depth - 1
    return ok
  end
  local stats = M.run(eng, params)
  return stats, seq, eng
end

local function seqs_equal(s1, s2)
  if #s1 ~= #s2 then return false, ("len %d vs %d"):format(#s1, #s2) end
  for i = 1, #s1 do
    if s1[i] ~= s2[i] then return false, ("differ at %d"):format(i) end
  end
  return true
end

-- ===========================================================================
-- Alloc measurement: collectgarbage stop + count delta / inferences. min-of-5.
-- ===========================================================================
local function measure_alloc(EngineClass, params)
  local best = math.huge
  local best_infs = 0
  for _ = 1, 5 do
    local eng = EngineClass.new()
    -- warm the pools / JIT a touch before measuring this iteration's body
    collectgarbage("collect")
    collectgarbage("stop")
    local m0 = collectgarbage("count")
    local stats = M.run(eng, params)
    local m1 = collectgarbage("count")
    collectgarbage("restart")
    local infs = stats.inferences
    local binf = (m1 - m0) * 1024 / infs
    if binf < best then best = binf; best_infs = infs end
  end
  return best, best_infs
end

local function measure_wall(EngineClass, params)
  -- warm
  do local e = EngineClass.new(); M.run(e, params) end
  local best = math.huge
  for _ = 1, 3 do
    local e = EngineClass.new()
    local t0 = os.clock()
    M.run(e, params)
    local dt = os.clock() - t0
    if dt < best then best = dt end
  end
  return best
end

-- ===========================================================================
-- MAIN
-- ===========================================================================
local function main()
  -- Correctness gate at a smaller scale (sequence comparison must hold exactly).
  local gate_params = {inferences = 200000, seed = 0xC0FFEE}
  io.write("== correctness gate (", gate_params.inferences, " inf) ==\n")
  local bstats, bseq = run_capture(Base, gate_params, true)
  local wstats, wseq = run_capture(Wam, gate_params, true)

  local ok_seq, why = seqs_equal(bseq, wseq)
  -- also compare the workload-level stats (clause_tries, unify_ok, etc.)
  local stats_match = true
  local stats_why = ""
  for _, k in ipairs({"inferences","clause_tries","guard_fails","newpv","reclaimed","cuts","conts_made","conts_run","unifies","unify_ok"}) do
    if bstats[k] ~= wstats[k] then
      stats_match = false
      stats_why = stats_why .. (" %s:%s/%s"):format(k, tostring(bstats[k]), tostring(wstats[k]))
    end
  end
  local correct = ok_seq and stats_match
  io.write(string.format("  unify ok-seq match: %s%s\n", tostring(ok_seq), ok_seq and "" or (" ("..tostring(why)..")")))
  io.write(string.format("  workload stats match: %s%s\n", tostring(stats_match), stats_match and "" or (" ("..stats_why..")")))
  io.write(string.format("  unify_ok = %d (baseline) / %d (wam)\n", bstats.unify_ok, wstats.unify_ok))
  io.write(string.format("  CORRECTNESS: %s\n", correct and "PASS" or "FAIL"))

  -- Allocation measurement at full scale.
  local bench_params = {inferences = 2000000, seed = 0x2545F491}
  io.write("\n== alloc bytes/inference (min-of-5, ", bench_params.inferences, " inf) ==\n")
  local base_binf, base_infs = measure_alloc(Base, bench_params)
  local wam_binf, wam_infs   = measure_alloc(Wam, bench_params)
  io.write(string.format("  baseline (CPS-closure): %.1f B/inf  (infs=%d)\n", base_binf, base_infs))
  io.write(string.format("  wam (pure-lua iter):    %.1f B/inf  (infs=%d)\n", wam_binf, wam_infs))
  io.write(string.format("  delta: %.1f%% of baseline\n", 100 * wam_binf / base_binf))

  -- Rough wall (contention-noisy; min-of-3).
  io.write("\n== rough wall (min-of-3, CONTENTION-NOISY) ==\n")
  local base_w = measure_wall(Base, bench_params)
  local wam_w  = measure_wall(Wam, bench_params)
  io.write(string.format("  baseline: %.3fs   wam: %.3fs   (%.2fx)\n", base_w, wam_w, base_w / wam_w))

  -- machine-readable summary line for the harness to grep
  io.write(string.format("\nRESULT correctness=%s base_binf=%.2f wam_binf=%.2f base_wall=%.3f wam_wall=%.3f\n",
    correct and "PASS" or "FAIL", base_binf, wam_binf, base_w, wam_w))
end

main()
