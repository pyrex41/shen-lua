-- unii/test/run.lua -- the single test entrypoint.
--
--   luajit unii/test/run.lua [--only NAME] [--with-upstream]
--
-- Runs the typechecked build first (fails fast if the rule bundle does not
-- typecheck or the runtime differs from the pinned commit), then every
-- unii/test/test_*.lua module. --with-upstream also runs the pinned
-- shen-lua port specs (make test) and the Shen 42 kernel suite.
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/test/run%.lua$")
local root = here:match("^(.*)/unii$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local only, upstream = nil, false
local i = 1
while i <= #arg do
  if arg[i] == "--only" then only = arg[i + 1]; i = i + 2
  elseif arg[i] == "--with-upstream" then upstream = true; i = i + 1
  else io.stderr:write("unknown argument " .. arg[i] .. "\n"); os.exit(2) end
end

local function sh(cmd)
  io.stdout:write("$ ", cmd, "\n")
  local ok = os.execute(cmd)
  return ok == 0 or ok == true
end

if not sh(("luajit %q"):format(here .. "/build.lua")) then
  io.stderr:write("build failed\n")
  os.exit(1)
end

local files = {
  "test_codec", "test_boundary", "test_tree", "test_view", "test_transition",
  "test_traces", "test_hysteresis", "test_storage", "test_storage_phase2",
  "test_storage_faults", "test_network_mock", "test_milestone",
}

local passed, failed, skipped = 0, 0, 0
local failures = {}
local t_all = os.clock()
for _, name in ipairs(files) do
  if not only or name:find(only, 1, true) then
    local suite = require("unii.test." .. name)
    io.stdout:write("\n== ", name, "\n")
    for _, case in ipairs(suite) do
      local t0 = os.clock()
      local ok, err = pcall(case[2])
      local dt = os.clock() - t0
      if ok and err == "skip" then
        skipped = skipped + 1
        io.stdout:write(("  SKIP %-64s\n"):format(case[1]))
      elseif ok then
        passed = passed + 1
        io.stdout:write(("  ok   %-64s %6.2fs\n"):format(case[1], dt))
      else
        failed = failed + 1
        failures[#failures + 1] = name .. ": " .. case[1] .. ": " .. tostring(err)
        io.stdout:write(("  FAIL %-64s\n       %s\n"):format(case[1], tostring(err)))
      end
    end
  end
end

if upstream then
  io.stdout:write("\n== upstream shen-lua (pinned) port specs and kernel suite\n")
  if sh(("cd %q && make test >/tmp/unii-upstream-spec.log 2>&1"):format(root)) then
    passed = passed + 1; print("  ok   make test (log /tmp/unii-upstream-spec.log)")
  else
    failed = failed + 1; failures[#failures + 1] = "upstream make test"; print("  FAIL make test")
  end
  if sh(("cd %q && luajit run-kernel-tests.lua >/tmp/unii-upstream-kernel.log 2>&1"):format(root)) then
    passed = passed + 1; print("  ok   kernel suite (log /tmp/unii-upstream-kernel.log)")
  else
    failed = failed + 1; failures[#failures + 1] = "upstream kernel suite"; print("  FAIL kernel suite")
  end
end

io.stdout:write(("\n%d passed, %d failed, %d skipped (%.1fs CPU in this process)\n")
  :format(passed, failed, skipped, os.clock() - t_all))
for _, f in ipairs(failures) do io.stdout:write("  - ", f, "\n") end
os.exit(failed == 0 and 0 or 1)
