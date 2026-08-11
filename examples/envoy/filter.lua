-- examples/envoy/filter.lua — Shen at the edge: an Envoy Lua HTTP filter.
--
-- Envoy's Lua filter embeds LuaJIT — the same host tier as OpenResty — so the
-- typed core of the guestbook example (../openresty/rules.shen) can run INSIDE
-- the proxy: a malformed POST is rejected at the edge, with the SAME typed
-- error strings the browser (ShenScript) and the origin (shen-lua on
-- OpenResty) produce, before it ever costs an upstream hop. One rules.shen,
-- now enforced on a third host.
--
-- What belongs here and what doesn't: Envoy's Lua environment is per worker
-- THREAD, has no shared dicts, no cosockets, and no timers — its only
-- sanctioned I/O is handle:httpCall() to a configured cluster. So the edge
-- gets ONLY the pure typed core (validation); everything stateful — the authz
-- proof chain, the durable store, the audit log — stays in the OpenResty
-- services this proxy fronts (see envoy.yaml + README.md).
--
-- This top-level chunk runs ONCE per Envoy worker thread, when the filter
-- loads the script — Envoy's analogue of init_worker_by_lua. The kernel boot
-- (~1 s cold, tens of ms from the bytecode cache) happens here, never per
-- request. envoy_on_request below is the per-request hook.

-- Resolve the repo root: an explicit SHEN_LUA_ROOT wins; otherwise derive it
-- from this file's own path (works under `luajit selftest.lua` and under an
-- Envoy that names the chunk after the source_code filename); last resort is
-- the cwd, which is right when Envoy is run from the repo root as the README
-- says.
local SRC        = debug.getinfo(1, "S").source
local FILTER_DIR = SRC:match("^@(.*)[/\\][^/\\]+$")
local ROOT       = os.getenv("SHEN_LUA_ROOT")
                   or (FILTER_DIR and FILTER_DIR .. "/../..")
                   or "."
package.path = ROOT .. "/?.lua;" .. package.path

local shen = require("shen")
local IO   = require("lua_interop")
local P    = shen.prims

-- Envoy bundles no JSON codec, so always use the repo's self-contained shim
-- (the same one the selftests use; cjson-compatible surface).
local cjson = assert(loadfile(ROOT .. "/examples/openresty/json_shim.lua"))()

shen.boot{ quiet = true }

-- The typed core, loaded under (tc +): the SAME file the origin server loads
-- and the browser build is shaken from. A type error in a rule aborts the
-- proxy's script load — the edge never runs unproved rules.
shen.eval("(tc +)")
P.F["load"](ROOT .. "/examples/openresty/rules.shen")
shen.eval("(tc -)")

local validate = IO.fn("validate-message")   -- val -> list of error strings

-- Lua (decoded JSON) -> the tagged `val` shape rules.shen pattern-matches.
-- Identical to the marshaling in the two app.lua glues.
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

-- Validate a raw request body; nil means "clean, let it through", otherwise
-- an array of error strings — the same strings the origin would produce,
-- because it is the same rules.shen producing them.
local function edge_errors(raw)
  local decoded, err = cjson.decode(raw)
  if decoded == nil then return { "invalid JSON: " .. tostring(err) } end
  local errs = validate(to_val(decoded))   -- an empty Shen list marshals to nil
  if errs == nil or #errs == 0 then return nil end
  return errs
end

-- ---- the per-request hook ----------------------------------------------------
-- Only guestbook creations carry a body worth ruling on; everything else
-- passes through untouched (authorization already happened — the ext_authz
-- filter runs before this one in envoy.yaml's filter chain).
function envoy_on_request(handle)
  local headers = handle:headers()
  local method  = headers:get(":method")
  local path    = (headers:get(":path") or ""):match("^[^?]*")
  if method ~= "POST" or path ~= "/api/messages" then return end

  local body = handle:body()                   -- buffers the full body (yields)
  local raw  = body and body:getBytes(0, body:length()) or ""
  local errs = edge_errors(raw)
  if errs then
    handle:respond(
      { [":status"] = "400",
        ["content-type"]  = "application/json",
        ["x-shen-edge"]   = "rejected" },
      cjson.encode({ errors = errs }))
    return                                     -- never reached: respond() ends the coroutine
  end
  headers:add("x-shen-edge", "validated")      -- visible upstream: the edge ran the rules
end
