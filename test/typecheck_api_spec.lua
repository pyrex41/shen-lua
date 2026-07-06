-- typecheck_api_spec.lua : the shen.typecheck embedding helper.
--
--   luajit test/typecheck_api_spec.lua
--
-- Covers the two kernel traps the helper exists to absorb: syntax-vs-value
-- (callers pass source strings; the helper reads, never evaluates) and the
-- global cumulative inference counter (without a per-call reset, a
-- long-lived process crosses *maxinferences* and every later check fails —
-- the regression test here runs enough checks to cross a lowered budget
-- many times over).

local shen = require("shen")
shen.boot{ quiet = true }
local R = require("runtime")

local pass, fail = 0, 0
local function check(desc, got, want)
  local okv = (want == nil) and (got ~= false) or (got == want)
  if okv then pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL %s: got %s want %s", desc, tostring(got), tostring(want)))
  end
end
local function tyname(res)
  return res ~= false and R.to_str(res) or false
end

-- ---- basics: atoms and lists, check and infer -------------------------------
check("number : number", tyname(shen.typecheck("1", "number")), "number")
check("string : string", tyname(shen.typecheck('"x"', "string")), "string")
check("bool   : boolean", tyname(shen.typecheck("true", "boolean")), "boolean")
check("number : string fails", shen.typecheck("1", "string"), false)
check("list   : (list number)", shen.typecheck("[1 2 3]", "(list number)"))
check("mixed  : (list number) fails", shen.typecheck('[1 "a"]', "(list number)"), false)
check("infer via type variable", shen.typecheck("[1 2]", "A"))

-- ---- syntax not values: the bracket form reads to (cons ...) syntax ---------
check("nested list", shen.typecheck("[[1] [2 3]]", "(list (list number))"))

-- ---- user datatypes with verified premises ----------------------------------
shen.eval([[
(define spec.holds?
  Premise -> (trap-error (= true (eval Premise)) (/. E false)))
(datatype spec-discharge-verified
  if (spec.holds? Premise)
  ______________________
  Premise : verified;)
(datatype spec-box
  X : string;
  (not (= X "")) : verified;
  ================
  [X] : spec-box;)
]])
check("datatype + verified premise holds", tyname(shen.typecheck('["hi"]', "spec-box")), "spec-box")
check("verified premise fails", shen.typecheck('[""]', "spec-box"), false)
check("wrong element type fails", shen.typecheck("[37]", "spec-box"), false)

-- ---- the regression: compound types of 3+ elements ---------------------------
-- The reader cooks expression and type positions differently: read standalone,
-- (may alice write doc1) curries to ((((fn may) alice) write) doc1) and the
-- check silently returns false. The helper must read "EXPR : TYPE" as ONE
-- triple (the (load) work-through shape) so the type stays raw syntax. Simple
-- (list X) types never trip this — currying starts at two arguments — so the
-- checks above can't catch it; this is the examples/policy/policy_proof.shen
-- authorization encoding, where a term of (may S A R) is a proof of permission.
shen.eval([[
(datatype spec-authz
  ______________________________
  [owns-fact] : (owns alice doc1);

  ______________________________________
  [alice-tenant] : (same-tenant alice doc1);

  P : (owns S R); Q : (same-tenant S R);
  ======================================
  [by-owner P Q] : (may S A R);)
]])
check("4-ary compound type inhabited",
      shen.typecheck("[by-owner [owns-fact] [alice-tenant]]", "(may alice write doc1)"))
check("4-ary compound type: infs consumed (not a silent false)",
      shen.value("shen.*infs*") > 0, true)
check("4-ary compound type uninhabited fails",
      shen.typecheck("[by-owner [owns-fact] [alice-tenant]]", "(may bob write doc1)"), false)
check("2-ary compound type still fine", shen.typecheck("[owns-fact]", "(owns alice doc1)"))

-- ---- the regression: cumulative inference exhaustion ------------------------
-- Lower the budget so the bug (were it present) would trip in tens of checks,
-- then run 200: with the per-call reset every check must keep agreeing.
local prev_max = shen.value("shen.*maxinferences*")
shen.eval("(set shen.*maxinferences* 2000)")
local ok_all = true
for i = 1, 200 do
  if not shen.typecheck("[1 2 3]", "(list number)") then ok_all = false break end
  if shen.typecheck('[1 "a"]', "(list number)") ~= false then ok_all = false break end
end
check("200 checks under a 2000-inference budget (per-call reset)", ok_all, true)

-- a single check that EXCEEDS the budget fails closed (and does not poison
-- the next check). The kernel consults the cap at coarse checkpoints
-- (shen.maxinfexceeded? in t-star), not on every inference, so a tiny limit
-- is needed to guarantee a trip on a small term.
shen.eval("(set shen.*maxinferences* 1)")
check("over-budget check fails closed", shen.typecheck("[1 2 3 4 5 6 7 8]", "(list number)"), false)
shen.eval("(set shen.*maxinferences* " .. tostring(prev_max) .. ")")
check("next check recovers after budget failure", shen.typecheck("[1]", "(list number)"))

-- ---- bad input ---------------------------------------------------------------
local okc = pcall(shen.typecheck, "", "number")
check("empty expression errors", okc, false)

print(string.format("typecheck_api_spec: %d pass, %d fail", pass, fail))
os.exit(fail == 0 and 0 or 1)
