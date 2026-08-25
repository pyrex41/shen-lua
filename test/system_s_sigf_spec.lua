-- system_s_sigf_spec.lua : kernel signatures reach System S (issue #62).
--
--   luajit test/system_s_sigf_spec.lua
--
-- `declare` registers each kernel signature in shen.*sigf* as a closure that
-- unifies the goal type against the DECLARED type. boot.lua hoists the
-- trailing (declare Name Typeform) block of types.kl out of the kernel chunk
-- (see hoist_tail), and the regression here was passing Typeform — a KL
-- expression like (cons number (cons --> ...)) — to `declare` UNEVALUATED, so
-- every hoisted signature unified against the raw AST and never matched a
-- real type. The native typecheck harvests signatures separately and masked
-- the bug on the shen.typecheck path; a prolog?-driven shen.system-S query
-- (and the legacy typecheck path) consults the real *sigf* closures, which is
-- exactly what this spec exercises. Expected verdicts match shen-go/shen-cl.

local shen = require("shen")
shen.boot{ quiet = true }

local pass, fail = 0, 0
local function check(desc, got, want)
  if got == want then pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL %s: got %s want %s", desc, tostring(got), tostring(want)))
  end
end

shen.eval([[
(define system-s-sigf-spec-query
  Hyps [X : A] -> (prolog? (shen.system-S [(shen.curry (receive X)) : (receive A)] (receive Hyps))))
]])

local function judge(src)
  return shen.eval("(system-s-sigf-spec-query " .. src .. ")")
end

-- the four judgments from issue #62: arithmetic/comparison signatures come
-- from the hoisted declare block; cons has a dedicated System S rule and
-- never consults *sigf* (the control).
check("[* 2 3] : number", judge("[] [[* 2 3] : number]"), true)
check("[+ 2 3] : number", judge("[] [[+ 2 3] : number]"), true)
check("[> 2 3] : boolean", judge("[] [[> 2 3] : boolean]"), true)
check("[cons 1 []] : (list number)", judge("[] [[cons 1 []] : [list number]]"), true)

-- partial application resolves through the same hoisted signature closure
check("partial application [* 2] : (number --> number)",
      judge("[] [[* 2] : [number --> number]]"), true)

-- and wrong judgments must still fail
check("[* 2 3] : string fails", judge("[] [[* 2 3] : string]"), false)
check("[> 2 3] : number fails", judge("[] [[> 2 3] : number]"), false)

-- the legacy sig closure itself (what lookupsig applies): ground unify of the
-- declared type must succeed — this is false when the typeform was registered
-- unevaluated, whatever engine handles prolog? above.
check("*sigf* closure for + unifies its declared type",
      shen.eval([==[
(let Entry (assoc + (value shen.*sigf*))
  (if (cons? Entry)
      ((((((tl Entry) [number --> [number --> number]]) (shen.prolog-vector)) (@v true (@v 0 (vector 0)))) 0) (freeze true))
      symbol-plus-not-in-sigf))
]==]), true)

print(string.format("system_s_sigf_spec: %d pass, %d fail", pass, fail))
os.exit(fail == 0 and 0 or 1)
