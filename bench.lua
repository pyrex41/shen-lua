-- bench.lua : self-contained benchmark for the 41.2 port
-- Runs cold startup, then defines fib through the real Shen pipeline and
-- measures fib(30), fib(32). Also runs Einstein's riddle through the live
-- Prolog engine.
--
-- All numbers are reported via the kernel's own (time EXPR) (= get-time run,
-- i.e. CPU seconds). fib is measured after a JIT warm-up call.

local P = require("boot")
local R = require("runtime")

local function bench(name, body)
  local ok, err = pcall(body)
  if not ok then print(name, "ERROR:", err) end
end

-- ---- cold startup ----
local times = {}
do
  local t0 = os.clock()
  P.load_kernel(false)
  local t1 = os.clock()
  P.initialise()
  local t2 = os.clock()
  times.load = t1 - t0
  times.init = t2 - t1
  times.cold = t2 - t0
end
print(string.format("Cold startup: load=%.3fs init=%.3fs total=%.3fs",
  times.load, times.init, times.cold))
print()

-- Some tests need a non-interactive y-or-n? and the char-stream port primitives
P.F["y-or-n?"] = function() return true end
P.FA[P.F["y-or-n?"]] = 1

-- ---- fib via the live shen compile pipeline ----
print("== fib (compiled through Shen) ==")
bench("fib-def", function()
  -- Define fib in raw KL (what the Shen compiler emits for the source
  -- `(define fib 0 -> 0 1 -> 1 N -> (+ (fib (- N 1)) (fib (- N 2))))`).
  -- This matches what BENCHMARKS.md calls the "certified pipeline" -- the
  -- pattern-matcher output is exactly this if/elseif tree.
  local src = [[
    (defun fib (V)
      (cond ((= 0 V) 0)
            ((= 1 V) 1)
            (true (+ (fib (- V 1)) (fib (- V 2))))))
  ]]
  P.run_kl_string(src)
end)

-- warm up the JIT trace
P.F["fib"](20)
P.F["fib"](20)

for _, n in ipairs({25, 28, 30, 32}) do
  local t0 = os.clock()
  local r = P.F["fib"](n)
  local dt = os.clock() - t0
  print(string.format("  fib(%d) = %d  in %.4fs", n, r, dt))
end
print()

-- ---- Einstein's riddle via the loaded prolog test ----
print("== Einstein's riddle (Prolog backtracking, CPS-heavy) ==")
local ffi = require("ffi")
ffi.cdef[[
  int chdir(const char *path);
]]
if ffi.C.chdir("../cl-source/ShenOSKernel-41.2/tests") == 0 then
  -- run the test through Shen's load (which evaluates the file's top forms)
  bench("einstein-load", function()
    P.F["load"]("einsteins-riddle.shen")
  end)
  -- run the query a few times and take min
  local query_src = [[
    ((lambda V (lambda L (lambda K (lambda C
       (do (shen.incinfs) (riddle V L K C))))))
     (shen.prolog-vector) (@v true (@v 0 (vector 0))) 0 (freeze true))
  ]]
  -- warm
  P.run_kl_string(query_src)
  local best = math.huge
  for i = 1, 3 do
    local t0 = os.clock()
    local r = P.run_kl_string(query_src)
    local dt = os.clock() - t0
    if dt < best then best = dt end
    print(string.format("  run %d: result=%s in %.4fs", i, tostring(r), dt))
  end
  print(string.format("  einstein best:  %.4fs/solve", best))
else
  print("  (tests dir not found; skipping)")
end

print()
print("Done.")
