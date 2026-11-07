-- certify_spec.lua : make certify can fail. Runs run-kernel-tests.lua over a tiny
-- suite (SHEN_TESTS_DIR) that passes, fails, stops early and runs too few tests.
local here = (arg[0]:gsub("test/[^/]*$", ""))
if here == "" then here = "./" end
local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else nfail = nfail + 1; print("FAIL " .. name) end
end
local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local LUA = (arg[-1] or "luajit")

local dir = os.tmpname(); os.remove(dir); os.execute("mkdir -p " .. sh_quote(dir))
os.execute("cp " .. sh_quote(here .. "tests/harness.shen") .. " " .. sh_quote(dir .. "/harness.shen"))
local function suite(body)
  local f = assert(io.open(dir .. "/kerneltests.shen", "w")); f:write(body); f:close()
end
local function run(expected)
  local cmd = "cd " .. sh_quote(here) .. " && SHEN_TESTS_DIR=" .. sh_quote(dir)
    .. " SHEN_EXPECTED_TESTS=" .. expected .. " SHEN_FASL=off " .. LUA .. " run-kernel-tests.lua"
  local h = io.popen("{ " .. cmd .. " ; } 2>&1; echo \"__EXIT__:$?\"")
  local out = h:read("*a"); h:close()
  return tonumber(out:match("__EXIT__:(%d+)%s*$")), out
end
local function case(name, body, expected, want, counters)
  suite(body)
  local code, out = run(expected)
  check(code == want, name .. ": exit " .. tostring(code) .. ", wanted " .. want .. "\n" .. out:sub(-300))
  check(out:find(counters, 1, true) ~= nil, name .. ": counters, wanted " .. counters)
end
local good = '(report "t" 1 1 2 2)\n(reset)\n'
case("all pass", good, 2, 0, "Counters: passed=2 failed=0")
case("a wrong answer", '(report "t" 1 1 2 3)\n(reset)\n', 2, 1, "Counters: passed=1 failed=1")
case("an error in a test", '(report "t" 1 1 (simple-error "x") 2)\n(reset)\n', 2, 1, "Counters: passed=1 failed=1")
case("too few tests ran", good, 3, 1, "Counters: passed=2 failed=0")
case("the suite stops early", '(report "t" 1 1)\n(this is not closed\n', 1, 1, "Counters: passed=")
-- a kernel with no count on record fails and says what to do
do
  suite(good)
  local src = assert(io.open(here .. "run-kernel-tests.lua")):read("*a")
  src = src:gsub('%["43%.2"%] = 154', '["0.0"] = 1')
  local copy = dir .. "/rkt.lua"
  local f = assert(io.open(copy, "w")); f:write(src); f:close()
  local cmd = "cd " .. sh_quote(here) .. " && SHEN_TESTS_DIR=" .. sh_quote(dir)
    .. " SHEN_FASL=off " .. LUA .. " " .. sh_quote(copy)
  local h = io.popen("{ " .. cmd .. " ; } 2>&1; echo \"__EXIT__:$?\"")
  local out = h:read("*a"); h:close()
  check(tonumber(out:match("__EXIT__:(%d+)%s*$")) == 1, "unknown kernel: exit 1\n" .. out:sub(-200))
  check(out:find("no expected test count for kernel", 1, true) ~= nil, "unknown kernel: says why")
end
os.execute("rm -rf " .. sh_quote(dir))

print(("certify_spec: %d pass, %d fail"):format(npass, nfail))
os.exit(nfail == 0 and 0 or 1)
