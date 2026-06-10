-- examples/config_check.lua — typed validation of Lua config tables by Shen.
--
--   luajit examples/config_check.lua          (from the repo root)
--
-- What this shows, in one self-contained file:
--   Lua -> Shen   a nested Lua table marshaled into Shen data and validated
--                 by statically-typed Shen rules (examples/config_rules.shen)
--   Shen -> Lua   those rules call string.format and a HOST-DEFINED Lua
--                 function (host.matches) through lua.function, the TYPED
--                 bridge — every call site typechecked against the declared
--                 signature
--   the part no plain Lua library can do: the rules file is TYPECHECKED when
--                 it loads. A rules bug that Lua would only hit at runtime
--                 (config_rules_broken.shen formats a number with %q/string)
--                 is rejected before a single config is ever validated.

-- ---- locate the repo root so this runs from anywhere -----------------------
local root = arg[0]:match("^(.*)/examples/[^/]+$") or "."
package.path = root .. "/?.lua;" .. package.path
require("ffi").cdef[[int chdir(const char *);]]
require("ffi").C.chdir(root)   -- kernel + rules paths are root-relative

-- ---- boot Shen --------------------------------------------------------------
local P = require("boot")
P.load_kernel(false)
P.initialise()
local shen = require("lua_interop")   -- installed by load_kernel; module = API

-- ---- a host service the Shen rules will call (Shen -> Lua) ------------------
-- Shen has no Lua-pattern matching; the rules borrow ours, through a typed
-- bridge declared below as [string --> string --> boolean].
host = {
  matches = function(s, pat) return string.match(s, pat) ~= nil end,
}

-- ---- register the TYPED bridges (Shen -> Lua) --------------------------------
-- (lua.function Name Path Sig) installs F[Name] as a marshaling wrapper
-- around the Lua function at Path and declares Sig to the typechecker.
-- Registration is an untyped toplevel effect, so it happens before (tc +).
shen.eval [[
  (lua.function lua.format   "string.format" [string --> string --> string])
  (lua.function host.matches "host.matches"  [string --> string --> boolean])
]]

-- ---- marshal a nested Lua table into the rules' `val` representation --------
-- string -> [s X] ; number -> [n X] ; boolean -> [b X] ;
-- array  -> [arr [...]] ; hash table -> [obj [[key val] ...]] (sorted keys)
local sym = shen.sym
local function val(v)
  local t = type(v)
  if t == "string" then return { sym("s"), v } end
  if t == "number" then return { sym("n"), v } end
  if t == "boolean" then return { sym("b"), v } end
  assert(t == "table", "unsupported config value: " .. t)
  if v[1] ~= nil or next(v) == nil then        -- array part -> [arr ...]
    local a = {}
    for i, e in ipairs(v) do a[i] = val(e) end
    return { sym("arr"), a }
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys)
  local es = {}
  for i, k in ipairs(keys) do es[i] = { k, val(v[k]) } end
  return { sym("obj"), es }
end

-- ---- load (and TYPECHECK) the rules -----------------------------------------
-- Shen's `load` snapshots the tc mode once, at load start, so the switch
-- happens HERE, not inside the rules file.
print("== loading examples/config_rules.shen under (tc +) ==")
shen.eval("(tc +)")
P.F["load"]("examples/config_rules.shen")

-- ---- the 20 lines that matter: validate configs from Lua --------------------
local validate = shen.fn("validate-config")     -- Shen fn as a Lua callback

local function report(name, config)
  -- Lua table in, Lua array out. An empty Shen list () is nil at the
  -- boundary (see the marshaling rules in lua_interop.lua), hence `or {}`.
  local errs = validate(val(config)) or {}
  if #errs == 0 then
    print(("%-12s OK"):format(name))
  else
    print(("%-12s %d problem(s):"):format(name, #errs))
    for _, e in ipairs(errs) do print("    - " .. e) end
  end
end

print("\n== validating configs ==")
report("good", {
  service  = "web-frontend",
  port     = 8080,
  replicas = 3,
  tls      = { enabled = true, cert = "/etc/ssl/web.pem" },
  hosts    = { "alpha.example.com", "beta.example.com" },
})

report("bad", {
  service  = "Web Frontend!",                   -- not a valid service name
  port     = 70000,                             -- out of range
  replicas = 0.5,                               -- not a positive integer
  tls      = { enabled = true },                -- enabled but no cert
  hosts    = { "alpha.example.com", 42 },       -- non-string host
})

-- ---- the typechecker earning its keep ---------------------------------------
-- config_rules_broken.shen is the same port rule with one classic bug: the
-- number is fed straight to the %q/string formatter. In Lua that's a runtime
-- crash on the first bad config; Shen rejects the RULES FILE at load time.
print("\n== loading examples/config_rules_broken.shen (one bug planted) ==")
local ok, err = pcall(P.F["load"], "examples/config_rules_broken.shen")
print(ok and "!! loaded (unexpected)"
         or ("rejected by the typechecker: " .. shen.error_message(err)))
shen.eval("(tc -)")

-- ---- bonus: the same bridge, interactively ----------------------------------
-- valid-config? : (val --> boolean), called like any Lua predicate.
print("\n== valid-config? as a plain Lua predicate ==")
print("good is valid:", shen.call("valid-config?", val({ service = "api", port = 80 })))
print("bad  is valid:", shen.call("valid-config?", val({ port = "eighty" })))
