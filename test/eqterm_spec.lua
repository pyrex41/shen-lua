-- test/eqterm_spec.lua — native arena equality for `=` guards.
--
--   luajit test/eqterm_spec.lua
--
-- E.eqterm(a, b) must agree with the kernel's (= (materialize a)
-- (materialize b)) on every pair of terms, and the Prolog translator must
-- route (= T1 T2) guards over engine terms through it, whether each side is
-- spelled (shen.deref X B) or as a bare term variable (43.1's deref-hoisted
-- by-hypothesis-h compares the bare, already-dereferenced X).
package.path = (arg[0]:gsub("test/[^/]*$", "")) .. "?.lua;" .. package.path

local shen = require("shen")
shen.boot{ quiet = true }
local R = require("runtime")
local E = require("prolog_engine")
local PC = require("prolog_compile")
local F = shen.prims.F

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end

local function kl(s) return R.read_all(s)[1] end

-- ---------------------------------------------------------------------------
-- eqterm agrees with `=` over materialized terms
-- ---------------------------------------------------------------------------
do
  local q = E.query_begin()
  local imp = function(x) return E.import(x, {}) end
  local v1, v2 = E.newvar(), E.newvar()
  local bound = E.newvar()
  E.bind1(bound, imp(kl("(a b c)")), function() return true end)
  local tup = F["@p"](1, 2)
  local tup2 = F["@p"](1, 2)
  local vec = F["@v"](1, F["vector"](0))
  local vec2 = F["@v"](1, F["vector"](0))
  local terms = {
    imp(kl("a")), imp(kl("b")), imp(1), imp(1.0), imp(2), imp("s"), imp("t"),
    imp(true), imp(false), imp(R.NIL),
    imp(kl("(a b c)")), imp(kl("(a b c)")), imp(kl("(a b)")), imp(kl("(a b c d)")),
    imp(kl("((a (b)) c)")), imp(kl("((a (b)) c)")), imp(kl("((a (c)) c)")),
    imp(tup), imp(tup2), imp(F["@p"](1, 3)), imp(vec), imp(vec2),
    v1, v2, bound,
    E.cons(v1, 0), E.cons(v1, 0), E.cons(v2, 0),
    E.cons(imp(kl("a")), v1),
  }
  local agree, total = 0, 0
  for i = 1, #terms do
    for j = 1, #terms do
      total = total + 1
      local want = F["="](E.materialize(terms[i]), E.materialize(terms[j]))
      local got = E.eqterm(terms[i], terms[j])
      if got == want then agree = agree + 1
      else io.write("  eqterm mismatch at ", i, ",", j, ": got ", tostring(got),
                    " want ", tostring(want), "\n") end
    end
  end
  check(agree == total, "eqterm == (= (materialize a) (materialize b)) on all "
        .. total .. " pairs")
  check(E.eqterm(bound, imp(kl("(a b c)"))), "bound var derefs before compare")
  check(E.eqterm(imp(tup), imp(tup2)), "distinct tuples compare structurally")

  -- car nesting deeper than one Lua stack runs on stack segments (#93)
  local function deep(n)
    local t = imp(kl("x"))
    for _ = 1, n do t = E.cons(t, 0) end
    return t
  end
  local ok, r = pcall(E.eqterm, deep(200000), deep(200000))
  check(ok and r == true, "200000-deep car nesting compares (" .. tostring(r) .. ")")
  E.query_end(q)
end

-- ---------------------------------------------------------------------------
-- the translator lifts (= T1 T2) guards over engine terms to EQTERM
-- ---------------------------------------------------------------------------
local function translated(src)
  local fn, err, out = PC.translate_defun(kl(src))
  return fn, err, out or ""
end

do
  local fn, err, src = translated([[
(defun spec.empty-guard (V1 V2 V3 V4 V5)
  (if (= (shen.lazyderef V1 V2) ()) false true))]])
  check(fn ~= nil, "ec16a9f inline empty-list guard translates: " .. tostring(err))
  if fn then
    local q = E.query_begin()
    local v = E.newvar()
    check(fn(E.import(R.NIL, {}), 0, nil) == false, "empty hypotheses reject before helper")
    check(fn(E.import(kl("(x)"), {}), 0, nil) == true, "nonempty hypotheses enter helper")
    check(fn(v, 0, nil) == true, "unbound alternatives are not empty")
    E.bind1(v, E.import(R.NIL, {}), function()
      check(fn(v, 0, nil) == false, "bound empty alternatives lazily dereference")
      return true
    end)
    E.query_end(q)
  end
end

do
  -- shape of 43.1 shen.by-hypothesis (both sides dereferenced)
  local _, err, src = translated([[
(defun spec.byh (V1 V2 V3 V4 V5 V6 V7)
  (if (shen.unlocked? V5)
      (let W1 (shen.lazyderef V3 V4)
        (if (cons? W1)
            (let W2 (hd W1)
              (do (shen.incinfs)
                  (when (= (shen.deref V1 V4) (shen.deref W2 V4)) V4 V5 V6
                    (freeze (is! V2 W2 V4 V5 V6 V7)))))
            false))
      false))]])
  check(src:find("EQTERM(", 1, true) ~= nil, "deref/deref guard -> EQTERM (" .. tostring(err) .. ")")
  check(src:find("MAT(", 1, true) == nil, "deref/deref guard materializes nothing")
end

do
  -- shape of the deref-hoisted shen.by-hypothesis-h: (= X (shen.deref Y B))
  local _, err, src = translated([[
(defun spec.byhh (V1 V2 V3 V4 V5 V6 V7)
  (if (shen.unlocked? V5)
      (let W1 (shen.lazyderef V3 V4)
        (if (cons? W1)
            (let W2 (hd W1)
              (do (shen.incinfs)
                  (when (= V1 (shen.deref W2 V4)) V4 V5 V6
                    (freeze (is! V2 W2 V4 V5 V6 V7)))))
            false))
      false))]])
  check(src:find("EQTERM(", 1, true) ~= nil, "bare/deref guard -> EQTERM (" .. tostring(err) .. ")")
  check(src:find("MAT(", 1, true) == nil, "bare/deref guard materializes nothing")
end

do
  -- any other guard still lifts to a KL defun over materialized arguments
  local _, err, src = translated([[
(defun spec.other (V1 V2 V3 V4 V5)
  (if (shen.unlocked? V3)
      (do (shen.incinfs)
          (when (element? (shen.deref V1 V2) (cons a ())) V2 V3 V4 V5))
      false))]])
  check(src:find("MAT(", 1, true) ~= nil and src:find("EQTERM(", 1, true) == nil,
        "non-= guard keeps the lifted path (" .. tostring(err) .. ")")
end

-- ---------------------------------------------------------------------------
-- end to end: hypotheses are consulted through the native by-hypothesis
-- ---------------------------------------------------------------------------
do
  local function ty(src, t)
    local r = shen.typecheck(src, t)
    return r ~= false and R.to_str(r) or false
  end
  check(ty("(/. X (+ X 1))", "(number --> number)") == "(number --> number)",
        "lambda typechecks through hypotheses")
  check(ty("(/. X Y (@p X Y))", "(A --> B --> (A * B))") ~= false,
        "polymorphic pair typechecks")
  check(ty("(/. X (+ X \"a\"))", "(number --> number)") == false,
        "ill-typed body still fails")
end

io.write(string.format("eqterm_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
