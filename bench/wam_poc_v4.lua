-- bench/wam_poc_v4.lua — re-litigating the FFI verdict from wam_poc_v2.
--
-- v2 (the engine that produced "FFI is 2.2x slower") encoded every value as an
-- int64_t word with tag/payload packed via bit.lshift/band on casted 64-bit
-- cdata. That is a known LuaJIT anti-pattern INDEPENDENT of FFI: 64-bit cdata
-- intermediates box unless sunk, every wtag/wpay does a tonumber conversion,
-- and the hot loop compiled 1 trace vs v1's 98. So v2 may have condemned one
-- bad ENCODING, not FFI memory itself.
--
-- This file holds FOUR engines behind the wam_workload interface so each can be
-- timed serially in its own process (the only valid protocol — in-process A/B
-- was proven contaminated):
--   base    : CPS-closure reference (M.RefEngine shape) — the current shen-lua shape
--   wam     : v1's pure-Lua iterative engine (goal/trail stacks, pooled pvars)
--   arena64 : v2's FFI engine verbatim (int64 tag-packed words) — the condemned one
--   soa32   : NEW fair FFI design — struct-of-arrays: values are PLAIN Lua
--             numbers (range-tagged: atom < VAR_BASE <= var < CONS_BASE <= cons),
--             storage is int32_t FFI arrays. Zero bit ops, zero 64-bit cdata,
--             every read/write is a plain number. If FFI flat memory has value,
--             THIS shape shows it; if soa32 still loses to wam, FFI is dead fair.
--
-- Usage:
--   luajit bench/wam_poc_v4.lua gate            -- correctness traces vs Ref
--   luajit bench/wam_poc_v4.lua run <engine> [infs]  -- serial alloc+wall, one engine
-- Trace health: luajit -jv bench/wam_poc_v4.lua run <e> 2>&1 | grep -c 'TRACE ---'

package.path = (arg[0]:gsub("[^/]*$", "")) .. "?.lua;" .. package.path
local W = require("wam_workload")
local ffi = require("ffi")
local bit = require("bit")

-- ===========================================================================
-- base: CPS-closure baseline (== M.RefEngine; re-exposed under this name)
-- ===========================================================================
local Base = W.RefEngine

-- ===========================================================================
-- wam: v1's pure-Lua iterative engine (copied verbatim from wam_poc_v1.lua)
-- ===========================================================================
local Wam = {}
Wam.__index = Wam
do
  local function deref(x)
    while type(x) == "table" and x.var and x.bound do x = x.val end
    return x
  end
  function Wam.new()
    local self = setmetatable({}, Wam)
    self.pool = {}; self.pn = 0
    self.trail = {}; self.tn = 0
    self.gA = {}; self.gB = {}
    self.cbody = {}; self.ccaps = {}; self.cn = 0
    self.locked = false
    return self
  end
  function Wam:reset() self.pn = 0; self.tn = 0; self.cn = 0; self.locked = false end
  function Wam:newpv()
    self.pn = self.pn + 1
    local v = self.pool[self.pn]
    if v == nil then v = {var = true, bound = false, val = nil}; self.pool[self.pn] = v
    else v.bound = false; v.val = nil end
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
  function Wam:build_term(size, depth, rand)
    if size == 0 then return math.floor(rand() * 1000) end
    local function build(n)
      if n <= 0 then return (rand() < 0.3) and self:newpv() or math.floor(rand() * 1000) end
      return {n % 3 == 0 and self:newpv() or n, build(n - 1), cons = true}
    end
    return build(size)
  end
  function Wam:make_cont(caps, body)
    self.cn = self.cn + 1
    self.cbody[self.cn] = body
    self.ccaps[self.cn] = caps
    return self.cn
  end
  function Wam:run_cont(handle) return self.cbody[handle]() end
  function Wam:unify(a, b, cont_fn)
    local gA, gB = self.gA, self.gB
    local trail = self.trail
    local n = 1
    gA[1] = a; gB[1] = b
    local trail_mark = self.tn
    local ok = true
    while n > 0 do
      local x = gA[n]; local y = gB[n]
      gA[n] = nil; gB[n] = nil; n = n - 1
      x = deref(x); y = deref(y)
      if x == y then
      elseif type(x) == "table" and x.var then
        x.bound = true; x.val = y
        self.tn = self.tn + 1; trail[self.tn] = x
      elseif type(y) == "table" and y.var then
        y.bound = true; y.val = x
        self.tn = self.tn + 1; trail[self.tn] = y
      elseif type(x) == "table" and x.cons and type(y) == "table" and y.cons then
        n = n + 1; gA[n] = x[2]; gB[n] = y[2]
        n = n + 1; gA[n] = x[1]; gB[n] = y[1]
      else
        ok = false; break
      end
    end
    if not ok then
      for i = self.tn, trail_mark + 1, -1 do
        local v = trail[i]; v.bound = false; v.val = nil; trail[i] = nil
      end
      self.tn = trail_mark
      while n > 0 do gA[n] = nil; gB[n] = nil; n = n - 1 end
      return false
    end
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
end

