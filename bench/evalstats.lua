-- bench/evalstats.lua : measure runtime recompilation over the 41.2 suite.
-- Counts P.eval calls, compile_top/compile_expr_chunk invocations, duplicate
-- form identities and duplicate generated sources, and total time inside eval.
-- Run from the repo root: luajit bench/evalstats.lua
local P = require("boot")
local C = require("compiler")

local phase = "kernel-load"
local st = {
  evals = 0, eval_time = 0,
  top = 0, expr = 0,
  top_src, expr_src,
  id_seen = {}, id_dup = 0,
  src_seen = {}, src_dup = 0, src_dup_bytes = 0, src_bytes = 0,
}

local orig_top = C.compile_top
function C.compile_top(form)
  local src = orig_top(form)
  if phase == "suite" then
    st.top = st.top + 1
    st.src_bytes = st.src_bytes + #src
    if st.src_seen[src] then
      st.src_dup = st.src_dup + 1
      st.src_dup_bytes = st.src_dup_bytes + #src
    else st.src_seen[src] = true end
  end
  return src
end

local orig_expr = C.compile_expr_chunk
function C.compile_expr_chunk(form)
  local src = orig_expr(form)
  if phase == "suite" then
    st.expr = st.expr + 1
    st.src_bytes = st.src_bytes + #src
    if st.src_seen[src] then
      st.src_dup = st.src_dup + 1
      st.src_dup_bytes = st.src_dup_bytes + #src
    else st.src_seen[src] = true end
  end
  return src
end

local orig_eval = P.eval
function P.eval(form)
  if phase == "suite" then
    st.evals = st.evals + 1
    if type(form) == "table" then
      if st.id_seen[form] then st.id_dup = st.id_dup + 1
      else st.id_seen[form] = true end
    end
    local t0 = os.clock()
    local r = orig_eval(form)
    st.eval_time = st.eval_time + (os.clock() - t0)
    return r
  end
  return orig_eval(form)
end

-- run the suite; flip phase once the kernel is loaded by hooking initialise
local orig_init = P.initialise
P.initialise = function(...)
  local r = orig_init(...)
  phase = "suite"
  return r
end

local t0 = os.clock()
dofile("run-kernel-tests.lua")
local total = os.clock() - t0

local distinct_src = (st.top + st.expr) - st.src_dup
io.stderr:write(string.format([[

==== evalstats ====
suite wall (incl. kernel load): %.2fs
eval calls (suite phase):       %d   (defun+expr compiles: %d top, %d expr)
time inside eval:               %.2fs (%.1f%% of wall)
duplicate form identities:      %d
generated sources: %d total, %d distinct, %d duplicates (%.1f%% of compiles)
duplicate source bytes:         %d of %d (%.1f%%)
]], total, st.evals, st.top, st.expr, st.eval_time, 100*st.eval_time/total,
    st.id_dup, st.top + st.expr, distinct_src, st.src_dup,
    100*st.src_dup/math.max(1, st.top+st.expr),
    st.src_dup_bytes, st.src_bytes, 100*st.src_dup_bytes/math.max(1,st.src_bytes)))
