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
local PC = require("prolog_compile")

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

local function varname(i) return "V" .. i end

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
-- first that used to be missing. From sixteen the native consume helper
-- nested past LuaJIT's 100-table __index chain ("loop in gettable") and then
-- past Lua's 200 locals per function; from about thirty the legacy KL defun
-- did too, and the datatype failed to load at all. Thirty-seven is the
-- widest that loads today (see the note at the end of this file).
local WIDTHS = { 5, 6, 8, 12, 15, 16, 20, 24, 30, 32, 37 }

local function check_width(n)
  local before = {}
  for k in pairs(PC.registry) do before[k] = true end
  local loaded, name = pcall(define_row, n)
  check(n .. " premises: datatype loads", loaded or errmsg(name), true)
  if not loaded then return end
  local helpers, native = 0, 0
  for k in pairs(PC.registry) do
    if not before[k] and k:match("^shen%.consume") then
      helpers = helpers + 1
      if E.NativePred[k] ~= nil then native = native + 1 end
    end
  end
  check(n .. " premises: every consume helper translates natively",
        helpers > 0 and native == helpers, true)
  check(n .. " premises: rule predicate translates natively",
        E.NativePred[name .. "#type"] ~= nil, true)
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

  -- the LAST premise is still unpacked: on wide rules it runs in code that
  -- a let-chain split moved into a separate function. Only the assumption
  -- 7 : piece taken from the last element proves 7 : piece.
  local tail = {}
  for i = 1, n do tail[i] = elems[i] end
  tail[n] = 7
  local tailhyp = R.cons(judgement(list_form(tail), R.intern(name)), R.NIL)
  local seven = judgement(7, PIECE)
  local thit, therr = run_rule(name, seven, tailhyp)
  check(n .. " premises: last element is unpacked", therr or thit, true)
  local tmiss, tmerr = run_rule(name, seven, hyp)
  check(n .. " premises: 7 : piece needs the last element", tmerr or tmiss, false)

  local nope = judgement(2, PIECE)
  local no, nerr = run_rule(name, nope, hyp)
  check(n .. " premises: unpacked rule does not prove 2 : piece",
        nerr or no, false)
end

for _, n in ipairs(WIDTHS) do check_width(n) end

-- Thirty-eight premises still fail to load: the legacy KL compiler hoists
-- each premise's freeze continuation into a function taking all ~3N
-- captures as parameters and passes them on in a nested call, which passes
-- LuaJIT's 250-slot frame limit ("function or expression too complex").

print(string.format("datatype_consume_spec: %d pass, %d fail", pass, fail))
os.exit(fail == 0 and 0 or 1)
