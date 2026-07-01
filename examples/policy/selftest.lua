-- examples/policy/selftest.lua — verify the authorization demo off-nginx.
--
--   luajit examples/policy/selftest.lua      (from the repo root)
--
-- Drives the SAME decide() the edge gate uses over a table of requests, then
-- loads policy_proof.shen under (tc +) to confirm the "permission is a proof"
-- terms typecheck. No nginx, no network.

local root = arg[0]:match("^(.*)/examples/policy/[^/]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/examples/policy/?.lua;" .. package.path

local app  = require("app")
local shen = require("shen")

local fail = 0
local function expect(label, want, principal, action, resource)
  local allowed, reason = app.check(principal, action, resource)
  io.write(("  %-22s %-5s  %s\n"):format(label, allowed and "ALLOW" or "DENY", reason))
  if allowed ~= want then fail = fail + 1; print("      FAIL: expected " .. tostring(want)) end
end

local alice  = { name = "ada",  role = "member", tenant = "t1" }
local boss   = { name = "boss", role = "admin",  tenant = "t1" }
local viewer = { name = "viv",  role = "viewer", tenant = "t1" }
local other  = { name = "boss", role = "admin",  tenant = "t2" }
local doc    = { owner = "ada", tenant = "t1" }

print("== decisions (the rules the edge gate enforces) ==")
expect("owner writes own",  true,  alice,  "write",  doc)
expect("admin deletes",     true,  boss,   "delete", doc)
expect("viewer reads",      true,  viewer, "read",   doc)
expect("viewer writes",     false, viewer, "write",  doc)
expect("member deletes",    false, { name="bob", role="member", tenant="t1" }, "delete", doc)
expect("cross-tenant admin",false, other,  "read",   doc)

print("\n== permission-as-proof (tier c, type inhabitation) ==")
shen.eval("(tc +)")
local ok = pcall(shen.prims.F["load"], root .. "/examples/policy/policy_proof.shen")
shen.eval("(tc -)")
io.write(("  %-44s %s\n"):format("policy_proof.shen loads => proofs check", ok and "ok" or "FAIL"))
if not ok then fail = fail + 1 end

if fail == 0 then print("\nOK — all checks passed")
else print(("\n%d check(s) FAILED"):format(fail)); os.exit(1) end
