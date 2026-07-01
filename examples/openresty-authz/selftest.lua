-- examples/openresty-authz/selftest.lua — drive the authz app off-nginx.
--
--   luajit examples/openresty-authz/selftest.lua      (from the repo root)
--
-- Boots the same app.lua the server uses, wires a FILE-backed durable store,
-- and runs the multi-tenant policy through app.dispatch(). Then it reopens the
-- store from the same on-disk log (a simulated crash/restart) to show that the
-- facts AND the audit trail survive replay — the durable-execution property.

local root = arg[0]:match("^(.*)/examples/openresty%-authz/[^/]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/examples/openresty-authz/?.lua;" .. package.path

local app   = require("app")
local Store = require("store")
local cjson = app.json

local logpath = os.tmpname(); os.remove(logpath)
local function open_store() return Store.new{ codec = cjson, backend = "file", path = logpath } end

-- ---- test harness -----------------------------------------------------------
local fail = 0
local function req(method, path, body)
  local status, resp = app.dispatch(method, path, body)
  return status, resp
end
local function expect(label, want, method, path, body)
  local status, resp = req(method, path, body)
  local note = resp and (resp.error or (resp.ok and resp.content) or "") or ""
  print(("  %-38s -> %d  %s"):format(label, status, note ~= "" and ("(" .. note .. ")") or ""))
  if status ~= want then fail = fail + 1; print(("      FAIL: expected %d"):format(want)) end
  return resp
end

-- ---- bootstrap identities (tokens -> users) + admin ------------------------
local s = open_store()
s.seed_token("tok-admin", "admin", true)
s.seed_token("tok-alice", "alice", false)
s.seed_token("tok-bob",   "bob",   false)
s.seed_token("tok-carol", "carol", false)
app.use_store(s)

print("== provision tenants, docs, memberships (admin) ==")
expect("create acme/doc-1",   200, "POST", "/api/admin/create",
       { token = "tok-admin", tenant = "acme",   resource = "doc-1", content = "acme launch plan" })
expect("create globex/doc-2", 200, "POST", "/api/admin/create",
       { token = "tok-admin", tenant = "globex", resource = "doc-2", content = "globex roadmap" })
expect("grant alice editor@acme", 200, "POST", "/api/admin/grant",
       { token = "tok-admin", user = "alice", tenant = "acme", role = "editor" })
expect("grant bob viewer@acme",   200, "POST", "/api/admin/grant",
       { token = "tok-admin", user = "bob",   tenant = "acme", role = "viewer" })
expect("non-admin cannot grant",  403, "POST", "/api/admin/grant",
       { token = "tok-alice", user = "carol", tenant = "acme", role = "editor" })

print("\n== the proof chain: token -> user -> tenant -> resource ==")
expect("alice reads acme doc",     200, "POST", "/api/read",  { token = "tok-alice", resource = "doc-1" })
expect("bob (viewer) reads acme",  200, "POST", "/api/read",  { token = "tok-bob",   resource = "doc-1" })
expect("carol (no member) denied", 403, "POST", "/api/read",  { token = "tok-carol", resource = "doc-1" })
expect("alice denied cross-tenant",403, "POST", "/api/read",  { token = "tok-alice", resource = "doc-2" })
expect("bad token unauthenticated",403, "POST", "/api/read",  { token = "nope",      resource = "doc-1" })
expect("unknown resource",         403, "POST", "/api/read",  { token = "tok-alice", resource = "doc-404" })

print("\n== write needs the editor role ==")
expect("alice (editor) writes",    200, "POST", "/api/write", { token = "tok-alice", resource = "doc-1", content = "edited by alice" })
expect("bob (viewer) cannot write",403, "POST", "/api/write", { token = "tok-bob",   resource = "doc-1", content = "bob was here" })

print("\n== revocation (a deny that overrides membership) ==")
expect("revoke bob's access",      200, "POST", "/api/admin/revoke", { token = "tok-admin", user = "bob", resource = "doc-1" })
expect("bob now denied (revoked)", 403, "POST", "/api/read",  { token = "tok-bob", resource = "doc-1" })
expect("alice still reads",        200, "POST", "/api/read",  { token = "tok-alice", resource = "doc-1" })

-- ---- durable execution: reopen from the on-disk log, replay, same state -----
print("\n== durable execution: simulate a restart (reopen + replay the log) ==")
local seq_before = s.seq()
local s2 = open_store()            -- brand-new store object, same log file
app.use_store(s2)
print(("  replayed %d events from the log into a fresh process"):format(s2.seq()))
if s2.seq() ~= seq_before then fail = fail + 1; print("      FAIL: replayed seq mismatch") end
expect("alice reads after restart", 200, "POST", "/api/read", { token = "tok-alice", resource = "doc-1" })
expect("revocation survived restart",403,"POST", "/api/read", { token = "tok-bob",   resource = "doc-1" })

-- ---- the durable proof log (discharge reports) ------------------------------
print("\n== GET /api/audit — the durable decision log ==")
local _, audit = req("GET", "/api/audit")
for _, row in ipairs(audit.log or {}) do
  print(("  #%-2d %-6s %-6s %-7s %-6s %s"):format(
    row.seq, row.user, row.action, row.resource, row.decision, row.reason))
end

if fail == 0 then print("\nOK — all cases passed")
else print(("\n%d case(s) FAILED"):format(fail)); os.exit(1) end
