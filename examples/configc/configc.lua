-- examples/configc/configc.lua — the typed config compiler as a CLI.
--
--   luajit examples/configc/configc.lua          (from the repo root)
--
-- Marshals Lua config tables into Shen, compiles each with compile-config
-- (validate; then, only if valid, EMIT a Kubernetes Deployment + an nginx
-- server block), and prints the artifacts or the errors. Finally it loads
-- configc_broken.shen — a generator with one type bug — to show the
-- typechecker rejecting a bad generator at load, before any config compiles.

local root = arg[0]:match("^(.*)/examples/configc/[^/]+$") or "."
package.path = root .. "/?.lua;" .. package.path
require("ffi").cdef[[int chdir(const char *);]]
require("ffi").C.chdir(root)

local P = require("boot")
P.load_kernel(false)
P.initialise()
local shen = require("lua_interop")   -- the MARSHALING API (Lua table <-> Shen)

-- ---- marshal a nested Lua table into the `val` shape (as config_check.lua) --
local sym = shen.sym
local function val(v)
  local t = type(v)
  if t == "string"  then return { sym("s"), v } end
  if t == "number"  then return { sym("n"), v } end
  if t == "boolean" then return { sym("b"), v } end
  assert(t == "table", "unsupported config value: " .. t)
  if v[1] ~= nil or next(v) == nil then
    local a = {}; for i, e in ipairs(v) do a[i] = val(e) end
    return { sym("arr"), a }
  end
  local keys = {}; for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys)
  local es = {}; for i, k in ipairs(keys) do es[i] = { k, val(v[k]) } end
  return { sym("obj"), es }
end

-- ---- load (and TYPECHECK) the compiler --------------------------------------
print("== loading examples/configc/configc.shen under (tc +) ==")
shen.eval("(tc +)")
P.F["load"]("examples/configc/configc.shen")
shen.eval("(tc -)")

local compile = shen.fn("compile-config")
local fail = 0

local function show(name, config)
  print("\n== compile " .. name .. " ==")
  local out = compile(val(config))          -- {"compiled", files} | {"invalid", errs}
  if out[1] == "compiled" then
    for _, f in ipairs(out[2]) do            -- f = {"file", name, body}
      print(("--- %s ---"):format(f[2]))
      print(f[3])
    end
  else
    print("INVALID:")
    for _, e in ipairs(out[2]) do print("  - " .. e) end
  end
  return out[1]
end

if show("good", {
  service = "web", port = 8080, replicas = 3,
  hosts = { "a.example.com", "b.example.com" },
}) ~= "compiled" then fail = fail + 1; print("  FAIL: expected compiled") end

if show("bad", { service = "", port = 70000 }) ~= "invalid" then
  fail = fail + 1; print("  FAIL: expected invalid")
end

-- ---- the typechecker earning its keep on a GENERATOR bug --------------------
print("\n== loading examples/configc/configc_broken.shen (one generator bug) ==")
shen.eval("(tc +)")
local ok, err = pcall(P.F["load"], "examples/configc/configc_broken.shen")
shen.eval("(tc -)")
if ok then
  print("  FAIL: broken generator loaded (expected a type error)"); fail = fail + 1
else
  print("  rejected by the typechecker: " .. shen.error_message(err))
end

if fail == 0 then print("\nOK — all checks passed")
else print(("\n%d check(s) FAILED"):format(fail)); os.exit(1) end
