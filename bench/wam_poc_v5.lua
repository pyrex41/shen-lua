-- bench/wam_poc_v5.lua — Phase-1 gate: the PRODUCTION substrate
-- (prolog_engine.lua) driven through the same synthetic workload that
-- validated the soa32 PoC (bench/wam_poc_v4.lua). Confirms productionizing
-- (growth checks, cont handles, trail marks, query plumbing) kept the PoC's
-- properties: byte-identical correctness traces vs the CPS reference,
-- engine-intrinsic alloc ~0, and the wall-time advantage.
--
--   luajit bench/wam_poc_v5.lua gate              -- correctness vs RefEngine
--   luajit bench/wam_poc_v5.lua run <base|sub> [infs]   -- serial alloc+wall
-- Trace health: luajit -jv bench/wam_poc_v5.lua run sub 2>&1 | grep -c 'TRACE ---'

package.path = (arg[0]:gsub("[^/]*$", "")) .. "?.lua;"
            .. (arg[0]:gsub("bench/[^/]*$", "")) .. "?.lua;" .. package.path
local W = require("wam_workload")
local E = require("prolog_engine")

-- ---------------------------------------------------------------------------
-- adapter: prolog_engine -> wam_workload Engine interface
-- ---------------------------------------------------------------------------
local Sub = {}
Sub.__index = Sub

function Sub.new()
  E.reset_all()
  return setmetatable({}, Sub)
end

function Sub:reset() E.reset_all() end

function Sub:newpv() return E.newvar() end

function Sub:reclaim(n)
  -- mirror v4 soa32 reclaim semantics: pop n vars, discard this inference's
  -- terms / continuations / trail (the workload's per-inference arena reset)
  local _, vt = E.tops()
  local nv = vt - n
  if nv < 0 then nv = 0 end
  E.undo(0, nv, 0, 0, 0)
end

function Sub:cut() self.locked = true end
function Sub:guard_fail() return false end

-- identical structure + PRNG draw order to v4's Soa32:build_term, so the two
-- engines see the same terms -> identical unify decisions. Atoms are raw ids
-- < 1000 (never materialized, so the reserved-id overlap is irrelevant).
function Sub:build_term(size, depth, rand)
  if size == 0 then return math.floor(rand() * 1000) end
  local function build(n)
    if n <= 0 then
      if rand() < 0.3 then return E.newvar()
      else return math.floor(rand() * 1000) end
    end
    local car
    if n % 3 == 0 then car = E.newvar() else car = n end
    return E.cons(car, build(n - 1))
  end
  return build(size)
end

function Sub:make_cont(caps, body)
  -- body is called as a lifted cont fn (base, h) and ignores both
  return E.newcont7(body, caps[1], caps[2], caps[3], caps[4],
                          caps[5], caps[6], caps[7])
end

function Sub:run_cont(h) return E.thawH(h) end

function Sub:unify(a, b, cont)
  local r = E.unify(a, b, cont)
  return r ~= false
end

-- ---------------------------------------------------------------------------
-- driver (same protocol as v4)
-- ---------------------------------------------------------------------------
local ENGINES = {
  base = function() return W.RefEngine.new() end,
  sub  = function() return Sub.new() end,
}

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
  local refEng, refTrace = traced(W.RefEngine.new())
  local refStats = W.run(refEng, {inferences = CHECK_INFS, seed = 0x2545F491})
  local eng, tr = traced(Sub.new())
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
  io.write(string.format("sub      trace=%s stats=%s unify_ok=%d/%d  CORRECT=%s\n",
    tostring(same), tostring(stats_same), st.unify_ok, refStats.unify_ok,
    tostring(same and stats_same)))
  os.exit((same and stats_same) and 0 or 1)

elseif mode == "run" then
  local name = assert(arg[2], "usage: run <base|sub> [infs]")
  local make = assert(ENGINES[name], "unknown engine: " .. name)
  local INFS = tonumber(arg[3]) or 2000000
  local params = {inferences = INFS, seed = 0x2545F491}

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
  io.write("usage: luajit bench/wam_poc_v5.lua gate | run <base|sub> [infs]\n")
end
