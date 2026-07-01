-- examples/configc/app.lua — the config compiler behind an OpenResty endpoint.
--
-- POST a JSON config to /api/compile; it is marshaled into Shen and run through
-- compile-config (validate; then, if valid, EMIT the artifacts) from
-- configc.shen, loaded under (tc +). The browser preview calls this to show
-- the generated Kubernetes/nginx artifacts — or the validation errors — live.
-- The exact same compiler would run as a CI step or an admission webhook.
--
-- Kernel boot + typed load happen ONCE per worker (see nginx.conf).

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
P.F["load"](APP_DIR .. "/configc.shen")
shen.eval("(tc -)")

local compile = IO.fn("compile-config")
local sym = IO.sym

-- ---- Lua (cjson) value -> Shen `val` ---------------------------------------
local function to_val(v)
  local t = type(v)
  if t == "string"  then return { sym("s"), v } end
  if t == "number"  then return { sym("n"), v } end
  if t == "boolean" then return { sym("b"), v } end
  if t == "table" then
    if v[1] ~= nil or next(v) == nil then
      local a = {}; for i, e in ipairs(v) do a[i] = to_val(e) end
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

-- ---- compile a decoded config -> a JSON-friendly result --------------------
-- Shen returns {"compiled", {{"file",name,body}...}} or {"invalid", {errs}}.
local function compile_config(decoded)
  local out = compile(to_val(decoded or {}))
  if out[1] == "compiled" then
    local files = {}
    for i, f in ipairs(out[2]) do files[i] = { name = f[2], body = f[3] } end
    return { ok = true, files = files }
  end
  return { ok = false, errors = out[2] }
end

local function dispatch(method, path, body)
  if path == "/api/compile" and method == "POST" then
    return 200, compile_config(body)
  end
  return 404, { error = "not found" }
end

local M = { dispatch = dispatch, compile_config = compile_config, json = cjson }

function M.handle()
  local method = ngx.req.get_method()
  local decoded
  if method == "POST" then
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if raw and raw ~= "" then
      local d, err = cjson.decode(raw)
      if d == nil then
        ngx.status = 400; ngx.header.content_type = "application/json"
        ngx.say(cjson.encode({ error = "invalid JSON: " .. tostring(err) })); return
      end
      decoded = d
    end
  end
  local status, body = dispatch(method, ngx.var.uri, decoded)
  ngx.status = status
  ngx.header.content_type = "application/json"
  ngx.say(cjson.encode(body))
end

return M
