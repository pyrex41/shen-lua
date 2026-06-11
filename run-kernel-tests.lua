-- run-kernel-tests.lua
-- Driver to run the Shen kernel test suite (vendored under tests/) under shen-lua

-- Require shen-lua modules from the shen-lua directory (KL dir discovery uses relative paths)
local P = require("boot")
local R = require("runtime")

print("Loading Shen kernel...")
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
-- Under LuaJIT we chdir via the FFI (unchanged); under PUC Lua try lfs, and
-- if neither is available fall back to prefixing relative paths inside the
-- `open` primitive — ALL kernel file I/O (load -> read-file -> open, plus the
-- suite's write-to-file output) funnels through it, so prefixing there is
-- equivalent to a chdir for the suite's purposes.
local tests_dir = os.getenv("SHEN_TESTS_DIR") or "tests"
local chdir_done = false
local ok_ffi, ffi = pcall(require, "ffi")
if ok_ffi then
  ffi.cdef[[
    int chdir(const char *path);
    char *getcwd(char *buf, size_t size);
  ]]
  if ffi.C.chdir(tests_dir) ~= 0 then
    error("failed to chdir to " .. tests_dir)
  end
  local cwd = ffi.string(ffi.C.getcwd(nil, 0)) or "?"
  print("Switched working directory for tests: " .. cwd)
  chdir_done = true
else
  local ok_lfs, lfs = pcall(require, "lfs")
  if ok_lfs and lfs.chdir(tests_dir) then
    print("Switched working directory for tests (lfs): " .. (lfs.currentdir() or "?"))
    chdir_done = true
  end
end
if not chdir_done then
  local probe = io.open(tests_dir .. "/harness.shen", "r")
  if not probe then
    error("cannot find tests at " .. tests_dir .. " (set SHEN_TESTS_DIR)")
  end
  probe:close()
  local orig_open = P.F["open"]
  P.F["open"] = function(name, dir)
    if type(name) == "string" and name:sub(1, 1) ~= "/" then
      name = tests_dir .. "/" .. name
    end
    return orig_open(name, dir)
  end
  P.FA[P.F["open"]] = 2
  print("No chdir primitive (PUC Lua): prefixing relative paths with " .. tests_dir)
end

-- initialise is not populating *macros* (and shen.*tc* etc.) in a way
-- the bare names the harness and early code expect. Force the initial value
-- that shen.initialise-environment was supposed to install.
-- This is needed for the macro system (defmacro, etc.) to work.
do
  local macros_fn = P.F["shen.macros"]
  if macros_fn and not P.GLOBALS["*macros*"] then
    local entry = R.cons( R.cons(R.intern("shen.macros"), macros_fn), R.NIL )
    P.GLOBALS["*macros*"] = R.cons(entry, R.NIL)
    print("Note: manually seeded *macros* for kernel compatibility")
  end
  -- Also make bare *tc* work if code expects it (the kernel set shen.*tc*)
  if P.GLOBALS["shen.*tc*"] ~= nil and P.GLOBALS["*tc*"] == nil then
    P.GLOBALS["*tc*"] = P.GLOBALS["shen.*tc*"]
  end
end

-- Make y-or-n? non-interactive (harness asks "failed; continue?" on each
-- failure; we want it to always say yes so the test run keeps going and we
-- collect a real pass/fail count for the whole suite).
P.F["y-or-n?"] = function(_msg) return true end
P.FA[P.F["y-or-n?"]] = 1
-- Some tests look up `y-or-n?` via `(fn ...)` (Shen Prolog) and end up calling
-- the symbol — leave the underlying KL function as-is so direct calls work.

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

-- Final counters from the harness. The harness defines *passed* / *failed*
-- inside its `(package test-harness ...)` block, so the bare symbol names get
-- prefixed to `test-harness.*passed*` / `test-harness.*failed*`.
local function getg(...)
  for _, name in ipairs({...}) do
    local v = P.GLOBALS[name]
    if v ~= nil then return v end
  end
  return "?"
end
print(string.format("Counters: passed=%s failed=%s",
  getg("test-harness.*passed*", "*passed*"),
  getg("test-harness.*failed*", "*failed*")))

print("\nDone.")
