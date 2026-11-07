-- seg_pool_spec.lua : what a stack segment's reuse must not change. Needs only
-- runtime.lua, so it also runs on PUC Lua: lua test/seg_pool_spec.lua
package.path = (arg[0]:gsub("test/[^/]*$", "")) .. "?.lua;" .. package.path
local R = require("runtime")
local run = R.seg.run
local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else nfail = nfail + 1; print("FAIL " .. name) end
end
local pack = function(...) return { n = select("#", ...), ... } end

-- a yield through a segment keeps its exact values, each way. PUC 5.1 cannot
-- yield across the pcall a segment runs in, before these branches or after.
if jit then
  local function through(...)
    local args = pack(...)
    local co = coroutine.create(function()
      return "done", run(function()
        return coroutine.yield(unpack(args, 1, args.n))
      end)
    end)
    return pack(coroutine.resume(co))
  end
  local r = through()
  check(r.n == 1 and r[1] == true, "yield of nothing gives nothing, got " .. r.n)
  r = through("a")
  check(r.n == 2 and r[2] == "a", "yield of one value gives one, got " .. r.n)
  r = through("a", "b")
  check(r.n == 3 and r[3] == "b", "yield of two gives two, got " .. r.n)
  r = through("a", nil)
  check(r.n == 3 and r[2] == "a", "a trailing nil that was yielded stays, got " .. r.n)
  r = through(1, 2, 3, 4, 5)
  check(r.n == 6 and r[6] == 5, "yield of five gives five, got " .. r.n)
  local co = coroutine.create(function()
    return run(function() local a, b = coroutine.yield("y"); return a + b end)
  end)
  coroutine.resume(co)
  local ok, v = coroutine.resume(co, 3, 4)
  check(ok and v == 7, "a resume's values reach the yield")
  check(run(function() return 5 end) == 5, "a job after the yields runs on the pool")
end

-- a hook set on a segment is not seen by the next job. On LuaJIT hooks are global,
-- so only PUC Lua can tell.
if not jit then
  run(function() debug.sethook(function() end, "", 100000); return 1 end)
  check(debug.gethook() == nil, "the main thread has no hook after the job")
  local hooked = run(function() return debug.gethook() ~= nil end)
  check(not hooked, "the next job does not inherit a hook")
  local again = run(function() return debug.gethook() ~= nil end)
  check(not again, "nor the one after")
end

print(("seg_pool_spec: %d pass, %d fail"):format(npass, nfail))
os.exit(nfail == 0 and 0 or 1)
