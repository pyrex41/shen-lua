-- bench/wam_poc_v3.lua — Phase 2 PoC engine v3 (HYBRID arena variant).
--
-- Tests the hypothesis from the Phase-1 fingerprint: that the per-inference
-- allocation of the type-inference engine (≈382 B/inf real, ≈578 B/inf on the
-- synthetic RefEngine) is dominated by (a) freeze-thunk CONTINUATIONS that are
-- 83% never run, and (b) cons-term churn + a per-step trail.
--
-- VARIANT: HYBRID. Lua values (cons tables, var tables) + Lua goal/choice
-- stacks, BUT the two HIGH-CHURN transient memory regions live in reused FFI
-- cdata buffers that are reset by a pointer-bump on backtrack:
--   1. THE TRAIL — an int32 cdata ring of bound-var slots, unwound by resetting
--      a top index (no GC, no table growth).
--   2. THE CONTINUATION FRAMES — the dominant cost. The workload's continuation
--      is a closure capturing N (=7) integer "vars" plus a fixed body. Instead of
--      allocating a Lua closure (the 291 B/inf BIND shape), we BUMP-ALLOCATE the
--      captured words into an int32 cdata arena and represent the continuation as
--      a small integer HANDLE (a base offset). run_cont reads the captures back
--      from the arena and calls the shared body. 83%-never-run conts therefore
--      cost only a pointer bump that is reset every inference — zero GC.
--
-- This isolates "arena just the transient churn" from a full WAM rewrite: terms
-- and the goal stack stay as ordinary Lua so unify semantics are byte-identical
-- to the baseline, and only the trail + continuation captures are arena'd.
--
-- Both this variant AND the CPS-closure baseline (RefEngine shape, variant a)
-- are implemented here and A/B'd in the SAME process on the SAME workload.
--
-- Headline metric: bytes-allocated / inference (collectgarbage stop + count
-- delta / infs), min-of-5. Wall time is rough (contention-sensitive). infs are
-- counted like shen.incinfs (one per unify step).

local ffi = require("ffi")
local W   = require("wam_workload")

local INFS_SCALE = tonumber(arg and arg[1]) or 2000000

-- ===========================================================================
-- (a) BASELINE — CPS-closure engine. This is W.RefEngine's shape verbatim,
--     re-declared locally so the file is self-contained for A/B in-process.
--     A logic var is {var=true,bound=false}; unify is recursive CPS with a
--     closure continuation and trail-unwind on failure (mirrors shen.lzy=!).
-- ===========================================================================
local Baseline = {}
Baseline.__index = Baseline
function Baseline.new()
  return setmetatable({vars = {}, vn = 0, locked = false}, Baseline)
end
function Baseline:reset() self.vn = 0; self.locked = false end
function Baseline:newpv()
  self.vn = self.vn + 1
  local v = {var = true, bound = false}
  self.vars[self.vn] = v
  return v
end
function Baseline:reclaim(n)
  for _ = 1, n do
    local v = self.vars[self.vn]; if v then v.bound = false; v.val = nil end
    self.vn = self.vn - 1
    if self.vn < 0 then self.vn = 0 end
  end
end
function Baseline:cut() self.locked = true end
function Baseline:guard_fail() return false end
function Baseline:build_term(size, depth, rand)
  if size == 0 then return math.floor(rand() * 1000) end
  local function build(n)
    if n <= 0 then return (rand() < 0.3) and self:newpv() or math.floor(rand() * 1000) end
    return {n % 3 == 0 and self:newpv() or n, build(n - 1), cons = true}
  end
  return build(size)
end
function Baseline:make_cont(caps, body)
  return function() local _ = caps; return body() end
end
function Baseline:run_cont(cont) return cont() end
local function bderef(x)
  while type(x) == "table" and x.var and x.bound do x = x.val end
  return x
