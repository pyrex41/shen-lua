-- examples/pcr/selftest.lua — verify the live-facts proof-carrying gateway off-nginx.
--
--   luajit examples/pcr/selftest.lua                            (native engine)
--   SHEN_TYPECHECK_NATIVE=off luajit examples/pcr/selftest.lua  (parity leg)
--
-- Drives the SAME check() the edge gate uses (pure-Lua fact store fallback)
-- over the demo authority graph:
--
--   alice (human) owns crm-contacts
--     -> delegates (full) to orchestrator (her agent session)
--        -> delegates-read (ATTENUATED) to researcher (spawned subagent)
--
-- Covers: the allow cases including the three-hop agent chain, attenuation
-- enforced at the type layer (a read-only subagent cannot construct a write
-- proof), the REVOCATION WINDOW (revoking one delegation edge kills the
-- whole subtree built through it on the immediately-next check, surgically),
-- TTL facts, replica-mode staleness hard cap, every category of
-- hostile-input denial, an intern-growth regression, and a warm timing
-- loop. The parity leg must print IDENTICAL verdicts and inference counts —
-- that is the only guard against side-condition rules silently diverging
-- between the two engines.

local root = arg[0]:match("^(.*)/examples/pcr/[^/]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/examples/pcr/?.lua;" .. package.path

local app   = require("app")
local facts = app.facts
local shen  = require("shen")

local fail = 0
local function expect(label, want, subject, action, resource, proof)
  local authorized, reason = app.check(subject, action, resource, proof)
  io.write(("  %-34s %-5s  infs=%-4d %s\n"):format(label,
    authorized and "ALLOW" or "DENY", shen.value("shen.*infs*"), reason))
  if authorized ~= want then fail = fail + 1; print("      FAIL: expected " .. tostring(want)) end
end

-- assert a DENY whose reason contains a substring — used to prove *which
-- layer* denied (the type checker vs the pre-intern gate).
local function expect_reason(label, want_sub, subject, action, resource, proof)
  local authorized, reason = app.check(subject, action, resource, proof)
  local ok = (not authorized) and reason:find(want_sub, 1, true) ~= nil
  io.write(("  %-34s %-5s  %s\n"):format(label, authorized and "ALLOW" or "DENY", reason))
  if not ok then
    fail = fail + 1
    print("      FAIL: expected deny with reason containing: " .. want_sub)
  end
end

local function expect_admin(label, want_ok, path, body)
  local status, out = app.dispatch("POST", path, body)
  io.write(("  %-34s HTTP %-3d %s\n"):format(label, status, out.reason or out.error or "ok"))
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

-- the proofs: each principal's justification chain, as carried on the wire
local owner_proof  = "[by-owner [fact owns alice crm-contacts] [fact same-tenant alice crm-contacts]]"
local member_proof = "[by-member-read [fact has-role bob member] [fact same-tenant bob crm-contacts]]"
local agent_proof  = "[by-delegation " .. owner_proof .. " [fact delegates alice orchestrator]]"
local sub_proof    = "[by-read-delegation " .. agent_proof .. " [fact delegates-read orchestrator researcher]]"
-- what a compromised subagent WISHES it could present: a full-delegation
-- chain — the shape typechecks, but the fact leaf is decided by the store
local forged_full  = "[by-delegation " .. agent_proof .. " [fact delegates orchestrator researcher]]"

print("== proofs that check against the live fact world ==")
expect("human owner writes",           true, "alice", "write",  "crm-contacts", owner_proof)
expect("same proof, any action",       true, "alice", "delete", "crm-contacts", owner_proof)
expect("human member reads",           true, "bob",   "read",   "crm-contacts", member_proof)
expect("agent writes (delegated)",     true, "orchestrator", "write", "crm-contacts", agent_proof)
expect("subagent reads (3-hop chain)", true, "researcher",   "read",  "crm-contacts", sub_proof)

print("\n== attenuation: a read-only subagent cannot escalate ==")
-- delegates-read can only conclude (may T read R): there is no proof term
-- the researcher can construct for a write judgment from the facts it holds
expect("subagent write, own proof",    false, "researcher", "write", "crm-contacts", sub_proof)
expect("subagent write, forged chain", false, "researcher", "write", "crm-contacts", forged_full)
expect("subagent delete",              false, "researcher", "delete","crm-contacts", sub_proof)
expect("...its read still works",      true,  "researcher", "read",  "crm-contacts", sub_proof)

print("\n== the revocation window: identical bytes, next check ==")
-- kill the agent session's authority mid-run: the whole subtree built
-- through delegates/alice/orchestrator dies on the very next check
for round = 1, 3 do
  facts.revoke("delegates", "alice", "orchestrator")
  expect("agent revoked -> deny (round " .. round .. ")", false, "orchestrator", "write", "crm-contacts", agent_proof)
  expect("...subagent chain dies too",           false, "researcher", "read",  "crm-contacts", sub_proof)
  expect("...surgical: human unaffected",        true,  "alice",      "write", "crm-contacts", owner_proof)
  facts.grant("delegates", "alice", "orchestrator")
  expect("re-granted -> chain revives",          true,  "researcher", "read",  "crm-contacts", sub_proof)
end
-- the other end: revoke just the subagent's edge, the agent keeps working
facts.revoke("delegates-read", "orchestrator", "researcher")
expect("subagent edge revoked",   false, "researcher",   "read",  "crm-contacts", sub_proof)
expect("...agent unaffected",     true,  "orchestrator", "write", "crm-contacts", agent_proof)
facts.grant("delegates-read", "orchestrator", "researcher")
-- and the root: revoke alice's ownership, every chain on it dies
facts.revoke("owns", "alice", "crm-contacts")
expect("revoke root fact",        false, "alice",      "write", "crm-contacts", owner_proof)
expect("...kills chains on it",   false, "researcher", "read",  "crm-contacts", sub_proof)
facts.grant("owns", "alice", "crm-contacts")
expect("restore root fact",       true,  "alice",      "write", "crm-contacts", owner_proof)

-- a known principal whose delegated capability is revoked must deny at the
-- TYPE layer with the honest reason — not be rejected at the gate as an
-- unknown atom. This locks the admit() rework: fact-world atoms are always
-- admitted, so the researcher reaches the checker and fails there.
facts.revoke("delegates-read", "orchestrator", "researcher")
expect_reason("de-authorized, still known", "proof does not establish",
              "researcher", "read", "crm-contacts", sub_proof)
facts.grant("delegates-read", "orchestrator", "researcher")

print("\n== fact-store write failures fail closed ==")
local before = facts.snapshot()
local before_version = before.version
facts._test.simulate_write_failure = "simulated shared-dict full"
expect_admin("failed revoke reports", false, "/admin/revoke",
             { pred = "delegates", s = "alice", r = "orchestrator" })
expect("failed revoke keeps grant", true, "orchestrator", "write", "crm-contacts", agent_proof)
local after = facts.snapshot()
if after.version ~= before_version then
  fail = fail + 1
  print("      FAIL: failed revoke advanced fact version")
end

local temp_proof = "[by-delegation " .. owner_proof .. " [fact delegates alice temp-agent]]"
expect_admin("failed grant reports", false, "/admin/grant",
             { pred = "delegates", s = "alice", r = "temp-agent" })
expect("failed grant stays absent", false, "temp-agent", "write", "crm-contacts", temp_proof)
after = facts.snapshot()
if after.version ~= before_version then
  fail = fail + 1
  print("      FAIL: failed grant advanced fact version")
end

facts._test.simulate_write_failure = nil
expect_admin("grant recovers", true, "/admin/grant",
             { pred = "delegates", s = "alice", r = "temp-agent" })
expect("recovered grant allows", true, "temp-agent", "write", "crm-contacts", temp_proof)
expect_admin("revoke recovers", true, "/admin/revoke",
             { pred = "delegates", s = "alice", r = "temp-agent" })
expect("recovered revoke denies", false, "temp-agent", "write", "crm-contacts", temp_proof)

print("\n== TTL facts: a time-boxed agent needs no revoke call ==")
local real_now = facts.now
facts.grant("delegates", "alice", "oncall-agent", real_now() + 3600)   -- a one-hour session
expect("TTL delegation within window", true,  "oncall-agent", "write", "crm-contacts",
       "[by-delegation " .. owner_proof .. " [fact delegates alice oncall-agent]]")
facts.now = function() return real_now() + 7200 end   -- clock passes expiry
expect("TTL delegation expired",       false, "oncall-agent", "write", "crm-contacts",
       "[by-delegation " .. owner_proof .. " [fact delegates alice oncall-agent]]")
facts.now = real_now
facts.revoke("delegates", "alice", "oncall-agent")

print("\n== replica mode: staleness hard cap fails closed ==")
facts.mode = "replica"
expect("fresh replica allows",    true,  "alice", "write", "crm-contacts", owner_proof)
facts.now = function() return real_now() + 3 * facts.W + 1 end   -- sync ages past 3W
expect("stale replica denies all",false, "alice", "write", "crm-contacts", owner_proof)
facts.now = real_now
expect("recovers when fresh",     true,  "alice", "write", "crm-contacts", owner_proof)
facts.mode = "authoritative"

print("\n== denials: the proof is bound to the exact judgment ==")
expect("read proof, delete asked",  false, "bob", "delete", "crm-contacts", member_proof)
expect("spoof: alice's proof, bob", false, "bob", "write",  "crm-contacts", owner_proof)
expect("delegation chain broken",   false, "orchestrator", "read", "crm-contacts",
       "[by-delegation " .. member_proof .. " [fact delegates alice orchestrator]]")
expect("leaf asserts a grant",      false, "researcher", "write", "crm-contacts",
       "[fact may researcher write crm-contacts]")   -- pred allowlist: facts can't mint (may ...)

print("\n== denials: hostile input fails closed ==")
expect("no proof",            false, "alice", "write", "crm-contacts", nil)
expect("unreadable proof",    false, "alice", "write", "crm-contacts", "[by-owner [fact owns alice")
expect("smuggled judgment",   false, "bob", "delete", "crm-contacts",
       member_proof .. " : (may bob read crm-contacts)")
expect("judgment injection",  false, "crm-contacts) (may bob delete crm-contacts", "write", "crm-contacts", owner_proof)
expect("unknown subject",     false, "mallory", "write", "crm-contacts", owner_proof)
expect("unknown proof token", false, "alice", "write", "crm-contacts",
       "[by-owner [fact owns mallory crm-contacts] [fact same-tenant alice crm-contacts]]")
expect("oversized proof",     false, "alice", "write", "crm-contacts",
       "[by-owner " .. string.rep("[fact owns alice crm-contacts] ", 60) .. "]")
expect("unbound-var leaf",    false, "alice", "write", "crm-contacts",
       "[by-owner [fact owns X crm-contacts] [fact same-tenant alice crm-contacts]]")
facts.grant("owns", "S", "crm-contacts")   -- admit uppercase atoms into the fact world first
facts.grant("owns", "alice", "R")          -- the request gate must still reject them
facts.grant("owns", "alice", "A")          -- because Shen would read them as type variables
expect("uppercase subject",   false, "S",     "write", "crm-contacts", owner_proof)
expect("uppercase action",    false, "alice", "A",     "crm-contacts", owner_proof)
expect("uppercase resource",  false, "alice", "write", "R",            owner_proof)
expect("uppercase proof atom",false, "alice", "write", "crm-contacts",
       "[by-owner [fact owns S crm-contacts] [fact same-tenant alice crm-contacts]]")

-- a throwing fact store denies, and the next check recovers
local real_factq = facts.factq
facts.factq = function() error("db down") end
expect("store throws -> deny", false, "alice", "write", "crm-contacts", owner_proof)
facts.factq = real_factq
expect("recovers after throw", true,  "alice", "write", "crm-contacts", owner_proof)

-- a term needing more inferences than the budget fails closed, then recovers
local prev_max = shen.value("shen.*maxinferences*")
shen.eval("(set shen.*maxinferences* 1)")
expect("over budget",          false, "alice", "write", "crm-contacts", owner_proof)
shen.eval("(set shen.*maxinferences* " .. tostring(prev_max) .. ")")
expect("recovers after budget",true,  "alice", "write", "crm-contacts", owner_proof)

print("\n== the guard itself (defense under the tokenizer) ==")
local function guard(label, want, ...)
  local got = facts.factq(...)
  io.write(("  %-34s %s\n"):format(label, got == want and "ok" or "FAIL"))
  if got ~= want then fail = fail + 1 end
end
facts.snapshot()   -- ensure the guard's view is current
guard("held fact",           true,  "owns", "alice", "crm-contacts")
guard("grant pred refused",  false, "may", "researcher", "crm-contacts")   -- PRED_ALLOW
guard("slash injection",     false, "owns", "alice/crm-contacts", "x")     -- key forgery
guard("non-string (pvar)",   false, "owns", {}, "crm-contacts")            -- unbound var
guard("empty atom",          false, "owns", "", "crm-contacts")

print("\n== intern regression: distinct hostile atoms stay bounded ==")
collectgarbage("collect"); collectgarbage("collect")
local kb0 = collectgarbage("count")
local denied = 0
for i = 1, 10000 do
  local a = app.check("intruder" .. i, "write", "crm-contacts", owner_proof)
  if not a then denied = denied + 1 end
end
collectgarbage("collect"); collectgarbage("collect")
local grew = collectgarbage("count") - kb0
io.write(("  10k distinct-atom requests: %d denied, heap %+.0f KB\n"):format(denied, grew))
if denied ~= 10000 then fail = fail + 1; print("      FAIL: hostile atoms must all deny") end
if grew > 512 then fail = fail + 1; print("      FAIL: heap grew > 512 KB — atoms are leaking past the gate") end

print("\n== warm cost of checking (the whole per-request price) ==")
for _ = 1, 200 do app.check("researcher", "read", "crm-contacts", sub_proof) end
local N = 2000
local t0 = os.clock()
for _ = 1, N do app.check("researcher", "read", "crm-contacts", sub_proof) end
local us = (os.clock() - t0) * 1e6 / N
io.write(("  three-hop agent chain vs live facts: %.0f us/check (%d inferences), ~%d checks/sec/core\n")
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
local st = app.dispatch("POST", "/admin/grant", { pred = "owns", s = "alice", r = "crm-notes" })
if st == 200 then
  fail = fail + 1; print("      FAIL: mutate over a corrupt blob must refuse, not reset")
else
  print(("  mutate over corrupt blob -> HTTP %d    ok"):format(st))
end

if fail == 0 then print("\nOK — all checks passed")
else print(("\n%d check(s) FAILED"):format(fail)); os.exit(1) end
