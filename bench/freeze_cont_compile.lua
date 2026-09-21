-- Deterministic freeze-cont A/B: BIND counts + jit.off compile of kernel .kl.
--   luajit bench/freeze_cont_compile.lua
package.path = "./?.lua;" .. package.path
pcall(function() require("jit").off() end)

local n = tonumber(os.getenv("N") or "4")
local files = {
  "klambda/macros.kl",
  "klambda/core.kl",
  "klambda/reader.kl",
  "klambda/writer.kl",
  "klambda/yacc.kl",
  "klambda/prolog.kl",
  "klambda/sequent.kl",
  "klambda/t-star.kl",
}

local function compile_all()
  -- fresh compiler/runtime each subprocess; here we just re-cdefun
  local R = require("runtime")
  local C = require("compiler")
  require("prims")  -- ARITY for prims
  local nbind, nfail, nfun, bytes = 0, 0, 0, 0
  for _, path in ipairs(files) do
    local src = assert(io.open(path)):read("*a")
    for _, f in ipairs(R.read_all(src)) do
      if R.is_cons(f) and R.is_symbol(f[1]) and f[1].name == "defun" then
        nfun = nfun + 1
        local s = C.cdefun(f)
        bytes = bytes + #s
        for _ in s:gmatch("BIND%(") do nbind = nbind + 1 end
        for _ in s:gmatch("goto fail") do nfail = nfail + 1 end
      end
    end
  end
  return nfun, nbind, nfail, bytes
end

if arg[1] ~= "--worker" then
  local function worker(off)
    local env = off and "SHEN_FREEZE_CONT=off " or ""
    local h = io.popen(env .. "luajit bench/freeze_cont_compile.lua --worker", "r")
    local out = h:read("*a") or ""
    h:close()
    local t, nfun, nbind, nfail, bytes =
      out:match("TIME ([%d.]+) FUN (%d+) BIND (%d+) GOTO (%d+) BYTES (%d+)")
    return tonumber(t), tonumber(nfun), tonumber(nbind), tonumber(nfail), tonumber(bytes)
  end
  local on_t, off_t = {}, {}
  local nfun, nbind_on, nbind_off, ngoto, bytes_on, bytes_off
  for i = 1, n do
    local t1, f, b1, g, by1 = worker(false)
    local t0, _, b0, _, by0 = worker(true)
    on_t[#on_t+1] = t1; off_t[#off_t+1] = t0
    nfun, nbind_on, nbind_off, ngoto = f, b1, b0, g
    bytes_on, bytes_off = by1, by0
    io.stderr:write(string.format("  round %d/%d  on=%.4f off=%.4f\n", i, n, t1, t0))
  end
  local function minv(t)
    local m = t[1]
    for i = 2, #t do if t[i] < m then m = t[i] end end
    return m
  end
  print("jit.off compile of macros+core+reader+writer+yacc+prolog+sequent+t-star")
  print(string.format("  defuns          %d", nfun))
  print(string.format("  BIND            on %d  off %d  (%.2fx fewer)",
    nbind_on, nbind_off, nbind_off / math.max(nbind_on, 1)))
  print(string.format("  goto fail       on %d  off 0", ngoto))
  print(string.format("  codegen bytes   on %d  off %d  (%+.1f%%)",
    bytes_on, bytes_off, 100 * (bytes_on - bytes_off) / bytes_off))
  print(string.format("  compile min     on %.4fs  off %.4fs  (%.2fx)",
    minv(on_t), minv(off_t), minv(off_t) / minv(on_t)))
  return
end

local t0 = os.clock()
local nfun, nbind, nfail, bytes = compile_all()
local dt = os.clock() - t0
print(string.format("TIME %.6f FUN %d BIND %d GOTO %d BYTES %d",
  dt, nfun, nbind, nfail, bytes))