-- ===========================================================================
-- arena64: v2's FFI engine VERBATIM (int64 tag-packed words) — the condemned one
-- ===========================================================================
local TAG_ATOM, TAG_VAR, TAG_CONS = 0, 1, 2
local TAGSHIFT = 61
local PAYLOAD_MASK = 0x1FFFFFFFFFFFFFFFLL
local function mkword(tag, payload)
  return bit.bor(bit.lshift(ffi.cast("int64_t", tag), TAGSHIFT),
                 bit.band(ffi.cast("int64_t", payload), PAYLOAD_MASK))
end
local function wtag(w) return tonumber(bit.rshift(w, TAGSHIFT)) end
local function wpay(w) return tonumber(bit.band(w, PAYLOAD_MASK)) end

local CELLS, VARS, GOALS, TRAIL, CONTCAP = 1048576, 65536, 4096, 65536, 16384

ffi.cdef[[
  typedef struct {
    int64_t *cells; int64_t *vbind; uint8_t *vbound;
    int64_t *goalA; int64_t *goalB; int32_t *trail; int64_t *capbuf;
    int32_t cell_top; int32_t var_top; int32_t cap_top;
  } arena_t;
]]

local Arena64 = {}
Arena64.__index = Arena64
do
  function Arena64.new()
    local self = setmetatable({}, Arena64)
    self._cells  = ffi.new("int64_t[?]", CELLS)
    self._vbind  = ffi.new("int64_t[?]", VARS)
    self._vbound = ffi.new("uint8_t[?]", VARS)
    self._goalA  = ffi.new("int64_t[?]", GOALS)
    self._goalB  = ffi.new("int64_t[?]", GOALS)
    self._trail  = ffi.new("int32_t[?]", TRAIL)
    self._capbuf = ffi.new("int64_t[?]", CONTCAP)
    local a = ffi.new("arena_t")
    a.cells = self._cells; a.vbind = self._vbind; a.vbound = self._vbound
    a.goalA = self._goalA; a.goalB = self._goalB; a.trail = self._trail
    a.capbuf = self._capbuf
    a.cell_top = 0; a.var_top = 0; a.cap_top = 0
    self.a = a
    self.locked = false
    self.cont_bodies = {}
    return self
  end
  function Arena64:reset()
    local a = self.a
    a.cell_top = 0; a.var_top = 0; a.cap_top = 0
    self._trail_top = 0
    self.locked = false
  end
  function Arena64:newpv()
    local a = self.a
    local idx = a.var_top
    a.vbound[idx] = 0
    a.var_top = idx + 1
    return mkword(TAG_VAR, idx)
  end
  function Arena64:reclaim(n)
    local a = self.a
    local nt = a.var_top - n
    if nt < 0 then nt = 0 end
    a.var_top = nt
    a.cell_top = 0; a.cap_top = 0
    self._trail_top = 0
  end
  function Arena64:cut() self.locked = true end
  function Arena64:guard_fail() return false end
  function Arena64:build_term(size, depth, rand)
    local a = self.a
    if size == 0 then return mkword(TAG_ATOM, math.floor(rand() * 1000)) end
    local function build(n)
      if n <= 0 then
        if rand() < 0.3 then return self:newpv()
        else return mkword(TAG_ATOM, math.floor(rand() * 1000)) end
      end
      local car
      if n % 3 == 0 then car = self:newpv() else car = mkword(TAG_ATOM, n) end
      local cdr = build(n - 1)
      local p = a.cell_top
      if p + 2 >= CELLS then p = 0 end
      a.cells[p] = car; a.cells[p + 1] = cdr
      a.cell_top = p + 2
      return mkword(TAG_CONS, p)
    end
    return build(size)
  end
  function Arena64:make_cont(caps, body)
    local a = self.a
    local base = a.cap_top
    local n = #caps
    if base + n >= CONTCAP then base = 0 end
    for i = 1, n do a.capbuf[base + i - 1] = caps[i] end
    a.cap_top = base + n
    self.cont_bodies[base] = body
    return base
  end
  function Arena64:run_cont(handle) return self.cont_bodies[handle]() end
  local function aderef(a, w)
    while wtag(w) == TAG_VAR do
      local idx = wpay(w)
      if a.vbound[idx] ~= 0 then w = a.vbind[idx] else break end
    end
    return w
  end
  function Arena64:unify(rootA, rootB, cont)
    local a = self.a
    local gA, gB = a.goalA, a.goalB
    local n = 0
    gA[0] = rootA; gB[0] = rootB; n = 1
    local tmark = self._trail_top or 0
    local trail = a.trail
    local tn = tmark
    local ok = true
    while n > 0 do
      n = n - 1
      local x = aderef(a, gA[n])
      local y = aderef(a, gB[n])
      if x == y then
      else
        local tx, ty = wtag(x), wtag(y)
        if tx == TAG_VAR then
          local idx = wpay(x)
          a.vbound[idx] = 1; a.vbind[idx] = y
          trail[tn] = idx; tn = tn + 1
        elseif ty == TAG_VAR then
          local idx = wpay(y)
          a.vbound[idx] = 1; a.vbind[idx] = x
          trail[tn] = idx; tn = tn + 1
        elseif tx == TAG_CONS and ty == TAG_CONS then
          local px, py = wpay(x), wpay(y)
          gA[n] = a.cells[px + 1]; gB[n] = a.cells[py + 1]; n = n + 1
          gA[n] = a.cells[px];     gB[n] = a.cells[py];     n = n + 1
        else
          ok = false; break
        end
      end
    end
    if ok then
      self._trail_top = tn
      local r = cont()
      if not r then
        for i = tn - 1, tmark, -1 do a.vbound[trail[i]] = 0 end
        self._trail_top = tmark
        return false
      end
      return true
    else
      for i = tn - 1, tmark, -1 do a.vbound[trail[i]] = 0 end
      self._trail_top = tmark
      return false
    end
  end
