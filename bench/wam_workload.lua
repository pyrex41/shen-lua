-- bench/wam_workload.lua — Phase 2 SYNTHETIC WORKLOAD GENERATOR.
--
-- Produces a parameterized set of goals + clauses + unify problems that
-- reproduces the BEHAVIORAL SHAPE of the real shen-lua type-inference engine on
-- the 431,741-inf y-combinator typecheck (bench/typecheck_alloc.lua), as
-- measured by bench/wam_fingerprint.lua + bench/alloc_attrib.lua:
--
--   * goal dispatch tries a list of clauses; the head GUARD fails ~99.8% of the
--     time, BEFORE any binding, so the clause-body continuation is built then
--     discarded (this is the "83% of freeze-thunks never thawed" shape).
--   * ~1.29 newpv per inference, allocated LIFO and 100% reclaimed on backtrack
--     (pvar pooling already makes this alloc-free; the generator models the
--     create/reclaim CHURN so a candidate engine's arena reset is exercised).
--   * a freeze-style continuation per clause body, ~7 captured vars (8-slot),
--     83% never run.
--   * cut at ~3.2% of inferences (locks the choice frame, prunes alternatives).
--   * unified term sizes are BIMODAL: ~60% atomic (size 0), a cluster at ~6
--     cons-cells (~19%), and a long tail to ~90 cells / depth ~57.
--
-- The Phase-2 PoC engines (CPS-closure baseline vs WAM iterative + FFI arena)
-- each implement the `Engine` interface below and are driven by `run(engine,
-- params)`; the headline metric is bytes-allocated / inference (GC stopped),
-- identical protocol to bench/typecheck_alloc.lua.
--
-- This module has NO dependency on the shen runtime; it is a standalone model so
-- the PoC engines can be measured in isolation (CPU + alloc) without kernel load
-- noise. See fidelity_notes in the Phase-1 report for what it does/does NOT
-- capture (critically: NOT the t-star driver's own continuation layer).

local M = {}

-- ===========================================================================
-- Default parameters, calibrated to the measured fingerprint.
-- All ratios are "per inference"; set `inferences` to scale (≈2M like the
-- trampoline microbench, or 431741 to match the real typecheck exactly).
-- ===========================================================================
M.DEFAULTS = {
  inferences        = 2000000,  -- total inference budget (knob; ~2M like spikeB)
  -- dispatch / branching --------------------------------------------------
  clauses_per_goal  = 5.0,      -- avg clauses a goal tries (datatype search shape)
  guard_fail_ratio  = 0.998,    -- P(a tried clause's head guard fails before bind)
  -- choice points / backtrack ---------------------------------------------
  newpv_per_inf     = 1.287,    -- fresh logic vars per inference (LIFO, all reclaimed)
  backtrack_ratio   = 1.00,     -- fraction of newpv reclaimed on backtrack (measured 100%)
  -- continuations ----------------------------------------------------------
  -- A "continuation" here is a CAPTURED freeze-thunk (BIND with >=1 captured
  -- var). Measured: 458,492 thunks / 431,741 inf = 1.062 per inference; of those
  -- 16.8% are thawed (run) at least once, 83.2% are never run (the branch fails
  -- at a guard before the continuation is reached). cont_run_ratio drives the
  -- "thaw the cont" decision so the PoC's continuation-reuse / arena-reset is
  -- exercised on the real run/discard mix.
  conts_per_inf     = 1.062,    -- captured freeze-thunks created per inference
  cont_captures     = 7,        -- captured vars per freeze-thunk (measured avg 7.14)
  cont_run_ratio    = 0.168,    -- fraction of continuations that get thawed (1 - 0.832)
  -- cut --------------------------------------------------------------------
  cut_per_inf       = 0.0321,   -- cut frequency
  -- unification term shape (bimodal; see size buckets below) ---------------
  -- weighted buckets {size, depth, weight}; sampled per goal-unify.
  term_buckets = {
    {size=0,  depth=0,  w=0.599},  -- atomic (symbol/number)
    {size=2,  depth=2,  w=0.064},
    {size=4,  depth=4,  w=0.032},
    {size=6,  depth=6,  w=0.194},  -- the dominant non-atomic cluster
    {size=12, depth=11, w=0.033},
    {size=24, depth=13, w=0.033},
    {size=45, depth=24, w=0.009},
    {size=63, depth=40, w=0.003},
    {size=84, depth=55, w=0.0013}, -- long tail
  },
  occurs_check      = true,     -- t* uses lzy=! (occurs-checked) on the hot path
}

-- ---------------------------------------------------------------------------
-- Deterministic PRNG (xorshift32) so a run is reproducible and parallel-safe.
-- ---------------------------------------------------------------------------
local function rng(seed)
  local s = seed or 0x2545F491
  return function()
    s = bit and bit.bxor(s, bit.lshift(s, 13)) or (s * 1103515245 + 12345)
    if bit then
      s = bit.bxor(s, bit.rshift(s, 17))
      s = bit.bxor(s, bit.lshift(s, 5))
      s = bit.band(s, 0x7FFFFFFF)
    else
      s = s % 0x7FFFFFFF
    end
    return s / 0x7FFFFFFF
  end
end
M.rng = rng

-- ---------------------------------------------------------------------------
-- Build the bucket sampler (alias-free cumulative table) from term_buckets.
-- Returns a fn(rand)->{size,depth}.
-- ---------------------------------------------------------------------------
local function make_bucket_sampler(buckets)
  local cum, tot = {}, 0
  for _, b in ipairs(buckets) do tot = tot + b.w end
  local acc = 0
  for i, b in ipairs(buckets) do
    acc = acc + b.w / tot
    cum[i] = {c = acc, size = b.size, depth = b.depth}
  end
  return function(rand)
    local r = rand()
    for i = 1, #cum do
      if r <= cum[i].c then return cum[i].size, cum[i].depth end
    end
    return cum[#cum].size, cum[#cum].depth
  end
end
M.make_bucket_sampler = make_bucket_sampler

-- ---------------------------------------------------------------------------
-- The synthetic WORKLOAD: a flat program that, when interpreted by an Engine,
-- reproduces the measured per-inference shape. We do NOT pre-materialize 2M
-- goals (that would dwarf the engine's own allocation); instead `run` drives the
-- engine with per-inference decisions drawn from the PRNG against the params.
--
-- An Engine is a table with these methods (the PoC implements both a CPS-closure
-- variant and a WAM/arena variant against this same interface):
--   engine:reset()                       -- start a fresh top-level query
--   engine:newpv() -> var                 -- allocate a logic var (choice point)
--   engine:reclaim(n)                     -- pop n logic vars (backtrack/LIFO)
--   engine:build_term(size, depth, rand)  -- build a term of the given shape
--   engine:make_cont(captures_tbl, body)  -- build a continuation (freeze) capturing N vars
--   engine:run_cont(cont)                  -- thaw/run a continuation
--   engine:unify(a, b, cont)              -- unify; thaw cont on success; returns bool
--   engine:cut()                          -- prune the current choice frame
--   engine:guard_fail()                   -- model a clause-head guard failing (no bind)
-- A minimal reference CPS-closure Engine is provided as M.RefEngine for the
-- correctness gate; the PoC swaps in its own.
-- ---------------------------------------------------------------------------

-- run(engine, params): drive `inferences` inferences of the synthetic shape and
-- return a stats table (so the PoC can assert it reproduced the target ratios).
function M.run(engine, params)
  local p = setmetatable(params or {}, {__index = M.DEFAULTS})
  local rand = rng(p.seed)
  local sample_term = make_bucket_sampler(p.term_buckets)

  local infs = 0
  local stats = {
    inferences = 0, clause_tries = 0, guard_fails = 0,
    newpv = 0, reclaimed = 0, cuts = 0,
    conts_made = 0, conts_run = 0, unifies = 0, unify_ok = 0,
  }

  engine:reset()
  while infs < p.inferences do
    infs = infs + 1
    stats.inferences = infs

    -- (1) choice-point allocation: newpv_per_inf vars, LIFO. Fractional rate
    -- handled by drawing.
    local nv = 0
    do
      local rate = p.newpv_per_inf
      while rate >= 1.0 do nv = nv + 1; rate = rate - 1.0 end
      if rand() < rate then nv = nv + 1 end
    end
    for _ = 1, nv do engine:newpv(); stats.newpv = stats.newpv + 1 end

    -- (2) clause dispatch: try ~clauses_per_goal clauses; each checks its head
    -- guard, ~99.8% failing BEFORE any bind. A guard-pass clause builds the
    -- terms and unifies (thawing its continuation).
    local ntry = 1
    do
      local rate = p.clauses_per_goal
      ntry = math.floor(rate)
      if rand() < (rate - ntry) then ntry = ntry + 1 end
      if ntry < 1 then ntry = 1 end
    end
    local solved = false
    for _ = 1, ntry do
      stats.clause_tries = stats.clause_tries + 1
      if rand() < p.guard_fail_ratio then
        stats.guard_fails = stats.guard_fails + 1
        engine:guard_fail()
      else
        local sa, da = sample_term(rand)
        local sb, db = sample_term(rand)
        local ta = engine:build_term(sa, da, rand)
        local tb = engine:build_term(sb, db, rand)
        stats.unifies = stats.unifies + 1
        local ok = engine:unify(ta, tb, function() return true end)
        if ok then stats.unify_ok = stats.unify_ok + 1; solved = true; break end
      end
    end

    -- (3') continuation churn: the dominant allocation source. Build
    -- conts_per_inf captured freeze-thunks (cont_captures vars each); thaw
    -- cont_run_ratio of them (the rest are discarded unrun -> the 83% shape).
    -- This is what a candidate engine must turn into bump-allocated, arena-reset
    -- frames instead of GC closures/tables.
    do
      local rate = p.conts_per_inf
      local nc = math.floor(rate)
      if rand() < (rate - nc) then nc = nc + 1 end
      for _ = 1, nc do
        local caps = {}
        for c = 1, p.cont_captures do caps[c] = c end
        stats.conts_made = stats.conts_made + 1
        local cont = engine:make_cont(caps, function()
          stats.conts_run = stats.conts_run + 1
          return true
        end)
        if rand() < p.cont_run_ratio then engine:run_cont(cont) end
      end
    end

    -- (4) cut at the measured rate.
    if rand() < p.cut_per_inf then engine:cut(); stats.cuts = stats.cuts + 1 end

    -- (5) backtrack: reclaim this inference's choice points (LIFO). Models the
    -- 100%-reclaim shape (gc on the failing branch).
    if nv > 0 and rand() < p.backtrack_ratio then
      engine:reclaim(nv); stats.reclaimed = stats.reclaimed + nv
    end
    if solved then engine:reset() end
  end
  return stats
end

-- ---------------------------------------------------------------------------
-- M.RefEngine: a minimal CPS-closure reference engine (the BASELINE shape) used
-- for the correctness gate. A logic var is {bound=false, val=nil}; a term is a
-- nested-cons table or an atom; unify is recursive with a closure continuation
-- and trail-unwind on failure, mirroring shen.lzy=/lzy=!.
-- ---------------------------------------------------------------------------
do
  local Ref = {}
  Ref.__index = Ref
  function Ref.new() return setmetatable({trail = {}, tn = 0, vars = {}, vn = 0, locked = false}, Ref) end
  function Ref:reset() self.vn = 0; self.tn = 0; self.locked = false end
  function Ref:newpv()
    self.vn = self.vn + 1
    local v = {var = true, bound = false}
    self.vars[self.vn] = v
    return v
  end
  function Ref:reclaim(n)
    for _ = 1, n do
      local v = self.vars[self.vn]; if v then v.bound = false; v.val = nil end
      self.vn = self.vn - 1
      if self.vn < 0 then self.vn = 0 end
    end
  end
  function Ref:cut() self.locked = true end
  function Ref:guard_fail() return false end
  -- build a right-nested cons term of `size` cells; embed a fresh var every 3rd leaf.
  function Ref:build_term(size, depth, rand)
    if size == 0 then return math.floor(rand() * 1000) end
    local function build(n)
      if n <= 0 then return (rand() < 0.3) and self:newpv() or math.floor(rand() * 1000) end
      return {n % 3 == 0 and self:newpv() or n, build(n - 1), cons = true}
    end
    return build(size)
  end
  function Ref:make_cont(caps, body)
    -- closure capturing the caps table + body (the CPS-closure shape).
    return function() local _ = caps; return body() end
  end
  function Ref:run_cont(cont) return cont() end
  local function deref(x)
    while type(x) == "table" and x.var and x.bound do x = x.val end
    return x
  end
  function Ref:unify(a, b, cont)
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
  M.RefEngine = Ref
end

return M
