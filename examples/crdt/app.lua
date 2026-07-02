-- examples/crdt/app.lua — the CRDT sync hub: OpenResty <-> shen-lua glue.
--
-- The server is just another replica. It holds one canonical document and,
-- on every POST, MERGES the client's whole document into it with the SAME
-- typed `doc-merge` from crdt.shen that the browser runs client-side. Because
-- merge is a join-semilattice operation (commutative/associative/idempotent —
-- proved in crdt_laws.shen), it does not matter what order replicas sync in or
-- how often: everyone converges to the identical document. No locks, no
-- last-write-stomps, no "who won" coordination.
--
-- Kernel boot + the typed load of crdt.shen happen ONCE per worker (see
-- nginx.conf init_worker_by_lua), never per request.

local APP_DIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$") or "."

local shen = require("shen")
local IO   = require("lua_interop")
local P    = shen.prims

-- cjson under nginx; the bundled shim off-nginx (selftest under plain luajit).
local cjson
do
  local ok, m = pcall(require, "cjson.safe")
  if not ok then ok, m = pcall(require, "cjson") end
  cjson = ok and m or assert(loadfile(APP_DIR .. "/json_shim.lua"))()
end

-- Canonical document store. Pluggable so selftest can inject an in-memory one;
-- under nginx M.use_store wires it to a lua_shared_dict (a JSON string).
local store = { get = function() return nil end, set = function(_) end }
local function set_store(s) store = s end

shen.boot{quiet = true}

-- crdt.shen is the SAME file the browser loads (via ShenScript). Loaded under
-- (tc +): every merge/law function is proved well-typed before the first
-- request, and a type error aborts worker boot.
shen.eval("(tc +)")
P.F["load"](APP_DIR .. "/crdt.shen")
shen.eval("(tc -)")

local doc_merge = IO.fn("doc-merge")
local sym = IO.sym

-- ---- marshaling: JSON document <-> Shen `doc` ------------------------------
-- Wire shape:  { "<field>": { "v": <string>, "ts": <number>, "id": <string> }, ... }
-- Shen shape:  [doc [[<field> [lww V Ts Id]] ...]]
-- A field whose value isn't a well-formed register is skipped (defensive).
local function to_doc(obj)
  local fields = {}
  if type(obj) == "table" then
    for k, r in pairs(obj) do
      if type(k) == "string" and type(r) == "table"
         and type(r.v) == "string" and type(r.ts) == "number" and type(r.id) == "string" then
        fields[#fields + 1] = { k, { sym("lww"), r.v, r.ts, r.id } }
      end
    end
  end
  return { sym("doc"), fields }
end

-- Shen `doc` (marshaled back to nested Lua arrays, tags as strings) -> JSON obj.
local function from_doc(d)
  local out = {}
  if type(d) == "table" and d[1] == "doc" then
    for _, field in ipairs(d[2]) do
      local key, reg = field[1], field[2]
      if reg and reg[1] == "lww" then
        out[key] = { v = reg[2], ts = reg[3], id = reg[4] }
      end
    end
  end
  return out
end

-- Read the canonical doc as a Lua/JSON value ({} if nothing stored yet).
local function load_canonical()
  local raw = store.get()
  if not raw or raw == "" then return {} end
  local d = cjson.decode(raw)
  return d or {}
end

-- ---- request handling (pure given method/path/body; shared with selftest) --
-- GET  /api/doc  -> the canonical merged document
-- POST /api/doc  -> merge the client's document in, return the converged doc
local function dispatch(method, path, decoded_body)
  if path ~= "/api/doc" then
    return 404, { error = "not found" }
  end
  if method == "GET" then
    return 200, load_canonical()
  end
  if method == "POST" then
    local incoming = to_doc(decoded_body or {})
    local merged   = from_doc(doc_merge(to_doc(load_canonical()), incoming))
    store.set(cjson.encode(merged))
    return 200, merged
  end
  return 404, { error = "not found" }
end

local M = { dispatch = dispatch, to_doc = to_doc, from_doc = from_doc,
            use_store = set_store, json = cjson }

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
        ngx.say(cjson.encode({ error = "invalid JSON: " .. tostring(err) }))
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