end

-- ===========================================================================
-- soa32: the FAIR FFI design. Values are plain Lua numbers, range-tagged:
--   atom : v in [0, VAR_BASE)         (payload = the atom id)
--   var  : v in [VAR_BASE, CONS_BASE) (idx = v - VAR_BASE)
--   cons : v >= CONS_BASE             (pair index p = v - CONS_BASE; car at
--                                      cells[p], cdr at cells[p+1])
-- All values fit in int32; tag tests are plain `<` compares; payload extraction
-- is a plain subtraction. Storage is int32_t FFI arrays (the flat-memory part).
-- vbind[idx] == -1 means unbound (values are always >= 0), so there is no
-- separate bound-flag array and no bit op anywhere.
-- ===========================================================================
local VAR_BASE  = 16777216          -- 2^24
local CONS_BASE = 33554432          -- 2^25; max value ~ CONS_BASE + 2*CELLS < 2^31

local Soa32 = {}
Soa32.__index = Soa32
do
  function Soa32.new()
    local self = setmetatable({}, Soa32)
    self.cells = ffi.new("int32_t[?]", CELLS)
    self.vbind = ffi.new("int32_t[?]", VARS)
    self.gA    = ffi.new("int32_t[?]", GOALS)
    self.gB    = ffi.new("int32_t[?]", GOALS)
    self.trail = ffi.new("int32_t[?]", TRAIL)
    self.capbuf = ffi.new("int32_t[?]", CONTCAP)
    self.cell_top = 0
    self.var_top = 0
    self.cap_top = 0
    self.trail_top = 0
    self.locked = false
    self.cont_bodies = {}
    return self
  end
  function Soa32:reset()
    self.cell_top = 0; self.var_top = 0; self.cap_top = 0; self.trail_top = 0
    self.locked = false
  end
  function Soa32:newpv()
    local idx = self.var_top
    self.vbind[idx] = -1
    self.var_top = idx + 1
    return VAR_BASE + idx
  end
  function Soa32:reclaim(n)
    local nt = self.var_top - n
    if nt < 0 then nt = 0 end
    self.var_top = nt
    self.cell_top = 0; self.cap_top = 0; self.trail_top = 0
  end
  function Soa32:cut() self.locked = true end
  function Soa32:guard_fail() return false end
  function Soa32:build_term(size, depth, rand)
    if size == 0 then return math.floor(rand() * 1000) end
    local cells = self.cells
    local function build(n)
      if n <= 0 then
        if rand() < 0.3 then return self:newpv()
        else return math.floor(rand() * 1000) end
      end
      local car
      if n % 3 == 0 then car = self:newpv() else car = n end
      local cdr = build(n - 1)
      local p = self.cell_top
      if p + 2 >= CELLS then p = 0 end
      cells[p] = car; cells[p + 1] = cdr
      self.cell_top = p + 2
      return CONS_BASE + p
    end
    return build(size)
  end
  function Soa32:make_cont(caps, body)
    local base = self.cap_top
    local n = #caps
    if base + n >= CONTCAP then base = 0 end
    local capbuf = self.capbuf
    for i = 1, n do capbuf[base + i - 1] = caps[i] end
    self.cap_top = base + n
    self.cont_bodies[base] = body
    return base
  end
  function Soa32:run_cont(handle) return self.cont_bodies[handle]() end
  function Soa32:unify(rootA, rootB, cont)
    local cells, vbind = self.cells, self.vbind
    local gA, gB, trail = self.gA, self.gB, self.trail
    local n = 1
    gA[0] = rootA; gB[0] = rootB
    local tmark = self.trail_top
    local tn = tmark
    local ok = true
    while n > 0 do
      n = n - 1
      local x = gA[n]
      local y = gB[n]
      -- inline deref: follow bound vars (plain compares + array reads)
      while x >= VAR_BASE and x < CONS_BASE do
        local b = vbind[x - VAR_BASE]
        if b >= 0 then x = b else break end
      end
      while y >= VAR_BASE and y < CONS_BASE do
        local b = vbind[y - VAR_BASE]
        if b >= 0 then y = b else break end
      end
      if x == y then
      elseif x >= VAR_BASE and x < CONS_BASE then
        local idx = x - VAR_BASE
        vbind[idx] = y
        trail[tn] = idx; tn = tn + 1
      elseif y >= VAR_BASE and y < CONS_BASE then
        local idx = y - VAR_BASE
        vbind[idx] = x
        trail[tn] = idx; tn = tn + 1
      elseif x >= CONS_BASE and y >= CONS_BASE then
        local px, py = x - CONS_BASE, y - CONS_BASE
        gA[n] = cells[px + 1]; gB[n] = cells[py + 1]; n = n + 1
        gA[n] = cells[px];     gB[n] = cells[py];     n = n + 1
      else
        ok = false; break
      end
    end
    if ok then
      self.trail_top = tn
      local r = cont()
      if not r then
        for i = tn - 1, tmark, -1 do vbind[trail[i]] = -1 end
        self.trail_top = tmark
        return false
      end
      return true
    else
      for i = tn - 1, tmark, -1 do vbind[trail[i]] = -1 end
      self.trail_top = tmark
      return false
    end
  end
