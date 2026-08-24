-- Shen Batteries feature bridge (including shen-extensions capabilities).
--
--   luajit test/features_spec.lua
local shen = require("shen")
shen.boot{ quiet = true }
local R = require("runtime")
local P = shen.prims

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else nfail = nfail + 1; io.write("FAIL: ", name, "\n") end
end

local function names(xs)
  local out = {}
  while R.is_cons(xs) do
    out[tostring(xs[1])] = true
    xs = xs[2]
  end
  return out
end

local ok, current = pcall(shen.call, "shen.x.features.current")
check(ok, "features.current is callable after boot")
if ok then
  local have = names(current)
  local backend = P.GLOBALS["shen.x.*sha256-backend*"]
  if backend == R.intern("host") then
    check(have["shen.x/sha256-host"] == true,
      "host SHA-256 backend is advertised to Batteries")
  else
    check(have["shen.x/sha256-host"] ~= true,
      "non-host SHA-256 backend is not advertised as host")
  end
  check(not have["shen.x/zmq-host"], "unsupported ZMQ backend is not advertised")
end

io.write(string.format("features_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
