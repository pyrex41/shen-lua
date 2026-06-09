-- bench/wam_poc_v2.lua — Phase 2 PoC engine v2: FULL FFI ARENA (ceiling design).
--
-- Tests the hypothesis that a WAM-style ITERATIVE engine (explicit goal-stack +
-- choice-point stack + trail, NO per-step CPS closures) with working memory in
-- pre-allocated LuaJIT FFI cdata buffers (bump-allocated, pointer-reset on
-- backtrack) drops per-inference allocation toward zero and beats the current
-- CPS-closure shape.
--
-- This file contains BOTH:
--   * Baseline  = the CPS-closure RefEngine from wam_workload.lua (variant a
--     shape: closure continuations, recursive unify, Lua-table values). This is
--     the thing to beat.
--   * ArenaEngine = the FFI-arena WAM engine (this variant). Values are tagged
--     64-bit cdata words in a pre-allocated ffi bump arena; goal / choice-point
--     / trail stacks are cdata arrays; choice-point marks save the bump pointer
--     and stack tops; backtrack restores them (O(1), zero GC). Iterative unify
--     over an explicit goal stack — NO per-step closure.
--
-- It extends trampoline_microbench variant (c) (explicit goal/undo stacks, no
-- per-step closures) into a full mini-engine: unify + conj + disj + cut +
-- backtrack, driven by the SAME synthetic workload (bench/wam_workload.lua) the
-- other Phase-2 variants run.
--
-- GATE: correctness first (same unify success/fail sequence as the baseline on
-- the same workload), THEN alloc bytes/inference (collectgarbage stop + count
-- delta / infs, min-of-5). Rough wall noted (contention-sensitive). Run under
-- `luajit -jv` to observe trace aborts (cdata-in-hot-loop risk).

local ffi = require("ffi")
local bit = require("bit")
local W = dofile((arg and arg[0] and arg[0]:gsub("[^/]*$", "") or "") .. "wam_workload.lua")

-- ===========================================================================
-- Tagged-word value encoding (tag + payload, 64-bit cdata).
-- A value lives in the arena as one int64 cell:
--   high 3 bits = tag, low 61 bits = payload.
-- Tags:
--   TAG_ATOM  : payload = small int (number/symbol id) — atomic leaf
--   TAG_VAR   : payload = var index into the var/binding arena
--   TAG_CONS  : payload = index into the arena of a 2-cell pair (car at p, cdr at p+1)
-- We avoid true NaN-boxing (we never need to store Lua doubles in the cell — the
-- synthetic atoms are small ints); tag+payload is simpler and JIT-friendlier.
-- ===========================================================================
local TAG_ATOM = 0
local TAG_VAR  = 1
local TAG_CONS = 2

local TAGSHIFT = 61
-- payload mask: low 61 bits
local PAYLOAD_MASK = 0x1FFFFFFFFFFFFFFFLL

local function mkword(tag, payload)
  return bit.bor(bit.lshift(ffi.cast("int64_t", tag), TAGSHIFT),
                 bit.band(ffi.cast("int64_t", payload), PAYLOAD_MASK))
end
local function wtag(w) return tonumber(bit.rshift(w, TAGSHIFT)) end
local function wpay(w) return tonumber(bit.band(w, PAYLOAD_MASK)) end

-- ===========================================================================
-- ArenaEngine: the FFI-arena WAM engine.
-- ===========================================================================
local ArenaEngine = {}
ArenaEngine.__index = ArenaEngine

-- arena cell type: 64-bit signed words (hold tagged values; also used as the
-- cons pair backing store and the goal/trail stacks).
local CELLS = 1048576      -- term/cons arena cells (2^20)
local VARS  = 65536        -- max live logic vars (2^16)
local GOALS = 4096         -- goal stack depth (2^12)
local TRAIL = 65536        -- trail depth (2^16)
local CONTCAP = 16384      -- continuation capture arena cells (2^14)

ffi.cdef[[
  typedef struct {
    int64_t *cells;     /* term/cons bump arena (tagged words) */
    int64_t *vbind;     /* per-var binding word (a tagged value) */
    uint8_t *vbound;    /* per-var bound flag */
    int64_t *goalA;     /* goal stack side A */
    int64_t *goalB;     /* goal stack side B */
    int32_t *trail;     /* trail: var indices bound since last mark */
    int64_t *capbuf;    /* continuation-capture bump arena */
    int32_t cell_top;   /* bump pointer into cells */
    int32_t var_top;    /* live var count (LIFO newpv/reclaim) */
    int32_t cap_top;    /* bump pointer into capbuf */
  } arena_t;
]]

