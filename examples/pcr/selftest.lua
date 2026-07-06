-- examples/pcr/selftest.lua — verify the proof-carrying-request gateway off-nginx.
--
--   luajit examples/pcr/selftest.lua      (from the repo root)
--
-- Drives the SAME check() the edge gate uses: the allow cases (including a
-- nested delegation proof), every category of denial — no proof, wrong rule,
-- a spoofed proof bound to someone else's judgment, judgment injection, proof
-- smuggling, oversized and over-budget terms — and a warm timing loop.
-- No nginx, no network.

local root = arg[0]:match("^(.*)/examples/pcr/[^/]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/examples/pcr/?.lua;" .. package.path

local app  = require("app")
local shen = require("shen")

local fail = 0
local function expect(label, want, subject, action, resource, proof)
  local authorized, reason = app.check(subject, action, resource, proof)
  io.write(("  %-28s %-5s  %s\n"):format(label, authorized and "ALLOW" or "DENY", reason))
  if authorized ~= want then fail = fail + 1; print("      FAIL: expected " .. tostring(want)) end
end

local owner_proof  = "[by-owner [owns-fact] [alice-tenant]]"
local member_proof = "[by-member-read [member-fact] [tenant-fact]]"
local deleg_proof  = "[by-delegation " .. owner_proof .. " [deleg-fact]]"

print("== proofs that check ==")
expect("owner writes",           true, "alice", "write",  "doc1", owner_proof)
expect("same proof, any action", true, "alice", "delete", "doc1", owner_proof)
expect("member reads",           true, "bob",   "read",   "doc1", member_proof)
expect("delegate writes",        true, "carol", "write",  "doc1", deleg_proof)

print("\n== denials: the proof is bound to the exact judgment ==")
expect("read proof, delete asked",  false, "bob",   "delete", "doc1", member_proof)
expect("spoof: alice's proof, bob", false, "bob",   "write",  "doc1", owner_proof)
expect("delegation chain broken",   false, "carol", "read",   "doc1",
       "[by-delegation " .. member_proof .. " [deleg-fact]]")

print("\n== denials: hostile input fails closed ==")
expect("no proof",           false, "alice", "write", "doc1", nil)
expect("unreadable proof",   false, "alice", "write", "doc1", "[by-owner [owns-fact")
expect("smuggled judgment",  false, "bob", "delete", "doc1",
       member_proof .. " : (may bob read doc1)")   -- extra forms: shape check trips
expect("judgment injection", false, "doc1) (may bob delete doc1", "write", "doc1", owner_proof)
expect("oversized proof",    false, "alice", "write", "doc1",
       "[by-owner " .. string.rep("[owns-fact] ", 200) .. "]")

-- a term needing more inferences than the budget fails closed, and the next
-- check recovers (shen.typecheck resets the counter per call)
local prev_max = shen.value("shen.*maxinferences*")
shen.eval("(set shen.*maxinferences* 1)")
expect("over budget",        false, "alice", "write", "doc1", owner_proof)
shen.eval("(set shen.*maxinferences* " .. tostring(prev_max) .. ")")
expect("recovers after budget", true, "alice", "write", "doc1", owner_proof)

print("\n== warm cost of checking (this is the whole per-request price) ==")
for _ = 1, 200 do app.check("carol", "write", "doc1", deleg_proof) end   -- warmup
local N = 2000
local t0 = os.clock()
for _ = 1, N do app.check("carol", "write", "doc1", deleg_proof) end
local us = (os.clock() - t0) * 1e6 / N
io.write(("  nested delegation proof: %.0f us/check (%d inferences), ~%d checks/sec/core\n")
         :format(us, shen.value("shen.*infs*"), math.floor(1e6 / us)))

if fail == 0 then print("\nOK — all checks passed")
else print(("\n%d check(s) FAILED"):format(fail)); os.exit(1) end
