-- run-41.1-tests.lua
-- Driver to run the Shen 41.1 kernel test suite under shen-lua

-- Require shen-lua modules from the shen-lua directory (KL dir discovery uses relative paths)
local P = require("boot")
local R = require("runtime")

print("Loading Shen 41.1 kernel...")
local t0 = os.clock()
P.load_kernel(false)
local t1 = os.clock()
print(string.format("  load_kernel: %.3fs", t1 - t0))

P.initialise()
local t2 = os.clock()
print(string.format("  initialise:  %.3fs", t2 - t1))
print("Kernel initialised. Version:", P.F["version"] and P.F["version"]() or "?")

-- Now that the kernel is live, switch the process cwd into the tests directory.
-- This makes all the relative (load "foo.shen") calls inside the test suite resolve correctly.
local ffi = require("ffi")
ffi.cdef[[
  int chdir(const char *path);
  char *getcwd(char *buf, size_t size);
]]

local tests_dir = "../cl-source/ShenOSKernel-41.1/tests"
if ffi.C.chdir(tests_dir) ~= 0 then
  error("failed to chdir to " .. tests_dir)
end

local cwd = ffi.string(ffi.C.getcwd(nil, 0)) or "?"
print("Switched working directory for tests: " .. cwd)

-- 41.1 initialise is not populating *macros* (and shen.*tc* etc.) in a way
-- the bare names the harness and early code expect. Force the initial value
-- that shen.initialise-environment was supposed to install.
-- This is needed for the macro system (defmacro, etc.) to work.
do
  local macros_fn = P.F["shen.macros"]
  if macros_fn and not P.GLOBALS["*macros*"] then
    local entry = R.cons( R.cons(R.intern("shen.macros"), macros_fn), R.NIL )
    P.GLOBALS["*macros*"] = R.cons(entry, R.NIL)
    print("Note: manually seeded *macros* for 41.1 compatibility")
  end
  -- Also make bare *tc* work if code expects it (the kernel set shen.*tc*)
  if P.GLOBALS["shen.*tc*"] ~= nil and P.GLOBALS["*tc*"] == nil then
    P.GLOBALS["*tc*"] = P.GLOBALS["shen.*tc*"]
  end
end

-- Try to make y-or-n? non-interactive (harness uses it to ask on failure).
local yn_ok, yn_err = pcall(function()
  P.run_kl_string([[(define y-or-n? _ -> true)]])
end)
if not yn_ok then
  print("Note: could not redefine y-or-n? (continuing anyway)")
end

print("\n=== Running test suite step by step ===\n")

-- Load harness first (defines the test macros and package)
print("Loading harness.shen ...")
local ok1, e1 = xpcall(function()
  P.F["load"]("harness.shen")
end, function(e)
  if type(e) == "table" and getmetatable(e) == R.Excn then
    return "SHEN-EX: " .. (e.msg or tostring(e))
  end
  return "LUA: " .. tostring(e)
end)
print("  harness result:", ok1 and "ok" or e1)

if not ok1 then
  print("Halting after harness failure.")
  os.exit(1)
end

-- Now the big one
print("Loading kerneltests.shen (this runs the actual reports)...")
local ok2, e2 = xpcall(function()
  P.F["load"]("kerneltests.shen")
end, function(e)
  if type(e) == "table" and getmetatable(e) == R.Excn then
    return "SHEN-EX: " .. (e.msg or tostring(e))
  end
  return "LUA: " .. tostring(e)
end)

print("\n=== Test run finished ===")
print("kerneltests result:", ok2 and "ok" or e2)

-- Final counters from the harness (they are set in the root as *passed* / *failed*)
local function getg(name)
  return P.GLOBALS[name] or "?"
end
print(string.format("Counters: passed=%s failed=%s", getg("*passed*"), getg("*failed*")))

print("\nDone.")
