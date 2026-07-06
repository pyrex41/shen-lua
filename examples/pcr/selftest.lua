-- examples/pcr/selftest.lua — verify the live-facts proof-carrying gateway off-nginx.
--
--   luajit examples/pcr/selftest.lua                            (native engine)
--   SHEN_TYPECHECK_NATIVE=off luajit examples/pcr/selftest.lua  (parity leg)
--
-- Drives the SAME check() the edge gate uses (pure-Lua fact store fallback):
-- the allow cases, the REVOCATION WINDOW (grant/revoke flips take effect on
-- the immediately-next check, surgically), TTL facts, replica-mode staleness
-- hard cap, every category of hostile-input denial, an intern-growth
-- regression, and a warm timing loop. The parity leg must print IDENTICAL
-- verdicts and inference counts — that is the only guard against
-- side-condition rules silently diverging between the two engines.

local root = arg[0]:match("^(.*)/examples/pcr/[^/]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/examples/pcr/?.lua;" .. package.path

local app   = require("app")
local facts = app.facts
local shen  = require("shen")

local fail = 0
local function expect(label, want, subject, action, resource, proof)
  local authorized, reason = app.check(subject, action, resource, proof)
  io.write(("  %-30s %-5s  infs=%-4d %s\n"):format(label,
    authorized and "ALLOW" or "DENY", shen.value("shen.*infs*"), reason))
  if authorized ~= want then fail = fail + 1; print("      FAIL: expected " .. tostring(want)) end
end

-- assert a DENY whose reason contains a substring — used to prove *which
-- layer* denied (the type checker vs the pre-intern gate).
local function expect_reason(label, want_sub, subject, action, resource, proof)
  local authorized, reason = app.check(subject, action, resource, proof)
  local ok = (not authorized) and reason:find(want_sub, 1, true) ~= nil
  io.write(("  %-30s %-5s  %s\n"):format(label, authorized and "ALLOW" or "DENY", reason))
  if not ok then
    fail = fail + 1
    print("      FAIL: expected deny with reason containing: " .. want_sub)
  end
end

local function expect_admin(label, want_ok, path, body)
  local status, out = app.dispatch("POST", path, body)
  io.write(("  %-30s HTTP %-3d %s\n"):format(label, status, out.reason or out.error or "ok"))
  local matched
  if want_ok then
    matched = status == 200 and out.ok == true
  else
    matched = status ~= 200 and out.ok == false
  end
  if not matched then
    fail = fail + 1
    print(("      FAIL: expected admin ok=%s"):format(tostring(want_ok)))
  end
  return status, out
end

local owner_proof  = "[by-owner [fact owns alice doc1] [fact same-tenant alice doc1]]"
local member_proof = "[by-member-read [fact has-role bob member] [fact same-tenant bob doc1]]"
local deleg_proof  = "[by-delegation " .. owner_proof .. " [fact delegates alice carol]]"

print("== proofs that check against the live fact world ==")
expect("owner writes",           true, "alice", "write",  "doc1", owner_proof)
expect("same proof, any action", true, "alice", "delete", "doc1", owner_proof)
expect("member reads",           true, "bob",   "read",   "doc1", member_proof)
expect("delegate writes",        true, "carol", "write",  "doc1", deleg_proof)

print("\n== the revocation window: identical bytes, next check ==")
for round = 1, 3 do
  facts.revoke("delegates", "alice", "carol")
  expect("revoked -> deny (round " .. round .. ")",  false, "carol", "write", "doc1", deleg_proof)
  expect("...surgical: owner unaffected",            true,  "alice", "write", "doc1", owner_proof)
  facts.grant("delegates", "alice", "carol")
  expect("re-granted -> allow",                      true,  "carol", "write", "doc1", deleg_proof)
end
facts.revoke("owns", "alice", "doc1")
expect("revoke root fact",        false, "alice", "write", "doc1", owner_proof)
expect("...kills chains on it",   false, "carol", "write", "doc1", deleg_proof)
facts.grant("owns", "alice", "doc1")
expect("restore root fact",       true,  "alice", "write", "doc1", owner_proof)

-- a known principal (carol is a tenant member) whose delegated capability is
-- revoked must deny at the TYPE layer with the honest reason — not be rejected
-- at the gate as an unknown atom. This locks the admit() rework: fact-world
-- atoms are always admitted, so carol reaches the checker and fails there.
facts.revoke("delegates", "alice", "carol")
expect_reason("de-authorized, still known", "proof does not establish",
              "carol", "write", "doc1", deleg_proof)
facts.grant("delegates", "alice", "carol")

print("\n== fact-store write failures fail closed ==")
local before = facts.snapshot()
local before_version = before.version
facts._test.simulate_write_failure = "simulated shared-dict full"
expect_admin("failed revoke reports", false, "/admin/revoke",
             { pred = "delegates", s = "alice", r = "carol" })
expect("failed revoke keeps grant", true, "carol", "write", "doc1", deleg_proof)
local after = facts.snapshot()
if after.version ~= before_version then
  fail = fail + 1
  print("      FAIL: failed revoke advanced fact version")
end

local erin_proof = "[by-delegation " .. owner_proof .. " [fact delegates alice erin]]"
expect_admin("failed grant reports", false, "/admin/grant",
             { pred = "delegates", s = "alice", r = "erin" })
expect("failed grant stays absent", false, "erin", "write", "doc1", erin_proof)
after = facts.snapshot()
if after.version ~= before_version then
  fail = fail + 1
  print("      FAIL: failed grant advanced fact version")
end

facts._test.simulate_write_failure = nil
expect_admin("grant recovers", true, "/admin/grant",
             { pred = "delegates", s = "alice", r = "erin" })
expect("recovered grant allows", true, "erin", "write", "doc1", erin_proof)
expect_admin("revoke recovers", true, "/admin/revoke",
             { pred = "delegates", s = "alice", r = "erin" })
expect("recovered revoke denies", false, "erin", "write", "doc1", erin_proof)

print("\n== TTL facts: expiry is revocation with no revoke call ==")
local real_now = facts.now
facts.grant("delegates", "alice", "dave", real_now() + 3600)
expect("TTL fact within expiry",  true,  "dave", "write", "doc1",
       "[by-delegation " .. owner_proof .. " [fact delegates alice dave]]")
facts.now = function() return real_now() + 7200 end   -- clock passes expiry
expect("TTL fact expired",        false, "dave", "write", "doc1",
       "[by-delegation " .. owner_proof .. " [fact delegates alice dave]]")
facts.now = real_now
facts.revoke("delegates", "alice", "dave")

print("\n== replica mode: staleness hard cap fails closed ==")
facts.mode = "replica"
expect("fresh replica allows",    true,  "alice", "write", "doc1", owner_proof)
facts.now = function() return real_now() + 3 * facts.W + 1 end   -- sync ages past 3W
expect("stale replica denies all",false, "alice", "write", "doc1", owner_proof)
facts.now = real_now
expect("recovers when fresh",     true,  "alice", "write", "doc1", owner_proof)
facts.mode = "authoritative"

print("\n== denials: the proof is bound to the exact judgment ==")
expect("read proof, delete asked",  false, "bob",   "delete", "doc1", member_proof)
expect("spoof: alice's proof, bob", false, "bob",   "write",  "doc1", owner_proof)
expect("delegation chain broken",   false, "carol", "read",   "doc1",
       "[by-delegation " .. member_proof .. " [fact delegates alice carol]]")
expect("leaf asserts a grant",      false, "carol", "write",  "doc1",
       "[fact may carol write doc1]")   -- pred allowlist: facts can't mint (may ...)

print("\n== denials: hostile input fails closed ==")
expect("no proof",            false, "alice", "write", "doc1", nil)
expect("unreadable proof",    false, "alice", "write", "doc1", "[by-owner [fact owns alice")
expect("smuggled judgment",   false, "bob", "delete", "doc1",
       member_proof .. " : (may bob read doc1)")
expect("judgment injection",  false, "doc1) (may bob delete doc1", "write", "doc1", owner_proof)
expect("unknown subject",     false, "mallory", "write", "doc1", owner_proof)
expect("unknown proof token", false, "alice", "write", "doc1",
       "[by-owner [fact owns mallory doc1] [fact same-tenant alice doc1]]")
expect("oversized proof",     false, "alice", "write", "doc1",
       "[by-owner " .. string.rep("[fact owns alice doc1] ", 60) .. "]")
expect("unbound-var leaf",    false, "alice", "write", "doc1",
       "[by-owner [fact owns X doc1] [fact same-tenant alice doc1]]")
facts.grant("owns", "S", "doc1")      -- admit uppercase atoms into the fact world first
facts.grant("owns", "alice", "R")     -- the request gate must still reject them
facts.grant("owns", "alice", "A")     -- because Shen would read them as type variables
expect("uppercase subject",   false, "S",     "write", "doc1", owner_proof)
expect("uppercase action",    false, "alice", "A",     "doc1", owner_proof)
expect("uppercase resource",  false, "alice", "write", "R",    owner_proof)
expect("uppercase proof atom",false, "alice", "write", "doc1",
       "[by-owner [fact owns S doc1] [fact same-tenant alice doc1]]")

-- a throwing fact store denies, and the next check recovers
local real_factq = facts.factq
facts.factq = function() error("db down") end
expect("store throws -> deny", false, "alice", "write", "doc1", owner_proof)
facts.factq = real_factq
expect("recovers after throw", true,  "alice", "write", "doc1", owner_proof)

-- a term needing more inferences than the budget fails closed, then recovers
local prev_max = shen.value("shen.*maxinferences*")
shen.eval("(set shen.*maxinferences* 1)")
expect("over budget",          false, "alice", "write", "doc1", owner_proof)
shen.eval("(set shen.*maxinferences* " .. tostring(prev_max) .. ")")
expect("recovers after budget",true,  "alice", "write", "doc1", owner_proof)

print("\n== the guard itself (defense under the tokenizer) ==")
local function guard(label, want, ...)
  local got = facts.factq(...)
  io.write(("  %-30s %s\n"):format(label, got == want and "ok" or "FAIL"))
  if got ~= want then fail = fail + 1 end
end
facts.snapshot()   -- ensure the guard's view is current
guard("held fact",           true,  "owns", "alice", "doc1")
guard("grant pred refused",  false, "may", "carol", "doc1")      -- PRED_ALLOW
guard("slash injection",     false, "owns", "alice/doc1", "x")   -- key forgery
guard("non-string (pvar)",   false, "owns", {}, "doc1")          -- unbound var
guard("empty atom",          false, "owns", "", "doc1")

print("\n== intern regression: distinct hostile atoms stay bounded ==")
collectgarbage("collect"); collectgarbage("collect")
local kb0 = collectgarbage("count")
local denied = 0
for i = 1, 10000 do
  local a = app.check("intruder" .. i, "write", "doc1", owner_proof)
  if not a then denied = denied + 1 end
end
collectgarbage("collect"); collectgarbage("collect")
local grew = collectgarbage("count") - kb0
io.write(("  10k distinct-atom requests: %d denied, heap %+.0f KB\n"):format(denied, grew))
if denied ~= 10000 then fail = fail + 1; print("      FAIL: hostile atoms must all deny") end
if grew > 512 then fail = fail + 1; print("      FAIL: heap grew > 512 KB — atoms are leaking past the gate") end

print("\n== warm cost of checking (the whole per-request price) ==")
for _ = 1, 200 do app.check("carol", "write", "doc1", deleg_proof) end
local N = 2000
local t0 = os.clock()
for _ = 1, N do app.check("carol", "write", "doc1", deleg_proof) end
local us = (os.clock() - t0) * 1e6 / N
io.write(("  nested delegation vs live facts: %.0f us/check (%d inferences), ~%d checks/sec/core\n")
         :format(us, shen.value("shen.*infs*"), math.floor(1e6 / us)))

-- last, because it leaves the store corrupt: an undecodable blob must deny
-- reads AND make a mutation refuse (not silently reset the fact world).
print("\n== undecodable blob: reads deny, mutate refuses (no reset) ==")
facts._test.corrupt_blob()
if facts.snapshot() ~= nil then
  fail = fail + 1; print("      FAIL: corrupt blob must make snapshot() deny")
else
  print("  corrupt blob -> snapshot denies       ok")
end
local st = app.dispatch("POST", "/admin/grant", { pred = "owns", s = "alice", r = "doc9" })
if st == 200 then
  fail = fail + 1; print("      FAIL: mutate over a corrupt blob must refuse, not reset")
else
  print(("  mutate over corrupt blob -> HTTP %d    ok"):format(st))
end

if fail == 0 then print("\nOK — all checks passed")
else print(("\n%d check(s) FAILED"):format(fail)); os.exit(1) end
