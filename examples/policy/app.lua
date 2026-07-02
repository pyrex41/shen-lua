-- examples/policy/app.lua — a typed authorization gateway on OpenResty.
--
-- One decision function (policy.shen, loaded under (tc +)) serves two roles:
--   * an ENFORCEMENT gate (access_by_lua) on /protected/ — every request is
--     marshaled into Shen, `decide`d, and allowed (200) or refused (403 with
--     the reason) before it reaches anything behind the gate;
--   * a PREVIEW endpoint (/api/check) the browser page calls to show, live,
--     why any (subject, action, resource) triple is allowed or denied.
-- Same rules, same reasons, edge and UI — no drift.
--
-- Kernel boot + the typed load happen ONCE per worker (see nginx.conf).

local APP_DIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$") or "."

local shen = require("shen")
local IO   = require("lua_interop")
local P    = shen.prims

local cjson
do
  local ok, m = pcall(require, "cjson.safe")
  if not ok then ok, m = pcall(require, "cjson") end
  cjson = ok and m or assert(loadfile(APP_DIR .. "/json_shim.lua"))()
end

shen.boot{quiet = true}
shen.eval("(tc +)")
P.F["load"](APP_DIR .. "/policy.shen")
shen.eval("(tc -)")

local decide = IO.fn("decide")
local sym    = IO.sym

-- ---- decide a request -------------------------------------------------------
-- principal = {name, role, tenant}; resource = {owner, tenant}; action string.
-- Returns allowed(bool), reason(string). The Shen `decision` comes back as
-- {"allow"|"deny", reason}; we read the tag directly.
local function check(principal, action, resource)
  principal = principal or {}; resource = resource or {}
  local prin = { sym("prin"), principal.name or "", principal.role or "", principal.tenant or "" }
  local res  = { sym("res"),  resource.owner  or "", resource.tenant or "" }
  local d = decide(prin, tostring(action or ""), res)
  return d[1] == "allow", d[2]
end

-- ---- request handling (pure; shared with selftest) --------------------------
local function dispatch(method, path, body)
  if path == "/api/check" and method == "POST" then
    local allowed, reason = check(body and body.subject, body and body.action, body and body.resource)
    return 200, { allowed = allowed, reason = reason, decision = allowed and "allow" or "deny" }
  end
  return 404, { error = "not found" }
end

local M = { dispatch = dispatch, check = check, json = cjson }

function M.handle()
  local method = ngx.req.get_method()
  local decoded
  if method == "POST" then
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if raw and raw ~= "" then
      local d = cjson.decode(raw)
      if d == nil then
        ngx.status = 400; ngx.header.content_type = "application/json"
        ngx.say(cjson.encode({ error = "invalid JSON" })); return
      end
      decoded = d
    end
  end
  local status, body = dispatch(method, ngx.var.uri, decoded)
  ngx.status = status
  ngx.header.content_type = "application/json"
  ngx.say(cjson.encode(body))
end

-- ---- the edge enforcement gate (access_by_lua on /protected/) --------------
-- The principal/resource come from request headers for the demo; in production
-- they'd come from a verified JWT / session and the resource being addressed.
function M.gate()
  local h = ngx.req.get_headers()
  local allowed, reason = check(
    { name = h["x-subject"], role = h["x-role"], tenant = h["x-tenant"] },
    ngx.req.get_method() == "GET" and "read" or "write",
    { owner = h["x-res-owner"], tenant = h["x-res-tenant"] })
  if not allowed then
    ngx.status = 403
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode({ error = "forbidden", reason = reason }))
    return ngx.exit(403)
  end
  -- allowed: fall through to the protected content
end

return M