end

-- ===========================================================================
-- Driver
-- ===========================================================================
local ENGINES = {
  base    = function() return Base.new() end,
  wam     = function() return Wam.new() end,
  arena64 = function() return Arena64.new() end,
  soa32   = function() return Soa32.new() end,
}

-- correctness tracing wrapper (== v2's traced())
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

local mode = arg[1] or "gate"

if mode == "gate" then
  local CHECK_INFS = 200000
  local refEng, refTrace = traced(Base.new())
  local refStats = W.run(refEng, {inferences = CHECK_INFS, seed = 0x2545F491})
  for _, name in ipairs({"wam", "arena64", "soa32"}) do
    local eng, tr = traced(ENGINES[name]())
    local st = W.run(eng, {inferences = CHECK_INFS, seed = 0x2545F491})
    local same = (#refTrace == #tr)
    if same then
      for i = 1, #refTrace do
        if refTrace[i] ~= tr[i] then same = false; break end
      end
    end
    local stats_same = true
    for _, k in ipairs({"inferences","clause_tries","guard_fails","newpv","reclaimed",
                        "cuts","conts_made","conts_run","unifies","unify_ok"}) do
      if refStats[k] ~= st[k] then stats_same = false end
    end
    io.write(string.format("%-8s trace=%s stats=%s unify_ok=%d/%d  CORRECT=%s\n",
      name, tostring(same), tostring(stats_same), st.unify_ok, refStats.unify_ok,
      tostring(same and stats_same)))
  end

elseif mode == "run" then
  local name = assert(arg[2], "usage: run <engine> [infs]")
  local make = assert(ENGINES[name], "unknown engine: " .. name)
  local INFS = tonumber(arg[3]) or 2000000
  local params = {inferences = INFS, seed = 0x2545F491}

  -- alloc: min-of-5, GC stopped
  local best_binf = math.huge
  for _ = 1, 5 do
    local eng = make()
    collectgarbage("collect")
    collectgarbage("stop")
    local m0 = collectgarbage("count")
    local stats = W.run(eng, params)
    local m1 = collectgarbage("count")
    collectgarbage("restart")
    local binf = (m1 - m0) * 1024 / stats.inferences
    if binf < best_binf then best_binf = binf end
  end

  -- wall: warm once, min-of-5
  do local e = make(); W.run(e, params) end
  local best_wall = math.huge
  for _ = 1, 5 do
    local e = make()
    collectgarbage("collect")
    local t0 = os.clock()
    W.run(e, params)
    local dt = os.clock() - t0
    if dt < best_wall then best_wall = dt end
  end

  io.write(string.format("RESULT engine=%s infs=%d binf=%.2f wall=%.3f\n",
    name, INFS, best_binf, best_wall))
else
  io.write("usage: luajit bench/wam_poc_v4.lua gate | run <engine> [infs]\n")
end
