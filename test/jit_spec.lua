-- test/jit_spec.lua — the SHEN_JIT=off / shen.boot{jit=false} switch (issue #43).
--
-- On aarch64 LuaJIT's trace compiler intermittently SIGSEGVs while compiling
-- the kernel during boot. The mitigation is an in-library way to boot with the
-- JIT disabled (jit.off(), the equivalent of `luajit -j off`). This spec drives
-- a fresh LuaJIT subprocess per case and asserts, via jit.status(), that:
--   * SHEN_JIT=off  actually turns the compiler OFF, and boot still works;
--   * shen.boot{jit=false} does the same programmatically;
--   * SHEN_JIT_OPT=off does NOT disable the JIT (it only resets jit.opt) —
--     the distinction the issue calls out;
--   * the default boot leaves the JIT ON.
--
-- Inherently a LuaJIT test: on PUC Lua (no `jit`) there is nothing to disable,
-- so the whole spec skips cleanly.
--
--   luajit test/jit_spec.lua

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end

-- Nothing to test without a JIT — skip cleanly on PUC Lua.
if not rawget(_G, "jit") then
  io.write("jit_spec: SKIP (no LuaJIT — nothing to disable)\n")
  io.write("jit_spec: 0 pass, 0 fail\n")
  os.exit(0)
end

-- Repo root relative to this spec, so the child's require() finds the modules.
local root = arg[0]:gsub("test/[^/]*$", "")
if root == "" then root = "./" end

local function have(cmd)
  local h = io.popen("command -v " .. cmd .. " 2>/dev/null")
  if not h then return false end
  local out = h:read("*a"); h:close()
  return out ~= nil and out:match("%S") ~= nil
end
local TIMEOUT = have("timeout") and "timeout 60 " or (have("gtimeout") and "gtimeout 60 " or "")

local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- Boot the kernel in a fresh LuaJIT process with the given env prefix and Lua
-- body, then print "JIT:<on|off> VAL:<eval result>" so the parent can assert on
-- both the compiler state after boot and that boot actually produced a value.
-- The kernel bytecode cache is disabled so every case exercises a real boot.
local BODY = [[
local shen = require("shen")
%s
local v = shen.eval("(+ 1 2)")
io.write("JIT:", (require("jit").status()) and "on" or "off", " VAL:", tostring(v), "\n")
]]

local function run_case(env, boot_stmt)
  local body = BODY:format(boot_stmt)
  local cmd = "env LUA_PATH=" .. sh_quote(root .. "?.lua;;")
    .. " SHEN_KERNEL_CACHE=off " .. env
    .. " luajit -e " .. sh_quote(body)
  local full = "{ " .. TIMEOUT .. cmd .. " ; } 2>&1; echo \"__EXIT__:$?\""
  local h = io.popen(full, "r")
  local out = h:read("*a") or ""
  h:close()
  local code = tonumber(out:match("__EXIT__:(%d+)%s*$")) or -1
  out = out:gsub("__EXIT__:%d+%s*$", "")
  return out, code
end

-- 1. Default boot: JIT stays on, boot works.
do
  local out, code = run_case("", 'shen.boot{quiet=true}')
  check(code == 0, "default boot exits 0")
  check(out:find("JIT:on", 1, true) ~= nil, "default boot leaves the JIT ON")
  check(out:find("VAL:3", 1, true) ~= nil, "default boot: (+ 1 2) => 3")
end

-- 2. SHEN_JIT=off: JIT disabled, boot still works.
do
  local out, code = run_case("SHEN_JIT=off", 'shen.boot{quiet=true}')
  check(code == 0, "SHEN_JIT=off boot exits 0")
  check(out:find("JIT:off", 1, true) ~= nil, "SHEN_JIT=off disables the JIT")
  check(out:find("VAL:3", 1, true) ~= nil, "SHEN_JIT=off: kernel still boots and evaluates")
end

-- 3. shen.boot{jit=false}: the programmatic equivalent.
do
  local out, code = run_case("", 'shen.boot{quiet=true, jit=false}')
  check(code == 0, "boot{jit=false} exits 0")
  check(out:find("JIT:off", 1, true) ~= nil, "boot{jit=false} disables the JIT")
  check(out:find("VAL:3", 1, true) ~= nil, "boot{jit=false}: kernel still boots and evaluates")
end

-- 4. SHEN_JIT_OPT=off resets jit.opt but must NOT disable the JIT (issue #43's
--    key distinction: the old flag would not have prevented the crash).
do
  local out, code = run_case("SHEN_JIT_OPT=off", 'shen.boot{quiet=true}')
  check(code == 0, "SHEN_JIT_OPT=off boot exits 0")
  check(out:find("JIT:on", 1, true) ~= nil, "SHEN_JIT_OPT=off leaves the JIT ON (distinct from SHEN_JIT=off)")
end

io.write(string.format("jit_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
