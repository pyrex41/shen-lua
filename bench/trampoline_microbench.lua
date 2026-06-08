-- spikeB.lua : Does trampolining help or hurt LuaJIT on a Prolog-flavored
-- recursive CPS workload? Models shen.lzy=-style unification of nested cons
-- structures with logic variables + a success continuation, three ways:
--   (a) CPS with real Lua tail calls + closure continuations  (current shen-lua shape)
--   (b) Trampoline: each tail step returns a bounce thunk; a while-loop drives it
--   (c) Trampoline with explicit frame objects (no per-step closure; shen-go shape)
-- Each increments a global inference counter (like shen.incinfs) and mutates a
-- binding vector (like the prolog vector), with backtrack-unwind on failure.

local floor = math.floor

-- ---- shared data: build a deep nested cons structure with embedded vars -----
-- node: {1=head,2=tail, cons=true}  | var: {var=true, id=N} | atom: number
local function cons(h,t) return {h,t,cons=true} end
local function mkvar(id) return {var=true, id=id} end

-- build a right-nested list of `depth` cells; every K-th leaf is a fresh var
local function build(depth, withvars, idbase)
  local acc = 0
  local nextid = idbase
  for i=depth,1,-1 do
    local leaf
    if withvars and (i % 3 == 0) then leaf = mkvar(nextid); nextid = nextid + 1
    else leaf = i end
    acc = cons(leaf, acc)
  end
  return acc, nextid
end

local INF_TARGET = 2000000   -- ~2M inferences, matches typechecker scale

-- =============================================================================
-- (a) CPS with tail calls + closure continuations  (current shen-lua shape)
-- =============================================================================
local function run_cps()
  local infs = 0
  local vec = {}
  local unify
  unify = function(a, b, k)        -- k : 0-arg success continuation (thunk)
    infs = infs + 1
    if a == b then
      return k()
    elseif type(a) == "table" and a.var then
      local id = a.id; vec[id] = b
      local r = k()
      if r == false then vec[id] = nil end   -- unwind
      return r
    elseif type(a) == "table" and a.cons and type(b) == "table" and b.cons then
      -- unify heads, then (freeze (unify tails k))  -- closure continuation
      return unify(a[1], b[1], function() return unify(a[2], b[2], k) end)
    else
      return false
    end
  end
  local A = build(60, true, 0)
  local B = build(60, false, 0)
  local done = function() return true end
  while infs < INF_TARGET do
    unify(A, B, done)
  end
  return infs
end

-- =============================================================================
-- (b) Trampoline: tail steps return a bounce thunk; central loop drives.
--     Continuations are still closures (capture a,b,k).
-- =============================================================================
local function run_tramp_thunk()
  local infs = 0
  local vec = {}
  local unify
  -- returns either false/true (final) OR a thunk to bounce
  unify = function(a, b, k)
    infs = infs + 1
    if a == b then
      return k                                  -- bounce: run continuation
    elseif type(a) == "table" and a.var then
      local id = a.id; vec[id] = b
      return function()                         -- bounce that also unwinds on fail
        local r = k()
        if r == false then vec[id] = nil end
        return r
      end
    elseif type(a) == "table" and a.cons and type(b) == "table" and b.cons then
      return function() return unify(a[1], b[1], function() return unify(a[2], b[2], k) end) end
    else
      return false
    end
  end
  local A = build(60, true, 0)
  local B = build(60, false, 0)
  local done = function() return true end
  while infs < INF_TARGET do
    local r = unify(A, B, done)
    while type(r) == "function" do r = r() end   -- the trampoline loop
  end
  return infs
end

-- =============================================================================
-- (c) Trampoline with explicit frame objects + an explicit work stack.
--     No per-step closure alloc; frames are {kind,a,b,...}. shen-go shape.
-- =============================================================================
local function run_tramp_frames()
  local infs = 0
  local vec = {}
  -- A frame is a goal to solve: {a=, b=, next=frame|nil}
  -- We model the success-continuation chain as a linked list of frames.
  -- Solve walks frames in a loop; cons unification pushes the tail-goal frame.
  local function solve(rootA, rootB)
    -- work stack of pending goals (success chain), plus a parallel undo stack
    local goalsA, goalsB, n = {rootA}, {rootB}, 1
    local undo, un = {}, 0
    while n > 0 do
      infs = infs + 1
      local a, b = goalsA[n], goalsB[n]
      goalsA[n], goalsB[n] = nil, nil; n = n - 1
      if a == b then
        -- success, continue
      elseif type(a) == "table" and a.var then
        vec[a.id] = b; un = un + 1; undo[un] = a.id
      elseif type(a) == "table" and a.cons and type(b) == "table" and b.cons then
        -- push tail goal then head goal (head solved first)
        n = n + 1; goalsA[n] = a[2]; goalsB[n] = b[2]
        n = n + 1; goalsA[n] = a[1]; goalsB[n] = b[1]
      else
        for i=un,1,-1 do vec[undo[i]] = nil end   -- unwind
        return false
      end
    end
    return true
  end
  local A = build(60, true, 0)
  local B = build(60, false, 0)
  while infs < INF_TARGET do
    solve(A, B)
  end
  return infs
end

-- ---- driver -----------------------------------------------------------------
local which = arg[1] or "all"
local function timeit(name, fn)
  -- warm
  fn()
  local best = 1e9
  for i=1,3 do
    local t0 = os.clock()
    local infs = fn()
    local dt = os.clock() - t0
    if dt < best then best = dt end
  end
  io.write(string.format("%-16s %.3fs  (%.0fk inf/s)\n", name, best, INF_TARGET/best/1000))
end

if which == "a" or which == "all" then timeit("cps-tailcall", run_cps) end
if which == "b" or which == "all" then timeit("tramp-thunk", run_tramp_thunk) end
if which == "c" or which == "all" then timeit("tramp-frames", run_tramp_frames) end
