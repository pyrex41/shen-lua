-- typecheck_lazy_spec.lua : the deferred typecheck-driver translation.
--
--   luajit test/typecheck_lazy_spec.lua
--
-- The engine defers translating the 16 t-star driver defuns from install time
-- to the first typecheck (halving warm boot). This locks that contract:
--   * boot leaves the drivers UNtranslated (n_ok == 0);
--   * the exported native entry is GUARDED — calling it directly, before any
--     dispatch, translates the drivers instead of reading nil predicates and
--     crashing (the pre-fix failure mode);
--   * the drivers are translated exactly ONCE and translation is clean.

local shen = require("shen")
shen.boot{ quiet = true }
local tn = require("typecheck_native")
local P  = shen.prims
local R  = require("runtime")

local pass, fail = 0, 0
local function check(desc, cond)
  if cond then pass = pass + 1
  else fail = fail + 1; print("FAIL " .. desc) end
end

-- read a source string to the single form the kernel typecheck expects
local function form(s) return P.F["read-from-string"](s)[1] end

-- 1) boot does NOT translate the drivers — that is the whole point.
check("drivers deferred at boot (n_ok == 0)", tn.n_ok == 0)
check("no failures recorded at boot (n_fail == 0)", tn.n_fail == 0)

-- 2) the exported native_typecheck is guarded: a direct call (no dispatch has
--    run yet) must translate drivers first, not crash on nil NP predicates.
local ok, res = pcall(tn.native_typecheck, form("1"), form("number"))
check("direct native_typecheck does not crash", ok)
check("direct native_typecheck returns a result", ok and res ~= false)
check("direct call triggered driver translation (n_ok > 0)", tn.n_ok > 0)
check("driver translation was clean (n_fail == 0)", tn.n_fail == 0)

-- 3) translated exactly once: a normal typecheck afterwards does not re-run it.
local n = tn.n_ok
check("a normal typecheck still succeeds",
      shen.typecheck("[1 2 3]", "(list number)") ~= false)
check("drivers translated once (n_ok stable)", tn.n_ok == n)

print(string.format("typecheck_lazy_spec: %d pass, %d fail", pass, fail))
os.exit(fail == 0 and 0 or 1)