function ArenaEngine.new()
  local self = setmetatable({}, ArenaEngine)
  -- keep the cdata arrays anchored so they are not GC'd; the arena_t holds raw
  -- pointers into them.
  self._cells  = ffi.new("int64_t[?]", CELLS)
  self._vbind  = ffi.new("int64_t[?]", VARS)
  self._vbound = ffi.new("uint8_t[?]", VARS)
  self._goalA  = ffi.new("int64_t[?]", GOALS)
  self._goalB  = ffi.new("int64_t[?]", GOALS)
  self._trail  = ffi.new("int32_t[?]", TRAIL)
  self._capbuf = ffi.new("int64_t[?]", CONTCAP)
  local a = ffi.new("arena_t")
  a.cells  = self._cells
  a.vbind  = self._vbind
  a.vbound = self._vbound
  a.goalA  = self._goalA
  a.goalB  = self._goalB
  a.trail  = self._trail
  a.capbuf = self._capbuf
  a.cell_top = 0
  a.var_top  = 0
  a.cap_top  = 0
  self.a = a
  self.locked = false
  -- continuation bodies cannot live in cdata; they are Lua closures created by
  -- the workload. We keep a small reusable Lua array of body refs indexed by a
  -- cap-arena handle; cleared on reset so it does not grow unbounded. This is
  -- NOT per-inference GC alloc (we overwrite slots), it just anchors the body.
  self.cont_bodies = {}
  return self
end