end
function Baseline:unify(a, b, cont)
  a, b = bderef(a), bderef(b)
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
-- (v3) HYBRID arena engine.
--   * Terms / vars: ordinary Lua values (same as baseline) so unify semantics
--     are identical. Vars are pooled in a free list so newpv/reclaim are
--     alloc-free (mirrors the real engine's 100%-pooled pvars).
--   * Trail: int32 cdata ring; bound var-slots recorded by pushing an index;
--     unwound by resetting top. No GC.
--   * Continuations: bump-allocated into an int32 cdata "cont arena". A cont is
--     the integer base offset where its [ncaps, cap1..capN] words were written.
--     The arena top is reset to 0 every inference (the 83%-never-run frames are
--     just reclaimed by the pointer reset). run_cont reads the captures and
--     calls the single shared body fn (the workload's body has no per-cont
--     state other than the captured ints, so this is faithful).
-- ===========================================================================
local CONT_ARENA_WORDS = 65536   -- 64k int32 words; bump+reset, never grows
local TRAIL_WORDS       = 16384
local VAR_POOL_INIT     = 4096

local Hybrid = {}
Hybrid.__index = Hybrid

function Hybrid.new()
  local self = setmetatable({}, Hybrid)
  -- var pool (Lua tables, reused — models 100%-pooled pvars, alloc-free churn)
  self.varpool = {}
  for i = 1, VAR_POOL_INIT do self.varpool[i] = {var = true, bound = false} end
  self.vpool_n = VAR_POOL_INIT      -- free count
  self.live = {}                    -- live var stack (for reclaim LIFO)
  self.vn = 0
  self.locked = false
  -- FFI trail arena
  self.trail = ffi.new("int32_t[?]", TRAIL_WORDS)
  self.trail_top = 0
  -- the live vars themselves hold their binding; trail just records which to
  -- unbind. We keep a parallel Lua array of trailed var refs (fixed-size reuse).
  self.trailed = {}                 -- reused Lua array, indexed by trail slot
  -- FFI continuation arena (captured int words, bump-allocated, reset/inf)
  self.carena = ffi.new("int32_t[?]", CONT_ARENA_WORDS)
  self.carena_top = 0
  -- shared cont body (set by make_cont; in this workload all bodies are the
  -- same "count + return true" thunk, so one slot suffices — but to stay honest
  -- we keep a small table of distinct bodies keyed by identity).
  self.bodies = {}
  self.nbodies = 0
  return self
end

function Hybrid:reset()
  -- reclaim all live vars
  for i = self.vn, 1, -1 do
    local v = self.live[i]
    v.bound = false; v.val = nil
    self.vpool_n = self.vpool_n + 1
    self.varpool[self.vpool_n] = v
    self.live[i] = nil
  end
  self.vn = 0
  self.locked = false
  self.trail_top = 0
  self.carena_top = 0
end

function Hybrid:newpv()
  local v
  if self.vpool_n > 0 then
    v = self.varpool[self.vpool_n]
    self.varpool[self.vpool_n] = nil
    self.vpool_n = self.vpool_n - 1
    v.bound = false; v.val = nil
  else
    v = {var = true, bound = false}   -- pool exhausted (shouldn't happen)
  end
  self.vn = self.vn + 1
  self.live[self.vn] = v
  return v
end

function Hybrid:reclaim(n)
  for _ = 1, n do
    local v = self.live[self.vn]
    if v then
      v.bound = false; v.val = nil
      self.vpool_n = self.vpool_n + 1
      self.varpool[self.vpool_n] = v
      self.live[self.vn] = nil
    end
    self.vn = self.vn - 1
    if self.vn < 0 then self.vn = 0 end
  end
end

function Hybrid:cut() self.locked = true end
function Hybrid:guard_fail() return false end

-- terms: same construction as baseline (ordinary Lua), so unify is comparable.
function Hybrid:build_term(size, depth, rand)
  if size == 0 then return math.floor(rand() * 1000) end
  local function build(n)
    if n <= 0 then return (rand() < 0.3) and self:newpv() or math.floor(rand() * 1000) end
    return {n % 3 == 0 and self:newpv() or n, build(n - 1), cons = true}
  end
  return build(size)
end

-- make_cont: bump the captured int words into the FFI arena, return an integer
-- handle = base offset. The body fn is registered once (identity-deduped) and
-- referenced by index in word[base]. Layout: [bodyIdx, ncaps, cap1..capN].
function Hybrid:make_cont(caps, body)
  local bi = self.bodies[body]
  if not bi then
    self.nbodies = self.nbodies + 1
    bi = self.nbodies
    self.bodies[body] = bi
    self.bodies[bi] = body            -- reverse map (int -> fn)
  end
  local n = #caps
  local base = self.carena_top
  local arena = self.carena
  if base + 2 + n > CONT_ARENA_WORDS then
    -- arena full within one inference (won't happen at these rates); reset.
    base = 0; self.carena_top = 0
  end
  arena[base] = bi
  arena[base + 1] = n
  for i = 1, n do arena[base + 1 + i] = caps[i] end
  self.carena_top = base + 2 + n
  return base + 1   -- handle (offset by 1 so 0 can mean "nil cont" if needed)
end

function Hybrid:run_cont(handle)
  local base = handle - 1
  local arena = self.carena
  local bi = arena[base]
  -- (captures are available at arena[base+2 .. base+1+ncaps] if the body needed
  -- them; the workload body ignores them, matching the RefEngine closure which
  -- also only touches caps via `local _ = caps`.)
  local body = self.bodies[bi]
  return body()
end

-- trail-based unify. Bindings are recorded on the FFI trail (var index) so an
-- unwind is a pointer reset; the var refs are kept in a reused Lua side array.
function Hybrid:_bind(v, val)
  v.bound = true; v.val = val
  local t = self.trail_top
  self.trailed[t] = v
  self.trail[t] = 1            -- presence marker (keeps the cdata buffer hot)
  self.trail_top = t + 1
end

function Hybrid:_unwind(to)
  local trailed = self.trailed
  for i = self.trail_top - 1, to, -1 do
    local v = trailed[i]; v.bound = false; v.val = nil
    trailed[i] = nil
  end
  self.trail_top = to
end

local function hderef(x)
  while type(x) == "table" and x.var and x.bound do x = x.val end
  return x
end

function Hybrid:unify(a, b, cont)
  a, b = hderef(a), hderef(b)
  if a == b then return cont() and true or false end
  if type(a) == "table" and a.var then
    local mark = self.trail_top
    self:_bind(a, b)
    local r = cont()
    if not r then self:_unwind(mark); return false end
    return true
  elseif type(b) == "table" and b.var then
    local mark = self.trail_top
    self:_bind(b, a)
    local r = cont()
    if not r then self:_unwind(mark); return false end
    return true
  elseif type(a) == "table" and a.cons and type(b) == "table" and b.cons then
    return self:unify(a[1], b[1], function() return self:unify(a[2], b[2], cont) end)
  else
    return false
  end
end

-- ===========================================================================
-- CORRECTNESS GATE: run both engines on the SAME workload and assert the
-- emitted stats (success/fail sequence) are identical. The workload's PRNG is
-- deterministic given the seed, so identical stats == identical decisions ==
-- identical unification results.
-- ===========================================================================
local function deepeq(x, y)
  for k, v in pairs(x) do if y[k] ~= v then return false, k, v, y[k] end end
  for k, v in pairs(y) do if x[k] ~= v then return false, k, x[k], v end end
  return true
end

local function run_gate()
  local p = {inferences = 200000, seed = 0x2545F491}
  local b = Baseline.new()
  local sb = W.run(b, p)
  local h = Hybrid.new()
  local sh = W.run(h, p)
  local ok, k, bv, hv = deepeq(sb, sh)
  return ok, sb, sh, k, bv, hv
end

-- ===========================================================================
-- MEASUREMENT: bytes/inference via GC-stopped heap delta, min-of-5.
-- ===========================================================================
local function measure(engine_new, infs)
  local p = {inferences = infs, seed = 0x2545F491}
  local best_b, best_t = math.huge, math.huge
  for _ = 1, 5 do
    local e = engine_new()
    collectgarbage("collect")
    collectgarbage("stop")
    local m0 = collectgarbage("count")
    local t0 = os.clock()
    local st = W.run(e, p)
    local dt = os.clock() - t0
    local m1 = collectgarbage("count")
    collectgarbage("restart")
    local bytes = (m1 - m0) * 1024
    local binf = bytes / st.inferences
    if binf < best_b then best_b = binf end
    if dt < best_t then best_t = dt end
  end
  return best_b, best_t
end

-- ===========================================================================
-- DRIVER
-- ===========================================================================
local ok, sb, sh, k, bv, hv = run_gate()
io.stderr:write("=== correctness gate ===\n")
if ok then
  io.stderr:write("PASS: hybrid stats == baseline stats\n")
else
  io.stderr:write(string.format("FAIL at key %s: baseline=%s hybrid=%s\n", tostring(k), tostring(bv), tostring(hv)))
end
io.stderr:write(string.format("  baseline stats: infs=%d unifies=%d unify_ok=%d guard_fails=%d conts=%d conts_run=%d newpv=%d reclaimed=%d cuts=%d\n",
  sb.inferences, sb.unifies, sb.unify_ok, sb.guard_fails, sb.conts_made, sb.conts_run, sb.newpv, sb.reclaimed, sb.cuts))

io.stderr:write(string.format("\n=== alloc measurement (scale=%d, min-of-5) ===\n", INFS_SCALE))
local base_binf, base_t = measure(Baseline.new, INFS_SCALE)
local hyb_binf, hyb_t   = measure(Hybrid.new,   INFS_SCALE)
io.stderr:write(string.format("baseline (CPS closure): %.1f B/inf   rough wall %.3fs\n", base_binf, base_t))
io.stderr:write(string.format("hybrid  (FFI arena):    %.1f B/inf   rough wall %.3fs\n", hyb_binf, hyb_t))
io.stderr:write(string.format("delta: %.1f B/inf  (%.1f%% of baseline)\n",
  base_binf - hyb_binf, 100 * hyb_binf / base_binf))

-- machine-readable line for the harness
print(string.format("RESULT correctness=%s baseline_binf=%.2f hybrid_binf=%.2f base_wall=%.3f hyb_wall=%.3f",
  tostring(ok), base_binf, hyb_binf, base_t, hyb_t))
