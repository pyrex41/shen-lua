-- examples/openresty-authz/selftest.lua — drive the authz app off-nginx.
--
--   luajit examples/openresty-authz/selftest.lua      (from the repo root)
--
-- Boots the same app.lua the server uses and runs the full multi-tenant policy
-- through app.dispatch() against BOTH store backends:
--
--   * file : append-only JSONL on disk.
--   * lmdb : the lua-resty-lmdb adapter, exercised in-process against a faithful
--            fake of resty.lmdb (get + transaction commit) so the SAME store.lua
--            code path is tested here, no OpenResty required.
--
-- Each run reopens the store from its own durable log (a simulated restart) to
-- show facts AND the audit trail survive replay, and the two runs are asserted
-- to produce an identical audit trail — same interface, same behavior.

local root = arg[0]:match("^(.*)/examples/openresty%-authz/[^/]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/examples/openresty-authz/?.lua;" .. package.path

local app   = require("app")
local Store = require("store")
local cjson = app.json

-- ---- a faithful in-process fake of lua-resty-lmdb --------------------------
-- Implements exactly the surface store.lua's lmdb backend uses: resty.lmdb.get
-- and resty.lmdb.transaction.begin()/:set()/:commit(). The KV table stands in
-- for the memory-mapped environment: it persists across Store.new() calls, so
-- "reopen + replay" tests real durability the same way the on-disk file does.
local function install_fake_lmdb()
  local kv = {}
  package.loaded["resty.lmdb"] = { get = function(k) return kv[k] end }
  package.loaded["resty.lmdb.transaction"] = {
    begin = function()
      local buf = {}
      return {
        set    = function(_, k, v) buf[#buf + 1] = { k, v }; return true end,
        commit = function(_) for _, p in ipairs(buf) do kv[p[1]] = p[2] end; return true end,
      }
    end,
  }
end

-- ---- test harness -----------------------------------------------------------
local function req(method, path, body) return app.dispatch(method, path, body) end

-- run the whole scenario against one backend; returns (fail_count, audit_rows)
local function run_scenario(title, open_store)
  print("\n########## " .. title .. " ##########")
  local fail = 0
  local function expect(label, want, method, path, body)
    local status, resp = req(method, path, body)
    local note = resp and (resp.error or (resp.ok and resp.content) or "") or ""
    print(("  %-38s -> %d  %s"):format(label, status, note ~= "" and ("(" .. note .. ")") or ""))
    if status ~= want then fail = fail + 1; print(("      FAIL: expected %d"):format(want)) end
    return resp
  end

  -- bootstrap identities (tokens -> users) + admin, then wire the store
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
  expect("alice reads acme doc",     200, "POST", "/api/read", { token = "tok-alice", resource = "doc-1" })
  expect("bob (viewer) reads acme",  200, "POST", "/api/read", { token = "tok-bob",   resource = "doc-1" })
  expect("carol (no member) denied", 403, "POST", "/api/read", { token = "tok-carol", resource = "doc-1" })
  expect("alice denied cross-tenant",403, "POST", "/api/read", { token = "tok-alice", resource = "doc-2" })
  expect("bad token unauthenticated",403, "POST", "/api/read", { token = "nope",      resource = "doc-1" })
  expect("unknown resource",         403, "POST", "/api/read", { token = "tok-alice", resource = "doc-404" })

  print("\n== write needs the editor role ==")
  expect("alice (editor) writes",    200, "POST", "/api/write", { token = "tok-alice", resource = "doc-1", content = "edited by alice" })
  expect("bob (viewer) cannot write",403, "POST", "/api/write", { token = "tok-bob",   resource = "doc-1", content = "bob was here" })

  print("\n== revocation (a deny that overrides membership) ==")
  expect("revoke bob's access",      200, "POST", "/api/admin/revoke", { token = "tok-admin", user = "bob", resource = "doc-1" })
  expect("bob now denied (revoked)", 403, "POST", "/api/read", { token = "tok-bob",   resource = "doc-1" })
  expect("alice still reads",        200, "POST", "/api/read", { token = "tok-alice", resource = "doc-1" })

  print("\n== durable execution: simulate a restart (reopen + replay the log) ==")
  local seq_before = s.seq()
  local s2 = open_store()             -- brand-new store object, same durable log
  app.use_store(s2)
  print(("  replayed %d events into a fresh process"):format(s2.seq()))
  if s2.seq() ~= seq_before then fail = fail + 1; print("      FAIL: replayed seq mismatch") end
  expect("alice reads after restart",  200, "POST", "/api/read", { token = "tok-alice", resource = "doc-1" })
  expect("revocation survived restart",403, "POST", "/api/read", { token = "tok-bob",   resource = "doc-1" })

  local _, audit = req("GET", "/api/audit")
  return fail, (audit and audit.log) or {}
end

-- ---- backends ---------------------------------------------------------------
local function file_open()
  local path = os.tmpname(); os.remove(path)
  return function() return Store.new{ codec = cjson, backend = "file", path = path } end
end
local function lmdb_open()
  install_fake_lmdb()
  return function() return Store.new{ codec = cjson, backend = "lmdb" } end
end

local fail = 0
local f_fail, f_audit = run_scenario("file backend", file_open())
local l_fail, l_audit = run_scenario("lua-resty-lmdb backend (in-process fake)", lmdb_open())
fail = f_fail + l_fail

-- the two backends must agree, decision for decision
print("\n########## backend parity ##########")
local function audit_key(rows)
  local t = {}
  for i, r in ipairs(rows) do
    t[i] = table.concat({ r.seq, r.user, r.action, r.resource, r.decision, r.reason }, "|")
  end
  return table.concat(t, "\n")
end
if audit_key(f_audit) == audit_key(l_audit) then
  print(("  OK — identical %d-decision audit trail from both backends"):format(#f_audit))
else
  fail = fail + 1; print("  FAIL: backends produced different audit trails")
end

print("\n== the durable proof log (from the lmdb run) ==")
for _, row in ipairs(l_audit) do
  print(("  #%-2d %-6s %-6s %-7s %-6s %s"):format(
    row.seq, row.user, row.action, row.resource, row.decision, row.reason))
end

if fail == 0 then print("\nOK — all cases passed (both backends)")
else print(("\n%d case(s) FAILED"):format(fail)); os.exit(1) end
