-- examples/openresty-authz/selftest.lua — drive the authz app off-nginx.
--
--   luajit examples/openresty-authz/selftest.lua      (from the repo root)
--
-- Boots the same app.lua the server uses and runs the full multi-tenant policy
-- through app.dispatch() against BOTH store backends (file + the lua-resty-lmdb
-- adapter, faked in-process), then a THIRD time with identity resolved over a
-- cosocket (ngx.socket.tcp, also faked in-process) to a Redis-style session
-- store. All three must produce an identical, decision-for-decision audit trail
-- — same policy, different I/O substrates.

local root = arg[0]:match("^(.*)/examples/openresty%-authz/[^/]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/examples/openresty-authz/?.lua;" .. package.path

local app   = require("app")
local Store = require("store")
local Auth  = require("auth")
local cjson = app.json

-- ---- a faithful in-process fake of lua-resty-lmdb --------------------------
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

-- ---- a faithful in-process fake of ngx.socket.tcp + a Redis-RESP server ------
-- Speaks exactly the surface auth.lua's redis_get uses: settimeout, connect,
-- send, receive("*l")/receive(n), setkeepalive. Records how many times a socket
-- actually connects, so the test can prove the shared-dict cache elides
-- round-trips.
local sock_stats
local function install_fake_cosocket(tokens)
  local records = {}
  for tok, user in pairs(tokens) do records["auth:" .. tok] = user end
  sock_stats = { connects = 0 }
  _G.ngx = _G.ngx or {}
  ngx.ERR = ngx.ERR or "err"
  ngx.log = ngx.log or function() end
  ngx.socket = { tcp = function()
    local s = { buf = "" }
    function s:settimeout() end
    function s:connect() sock_stats.connects = sock_stats.connects + 1; return 1 end
    function s:send(req)
      local key = req:match("(auth:[^\r]+)\r\n$")   -- last bulk string = the key
      local v = key and records[key]
      s.buf = v and (("$%d\r\n%s\r\n"):format(#v, v)) or "$-1\r\n"
      return #req
    end
    function s:receive(pat)
      if pat == "*l" then
        local l, rest = s.buf:match("^([^\r]*)\r\n(.*)$")
        s.buf = rest or ""; return l
      end
      local d = s.buf:sub(1, pat); s.buf = s.buf:sub(pat + 1); return d
    end
    function s:setkeepalive() return 1 end
    function s:close() return 1 end
    return s
  end }
end
local function fake_cache()
  local kv = {}
  return { get = function(_, k) return kv[k] end, set = function(_, k, v) kv[k] = v end }
end

-- ---- test harness -----------------------------------------------------------
local function req(method, path, body) return app.dispatch(method, path, body) end

-- run the whole scenario against one store backend + identity resolver.
-- make_auth(store) -> resolver, applied on the initial store and again after the
-- simulated restart. Returns (fail_count, audit_rows).
local function run_scenario(title, open_store, make_auth)
  print("\n########## " .. title .. " ##########")
  local fail = 0
  local function expect(label, want, method, path, body)
    local status, resp = req(method, path, body)
    local note = resp and (resp.error or (resp.ok and resp.content) or "") or ""
    print(("  %-38s -> %d  %s"):format(label, status, note ~= "" and ("(" .. note .. ")") or ""))
    if status ~= want then fail = fail + 1; print(("      FAIL: expected %d"):format(want)) end
    return resp
  end

  local s = open_store()
  s.seed_token("tok-admin", "admin", true)
  s.seed_token("tok-alice", "alice", false)
  s.seed_token("tok-bob",   "bob",   false)
  s.seed_token("tok-carol", "carol", false)
  app.use_store(s); app.use_auth(make_auth(s))

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
  app.use_store(s2); app.use_auth(make_auth(s2))
  print(("  replayed %d events into a fresh process"):format(s2.seq()))
  if s2.seq() ~= seq_before then fail = fail + 1; print("      FAIL: replayed seq mismatch") end
  expect("alice reads after restart",  200, "POST", "/api/read", { token = "tok-alice", resource = "doc-1" })
  expect("revocation survived restart",403, "POST", "/api/read", { token = "tok-bob",   resource = "doc-1" })

  local _, audit = req("GET", "/api/audit")
  return fail, (audit and audit.log) or {}
end

-- ---- backends + resolvers ---------------------------------------------------
local function file_open()
  local path = os.tmpname(); os.remove(path)
  return function() return Store.new{ codec = cjson, backend = "file", path = path } end
end
local function lmdb_open()
  install_fake_lmdb()
  return function() return Store.new{ codec = cjson, backend = "lmdb" } end
end
local function local_auth(s)
  return Auth.local_resolver(function(t) return s.token_user(t) end)
end
local REDIS = { host = "127.0.0.1", port = 6379 }
local function cosocket_auth(s)
  return Auth.cosocket_resolver{ redis = REDIS, cache = fake_cache(), ttl = 5,
                                 fallback = function(t) return s.token_user(t) end }
end

local fail = 0
local f_fail, f_audit = run_scenario("file backend, local identity", file_open(), local_auth)
local l_fail, l_audit = run_scenario("lua-resty-lmdb backend, local identity", lmdb_open(), local_auth)
fail = f_fail + l_fail

-- ---- cosocket unit check: one round-trip, then cached -----------------------
print("\n########## cosocket identity resolver (ngx.socket.tcp fake) ##########")
install_fake_cosocket{ ["tok-admin"]="admin", ["tok-alice"]="alice",
                       ["tok-bob"]="bob", ["tok-carol"]="carol" }
do
  local r = Auth.cosocket_resolver{ redis = REDIS, cache = fake_cache(), ttl = 5,
                                    fallback = function() return "" end }
  local function check(label, cond) print("  " .. (cond and "ok  " or "FAIL") .. " " .. label)
                                     if not cond then fail = fail + 1 end end
  local u1 = r.token_user("tok-alice"); check("resolves tok-alice -> alice over cosocket", u1 == "alice")
  check("one connect for the first lookup", sock_stats.connects == 1)
  local u2 = r.token_user("tok-alice"); check("second lookup served from cache (no reconnect)",
                                              u2 == "alice" and sock_stats.connects == 1)
  local u3 = r.token_user("nope");      check("missing key -> '' (Redis $-1 path)",
                                              u3 == "" and sock_stats.connects == 2)
end

-- ---- cosocket end-to-end: whole policy with identity over the cosocket ------
local c_fail, c_audit = run_scenario("file backend, opaque-token identity over a cosocket (opt-in)", file_open(), cosocket_auth)
fail = fail + c_fail

-- ---- all three substrates must agree, decision for decision -----------------
print("\n########## backend parity ##########")
local function audit_key(rows)
  local t = {}
  for i, r in ipairs(rows) do
    t[i] = table.concat({ r.seq, r.user, r.action, r.resource, r.decision, r.reason }, "|")
  end
  return table.concat(t, "\n")
end
local kf, kl, kc = audit_key(f_audit), audit_key(l_audit), audit_key(c_audit)
if kf == kl and kl == kc then
  print(("  OK — identical %d-decision audit trail from file, lmdb, and cosocket runs"):format(#f_audit))
else
  fail = fail + 1; print("  FAIL: substrates produced different audit trails")
end

print("\n== the durable proof log (from the cosocket run) ==")
for _, row in ipairs(c_audit) do
  print(("  #%-2d %-6s %-6s %-7s %-6s %s"):format(
    row.seq, row.user, row.action, row.resource, row.decision, row.reason))
end

if fail == 0 then print("\nOK — all cases passed (file + lmdb + cosocket)")
else print(("\n%d case(s) FAILED"):format(fail)); os.exit(1) end
