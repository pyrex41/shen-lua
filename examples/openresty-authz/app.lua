-- examples/openresty-authz/app.lua — glue between OpenResty and shen-lua for
-- the multi-tenant authz demo. Same shape as the guestbook example's app.lua:
-- boot the kernel ONCE per worker, register the typed Lua bridges, load the
-- typed core (authz.shen, tc +) and the policy/router (app.shen, tc -), and
-- expose M.handle() as the content handler. Per request it marshals nginx data
-- into Shen, calls (route Method Path Body), and JSON-encodes the result.

local APP_DIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$") or "."

local shen = require("shen")
local IO   = require("lua_interop")
local P    = shen.prims

-- cjson under OpenResty; the repo's json_shim off-nginx (selftest under luajit).
local cjson
do
  local ok, m = pcall(require, "cjson.safe")
  if not ok then ok, m = pcall(require, "cjson") end
  cjson = ok and m or assert(loadfile(APP_DIR .. "/../openresty/json_shim.lua"))()
end

-- A pluggable durable store (store.lua). selftest.lua injects a file-backed
-- one; nginx wires an lmdb-backed one. Default no-op keeps this module loadable
-- on its own.
local store = {
  token_user = function() return "" end, is_admin = function() return false end,
  owner_tenant = function() return "" end, member = function() return false end,
  role = function() return false end, revoked = function() return false end,
  content = function() return "" end, grant = function() end, revoke = function() end,
  create = function() end, log_decision = function() end, audit = function() return {} end,
}
local function set_store(s) store = s end

-- Identity resolution (token -> user) is pluggable so it can go over a cosocket
-- to a networked session store under nginx (see auth.lua / use_auth) while
-- defaulting to the local store off-nginx. Everything else stays local.
local auth = { token_user = function(tok) return store.token_user(tok) end }
local function set_auth(a) auth = a end

-- ---- host services the Shen policy calls (Shen -> Lua) ----------------------
host = {
  token_user   = function(tok)      return auth.token_user(tok) end,
  is_admin     = function(tok)      return store.is_admin(tok) end,
  owner_tenant = function(res)      return store.owner_tenant(res) end,
  member       = function(u, t)     return store.member(u, t) end,
  role         = function(u, t, r)  return store.role(u, t, r) end,
  revoked      = function(u, r)     return store.revoked(u, r) end,
  content      = function(res)      return store.content(res) end,
  grant        = function(u, t, r)  return store.grant(u, t, r) end,
  revoke       = function(u, r)     return store.revoke(u, r) end,
  create       = function(t, r, c)  return store.create(t, r, c) end,
  log          = function(u, a, r, d, why) return store.log_decision(u, a, r, d, why) end,
  audit        = function()         return store.audit() end,
}

shen.boot{ quiet = true }

shen.eval("(tc +)")
P.F["load"](APP_DIR .. "/authz.shen")   -- typed core: a type error aborts boot
shen.eval("(tc -)")
P.F["load"](APP_DIR .. "/app.shen")     -- policy (Prolog) + router

local route = IO.fn("route")

-- ---- marshaling: cjson value <-> Shen `val` (identical to the guestbook) ----
local sym = IO.sym

local function to_val(v)
  local t = type(v)
  if t == "string"  then return { sym("s"), v } end
  if t == "number"  then return { sym("n"), v } end
  if t == "boolean" then return { sym("b"), v } end
  if t == "table" then
    if v[1] ~= nil or next(v) == nil then
      local a = {}
      for i, e in ipairs(v) do a[i] = to_val(e) end
      return { sym("arr"), a }
    end
    local es, i = {}, 0
    for k, val in pairs(v) do
      if type(k) == "string" then i = i + 1; es[i] = { k, to_val(val) } end
    end
    return { sym("obj"), es }
  end
  return { sym("s"), tostring(v) }
end

local function from_val(v)
  local tag, payload = v[1], v[2]
  if tag == "s" or tag == "n" or tag == "b" then return payload end
  if tag == "arr" then
    if #payload == 0 then return cjson.empty_array end
    local out = {}
    for i, e in ipairs(payload) do out[i] = from_val(e) end
    return out
  end
  if tag == "obj" then
    local o = {}
    for _, pair in ipairs(payload) do o[pair[1]] = from_val(pair[2]) end
    return o
  end
  return nil
end

-- ---- request handler (pure given method/path/decoded-body) ------------------
local function dispatch(method, path, decoded_body)
  local body = decoded_body and to_val(decoded_body) or nil
  local resp = route(method, path, body)
  return resp[1], from_val(resp[2])
end

local M = { dispatch = dispatch, to_val = to_val, from_val = from_val,
            use_store = set_store, use_auth = set_auth, json = cjson }

function M.handle()
  local method = ngx.req.get_method()
  local path   = ngx.var.uri
  local decoded
  if method == "POST" or method == "PUT" then
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if raw and raw ~= "" then
      local d, err = cjson.decode(raw)
      if d == nil then
        ngx.status = 400
        ngx.header.content_type = "application/json"
        ngx.say(cjson.encode({ ok = false, error = "invalid JSON: " .. tostring(err) }))
        return
      end
      decoded = d
    end
  end
  local status, body = dispatch(method, path, decoded)
  ngx.status = status
  ngx.header.content_type = "application/json"
  ngx.say(cjson.encode(body))
end

return M
