-- Cold compile/load of clause-heavy sources, freeze-cont on vs off.
--   luajit bench/freeze_cont_load.lua
--   SHEN_FREEZE_CONT=off luajit bench/freeze_cont_load.lua
-- Driver (interleaved min-of-N):
--   luajit bench/freeze_cont_load.lua --ab
package.path = "./?.lua;" .. package.path

if arg[1] == "--ab" then
  local n = tonumber(os.getenv("N") or "5")
  local function run(off)
    local env = off and "SHEN_FREEZE_CONT=off " or ""
    local cmd = env
      .. "SHEN_FASL=off SHEN_KERNEL_CACHE=off SHEN_STDLIB_IMAGE=off "
      .. "luajit bench/freeze_cont_load.lua"
    local h = io.popen(cmd, "r")
    local out = h:read("*a") or ""
    h:close()
    return out
  end
  local keys = {}
  local acc = { on = {}, off = {} }
  for i = 1, n do
    -- interleaved
    local a, b = run(false), run(true)
    for _, pair in ipairs({ { "on", a }, { "off", b } }) do
      local tag, out = pair[1], pair[2]
      for line in out:gmatch("[^\n]+") do
        local k, v = line:match("^TIME%s+(%S+)%s+([%d.]+)")
        if k then
          if not acc[tag][k] then
            acc[tag][k] = {}
            if tag == "on" then keys[#keys + 1] = k end
          end
          acc[tag][k][#acc[tag][k] + 1] = tonumber(v)
        end
      end
    end
    io.stderr:write(string.format("  round %d/%d\n", i, n))
  end
  local function minv(t)
    local m = t[1]
    for i = 2, #t do if t[i] < m then m = t[i] end end
    return m
  end
  print(string.format("%-28s  %10s  %10s  %s", "workload", "on", "off (BIND)", "speedup"))
  for _, k in ipairs(keys) do
    local on, off = minv(acc.on[k] or { 0 }), minv(acc.off[k] or { 0 })
    print(string.format("%-28s  %8.4fs  %8.4fs  %5.2fx", k, on, off, off / on))
  end
  return
end

os.setlocale("C")
local P = require("boot")
local R = require("runtime")

local mode = os.getenv("SHEN_FREEZE_CONT") == "off" and "off" or "on"

local function time(k, fn)
  local t0 = os.clock()
  fn()
  local dt = os.clock() - t0
  print(string.format("TIME %s %.6f", k, dt))
  return dt
end

time("kernel_compile", function()
  P.load_kernel(false)
  P.initialise()
end)

P.GLOBALS["*hush*"] = true
P.F["y-or-n?"] = function() return true end
P.FA[P.F["y-or-n?"]] = 1

local files = {
  "tests/yacc.shen",
  "tests/c-minus.shen",
  "tests/interpreter.shen",
  "tests/prologinterp.shen",
  "tests/montague.shen",
  "klambda/macros.kl",
}

-- macros.kl is KL, not Shen; skip load for that. Recompile the defuns as a
-- stand-in for "compile factorised kernel".
local C = require("compiler")
time("recompile_macros_kl", function()
  local src = assert(io.open("klambda/macros.kl")):read("*a")
  for _, f in ipairs(R.read_all(src)) do
    if R.is_cons(f) and R.is_symbol(f[1]) and f[1].name == "defun" then
      P.load_chunk(C.cdefun(f), "macros-re")()
    end
  end
end)

for _, path in ipairs({
  "tests/yacc.shen",
  "tests/c-minus.shen",
  "tests/interpreter.shen",
  "tests/prologinterp.shen",
  "tests/montague.shen",
}) do
  local name = path:match("([^/]+)$")
  time("load_" .. name, function()
    P.F["load"](path)
  end)
end

-- typed load of a fat file (typecheck + compile)
P.F["tc"](R.intern("+"))
time("typed_load_nqueens", function()
  P.F["load"]("tests/n queens.shen")
end)
io.stderr:write("mode=" .. mode .. "\n")
