-- examples/crdt/selftest.lua — verify the CRDT demo off-nginx.
--
--   luajit examples/crdt/selftest.lua      (from the repo root)
--
-- Three checks, no nginx, no network:
--   1. CONVERGENCE — three replicas edit the shared document offline, then
--      sync through the hub in DIFFERENT orders; all land on the identical doc.
--   2. LAWS (tier b) — the executable semilattice law checks from crdt.shen
--      (gc-commutative? / gc-associative? / gc-idempotent?) over sample state.
--   3. PROOFS (tier c) — load crdt_laws.shen under (tc +); if the universally
--      quantified merge proofs did not check, the load would abort here.

local root = arg[0]:match("^(.*)/examples/crdt/[^/]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/examples/crdt/?.lua;" .. package.path

local app   = require("app")
local cjson = app.json
local shen  = require("shen")
local IO    = require("lua_interop")
local sym   = IO.sym

local fail = 0
local function ok(cond, label)
  io.write(("  %-44s %s\n"):format(label, cond and "ok" or "FAIL"))
  if not cond then fail = fail + 1 end
end

-- A fresh in-memory hub (one canonical JSON document) per scenario.
local function new_hub()
  local cell = { json = nil }
  app.use_store({ get = function() return cell.json end,
                  set = function(s) cell.json = s end })
  return cell
end

-- A replica's local edit of one field: value wins by (timestamp, replica-id).
local function reg(v, ts, id) return { v = v, ts = ts, id = id } end

-- ===========================================================================
print("== 1. convergence: concurrent offline edits, synced in any order ==")

-- Replica A, B, C each edited the doc while offline (note the clocks):
local A = { name = reg("ada",   3, "A"), role = reg("admin", 1, "A") }
local B = { name = reg("grace", 5, "B"), team = reg("core",  2, "B") }
local C = { role = reg("owner", 4, "C"), team = reg("infra", 6, "C") }

-- Sync them through the hub in two DIFFERENT orders; compare final docs.
local function sync_all(order)
  new_hub()
  local last
  for _, rep in ipairs(order) do
    local _, body = app.dispatch("POST", "/api/doc", rep)
    last = body
  end
  return last
end

-- canonical JSON (sorted keys) so two docs compare by value, not table order
local function canon(doc)
  local keys = {}
  for k in pairs(doc) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local r = doc[k]
    parts[#parts + 1] = ("%s=%s@%d/%s"):format(k, r.v, r.ts, r.id)
  end
  return table.concat(parts, "  ")
end

local abc = sync_all({ A, B, C })
local cba = sync_all({ C, B, A })
local bca = sync_all({ B, C, A })

print("  A⊔B⊔C : " .. canon(abc))
print("  C⊔B⊔A : " .. canon(cba))
print("  B⊔C⊔A : " .. canon(bca))
ok(canon(abc) == canon(cba), "order A,B,C  ==  order C,B,A")
ok(canon(abc) == canon(bca), "order A,B,C  ==  order B,C,A")
-- expected winners: name=grace@5/B, role=owner@4/C, team=infra@6/C
ok(abc.name.v == "grace" and abc.role.v == "owner" and abc.team.v == "infra",
   "last-writer-wins picked the right value per field")

-- idempotent: re-syncing an already-merged doc changes nothing
local once = sync_all({ A, B, C })
local _, twice = app.dispatch("POST", "/api/doc", once)
ok(canon(once) == canon(twice), "re-syncing a merged doc is a no-op (idempotent)")

-- ===========================================================================
print("\n== 2. semilattice laws, checked by execution (tier b) ==")
-- Build G-Counters in Shen and run the law predicates from crdt.shen.
shen.eval([==[ (define gA -> (gc-inc "a" (gc-inc "a" [gc []])))
               (define gB -> (gc-inc "b" [gc []]))
               (define gC -> (gc-inc "c" (gc-inc "a" [gc []]))) ]==])
ok(shen.call("gc-idempotent?", shen.call("gA")) == true,  "gc-idempotent?  (merge x x = x)")
ok(shen.call("gc-commutative?", shen.call("gA"), shen.call("gB")) == true,
   "gc-commutative? (merge a b = merge b a)")
ok(shen.call("gc-associative?", shen.call("gA"), shen.call("gB"), shen.call("gC")) == true,
   "gc-associative? (merge a (merge b c) = merge (merge a b) c)")

-- adversarial: the laws must hold for EVERY typed value, not just well-formed
-- ones. These are the exact counterexamples a review found before the merge
-- was made dedup-canonicalizing / the LWW order made total over the value.
shen.eval([==[ (define gDup -> [gc [["a" 1] ["a" 3]]])   \\ malformed: duplicate key
               (define gOne -> [gc [["a" 2]]])
               (define rX -> [lww "x" 1 "A"])            \\ same (ts,id), differ in value
               (define rY -> [lww "y" 1 "A"]) ]==])
ok(shen.call("gc-commutative?", shen.call("gDup"), shen.call("gOne")) == true,
   "gc-commutative? on a duplicate-key counter")
ok(shen.call("gc-idempotent?", shen.call("gDup")) == true,
   "gc-idempotent? on a duplicate-key counter")
ok(shen.call("lww-commutative?", shen.call("rX"), shen.call("rY")) == true,
   "lww-commutative? on same (ts,id), different value")

-- ===========================================================================
print("\n== 2b. laws by PROPERTY: the executable merge over random states ==")
-- Hand-picked cases test the laws on instances someone thought of. This runs
-- them over thousands of RANDOM states — including the shipped `doc-merge` (the
-- CRDT the demo actually uses) — which is the cheapest way to shrink the
-- model<->code gap tier (c) can't yet bridge. The PRNG is seeded, so any
-- failure prints a reproducible counterexample.
local seed = 2463534242
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
local function rint(n) return math.floor(rnd() * n) end
local function pick(t) return t[1 + rint(#t)] end

-- Small alphabets so ids/keys collide (dup keys) and clocks tie — the adversarial
-- corners. Generators produce a plain-Lua SPEC (for printing) + the Shen value.
local IDS, KEYS, VALS = { "A", "B", "C" }, { "name", "role", "team" }, { "ada", "grace", "x", "y" }
local function gc_spec()  local n = rint(4); local s = {}; for i = 1, n do s[i] = { pick(IDS), rint(5) } end; return s end
local function reg_spec() return { pick(VALS), rint(4), pick(IDS) } end
local function doc_spec() local n = rint(4); local s = {}; for i = 1, n do s[i] = { pick(KEYS), reg_spec() } end; return s end

local function gc_build(s)  return { sym("gc"), s } end                       -- s entries already {id,n}
local function reg_build(s) return { sym("lww"), s[1], s[2], s[3] } end
local function doc_build(s) local fs = {}; for i, f in ipairs(s) do fs[i] = { f[1], reg_build(f[2]) } end; return { sym("doc"), fs } end

local function reg_str(s) return ("%s@%d/%s"):format(s[1], s[2], s[3]) end
local function gc_str(s)  local p = {}; for _, t in ipairs(s) do p[#p+1] = t[1]..":"..t[2] end; return "gc{"..table.concat(p, ",").."}" end
local function doc_str(s) local p = {}; for _, f in ipairs(s) do p[#p+1] = f[1].."="..reg_str(f[2]) end; return "{"..table.concat(p, " ").."}" end

local N = 2000
local function prop(label, spec, build, str, pred, arity)
  local fn = IO.fn(pred)
  for i = 1, N do
    local sa, sb, sc = spec(), spec(), spec()
    local r = (arity == 1 and fn(build(sa)))
           or (arity == 2 and fn(build(sa), build(sb)))
           or fn(build(sa), build(sb), build(sc))
    if r ~= true then
      print(("  %-42s FAIL @ case %d"):format(label, i))
      print("      a = " .. str(sa)); if arity >= 2 then print("      b = " .. str(sb)) end
      if arity >= 3 then print("      c = " .. str(sc)) end
      fail = fail + 1; return
    end
  end
  ok(true, label .. "  (" .. N .. " random cases)")
end

prop("gc-idempotent?",  gc_spec,  gc_build,  gc_str,  "gc-idempotent?",  1)
prop("gc-commutative?", gc_spec,  gc_build,  gc_str,  "gc-commutative?", 2)
prop("gc-associative?", gc_spec,  gc_build,  gc_str,  "gc-associative?", 3)
prop("lww-idempotent?", reg_spec, reg_build, reg_str, "lww-idempotent?", 1)
prop("lww-commutative?",reg_spec, reg_build, reg_str, "lww-commutative?",2)
prop("lww-associative?",reg_spec, reg_build, reg_str, "lww-associative?",3)
prop("doc-idempotent?", doc_spec, doc_build, doc_str, "doc-idempotent?", 1)
prop("doc-commutative?",doc_spec, doc_build, doc_str, "doc-commutative?",2)
prop("doc-associative?",doc_spec, doc_build, doc_str, "doc-associative?",3)

-- ===========================================================================
print("\n== 3. universally-quantified proofs, checked by the type system (tier c) ==")
shen.eval("(tc +)")
local loaded = pcall(shen.prims.F["load"], root .. "/examples/crdt/crdt_laws.shen")
shen.eval("(tc -)")
ok(loaded, "crdt_laws.shen loads => idem/comm-sym/absorption proofs all check")

-- ---------------------------------------------------------------------------
if fail == 0 then print("\nOK — all checks passed")
else print(("\n%d check(s) FAILED"):format(fail)); os.exit(1) end
