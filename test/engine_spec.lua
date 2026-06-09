-- test/engine_spec.lua — unit tests for the soa32 substrate (prolog_engine.lua).
-- Pure Lua: requires only runtime.lua, NOT the kernel.
--   luajit test/engine_spec.lua
package.path = (arg[0]:gsub("test/[^/]*$", "")) .. "?.lua;" .. package.path

local E = require("prolog_engine")
local R = require("runtime")

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end

-- a trivially-succeeding continuation (Lua-function form of thaw)
local T = function() return true end

-- ---------------------------------------------------------------------------
-- atoms / interning
-- ---------------------------------------------------------------------------
do
  E.reset_all()
  local sym = R.intern("foo")
  check(E.atom(sym) == E.atom(sym), "symbol interned by identity")
  check(E.atom(sym) ~= E.atom(R.intern("bar")), "distinct symbols distinct ids")
  check(E.atomval(E.atom(sym)) == sym, "symbol round-trip")
  check(E.atom(42) == E.atom(42), "number interned by value")
  check(E.atomval(E.atom(42)) == 42, "number round-trip")
  check(E.atomval(E.atom(-1.5)) == -1.5, "negative float round-trip")
  check(E.atomval(E.atom("s")) == "s", "string round-trip")
  check(E.atom(R.NIL) == 0, "NIL is atom 0")
  check(E.atom(true) == 1 and E.atom(false) == 2, "booleans fixed ids")
  check(E.atom(42) ~= E.atom("42"), "number and string distinct")
end

-- ---------------------------------------------------------------------------
-- terms / vars / deref
-- ---------------------------------------------------------------------------
do
  local a = E.atom(R.intern("a"))
  local v = E.newvar()
  check(E.is_var(v) and not E.is_cons(v) and not E.is_atom(v), "var tags")
  local c = E.cons(a, v)
  check(E.is_cons(c) and E.car(c) == a and E.cdr(c) == v, "cons/car/cdr")
  check(E.lazyderef(v) == v, "unbound var derefs to itself")
end

-- ---------------------------------------------------------------------------
-- unify: atoms, vars, structures, failure unwind
-- ---------------------------------------------------------------------------
do
  local a, b = E.atom(R.intern("a")), E.atom(R.intern("b"))
  check(E.unify(a, a, T) == true, "atom self-unify")
  check(E.unify(a, b, T) == false, "distinct atoms fail")

  local v = E.newvar()
  check(E.unify(v, a, T) == true, "var-atom bind")
  check(E.lazyderef(v) == a, "binding visible after success")

  -- failure inside the continuation unwinds this unify's bindings
  local w = E.newvar()
  local r = E.unify(w, b, function() return false end)
  check(r == false, "cont-false propagates")
  check(E.lazyderef(w) == w, "cont-false unwound the binding")

  -- structural unify with embedded vars
  local x, y = E.newvar(), E.newvar()
  local t1 = E.cons(a, E.cons(x, 0))
  local t2 = E.cons(y, E.cons(b, 0))
  check(E.unify(t1, t2, T) == true, "structural unify")
  check(E.lazyderef(x) == b and E.lazyderef(y) == a, "structural bindings")

  -- structural mismatch fails and unwinds partial bindings
  local z = E.newvar()
  local t3 = E.cons(z, E.cons(a, 0))
  local t4 = E.cons(b, E.cons(b, 0))
  check(E.unify(t3, t4, T) == false, "structural mismatch fails")
  check(E.lazyderef(z) == z, "partial binding unwound on mismatch")

  -- var-var chains
  local p, q = E.newvar(), E.newvar()
  check(E.unify(p, q, T) == true, "var-var")
  check(E.unify(p, a, T) == true, "bind through chain")
  check(E.lazyderef(q) == a or E.lazyderef(p) == a, "chain deref")

  -- success value propagates (not coerced to true)
  local ans = E.unify(a, a, function() return 42 end)
  check(ans == 42, "success value propagates through unify")
end

-- ---------------------------------------------------------------------------
-- occurs check: unify_oc vs unify
-- ---------------------------------------------------------------------------
do
  local a = E.atom(R.intern("a"))
  local v = E.newvar()
  local cyc = E.cons(a, v)
  check(E.unify_oc(v, cyc, T) == false, "occurs check rejects cycle")
  check(E.lazyderef(v) == v, "occurs failure leaves var unbound")
  local u = E.newvar()
  local fin = E.cons(a, 0)
  check(E.unify_oc(u, fin, T) == true, "occurs check passes finite term")
end