function ArenaEngine:reset()
  local a = self.a
  a.cell_top = 0
  a.var_top  = 0
  a.cap_top  = 0
  self._trail_top = 0
  self.locked = false
  -- vbound is cleared lazily via reclaim/backtrack; on a full reset clear the
  -- live region only (var_top was the high-water before this reset's caller).
  -- Since var_top is now 0 and newpv clears the flag on allocation, nothing to
  -- do here. (cont_bodies slots are overwritten by handle, no clear needed.)
end

-- newpv: allocate a logic var (LIFO). O(1), no GC alloc.
function ArenaEngine:newpv()
  local a = self.a
  local idx = a.var_top
  a.vbound[idx] = 0
  a.var_top = idx + 1
  return mkword(TAG_VAR, idx)
end

-- reclaim n vars (LIFO backtrack). O(1) pointer reset of var_top; also resets
-- the term/cell bump pointer and cap pointer for this inference (arena reset).
function ArenaEngine:reclaim(n)
  local a = self.a
  local nt = a.var_top - n
  if nt < 0 then nt = 0 end
  a.var_top = nt
  -- Backtracking this inference discards its working terms + captured conts:
  -- reset the bump pointers (the WHOLE point of an arena — O(1) reclaim, no GC).
  a.cell_top = 0
  a.cap_top = 0
  self._trail_top = 0
end

function ArenaEngine:cut() self.locked = true end
function ArenaEngine:guard_fail() return false end

-- build a term of `size` cons-cells into the arena; returns a tagged word.
-- Mirrors RefEngine:build_term exactly (same PRNG draws, same shape) so the
-- two engines see identical structure -> identical unify decisions.
function ArenaEngine:build_term(size, depth, rand)
  local a = self.a
  if size == 0 then
    return mkword(TAG_ATOM, math.floor(rand() * 1000))
  end
  -- recursive build matching Ref: build(n) returns a cons {car, cdr} where
  -- car = (n%3==0 ? fresh var : atom n), cdr = build(n-1); leaf at n<=0 is
  -- (rand<0.3 ? fresh var : atom).
  local function build(n)
    if n <= 0 then
      if rand() < 0.3 then return self:newpv()
      else return mkword(TAG_ATOM, math.floor(rand() * 1000)) end
    end
    local car
    if n % 3 == 0 then car = self:newpv() else car = mkword(TAG_ATOM, n) end
    local cdr = build(n - 1)
    -- allocate a 2-cell cons pair in the arena (bump).
    local p = a.cell_top
    if p + 2 >= CELLS then p = 0 end  -- wrap guard (rare no-backtrack inf)
    a.cells[p] = car
    a.cells[p + 1] = cdr
    a.cell_top = p + 2
    return mkword(TAG_CONS, p)
  end
  return build(size)
end

-- make_cont: store the captures in the cap arena (bump cdata) + anchor the body
-- closure by handle. Returns a small integer handle (a Lua number, not a GC
-- object). No per-cont table/closure allocated by the engine.
function ArenaEngine:make_cont(caps, body)
  local a = self.a
  local base = a.cap_top
  local n = #caps
  if base + n >= CONTCAP then base = 0 end  -- wrap guard (rare no-backtrack inf)
  for i = 1, n do
    a.capbuf[base + i - 1] = caps[i]
  end
  a.cap_top = base + n
  -- encode handle as base*1 ; store body keyed by base (LIFO, overwritten).
  self.cont_bodies[base] = body
  return base
end

function ArenaEngine:run_cont(handle)
  local body = self.cont_bodies[handle]
  return body()
end

-- ---- iterative unify over an explicit goal stack (no per-step closure) ----
-- deref a tagged word to its representative (follow var bindings).
local function aderef(a, w)
  while wtag(w) == TAG_VAR do
    local idx = wpay(w)
    if a.vbound[idx] ~= 0 then w = a.vbind[idx] else break end
  end
  return w
end

-- unify(a,b,cont): iterative, occurs-check-free structural unify (matches the
-- RefEngine, which is also occurs-free on this synthetic shape). On success run
-- cont; if cont returns false, unwind the bindings made here (trail) and return
-- false. Uses the explicit goalA/goalB cdata stacks; pushes tail-goal then
-- head-goal for cons (head solved first), exactly like trampoline variant (c).
function ArenaEngine:unify(rootA, rootB, cont)
  local a = self.a
  local gA, gB = a.goalA, a.goalB
  local n = 0
  gA[0] = rootA; gB[0] = rootB; n = 1
  -- trail mark: record where bindings made in THIS unify start, so we can
  -- unwind exactly them on cont-failure.
  local tmark = self._trail_top or 0
  local trail = a.trail
  local tn = tmark
  local ok = true
  while n > 0 do
    n = n - 1
    local x = aderef(a, gA[n])
    local y = aderef(a, gB[n])
    if x == y then
      -- equal (same tag+payload); for vars this means same var -> nothing.
    else
      local tx, ty = wtag(x), wtag(y)
      if tx == TAG_VAR then
        local idx = wpay(x)
        a.vbound[idx] = 1
        a.vbind[idx] = y
        trail[tn] = idx; tn = tn + 1
      elseif ty == TAG_VAR then
        local idx = wpay(y)
        a.vbound[idx] = 1
        a.vbind[idx] = x
        trail[tn] = idx; tn = tn + 1
      elseif tx == TAG_CONS and ty == TAG_CONS then
        local px, py = wpay(x), wpay(y)
        -- push tail goal then head goal
        gA[n] = a.cells[px + 1]; gB[n] = a.cells[py + 1]; n = n + 1
        gA[n] = a.cells[px];     gB[n] = a.cells[py];     n = n + 1
      else
        ok = false
        break
      end
    end
  end
  if ok then
    self._trail_top = tn
    local r = cont()
    if not r then
      -- unwind bindings made in this unify
      for i = tn - 1, tmark, -1 do
        a.vbound[trail[i]] = 0
      end
      self._trail_top = tmark
      return false
    end
    return true
  else
    -- unify failed: unwind any bindings made before the clash
    for i = tn - 1, tmark, -1 do
      a.vbound[trail[i]] = 0
    end
    self._trail_top = tmark
    return false
  end
end

-- ===========================================================================
-- Correctness instrumentation: a tracing wrapper records the success/fail
-- sequence (and unify_ok) of an engine over a run so we can A/B two engines.
-- ===========================================================================
local function traced(engine)
  local trace = {}
  local proxy = setmetatable({}, {__index = engine})
  function proxy:reset() return engine:reset() end
  function proxy:newpv() return engine:newpv() end
  function proxy:reclaim(n) return engine:reclaim(n) end
  function proxy:cut() trace[#trace+1] = "C"; return engine:cut() end
  function proxy:guard_fail() trace[#trace+1] = "G"; return engine:guard_fail() end
  function proxy:build_term(s,d,r) return engine:build_term(s,d,r) end
  function proxy:make_cont(c,b) return engine:make_cont(c,b) end
  function proxy:run_cont(h) trace[#trace+1] = "R"; return engine:run_cont(h) end
  function proxy:unify(a,b,k)
    local ok = engine:unify(a,b,k)
    trace[#trace+1] = ok and "U1" or "U0"
    return ok
  end
  return proxy, trace
end

-- ===========================================================================
-- Driver
-- ===========================================================================
local function fmt(n) return string.format("%.2f", n) end

local function measure_alloc(make_engine, infs)
  -- min-of-5 bytes/inference, GC stopped.
  local best = math.huge
  for trial = 1, 5 do
    collectgarbage("collect")
    local eng = make_engine()
    -- warm one tiny run is unnecessary; we measure the whole run cold each time
    collectgarbage("collect")
    collectgarbage("stop")
    local before = collectgarbage("count")
    local stats = W.run(eng, {inferences = infs, seed = 0x2545F491})
    local after = collectgarbage("count")
    collectgarbage("restart")
    local bytes = (after - before) * 1024
    local binf = bytes / stats.inferences
    if binf < best then best = binf end
  end
  return best
end

local function rough_wall(make_engine, infs)
  local best = math.huge
  for trial = 1, 3 do
    local eng = make_engine()
    collectgarbage("collect")
    local t0 = os.clock()
    W.run(eng, {inferences = infs, seed = 0x2545F491})
    local dt = os.clock() - t0
    if dt < best then best = dt end
  end
  return best
end

local INFS = tonumber(arg and arg[1]) or 2000000

io.write("== wam_poc_v2: FFI-arena WAM engine vs CPS-closure baseline ==\n")
io.write("infs = " .. INFS .. "\n\n")

-- ---- correctness gate: same success/fail (+cut/run) sequence -----------
do
  local CHECK_INFS = 200000
  local refEng, refTrace = traced(W.RefEngine.new())
  local refStats = W.run(refEng, {inferences = CHECK_INFS, seed = 0x2545F491})
  local arEng, arTrace = traced(ArenaEngine.new())
  local arStats = W.run(arEng, {inferences = CHECK_INFS, seed = 0x2545F491})

  local same = (#refTrace == #arTrace)
  local firstdiff = nil
  if same then
    for i = 1, #refTrace do
      if refTrace[i] ~= arTrace[i] then same = false; firstdiff = i; break end
    end
  end
  -- also compare the high-level stats
  local stats_same =
        refStats.inferences == arStats.inferences
    and refStats.clause_tries == arStats.clause_tries
    and refStats.guard_fails == arStats.guard_fails
    and refStats.newpv == arStats.newpv
    and refStats.reclaimed == arStats.reclaimed
    and refStats.cuts == arStats.cuts
    and refStats.conts_made == arStats.conts_made
    and refStats.conts_run == arStats.conts_run
    and refStats.unifies == arStats.unifies
    and refStats.unify_ok == arStats.unify_ok

  io.write("-- correctness gate (" .. CHECK_INFS .. " infs) --\n")
  io.write("  trace len: ref=" .. #refTrace .. " arena=" .. #arTrace .. "\n")
  io.write("  trace identical: " .. tostring(same))
  if firstdiff then io.write(" (first diff at " .. firstdiff .. ": ref=" .. tostring(refTrace[firstdiff]) .. " arena=" .. tostring(arTrace[firstdiff]) .. ")") end
  io.write("\n")
  io.write("  unifies: ref=" .. refStats.unifies .. " arena=" .. arStats.unifies ..
           "  unify_ok: ref=" .. refStats.unify_ok .. " arena=" .. arStats.unify_ok .. "\n")
  io.write("  stats identical: " .. tostring(stats_same) .. "\n")
  io.write("  CORRECTNESS_OK: " .. tostring(same and stats_same) .. "\n\n")
  _G.__CORRECT = same and stats_same
end

-- ---- workload-shape validation (reproduce target ratios) ---------------
do
  local eng = ArenaEngine.new()
  local s = W.run(eng, {inferences = INFS, seed = 0x2545F491})
  io.write("-- workload shape (arena, " .. INFS .. " infs) --\n")
  io.write(string.format("  clause_tries/inf=%s guard_fail=%s newpv/inf=%s reclaim/newpv=%s\n",
    fmt(s.clause_tries/s.inferences), fmt(s.guard_fails/s.clause_tries),
    fmt(s.newpv/s.inferences), fmt(s.reclaimed/s.newpv)))
  io.write(string.format("  cut/inf=%s conts/inf=%s cont_run_ratio=%s\n\n",
    fmt(s.cuts/s.inferences), fmt(s.conts_made/s.inferences), fmt(s.conts_run/s.conts_made)))
end

-- ---- allocation: this variant vs baseline -------------------------------
local base_binf  = measure_alloc(function() return W.RefEngine.new() end, INFS)
local arena_binf = measure_alloc(function() return ArenaEngine.new() end, INFS)

io.write("-- allocation (min-of-5, GC stopped) --\n")
io.write(string.format("  baseline (CPS-closure):  %s B/inf\n", fmt(base_binf)))
io.write(string.format("  arena (FFI WAM):         %s B/inf\n", fmt(arena_binf)))
io.write(string.format("  reduction: %s%%\n\n", fmt(100 * (1 - arena_binf / base_binf))))

-- ---- rough wall (CONTENTION-SENSITIVE; indicative only) -----------------
local base_wall  = rough_wall(function() return W.RefEngine.new() end, INFS)
local arena_wall = rough_wall(function() return ArenaEngine.new() end, INFS)
io.write("-- rough wall (min-of-3, NOISY/contended) --\n")
io.write(string.format("  baseline: %.3fs  arena: %.3fs  (arena %.2fx)\n",
  base_wall, arena_wall, base_wall / arena_wall))

io.write("\nDONE\n")
