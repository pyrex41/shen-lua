-- A/B: list builders with and without tail recursion modulo cons (TRMC, #58),
-- and higher-order (kernel map over a lambda) vs explicit recursion (#66).
-- Each builder is compiled twice from the same KL, once with C.TRMC on and
-- once off, then called DIRECTLY from Lua (no Shen-level harness: a toplevel
-- Shen lambda applies its callee through a curried APP chain that costs more
-- than the short builders being measured). Interleaved, min-of-N.
--
--   luajit bench/list_builders_ab.lua [rounds]
--
-- Short lists (8, 32) are in the table on purpose: they are where an earlier
-- loop-lowering relaxation regressed (doc/PERF-URDR-RESULTS.md).

package.path = "./?.lua;" .. package.path
local P = require("boot")
local R = require("runtime")
local C = require("compiler")
P.load_kernel(false)
P.initialise()

local F, NIL = P.F, R.NIL
local ROUNDS = tonumber(arg and arg[1]) or 7

local function ev(s)
  local r
  for _, f in ipairs(R.read_all(s)) do r = P.eval(f) end
  return r
end

local function nlist(n, f)
  local acc = NIL
  for i = n, 1, -1 do acc = R.cons(f and f(i) or i, acc) end
  return acc
end

-- NAME is substituted with the variant's function name.
local SHAPES = {
  { "inc",     "(defun NAME (L) (if (cons? L) (cons (+ 1 (hd L)) (NAME (tl L))) ()))" },
  { "take",    "(defun NAME (N L) (if (and (> N 0) (cons? L)) (cons (hd L) (NAME (- N 1) (tl L))) ()))" },
  { "set-nth", "(defun NAME (N V L) (if (= N 1) (cons V (tl L)) (cons (hd L) (NAME (- N 1) V (tl L)))))" },
  { "evens",   "(defun NAME (L) (cond ((= L ()) ()) ((= 0 (shen.mod (hd L) 2)) (cons (hd L) (NAME (tl L)))) (true (NAME (tl L)))))" },
  { "xor",     "(defun NAME (A B) (if (cons? A) (cons (if (= (hd A) (hd B)) 0 1) (NAME (tl A) (tl B))) ()))" },
}

local saved = C.TRMC
local fns = {}
for _, sh in ipairs(SHAPES) do
  for _, on in ipairs({ true, false }) do
    C.TRMC = on
    local name = "bench-" .. sh[1] .. (on and "-trmc" or "-rec")
    ev((sh[2]:gsub("NAME", name)))
    fns[name] = F[name]
  end
end
C.TRMC = saved
local map = F["map"]
local inc1 = P.eval(R.read_all("(lambda X (+ X 1))")[1])

-- { label, iterations, function(variant) -> thunk }
local CASES = {}
for _, n in ipairs({ 8, 32, 1000 }) do
  local l = nlist(n)
  local bits = nlist(n, function(i) return i % 3 == 0 and 1 or 0 end)
  local iters = n == 1000 and 2000 or 200000
  local function add(label, mk) CASES[#CASES + 1] = { label .. " n=" .. n, iters, mk } end
  add("inc (explicit rec)", function(v) local f = fns["bench-inc-" .. v]; return function() return f(l) end end)
  add("take n", function(v) local f = fns["bench-take-" .. v]; return function() return f(n, l) end end)
  add("set-nth last", function(v) local f = fns["bench-set-nth-" .. v]; return function() return f(n, 0, l) end end)
  add("evens", function(v) local f = fns["bench-evens-" .. v]; return function() return f(l) end end)
  add("xor bits", function(v) local f = fns["bench-xor-" .. v]; return function() return f(bits, bits) end end)
  add("inc via (map lambda)", function() return function() return map(inc1, l) end end)
end

local function time(thunk, iters)
  local t0 = os.clock()
  for _ = 1, iters do thunk() end
  return (os.clock() - t0) / iters * 1e9
end

local best = {}
for _ = 1, ROUNDS do
  for i, c in ipairs(CASES) do
    for _, v in ipairs({ "trmc", "rec" }) do
      local ns = time(c[3](v), c[2])
      local k = i .. v
      if not best[k] or ns < best[k] then best[k] = ns end
    end
  end
end

print(string.format("%-28s %12s %12s %7s", "case (ns/call, min of " .. ROUNDS .. ")", "TRMC", "recursive", "ratio"))
for i, c in ipairs(CASES) do
  local a, b = best[i .. "trmc"], best[i .. "rec"]
  print(string.format("%-28s %12.1f %12.1f %7.2f", c[1], a, b, a / b))
end
