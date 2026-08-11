-- examples/envoy/selftest.lua — the three-layer pipeline, off-Envoy/off-nginx.
--
--   luajit examples/envoy/selftest.lua      (from the repo root)
--
-- One luajit process plays Envoy's part and chains the REAL pieces in Envoy's
-- exact filter order:
--
--   1. ext_authz   -> the real authz app (examples/openresty-authz): the
--                     Prolog proof chain decides on method + path + token,
--                     appending every decision to the durable audit log.
--   2. lua filter  -> the real filter.lua, driven through a faithful fake of
--                     Envoy's request_handle (headers/body/respond): the typed
--                     rules.shen rejects malformed bodies at the "edge".
--   3. upstream    -> a 10-line stand-in for the guestbook (the real one is
--                     exercised by examples/openresty/selftest.lua; only
--                     requests that survived BOTH gates ever reach it).
--
-- Both Shen loads happen in this one process — filter.lua boots the kernel
-- and loads rules.shen (tc +), then the authz app loads authz.shen (tc +) and
-- app.shen — which is exactly what makes the shared-environment story
-- testable without Envoy or nginx.

local root = arg[0]:match("^(.*)/examples/envoy/[^/]+$") or "."
package.path = root .. "/?.lua;"
            .. root .. "/examples/openresty-authz/?.lua;" .. package.path

-- ---- layer 2: the edge — filter.lua defines envoy_on_request ----------------
dofile(root .. "/examples/envoy/filter.lua")
assert(type(envoy_on_request) == "function", "filter.lua did not define envoy_on_request")

-- ---- layer 1: the authz service (real app + durable store) ------------------
local app   = require("app")            -- examples/openresty-authz/app.lua
local Store = require("store")
local cjson = app.json

local log_path = os.tmpname(); os.remove(log_path)
local store = Store.new{ codec = cjson, backend = "file", path = log_path }
-- the same world authz.conf seeds
store.seed_token("tok-admin", "admin", true)
store.seed_token("tok-alice", "alice", false)
store.seed_token("tok-bob",   "bob",   false)
store.seed_token("tok-carol", "carol", false)
store.create("acme", "guestbook", "guestbook access marker")
store.grant("alice", "acme", "editor")
store.grant("bob",   "acme", "viewer")
app.use_store(store)

