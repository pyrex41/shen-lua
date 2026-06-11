-- bench/callfreq.lua — THROWAWAY profiler (Track 0.1).
-- Wraps every F-table entry with a call counter, runs the full 41.2 suite,
-- and dumps the most-called functions. Used to find native-override targets.
-- Run from the shen-lua dir:  luajit bench/callfreq.lua 2>/tmp/callfreq.txt
package.path = "./?.lua;" .. package.path
local P = require("boot")
local R = require("runtime")

P.load_kernel(false)   -- includes install_native_prolog at the end
P.initialise()

local ffi = require("ffi")
ffi.cdef[[int chdir(const char *path);]]
assert(ffi.C.chdir("../cl-source/ShenOSKernel-41.2/tests") == 0, "chdir failed")

-- kernel compat seeding (mirror run-kernel-tests.lua)
do
  local macros_fn = P.F["shen.macros"]
  if macros_fn and not P.GLOBALS["*macros*"] then
    local entry = R.cons(R.cons(R.intern("shen.macros"), macros_fn), R.NIL)
    P.GLOBALS["*macros*"] = R.cons(entry, R.NIL)
  end
  if P.GLOBALS["shen.*tc*"] ~= nil and P.GLOBALS["*tc*"] == nil then
    P.GLOBALS["*tc*"] = P.GLOBALS["shen.*tc*"]
  end
end
P.F["y-or-n?"] = function(_msg) return true end
P.FA[P.F["y-or-n?"]] = 1

-- Wrap every function in F with a counter. `return orig(...)` is a proper
-- Lua tail call, so TCO is preserved; copy FA arity so APP still dispatches
-- partial/over-application correctly.
local counts = {}
local F, FA = P.F, P.FA
for name, fn in pairs(F) do
  if type(fn) == "function" then
    counts[name] = 0
    local orig = fn
    local wrapped = function(...) counts[name] = counts[name] + 1; return orig(...) end
    FA[wrapped] = FA[orig]
    F[name] = wrapped
  end
end

local function quiet() end
P.F["load"]("harness.shen")
P.F["load"]("kerneltests.shen")

-- dump sorted
local rows = {}
for name, c in pairs(counts) do if c > 0 then rows[#rows+1] = {name, c} end end
table.sort(rows, function(a,b) return a[2] > b[2] end)
io.stderr:write("\n=== CALL FREQUENCY (41.2 suite) ===\n")
for i = 1, math.min(60, #rows) do
  io.stderr:write(string.format("%3d  %-32s %12d\n", i, rows[i][1], rows[i][2]))
end