-- ---------------------------------------------------------------------------
-- marks / undo (the choice-point discipline)
-- ---------------------------------------------------------------------------
do
  local a = E.atom(R.intern("a"))
  local tm, vm, hm, bm, cm = E.marks()
  local v1, v2 = E.newvar(), E.newvar()
  E.unify(v1, a, T)
  E.unify(v2, E.cons(a, 0), T)
  check(E.lazyderef(v1) == a, "bound before undo")
  E.undo(tm, vm, hm, bm, cm)
  local ct, vt = E.tops()
  check(vt == vm, "var_top restored")
  check(ct == cm, "cell_top restored")
  local v3 = E.newvar()
  check(E.lazyderef(v3) == v3, "reallocated var slot is unbound")
end

-- ---------------------------------------------------------------------------
-- bind1
-- ---------------------------------------------------------------------------
do
  local a = E.atom(R.intern("a"))
  local v = E.newvar()
  check(E.bind1(v, a, T) == true, "bind1 success")
  check(E.lazyderef(v) == a, "bind1 binding")
  local w = E.newvar()
  check(E.bind1(w, a, function() return false end) == false, "bind1 cont-false")
  check(E.lazyderef(w) == w, "bind1 unwound")
end

-- ---------------------------------------------------------------------------
-- continuations: captures, handles, undo reclaim
-- ---------------------------------------------------------------------------
do
  local got
  local k2 = function(b, h)
    got = { E.capref(b, 0), E.capref(b, 1) }
    return true
  end
  local h = E.newcont2(k2, 7, 9)
  check(E.thawH(h) == true, "thawH runs lifted fn")
  check(got[1] == 7 and got[2] == 9, "captures read back")

  local tm, vm, hm, bm, cm = E.marks()
  local h2 = E.newcont1(function() return true end, 5)
  E.undo(tm, vm, hm, bm, cm)
  local _, _, _, _, ht = E.tops()
  check(ht == hm, "cont handles reclaimed by undo")

  -- spill table for non-int captures
  local sym = R.intern("spilled")
  local hs = E.newcont_spill(function(b, hh)
    return E.spill(hh)[1] == sym
  end, { sym })
  check(E.thawH(hs) == true, "spill captures")
end