-- ---- layer 3: the guestbook upstream (stand-in) ------------------------------
local rows = {}
local function upstream(method, path, body)
  if method == "GET"  and path == "/api/messages" then
    return 200, { messages = rows }
  end
  if method == "POST" and path == "/api/messages" then
    rows[#rows + 1] = { name = body.name, message = body.message }
    return 201, { ok = true }
  end
  return 404, { error = "not found" }
end

-- ---- a faithful fake of Envoy's request_handle ------------------------------
-- Speaks exactly the surface filter.lua uses: headers():get/add, body():
-- length/getBytes, respond(headers, body).
local function fake_handle(method, path, raw_body)
  local hdrs, added, responded = { [":method"] = method, [":path"] = path }, {}, nil
  local h = {}
  function h:headers()
    return {
      get = function(_, k) return hdrs[k] end,
      add = function(_, k, v) added[k] = v end,
    }
  end
  function h:body()
    if not raw_body or raw_body == "" then return nil end
    return {
      length   = function() return #raw_body end,
      getBytes = function(_, off, len) return raw_body:sub(off + 1, off + len) end,
    }
  end
  function h:respond(headers, body) responded = { headers = headers, body = body } end
  function h:logInfo() end
  return h, function() return responded end, added
end

-- ---- "Envoy": the filter chain, in envoy.yaml's order ------------------------
-- Returns status, decoded body, the stage that produced the response, and the
-- headers the Lua filter added to a request it let through.
local function through_envoy(method, path, token, body_tbl, raw_override)
  -- 1. ext_authz: Envoy forwards "<method> /authz<path>" + the authorization
  --    header; app.lua's glue turns that into (route "CHECK" Path ...).
  local astatus, aresp = app.dispatch("CHECK", path:match("^[^?]*"),
                                      { token = token or "", method = method })
  if astatus ~= 200 then return astatus, aresp, "ext_authz", {} end
  -- 2. the Lua filter (filter.lua, for real)
  local raw = raw_override or (body_tbl and cjson.encode(body_tbl)) or nil
  local h, responded, added = fake_handle(method, path, raw)
  envoy_on_request(h)
  local r = responded()
  if r then return tonumber(r.headers[":status"]), cjson.decode(r.body), "lua-filter", added end
  -- 3. the upstream
  local ustatus, ubody = upstream(method, path:match("^[^?]*"), body_tbl)
  return ustatus, ubody, "upstream", added
end

-- ---- the scenario -------------------------------------------------------------
local fail = 0
local last_resp, last_added
local function expect(label, want_status, want_stage, method, path, token, body, raw)
  local status, resp, stage, added = through_envoy(method, path, token, body, raw)
  last_resp, last_added = resp, added
  local note = resp and (resp.error or (resp.errors and table.concat(resp.errors, "; "))) or ""
  print(("  %-40s -> %d @ %-9s %s"):format(label, status, stage,
                                           note ~= "" and ("(" .. note .. ")") or ""))
  if status ~= want_status or stage ~= want_stage then
    fail = fail + 1
    print(("      FAIL: expected %d @ %s"):format(want_status, want_stage))
  end
  return resp
end
local function check(label, cond)
  print("  " .. (cond and "ok  " or "FAIL") .. " " .. label)
  if not cond then fail = fail + 1 end
end

print("== gate 1: the proof chain holds the edge (ext_authz) ==")
expect("no token",                    403, "ext_authz", "GET",  "/api/messages")
expect("carol: not a member",         403, "ext_authz", "GET",  "/api/messages", "tok-carol")
expect("bad token",                   403, "ext_authz", "GET",  "/api/messages", "tok-nope")
expect("unmapped path fails closed",  403, "ext_authz", "GET",  "/api/nope",     "tok-alice")
expect("bob (viewer) may read",       200, "upstream",  "GET",  "/api/messages", "tok-bob")
expect("bob (viewer) may NOT post",   403, "ext_authz", "POST", "/api/messages", "tok-bob",
       { name = "bob", message = "hi" })

print("\n== gate 2: typed rules.shen at the edge (the Lua filter) ==")
expect("alice posts, missing name",   400, "lua-filter", "POST", "/api/messages", "tok-alice",
       { message = "anon" })
check("edge error == the origin's typed string",
      last_resp.errors and last_resp.errors[1] == "name: is required")
expect("alice posts, blank message",  400, "lua-filter", "POST", "/api/messages", "tok-alice",
       { name = "ada", message = "" })
check("edge error == the origin's typed string",
      last_resp.errors and last_resp.errors[1] == "message: must be 1..280 characters")
expect("alice posts a non-object",    400, "lua-filter", "POST", "/api/messages", "tok-alice",
       { "not", "an", "object" })
check("edge error == the origin's typed string",
      last_resp.errors and last_resp.errors[1] == "body: must be a JSON object")
expect("alice posts broken JSON",     400, "lua-filter", "POST", "/api/messages", "tok-alice",
       nil, "{ definitely not json")
check("edge names the parse failure",
      last_resp.errors and last_resp.errors[1]:find("^invalid JSON") ~= nil)

print("\n== what survives both gates reaches the guestbook ==")
expect("alice posts a valid entry",   201, "upstream",  "POST", "/api/messages", "tok-alice",
       { name = "ada", message = "through the edge" })
check("the Lua filter stamped x-shen-edge: validated", last_added["x-shen-edge"] == "validated")
expect("alice reads it back",         200, "upstream",  "GET",  "/api/messages", "tok-alice")
check("one row stored upstream", #rows == 1 and rows[1].name == "ada")

print("\n== revocation: durable state changes the edge's answer ==")
local rstatus = app.dispatch("POST", "/api/admin/revoke",
                             { token = "tok-admin", user = "alice", resource = "guestbook" })
check("admin revokes alice (direct API)", rstatus == 200)
expect("alice now denied at the edge",403, "ext_authz", "GET",  "/api/messages", "tok-alice")

print("\n== every edge decision is in the durable audit log ==")
local _, audit = app.dispatch("POST", "/api/admin/audit", { token = "tok-admin" })
local edge_rows = {}
for _, row in ipairs((audit and audit.log) or {}) do
  if row.resource == "guestbook" or row.resource == "" then
    edge_rows[#edge_rows + 1] = row
    print(("  #%-2d %-6s %-6s %-10s %-6s %s"):format(
      row.seq, row.user, row.action, row.resource, row.decision, row.reason))
  end
end
check("the log holds the whole session (13 edge decisions)", #edge_rows == 13)

if fail == 0 then print("\nOK — all cases passed (ext_authz + Lua filter + upstream)")
else print(("\n%d case(s) FAILED"):format(fail)); os.exit(1) end
