-- examples/openresty/app.lua — the glue between OpenResty and shen-lua.
--
-- Loaded once per nginx worker (from init_worker_by_lua in nginx.conf): it
-- boots the Shen kernel, registers the typed Lua bridges, loads the typed
-- core (validate.shen) and the router (app.shen), and exposes M.handle() as
-- the content handler. Per request it marshals nginx data into Shen, calls
-- (route Method Path Body), and turns the [Status BodyVal] result into JSON.
--
-- The expensive work (kernel boot ~ tens of ms warm, ~1 s cold) happens at
-- module-load time, i.e. ONCE per worker — never per request. This is the
-- single most important rule for running shen-lua under nginx.

-- Resolve this file's own directory so the .shen loads are absolute and don't
-- depend on the nginx worker's cwd.
local APP_DIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$") or "."

local shen = require("shen")
local IO   = require("lua_interop")   -- the marshaling API (Lua array <-> Shen list)
local P    = shen.prims               -- F-table, load, ...

-- cjson ships with OpenResty. Off-nginx (e.g. selftest.lua under plain
-- luajit) it may be absent, so fall back to a tiny self-contained JSON shim
-- with the same surface we use: decode, encode, and the empty_array sentinel.
local cjson
do
  local ok, m = pcall(require, "cjson.safe")
  if not ok then ok, m = pcall(require, "cjson") end
  cjson = ok and m or assert(loadfile(APP_DIR .. "/json_shim.lua"))()
end

-- A pluggable store so this module is testable off-nginx (selftest.lua injects
-- an in-memory table; under nginx M.use_store wires it to a lua_shared_dict).
local store = {
  add  = function(_, _) return 0 end,
  list = function() return {} end,
}
local function set_store(s) store = s end

-- ---- host services the Shen code calls (Shen -> Lua) ------------------------
-- `host` is a global so the dotted paths below ("host.store_add", ...) resolve
-- through lua.call / lua.function, the same convention as examples/config_check.
host = {
  -- storage, delegated to whatever store is installed
  store_add  = function(name, message) return store.add(name, message) end,
  store_list = function() return store.list() end,
}

shen.boot{quiet = true}

-- Load the typed core under (tc +) and the router under (tc -). rules.shen is
-- the SAME file the browser loads via ShenScript (see public/index.html) — one
-- source of truth for the field rules. It needs no Lua bridges: it is pure,
-- portable Shen (cn/str/tlstr only), which is exactly why it runs unchanged on
-- both ports. A type error in it aborts startup, before the first request.
shen.eval("(tc +)")
P.F["load"](APP_DIR .. "/rules.shen")
shen.eval("(tc -)")
P.F["load"](APP_DIR .. "/app.shen")

local route = IO.fn("route")   -- marshals args in and the result back out

-- ---- marshaling: cjson value <-> Shen `val` ---------------------------------
local sym = IO.sym

-- Lua (cjson-decoded) -> Shen `val`. Tags are interned SYMBOLS so the Shen
-- patterns [s X]/[n X]/... match; strings stay strings (never auto-interned).
local function to_val(v)
  local t = type(v)
  if t == "string"  then return { sym("s"), v } end
  if t == "number"  then return { sym("n"), v } end
  if t == "boolean" then return { sym("b"), v } end
  if t == "table" then
    if v[1] ~= nil or next(v) == nil then        -- array (or empty) -> [arr ...]
      local a = {}
      for i, e in ipairs(v) do a[i] = to_val(e) end
      return { sym("arr"), a }
    end
    local es, i = {}, 0                            -- object -> [obj [[k v] ...]]
    for k, val in pairs(v) do
      if type(k) == "string" then i = i + 1; es[i] = { k, to_val(val) } end
    end
    return { sym("obj"), es }
  end
  return { sym("s"), tostring(v) }                 -- null / unsupported -> string
end

-- Shen `val` (already marshaled by IO.fn to nested Lua arrays, tags as
-- strings) -> a plain Lua value ready for cjson.encode.
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

-- ---- the request handler ----------------------------------------------------
-- Pure given (method, path, decoded-body); shared with selftest.lua.
local function dispatch(method, path, decoded_body)
  local body = decoded_body and to_val(decoded_body) or nil
  local resp = route(method, path, body)           -- { Status, BodyVal }
  return resp[1], from_val(resp[2])
end

local M = { dispatch = dispatch, to_val = to_val, from_val = from_val,
            use_store = set_store, json = cjson }

-- content_by_lua entry point.
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
        ngx.say(cjson.encode({ errors = { "invalid JSON: " .. tostring(err) } }))
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
