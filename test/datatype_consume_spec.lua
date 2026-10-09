-- datatype_consume_spec.lua — sequent rules with many premises.
--
--   luajit test/datatype_consume_spec.lua
--
-- A datatype rule whose conclusion context has six or more premises over
-- another user type used to die, once that rule was entered, with
-- "shen.consume<N> is undefined". Five premises worked.
--
-- shen.specialise-consume gensyms a helper per premise. The native Prolog
-- translator closure-converts that helper's continuation, and the capture
-- count is two locals per premise variable plus the assumption and engine
-- temps (2*N+5). Five premises capture 15 values and fit NEWCONT0..16.
-- Six premises capture 17. mkhandle refused past 16, so NativePred[name]
-- stayed nil and the already-translated caller invoked a missing field.
--
-- Entering the rule does not require the query to use it: after the datatype
-- is loaded, any typecheck that walks *datatypes* and reaches the predicate
-- (here, "2 : piece", which fails the earlier piece rule) calls it. A
-- matching hypothesis must still succeed, and a miss must still fail.

local shen = require("shen")
shen.boot{ quiet = true }
local R = require("runtime")
local P = shen.prims
local E = require("prolog_engine")

local pass, fail = 0, 0
local function check(desc, got, want)
  if got == want then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL %s: got %s want %s", desc, tostring(got), tostring(want)))
  end
end

local function errmsg(err)
  if type(err) == "string" then return P.translate_error(err) end
  if type(err) ~= "table" then return P.translate_error(tostring(err)) end
  local parts = {}
  for k, v in pairs(err) do
    parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
  end
  return table.concat(parts, " | ")
end

-- Kernel shen.typecheck, not the embedding helper: the helper turns every
-- error into false, which would hide "shen.consumeN is undefined".
local function typecheck(expr, ty)
  P.GLOBALS["shen.*infs*"] = 0
  local forms = P.F["read-from-string"](expr .. " : " .. ty)
  local ok, res = pcall(P.F["shen.typecheck"], forms[1], forms[2][2][1])
  if not ok then return nil, errmsg(res) end
  return res
end

local CONS = R.intern("cons")
local COLON = R.intern(":")
local PIECE = R.intern("piece")

local function cons_form(a, b)
  return R.cons(CONS, R.cons(a, R.cons(b, R.NIL)))
end

local function list_form(xs)
  local t = R.NIL
  for i = #xs, 1, -1 do t = cons_form(xs[i], t) end
  return t
end

local function judgement(term, ty)
  return R.cons(term, R.cons(COLON, R.cons(ty, R.NIL)))
end

-- Run the datatype predicate the way search-user-datatypes does.
local function run_rule(name, goal, assum)
  local fn = E.NativePred[name .. "#type"]
  if fn == nil then return nil, "no native predicate " .. name end
  local q = E.query_begin()
  local done = E.newcont0(function() return true end)
  local ok, res = pcall(fn, E.import_cached(goal), E.import_cached(assum), 0, done)
  E.query_end(q)
  if not ok then return nil, errmsg(res) end
  return res
end

local function varname(i) return string.char(64 + i) end

local function define_row(n)
  local vars, jud = {}, {}
  for i = 1, n do
    vars[i] = varname(i)
    jud[i] = vars[i] .. " : piece"
  end
  local name = "row" .. n
  shen.eval(string.format([[
(datatype %s
  %s >> P;
  %s
  [%s] : %s >> P;)
]], name, table.concat(jud, ", "), string.rep("_", 16),
     table.concat(vars, " "), name))
  return name
end

shen.eval([[
(datatype piece
  if (element? X [0 1])
  _____________________
  X : piece;)
]])

-- Five is the last width that fit the old 16-capture helper. Six is the
-- first that used to be missing. Eight and twelve sit past that threshold
-- and under the later metatable-chain limit on very deep clauses.
for _, n in ipairs({ 5, 6, 8, 12 }) do
  local name = define_row(n)
  local ty, err = typecheck("0", "piece")
  check(n .. " premises: 0 : piece still holds",
        err or R.to_str(ty), "piece")
  local ty2, err2 = typecheck("2", "piece")
  check(n .. " premises: walking the rule does not raise", err2, nil)
  check(n .. " premises: 2 : piece is not a piece",
        ty2 == false, true)

  local elems = {}
  for i = 1, n do elems[i] = (i % 2 == 0) and 1 or 0 end
  local row = list_form(elems)
  local hyp = R.cons(judgement(row, R.intern(name)), R.NIL)
  local goal = judgement(0, PIECE)
  local hit, herr = run_rule(name, goal, hyp)
  check(n .. " premises: matching hypothesis fires the rule",
        herr or hit, true)
  local miss, merr = run_rule(name, goal, R.NIL)
  check(n .. " premises: empty context misses", merr or miss, false)

  local short = {}
  for i = 1, n - 1 do short[i] = 0 end
  local bad = R.cons(judgement(list_form(short), R.intern(name)), R.NIL)
  local wrong, werr = run_rule(name, goal, bad)
  check(n .. " premises: short hypothesis misses", werr or wrong, false)

  local nope = judgement(2, PIECE)
  local no, nerr = run_rule(name, nope, hyp)
  check(n .. " premises: unpacked rule does not prove 2 : piece",
        nerr or no, false)
end

print(string.format("datatype_consume_spec: %d pass, %d fail", pass, fail))
os.exit(fail == 0 and 0 or 1)
