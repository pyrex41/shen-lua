-- examples/openresty/selftest.lua — verify the Shen app off-nginx.
--
--   luajit examples/openresty/selftest.lua      (from the repo root)
--
-- Boots the same app.lua the server uses, swaps in an in-memory store, and
-- drives (route ...) through app.lua's dispatch() with sample requests. This
-- exercises the typed load of validate.shen (a type error there aborts here,
-- before nginx is ever involved) and the routing/validation/storage paths.

local root = arg[0]:match("^(.*)/examples/openresty/[^/]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/examples/openresty/?.lua;" .. package.path

local app = require("app")

-- in-memory stand-in for the nginx lua_shared_dict
local rows = {}
app.use_store({
  add  = function(name, message) rows[#rows + 1] = { name, message }; return #rows end,
  list = function() return rows end,
})

local cjson = app.json   -- the codec app.lua resolved (real cjson or the shim)
local function show(label, method, path, body)
  local status, resp = app.dispatch(method, path, body)
  print(("%-28s -> %d  %s"):format(label, status, cjson.encode(resp)))
  return status
end

local fail = 0
local function expect(label, want, method, path, body)
  local got = show(label, method, path, body)
  if got ~= want then fail = fail + 1; print(("    FAIL: expected %d"):format(want)) end
end

print("== guestbook API (in-memory store) ==")
expect("GET empty list",        200, "GET",  "/api/messages")
expect("POST valid",            201, "POST", "/api/messages",
       { name = "ada", message = "first post" })
expect("POST another valid",    201, "POST", "/api/messages",
       { name = "grace", message = "hello from shen" })
expect("GET list (2 rows)",     200, "GET",  "/api/messages")
expect("POST missing name",     400, "POST", "/api/messages",
       { message = "anon" })
expect("POST blank message",    400, "POST", "/api/messages",
       { name = "bob", message = "" })
expect("POST not an object",    400, "POST", "/api/messages",
       { "not", "an", "object" })
expect("unknown route -> 404",  404, "GET",  "/api/nope")

if fail == 0 then print("\nOK — all cases passed")
else print(("\n%d case(s) FAILED"):format(fail)); os.exit(1) end
