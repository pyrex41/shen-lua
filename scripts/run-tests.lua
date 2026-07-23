-- scripts/run-tests.lua — unified PORT test runner.
--
-- Runs every port-authored spec under test/*_spec.lua as its own subprocess
-- (each spec ends with os.exit(nfail==0 and 0 or 1)), aggregates the per-spec
-- pass/fail counts, prints a summary, and exits NONZERO if any spec failed or
-- crashed. This is `make test` — the fast, port-owned tier.
--
-- The canonical Shen kernel certification (run-kernel-tests.lua) is a SEPARATE
-- tier (`make certify`); it is intentionally NOT run here.
--
--   luajit scripts/run-tests.lua
--   LUA=lua scripts/run-tests.lua        # use a specific interpreter

local root = (arg and arg[0]) and arg[0]:gsub("scripts/[^/]*$", "") or ""
if root == "" then root = "./" end

-- The interpreter to drive each spec with. Defaults to luajit (the project's
-- primary host); override with $LUA. Fall back to plain lua if luajit absent.
local function have(cmd)
  local h = io.popen("command -v " .. cmd .. " 2>/dev/null")
  if not h then return false end
  local out = h:read("*a"); h:close()
  return out ~= nil and out:match("%S") ~= nil
end
local LUA = os.getenv("LUA")
if not LUA or LUA == "" then
  LUA = have("luajit") and "luajit" or "lua"
end

-- Discover specs deterministically (sorted) so the run order is stable.
local specs = {
  "test/cli_spec.lua",
  "test/engine_spec.lua",
  "test/error_robustness_spec.lua",
  "test/interop_spec.lua",
  "test/io_spec.lua",
  "test/jit_spec.lua",
  "test/library_spec.lua",
  "test/primitives_spec.lua",
  "test/reader_spec.lua",
  "test/repl_spec.lua",
  "test/stdlib_spec.lua",
  "test/tailcall_spec.lua",
  "test/typecheck_api_spec.lua",
  "test/typecheck_lazy_spec.lua",
}

local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- Run one spec, echo its output, and recover its exit code via a sentinel
-- (LuaJIT io.popen:close does not report child status).
local function run_spec(path)
  local cmd = LUA .. " " .. sh_quote(root .. path)
  local full = "{ " .. cmd .. " ; } 2>&1; echo \"__EXIT__:$?\""
  local h = io.popen(full, "r")
  local out = h:read("*a") or ""
  h:close()
  local code = tonumber(out:match("__EXIT__:(%d+)%s*$")) or -1
  out = out:gsub("__EXIT__:%d+%s*$", "")
  io.write(out)
  -- Pull the spec's own "<name>: N pass, M fail" / "N passed / M failed" line.
  local pass = tonumber(out:match("(%d+)%s*pass")) or 0
  local fail = tonumber(out:match("pass[^%d]*(%d+)%s*fail"))
            or tonumber(out:match("/%s*(%d+)%s*failed"))
            or (code == 0 and 0 or nil)
  return code, pass, fail
end

print("== shen-lua port test suite ==")
print("interpreter: " .. LUA)
print("")

local total_pass, total_fail, failed_specs = 0, 0, {}
for _, path in ipairs(specs) do
  io.write("---- ", path, " ----\n")
  local code, pass, fail = run_spec(path)
  total_pass = total_pass + (pass or 0)
  total_fail = total_fail + (fail or 0)
  if code ~= 0 then
    failed_specs[#failed_specs + 1] = path .. " (exit " .. code .. ")"
  end
  io.write("\n")
end

print("============================================")
print(string.format("TOTAL: %d pass, %d fail across %d specs",
  total_pass, total_fail, #specs))
if #failed_specs > 0 then
  print("FAILED SPECS:")
  for _, s in ipairs(failed_specs) do print("  - " .. s) end
  os.exit(1)
end
print("ALL PORT SPECS GREEN")
os.exit(0)
