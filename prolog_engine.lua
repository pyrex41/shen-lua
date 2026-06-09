-- prolog_engine.lua — native soa32 Prolog / type-inference substrate.
--
-- The execution engine that replaces the compiled-KL CPS Prolog machinery
-- (klambda/prolog.kl runtime + the t-star.kl driver's allocation profile).
-- Design validated by bench/wam_poc_v4.lua ("soa32"):
--
--   * Terms are PLAIN LUA NUMBERS, range-tagged:
--       atom id          v <  VAR_BASE  (2^24)
--       var   VAR_BASE <= v <  CONS_BASE (2^25), idx = v - VAR_BASE
--       cons             v >= CONS_BASE,         pair p = v - CONS_BASE
--     Tag tests are `<` compares; payload extraction is subtraction. There are
--     deliberately NO bit operations and NO 64-bit cdata anywhere — int64
--     tag-packing was measured 2.2x slower (the v2 PoC trap).
--   * Storage is int32_t FFI arrays (cells / vbind / trail / capture buffer),
--     grown by doubling. vbind[idx] == -1 means unbound (terms are >= 0).
--   * Unification is ITERATIVE over explicit goal stacks with a trail;
--     failure unwinds bindings in a batch back to the caller's trail mark.
--   * Continuations are DEFUNCTIONALIZED: an integer handle indexing
--     contFn[h] (a statically-lifted Lua function) + contBase[h] (offset into
--     the int32 capture buffer). No freeze closures. Rare non-int32 captures
--     go to the cold contSpill[h] table.
--   * Choice points live in the LUA STACK FRAME of each predicate function:
--     plain-local marks (trail/var/cont tops) captured at entry, batch-unwound
--     at every alternative-try point. No heap choice-point objects.
--   * Cut is a 1:1 transcription of shen.cut/lock/unlock/unlocked?/fits?
--     (klambda/prolog.kl:80-92) over two scalars lock_open / lock_depth.
--
-- Success propagates as a non-false return value (like the legacy engine —
-- `return` passes the answer term up through the cont chain); failure is the
-- literal `false`.
--
-- This module is loaded by boot.lua unless SHEN_PROLOG_ENGINE=legacy. Until
-- the clause compiler (prolog_compile.lua) and the t-star port
-- (typecheck_native.lua) wire into it, install() is inert.

local ffi = require("ffi")
local R = require("runtime")

local M = {}

-- ---------------------------------------------------------------------------
-- tagging
-- ---------------------------------------------------------------------------
local VAR_BASE  = 16777216        -- 2^24
local CONS_BASE = 33554432        -- 2^25
M.VAR_BASE, M.CONS_BASE = VAR_BASE, CONS_BASE

-- ---------------------------------------------------------------------------
-- arenas (int32 FFI arrays, grow-by-doubling)
-- ---------------------------------------------------------------------------
local function newarr(n) return ffi.new("int32_t[?]", n) end
local function grown(arr, cap, need)
  local nc = cap
  repeat nc = nc * 2 until nc >= need
  local na = newarr(nc)
  ffi.copy(na, arr, cap * 4)
  return na, nc
end

local cells, ccap = newarr(65536), 65536      -- cons pairs: car at p, cdr at p+1
local vbind, vcap = newarr(16384), 16384      -- per-var binding; -1 = unbound
local trail, tcap = newarr(16384), 16384      -- bound var indices
local capbuf, kcap = newarr(16384), 16384     -- continuation captures
local gA, gB, gcap = newarr(4096), newarr(4096), 4096  -- unify goal stacks

local cell_top, var_top, trail_top, cap_top = 0, 0, 0, 0

-- continuation registry (handles are 1-based ints)
local contFn, contBase, contSpill = {}, {}, {}
local ch_top = 0

-- cut lock (transcribed from the legacy lock absvector {unlocked?, depth})
local lock_open, lock_depth = true, 0

-- inference counter (flushed to GLOBALS["shen.*infs*"] by the typecheck port)
local infs = 0

-- ---------------------------------------------------------------------------
-- atom interning
-- ---------------------------------------------------------------------------
local Symbol, Cons, Vmt, NIL = R.Symbol, R.Cons, R.Vmt, R.NIL
local shen_pvar = R.intern("shen.pvar")
local getmt = getmetatable

local atomval = { [0] = NIL, [1] = true, [2] = false }
local atom_top = 2
local symAtom, numAtom, strAtom = {}, {}, {}
local opqAtom = {}              -- opaque objects, identity-interned
local opq_log, opq_top = {}, 0  -- interned-this-query log (epoch-cleared)

local function atom(x)
  if x == NIL then return 0 end
  local t = type(x)
  local id
  if t == "boolean" then
    return x and 1 or 2
  elseif t == "number" then
    id = numAtom[x]
    if id then return id end
    atom_top = atom_top + 1; id = atom_top
    if id >= VAR_BASE then error("prolog_engine: atom table overflow") end
    numAtom[x] = id; atomval[id] = x
    return id
  elseif t == "string" then
    id = strAtom[x]
    if id then return id end
    atom_top = atom_top + 1; id = atom_top
    if id >= VAR_BASE then error("prolog_engine: atom table overflow") end
    strAtom[x] = id; atomval[id] = x
    return id
  elseif getmt(x) == Symbol then
    id = symAtom[x]
    if id then return id end
    atom_top = atom_top + 1; id = atom_top
    if id >= VAR_BASE then error("prolog_engine: atom table overflow") end
    symAtom[x] = id; atomval[id] = x
    return id
  else
    -- opaque value (freshterm absvector, tuple, stream, closure, ...):
    -- identity-interned, released at query end so a long session can't leak.
    id = opqAtom[x]
    if id then return id end
    atom_top = atom_top + 1; id = atom_top
    if id >= VAR_BASE then error("prolog_engine: atom table overflow") end
    opqAtom[x] = id; atomval[id] = x
    opq_top = opq_top + 1; opq_log[opq_top] = x
    return id
  end
end
M.atom = atom

function M.atomval(v) return atomval[v] end

-- ---------------------------------------------------------------------------
-- term construction / inspection
-- ---------------------------------------------------------------------------
local function newvar()
  local idx = var_top
  if idx >= vcap then vbind, vcap = grown(vbind, vcap, idx + 1) end
  vbind[idx] = -1
  var_top = idx + 1
  return VAR_BASE + idx
end
M.newvar = newvar

local function mkcons(carv, cdrv)
  local p = cell_top
  if p + 2 > ccap then cells, ccap = grown(cells, ccap, p + 2) end
  cells[p] = carv
  cells[p + 1] = cdrv
  cell_top = p + 2
  return CONS_BASE + p
end
M.cons = mkcons

function M.car(v) return cells[v - CONS_BASE] end
function M.cdr(v) return cells[v - CONS_BASE + 1] end
function M.is_cons(v) return v >= CONS_BASE end
function M.is_var(v) return v >= VAR_BASE and v < CONS_BASE end
function M.is_atom(v) return v < VAR_BASE end

-- follow bound-var chains; stops at an unbound var or a non-var
local function lazyderef(v)
  while v >= VAR_BASE and v < CONS_BASE do
    local b = vbind[v - VAR_BASE]
    if b >= 0 then v = b else break end
  end
  return v
end
M.lazyderef = lazyderef

-- ---------------------------------------------------------------------------
-- continuations
-- ---------------------------------------------------------------------------
-- Lifted continuation functions are called as fn(base, h): they read their
-- captures at fixed offsets capbuf[base + i] (and cold spills via
-- contSpill[h]). thaw accepts either a handle (number) or a plain Lua
-- function — call sites are monomorphic, so the type() branch is trace-cheap.
local function thawH(h)
  if type(h) == "number" then
    return contFn[h](contBase[h], h)
  end
  return h()
end
M.thawH = thawH

local function ckroom(n)
  if cap_top + n > kcap then capbuf, kcap = grown(capbuf, kcap, cap_top + n) end
end

function M.newcont0(fn)
  local h = ch_top + 1; ch_top = h
  contFn[h] = fn; contBase[h] = cap_top
  return h
end
function M.newcont1(fn, a)
  ckroom(1)
  local b = cap_top; capbuf[b] = a; cap_top = b + 1
  local h = ch_top + 1; ch_top = h
  contFn[h] = fn; contBase[h] = b
  return h
end
function M.newcont2(fn, a, a2)
  ckroom(2)
  local b = cap_top; capbuf[b] = a; capbuf[b+1] = a2; cap_top = b + 2
  local h = ch_top + 1; ch_top = h
  contFn[h] = fn; contBase[h] = b
  return h
end
function M.newcont3(fn, a, a2, a3)
  ckroom(3)
  local b = cap_top; capbuf[b] = a; capbuf[b+1] = a2; capbuf[b+2] = a3
  cap_top = b + 3
  local h = ch_top + 1; ch_top = h
  contFn[h] = fn; contBase[h] = b
  return h
end
function M.newcont4(fn, a, a2, a3, a4)
  ckroom(4)
  local b = cap_top
  capbuf[b] = a; capbuf[b+1] = a2; capbuf[b+2] = a3; capbuf[b+3] = a4
  cap_top = b + 4
  local h = ch_top + 1; ch_top = h
  contFn[h] = fn; contBase[h] = b
  return h
end
function M.newcont5(fn, a, a2, a3, a4, a5)
  ckroom(5)
  local b = cap_top
  capbuf[b] = a; capbuf[b+1] = a2; capbuf[b+2] = a3; capbuf[b+3] = a4
  capbuf[b+4] = a5
  cap_top = b + 5
  local h = ch_top + 1; ch_top = h
  contFn[h] = fn; contBase[h] = b
  return h
end
function M.newcont6(fn, a, a2, a3, a4, a5, a6)
  ckroom(6)
  local b = cap_top
  capbuf[b] = a; capbuf[b+1] = a2; capbuf[b+2] = a3; capbuf[b+3] = a4
  capbuf[b+4] = a5; capbuf[b+5] = a6
  cap_top = b + 6
  local h = ch_top + 1; ch_top = h
  contFn[h] = fn; contBase[h] = b
  return h
end
function M.newcont7(fn, a, a2, a3, a4, a5, a6, a7)
  ckroom(7)
  local b = cap_top
  capbuf[b] = a; capbuf[b+1] = a2; capbuf[b+2] = a3; capbuf[b+3] = a4
  capbuf[b+4] = a5; capbuf[b+5] = a6; capbuf[b+6] = a7
  cap_top = b + 7
  local h = ch_top + 1; ch_top = h
  contFn[h] = fn; contBase[h] = b
  return h
end
function M.newcont8(fn, a, a2, a3, a4, a5, a6, a7, a8)
  ckroom(8)
  local b = cap_top
  capbuf[b] = a; capbuf[b+1] = a2; capbuf[b+2] = a3; capbuf[b+3] = a4
  capbuf[b+4] = a5; capbuf[b+5] = a6; capbuf[b+6] = a7; capbuf[b+7] = a8
  cap_top = b + 8
  local h = ch_top + 1; ch_top = h
  contFn[h] = fn; contBase[h] = b
  return h
end

-- handle with a spill table for non-int32 captures (cold path)
function M.newcont_spill(fn, tbl)
  local h = ch_top + 1; ch_top = h
  contFn[h] = fn; contBase[h] = cap_top; contSpill[h] = tbl
  return h
end
function M.spill(h) return contSpill[h] end

function M.capref(b, i) return capbuf[b + i] end

-- ---------------------------------------------------------------------------
-- marks / backtracking
-- ---------------------------------------------------------------------------
-- A choice point saves five tops: trail, var, cont-handle, capture-buffer,
-- cell. Cell reclaim at a failed alternative is safe: cells built after the
-- mark are only reachable through (a) bindings made after the mark — unwound
-- by the same undo — or (b) Lua locals of frames that are dead on the failure
-- path. Anything that must survive backtracking (findall solutions, returned
-- answers) is materialized OUT to Shen values first.
local function marks()
  return trail_top, var_top, ch_top, cap_top, cell_top
end
M.marks = marks

local function undo(tm, vm, hm, bm, cm)
  for i = trail_top - 1, tm, -1 do
    vbind[trail[i]] = -1
  end
  trail_top = tm
  var_top = vm
  for h = ch_top, hm + 1, -1 do
    contFn[h] = nil; contSpill[h] = nil
  end
  ch_top = hm
  cap_top = bm
  cell_top = cm
end
M.undo = undo

-- ---------------------------------------------------------------------------
-- unification
-- ---------------------------------------------------------------------------
-- occurs(idx, term): does var idx occur in (derefed) term? Iterative walk
-- using the gB stack scratch (safe: only called outside an active unify loop,
-- before any goal-stack use of the same depth region... NOT safe — use its
-- own small stack instead).
local ostk, ocap = newarr(1024), 1024
local function occurs(idx, v)
  local n = 1
  ostk[0] = v
  while n > 0 do
    n = n - 1
    local x = lazyderef(ostk[n])
    if x >= CONS_BASE then
      local p = x - CONS_BASE
      if n + 2 > ocap then ostk, ocap = grown(ostk, ocap, n + 2) end
      ostk[n] = cells[p]; ostk[n + 1] = cells[p + 1]
      n = n + 2
    elseif x >= VAR_BASE then
      if x - VAR_BASE == idx then return true end
    end
  end
  return false
end
M.occurs = occurs

-- core unify loop. oc = occurs-check var bindings (lzy=! vs lzy=).
-- On structural success thaws cont; if the cont fails, bindings made HERE are
-- unwound (batch, to the entry trail mark) — semantically identical to the
-- legacy per-bind! unwind chain. Returns the cont's value, or false.
local function unify_core(rootA, rootB, cont, oc)
  local n = 1
  gA[0] = rootA; gB[0] = rootB
  local tmark = trail_top
  local tn = tmark
  local ok = true
  while n > 0 do
    n = n - 1
    local x = gA[n]
    local y = gB[n]
    -- inline lazyderef
    while x >= VAR_BASE and x < CONS_BASE do
      local b = vbind[x - VAR_BASE]
      if b >= 0 then x = b else break end
    end
    while y >= VAR_BASE and y < CONS_BASE do
      local b = vbind[y - VAR_BASE]
      if b >= 0 then y = b else break end
    end
    if x == y then
      -- identical atom / same var / same cons cell: success at this goal
    elseif x >= VAR_BASE and x < CONS_BASE then
      local idx = x - VAR_BASE
      if oc and y >= CONS_BASE and occurs(idx, y) then ok = false; break end
      vbind[idx] = y
      if tn >= tcap then trail, tcap = grown(trail, tcap, tn + 1) end
      trail[tn] = idx; tn = tn + 1
    elseif y >= VAR_BASE and y < CONS_BASE then
      local idx = y - VAR_BASE
      if oc and x >= CONS_BASE and occurs(idx, x) then ok = false; break end
      vbind[idx] = x
      if tn >= tcap then trail, tcap = grown(trail, tcap, tn + 1) end
      trail[tn] = idx; tn = tn + 1
    elseif x >= CONS_BASE and y >= CONS_BASE then
      local px, py = x - CONS_BASE, y - CONS_BASE
      if n + 2 > gcap then
        local oldcap = gcap
        gA, gcap = grown(gA, oldcap, n + 2)
        gB = (grown(gB, oldcap, n + 2))
      end
      gA[n] = cells[px + 1]; gB[n] = cells[py + 1]; n = n + 1
      gA[n] = cells[px];     gB[n] = cells[py];     n = n + 1
    else
      ok = false
      break
    end
  end
  if ok then
    trail_top = tn
    local r = thawH(cont)
    if r == false then
      for i = tn - 1, tmark, -1 do vbind[trail[i]] = -1 end
      trail_top = tmark
      return false
    end
    return r
  else
    for i = tn - 1, tmark, -1 do vbind[trail[i]] = -1 end
    -- trail_top was never advanced past tmark on the failure path
    return false
  end
end

function M.unify(a, b, cont)    return unify_core(a, b, cont, false) end  -- lzy=
function M.unify_oc(a, b, cont) return unify_core(a, b, cont, true)  end  -- lzy=!

-- shen.bind! equivalent: bind a (known-unbound) var, thaw, unwind on failure.
function M.bind1(varv, val, cont)
  local idx = varv - VAR_BASE
  vbind[idx] = val
  if trail_top >= tcap then trail, tcap = grown(trail, tcap, trail_top + 1) end
  trail[trail_top] = idx
  trail_top = trail_top + 1
  local r = thawH(cont)
  if r == false then
    vbind[idx] = -1
    trail_top = trail_top - 1
    return false
  end
  return r
end

-- ---------------------------------------------------------------------------
-- cut (transcribed from klambda/prolog.kl:80-92)
-- ---------------------------------------------------------------------------
function M.lock_is_open() return lock_open end

-- shen.cut: thaw; on failure with an open lock, lock at depth n.
function M.cut(n, cont)
  local r = thawH(cont)
  if r == false and lock_open then
    lock_open = false
    lock_depth = n
    return false
  end
  return r
end

-- shen.unlock: re-open iff locked at exactly this depth; always "fails"
-- (it is the value of a fully-exhausted clause sequence).
function M.unlock(n)
  if (not lock_open) and lock_depth == n then
    lock_open = true
  end
  return false
end

-- ---------------------------------------------------------------------------
-- inference counter
-- ---------------------------------------------------------------------------
function M.incinfs() infs = infs + 1 end
function M.getinfs() return infs end
function M.setinfs(n) infs = n end

-- ---------------------------------------------------------------------------
-- Shen-value <-> arena-term boundary
-- ---------------------------------------------------------------------------
-- import: deep-convert a Shen value into an arena term. Legacy-format pvar
-- absvectors map to arena vars via `varmap` (keyed by pvar ticket), creating
-- fresh vars on first sight — callers that need to read bindings back out
-- keep the map. Proper-list spines are converted iteratively (no deep
-- recursion); only car nesting recurses.
local function import(x, varmap)
  if getmt(x) == Cons then
    -- walk the spine, then build cells back-to-front
    local spine, sn = {}, 0
    while getmt(x) == Cons do
      sn = sn + 1; spine[sn] = x[1]
      x = x[2]
    end
    local tail = import(x, varmap)
    for i = sn, 1, -1 do
      tail = mkcons(import(spine[i], varmap), tail)
    end
    return tail
  elseif getmt(x) == Vmt and x[2] == shen_pvar then
    local key = x[3]
    local v = varmap and varmap[key]
    if v then return v end
    v = newvar()
    if varmap then varmap[key] = v end
    return v
  else
    return atom(x)
  end
end
M.import = import

-- materialize: deep deref + export an arena term to a Shen value. Unbound
-- vars become legacy-format pvar absvectors {2, shen.pvar, idx} (cached per
-- idx — they are immutable, so sharing across calls is safe), preserving
-- legacy printing / equality / guard behavior.
local pvcache = {}
local function mat_pvar(idx)
  local pv = pvcache[idx]
  if not pv then
    pv = setmetatable({ 2, shen_pvar, idx }, Vmt)
    pvcache[idx] = pv
  end
  return pv
end

local function materialize(v)
  v = lazyderef(v)
  if v < VAR_BASE then
    return atomval[v]
  elseif v < CONS_BASE then
    return mat_pvar(v - VAR_BASE)
  else
    -- iterative over the cdr spine; recursive on cars
    local items, n = {}, 0
    while true do
      v = lazyderef(v)
      if v >= CONS_BASE then
        local p = v - CONS_BASE
        n = n + 1; items[n] = materialize(cells[p])
        v = cells[p + 1]
      else
        break
      end
    end
    local tail
    if v < VAR_BASE then tail = atomval[v] else tail = mat_pvar(v - VAR_BASE) end
    for i = n, 1, -1 do
      tail = R.cons(items[i], tail)
    end
    return tail
  end
end
M.materialize = materialize

-- ---------------------------------------------------------------------------
-- goal builtins (legacy 6-arg goal ABI becomes (args..., n, cont))
-- ---------------------------------------------------------------------------
function M.g_when(test, n, cont)             -- (when Test ...) prolog.kl:179
  if test == true then return thawH(cont) end
  return false
end
function M.g_var(v, n, cont)                 -- (var? X ...)    prolog.kl:187
  local d = lazyderef(v)
  if d >= VAR_BASE and d < CONS_BASE then return thawH(cont) end
  return false
end
function M.g_return(v)                       -- (return V ...)  prolog.kl:177
  return materialize(v)
end
-- is/is!/bind compile straight to M.unify / M.unify_oc / M.bind1.
-- fork / findall / call need the clause compiler's dispatch table and are
-- provided by prolog_compile.lua (Phase 2).

-- ---------------------------------------------------------------------------
-- query lifecycle
-- ---------------------------------------------------------------------------
-- Nested queries run above the current tops and fully unwind before the outer
-- resumes; query_begin/query_end save and restore every piece of engine state
-- a query can touch (including the cut lock and the opaque-intern epoch).
function M.query_begin()
  local q = {
    cell_top, var_top, trail_top, cap_top, ch_top,
    lock_open, lock_depth, opq_top,
  }
  lock_open, lock_depth = true, 0
  return q
end

function M.query_end(q)
  -- unwind trail bindings made during the query
  for i = trail_top - 1, q[3], -1 do
    vbind[trail[i]] = -1
  end
  cell_top, var_top, trail_top, cap_top = q[1], q[2], q[3], q[4]
  for h = ch_top, q[5] + 1, -1 do
    contFn[h] = nil; contSpill[h] = nil
  end
  ch_top = q[5]
  lock_open, lock_depth = q[6], q[7]
  -- release opaque atoms interned during the query
  for i = opq_top, q[8] + 1, -1 do
    local obj = opq_log[i]
    atomval[opqAtom[obj]] = nil
    opqAtom[obj] = nil
    opq_log[i] = nil
  end
  opq_top = q[8]
end

-- full reset (tests / benchmarks only)
function M.reset_all()
  cell_top, var_top, trail_top, cap_top, ch_top = 0, 0, 0, 0, 0
  lock_open, lock_depth = true, 0
  infs = 0
  for h in pairs(contFn) do contFn[h] = nil end
  for h in pairs(contSpill) do contSpill[h] = nil end
end

-- expose tops read-only for tests/diagnostics
function M.tops()
  return cell_top, var_top, trail_top, cap_top, ch_top
end

-- ---------------------------------------------------------------------------
-- predicate dispatch table (filled by prolog_compile.lua / typecheck_native)
-- ---------------------------------------------------------------------------
M.NativePred = {}

-- ---------------------------------------------------------------------------
-- install: wiring into the running kernel. Inert until prolog_compile.lua
-- (Phase 2) and typecheck_native.lua (Phase 3) register their overrides.
-- ---------------------------------------------------------------------------
function M.install(P)
  M.P = P
  for _, mod in ipairs({ "prolog_compile", "typecheck_native" }) do
    local ok, m = pcall(require, mod)
    if ok then
      m.install(P, M)
    elseif not tostring(m):find("module '" .. mod .. "' not found", 1, true) then
      error(m)
    end
  end
end

return M