-- ---------------------------------------------------------------------------
-- cut / lock (clause-try simulation)
-- ---------------------------------------------------------------------------
do
  -- predicate p with three "clauses"; clause 2 contains a cut whose
  -- continuation fails -> the lock closes at depth n, suppressing clause 3,
  -- and unlock(n) at the sequence end re-opens it.
  local tried = {}
  local function pred(n)
    local tm, vm, hm, bm, cm = E.marks()
    if E.lock_is_open() then
      tried[#tried + 1] = 1
      -- clause 1: plain failure
      E.undo(tm, vm, hm, bm, cm)
    end
    if E.lock_is_open() then
      tried[#tried + 1] = 2
      -- clause 2: cut, then the rest of the body fails
      local r = E.cut(n, function() return false end)
      if r ~= false then return r end
      E.undo(tm, vm, hm, bm, cm)
    end
    if E.lock_is_open() then
      tried[#tried + 1] = 3
      E.undo(tm, vm, hm, bm, cm)
    end
    return E.unlock(n)
  end
  local r = pred(1)
  check(r == false, "cut predicate fails overall")
  check(#tried == 2 and tried[1] == 1 and tried[2] == 2,
        "cut suppressed clause 3")
  check(E.lock_is_open(), "unlock re-opened the lock")

  -- cut whose continuation SUCCEEDS passes the value through, no lock
  local r2 = E.cut(1, function() return 99 end)
  check(r2 == 99 and E.lock_is_open(), "successful cut passes value")

  -- lock at depth 2 is NOT re-opened by unlock at depth 1
  E.cut(2, function() return false end)
  check(not E.lock_is_open(), "lock closed at depth 2")
  E.unlock(1)
  check(not E.lock_is_open(), "unlock at wrong depth keeps lock closed")
  E.unlock(2)
  check(E.lock_is_open(), "unlock at matching depth opens")
end

-- ---------------------------------------------------------------------------
-- import / materialize round-trip
-- ---------------------------------------------------------------------------
do
  E.reset_all()
  local foo, bar = R.intern("foo"), R.intern("bar")
  local lst = R.cons(foo, R.cons(1, R.cons("s", R.cons(R.cons(bar, R.NIL), R.NIL))))
  local t = E.import(lst, nil)
  local back = E.materialize(t)
  -- structural comparison
  local function eq(a, b)
    if a == b then return true end
    if getmetatable(a) == R.Cons and getmetatable(b) == R.Cons then
      return eq(a[1], b[1]) and eq(a[2], b[2])
    end
    return false
  end
  check(eq(back, lst), "import/materialize round-trip")

  -- legacy pvar in input maps to one arena var per ticket
  local pv = setmetatable({ 2, R.intern("shen.pvar"), 77 }, R.Vmt)
  local vm = {}
  local t1 = E.import(R.cons(pv, R.cons(pv, R.NIL)), vm)
  check(E.car(t1) == E.lazyderef(E.car(E.cdr(t1))), "same ticket -> same var")

  -- materialize of an unbound var is a legacy-format pvar absvector
  local v = E.newvar()
  local out = E.materialize(v)
  check(getmetatable(out) == R.Vmt and out[2] == R.intern("shen.pvar"),
        "unbound var materializes as legacy pvar")
  check(E.materialize(v) == out, "pvar materialization cached")

  -- bound var materializes its value
  E.unify(v, E.atom(foo), T)
  check(E.materialize(v) == foo, "bound var materializes value")
end

-- ---------------------------------------------------------------------------
-- builtins
-- ---------------------------------------------------------------------------
do
  check(E.g_when(true, 1, T) == true, "g_when true")
  check(E.g_when(false, 1, T) == false, "g_when false")
  local v = E.newvar()
  check(E.g_var(v, 1, T) == true, "g_var unbound")
  E.unify(v, E.atom(1), T)
  check(E.g_var(v, 1, T) == false, "g_var bound")
  local out = E.g_return(E.cons(E.atom(R.intern("x")), 0))
  check(getmetatable(out) == R.Cons, "g_return materializes")
end

-- ---------------------------------------------------------------------------
-- query lifecycle: nesting, epoch restore, opaque release
-- ---------------------------------------------------------------------------
do
  E.reset_all()
  local a = E.atom(R.intern("a"))
  local q1 = E.query_begin()
  local v = E.newvar()
  E.unify(v, a, T)
  local opaque = { i_am = "opaque" }
  local oid = E.atom(opaque)
  check(E.atomval(oid) == opaque, "opaque interned")

  -- nested query
  local q2 = E.query_begin()
  local w = E.newvar()
  E.unify(w, E.cons(a, 0), T)
  E.query_end(q2)
  check(E.lazyderef(v) == a, "outer binding survives nested query")

  E.query_end(q1)
  local ct, vt, tt, kt, ht = E.tops()
  check(ct == 0 and vt == 0 and tt == 0 and kt == 0 and ht == 0,
        "query_end restored all tops")
  check(E.atomval(oid) == nil, "opaque atom released at query end")
  check(E.atom(opaque) ~= oid, "re-intern gets fresh id")
end

-- ---------------------------------------------------------------------------
-- growth: push every arena past its initial capacity
-- ---------------------------------------------------------------------------
do
  E.reset_all()
  -- vars + trail (initial 16384)
  local vars = {}
  for i = 1, 20000 do vars[i] = E.newvar() end
  local a = E.atom(R.intern("g"))
  local ok = true
  for i = 1, 20000 do
    if E.unify(vars[i], a, T) ~= true then ok = false end
  end
  check(ok, "20k binds across trail growth")
  ok = true
  for i = 1, 20000 do
    if E.lazyderef(vars[i]) ~= a then ok = false end
  end
  check(ok, "bindings intact after growth")

  -- cells (initial 65536): one long list = 40k cells, plus deep unify
  E.reset_all()
  local t1, t2 = 0, 0
  for i = 1, 40000 do t1 = E.cons(E.atom(i % 100), t1) end
  for i = 1, 40000 do t2 = E.cons(E.atom(i % 100), t2) end
  check(E.unify(t1, t2, T) == true, "40k-deep unify across cell growth")

  -- capture buffer (initial 16384)
  E.reset_all()
  for i = 1, 5000 do E.newcont8(T, i, i, i, i, i, i, i, i) end
  local h = E.newcont2(function(b) return E.capref(b, 0) + E.capref(b, 1) end, 3, 4)
  check(E.thawH(h) == 7, "capture buffer growth")
end

-- ---------------------------------------------------------------------------
-- cell reclaim at choice points: terms built in a failed try are reclaimed,
-- and reclaim never corrupts terms reachable from surviving bindings
-- ---------------------------------------------------------------------------
do
  E.reset_all()
  local a = E.atom(R.intern("a"))
  -- surviving structure built BEFORE the choice point
  local keeper = E.newvar()
  E.unify(keeper, E.cons(a, E.cons(a, 0)), T)
  local tm, vm, hm, bm, cm = E.marks()
  -- failed try: builds 1000 cells, binds keeper's tail var... then fails
  for i = 1, 1000 do E.cons(a, 0) end
  E.undo(tm, vm, hm, bm, cm)
  local ct = E.tops()
  check(ct == cm, "failed-try cells reclaimed")
  local back = E.materialize(keeper)
  check(getmetatable(back) == R.Cons and back[1] == R.intern("a"),
        "pre-mark structure intact after cell reclaim")
end

io.write(string.format("engine_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
