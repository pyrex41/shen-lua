-- unii/build.lua -- typecheck the rule bundle and record the build stamp.
--
--   luajit unii/build.lua            (or: unii/bin/unii build)
--
-- 1. Checks the toolchain (LuaJIT 2.1) and, when git is available, that the
--    shen-lua runtime outside unii/ is byte-identical to the pinned commit.
-- 2. Loads every core file under (tc +) with the fasl cache disabled, so the
--    kernel typechecker really runs, and confirms that a deliberately
--    ill-typed rules module is rejected (the check is live, not vacuous).
-- 3. Writes unii/build/bundle.stamp with the bundle hash. Boot refuses any
--    bundle whose hash differs from the stamp.
local ffi = require("ffi")
ffi.cdef [[ int setenv(const char *name, const char *value, int overwrite); ]]
ffi.C.setenv("SHEN_FASL", "off", 1)

local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/build%.lua$") or "unii"
local root = here:match("^(.*)/unii$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local manifest = require("unii.manifest")
local core = require("unii.host.core")

local function step(msg) io.stdout:write("[build] ", msg, "\n") end
local function die(msg) io.stderr:write("[build] FAILED: ", msg, "\n"); os.exit(1) end

-- 1. toolchain and pinned runtime
if not jit or not jit.version:match("^LuaJIT 2%.1") then
  die("LuaJIT 2.1 required, running " .. (jit and jit.version or _VERSION))
end
step("toolchain " .. jit.version .. " " .. jit.os .. "/" .. jit.arch)

local pin = manifest.shen_lua.commit
local git_ok = os.execute(("git -C %q rev-parse --verify -q %s^{commit} >/dev/null 2>&1"):format(root, pin))
if git_ok == 0 or git_ok == true then
  local same = os.execute(("git -C %q diff --quiet %s -- . ':(exclude)unii' 2>/dev/null"):format(root, pin))
  if not (same == 0 or same == true) then
    die("shen-lua runtime outside unii/ differs from pinned commit " .. pin)
  end
  local untracked = io.popen(("git -C %q ls-files --others --exclude-standard -- . ':(exclude)unii'"):format(root)):read("*a")
  if untracked ~= "" then die("untracked files outside unii/:\n" .. untracked) end
  step("shen-lua runtime matches pinned commit " .. pin:sub(1, 12))
else
  step("WARNING: git or pinned commit unavailable; runtime pin not verified")
end

-- 2. typecheck
local t0 = os.clock()
local ok, err = pcall(core.load_bundle, here)
if not ok then die(err) end
step(("typechecked %d core files under (tc +) in %.2fs CPU"):format(#manifest.core_files, os.clock() - t0))

local shen = core.shen()
shen.eval("(tc +)")
local bad = here .. "/test/fixtures/ill_typed_rules.shen"
local rejected, why = pcall(shen.prims.F["load"], bad)
shen.eval("(tc -)")
if rejected then die("typechecker accepted " .. bad .. "; type checking is not live") end
step("ill-typed fixture rejected: " .. core.error_message(why):gsub("\n.*", ""))

-- 3. stamp
local hash = core.bundle_hash(here)
os.execute(("mkdir -p %q"):format(here .. "/build"))
local f = assert(io.open(core.stamp_path(here), "wb"))
f:write("bundle ", hash, "\n",
        "bundle_format ", manifest.bundle_format, "\n",
        "files ", table.concat(manifest.core_files, " "), "\n",
        "shen_lua ", pin, "\n",
        "luajit ", jit.version, "\n")
f:close()
step("bundle " .. hash .. " -> " .. core.stamp_path(here))
