-- codegen_diff_spec.lua : compiled output against itself. Every optimisation switch off
-- gives the same results as all on, over a fixed fuzz program and an exhaustive set of
-- shapes built to reach count sinking's second compile. And no compiled chunk reads a
-- global that is not in the compiled environment: a local whose declaration got lost
-- reads as nil, with no error at all.
local here = (arg[0]:gsub("test/[^/]*$", ""))
if here == "" then here = "./" end
package.path = here .. "?.lua;" .. package.path
local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else nfail = nfail + 1; print("FAIL " .. name) end
end
local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local LUA = arg[-1] or "luajit"
local dir = os.tmpname(); os.remove(dir); os.execute("mkdir -p " .. sh_quote(dir))

-- the shapes: test x then x else, with arguments that reach each branch
local TESTS = {
  "(if (cons? (tl (tl X))) (not (cons? Y)) false)", "(if (cons? (tl X)) (not (cons? Y)) false)",
  "(if (cons? (tl (tl X))) (not (= Y 1)) false)", "(if (= Y 1) (not (cons? (tl (tl X)))) false)",
  "(not (if (cons? (tl (tl X))) (not (cons? Y)) false))",
  "(if (cons? (tl (tl X))) (not (cons? Y)) (or (cons? Y) false))",
  "(if (cons? (tl (tl X))) (not (cons? Y)) (not (cons? N)))",
  "(or (not (cons? Y)) (if (cons? (tl (tl X))) true false))",
  "(and (not (cons? Y)) (cons? (tl (tl X))))", "(and (cons? (tl (tl X))) (not (cons? Y)))",
  "(or (cons? (tl (tl X))) (not (cons? Y)))",
}
local THENS = {
  "(if (number? (hd (tl N))) 1 2)", "(hd (tl N))", "(if (cons? (tl N)) (hd (tl N)) 0)",
  "(if (= (hd (tl N)) 1) (hd (tl N)) (tl (tl N)))", "(if (= (hd (tl X)) 1) a b)",
}
local ELSES = {
  "(/. Q N)", "(/. Q Q)", "(/. Q (/. R N))", "(freeze N)", "(/. Q (sf N))", "(sf N)", "(+ 1 (sf N))",
  "(let A (/. Q N) A)", "0",
}
local ARGS = {
  "[0 1 2] [0 1 2] 0", "[0 1] [0 1] 0", "0 [0 1] 0", "[0 1 2] [0] [1]", "7 [0] 0", "[1 1] 5 1",
}
local shapes = dir .. "/shapes.shen"
do
  local f = assert(io.open(shapes, "w"))
  f:write("(define sf X -> X)\n",
    "(define show F -> (trap-error (let V (thaw F) (if (or (cons? V) (number? V) (symbol? V)) V fn)) (/. E raised)))\n")
  local n = 0
  for _, t in ipairs(TESTS) do for _, th in ipairs(THENS) do for _, e in ipairs(ELSES) do
    n = n + 1
    f:write("(define x", n, " N X Y -> (if ", t, " ", th, " ", e, "))\n")
    for i, a in ipairs(ARGS) do
      f:write('(output "', n, ".", i, " ~S~%\" (show (freeze (x", n, " ", a, "))))\n")
    end
  end end end
  f:close()
end
local function run(path, sw)
  local cache = dir .. "/kc-" .. (sw or "all") .. ".bin"
  local cmd = "env SHEN_FASL=off SHEN_KERNEL_CACHE=" .. sh_quote(cache) .. (sw and (" " .. sw .. "=off") or "")
    .. " " .. LUA .. " " .. sh_quote(here .. "bin/shen") .. " --hush-load " .. sh_quote(path) .. " 2>&1"
  local h = io.popen(cmd); local out = h:read("*a"); h:close()
  return (out:gsub("funex%d+", "funex"):gsub("[^ \n]*:%d+: ", ""))
end
local SWITCHES = { "SHEN_SINK_COUNT", "SHEN_UNCURRY", "SHEN_HOIST_LAMBDA", "SHEN_TRMC", "SHEN_FREEZE_CONT" }
local fuzz = here .. "test/fixtures/codegen-fuzz-112.shen"
for _, prog in ipairs({ { "shapes", shapes }, { "fuzz", fuzz } }) do
  local want = run(prog[2])
  check(#want > 1000, prog[1] .. ": the program ran, got " .. want:sub(1, 200))
  for _, sw in ipairs(SWITCHES) do
    local got = run(prog[2], sw)
    if got == want then npass = npass + 1 else
      local a, b = want:gmatch("[^\n]+"), got:gmatch("[^\n]+")
      local x, y = a(), b()
      while x and x == y do x, y = a(), b() end
      nfail = nfail + 1
      print("FAIL " .. prog[1] .. " with " .. sw .. "=off differs:\n  on:  " .. tostring(x) .. "\n  off: " .. tostring(y))
    end
  end
end

-- no undeclared global, in the kernel, the stdlib, the shapes and the fuzz program
if jit then
  local getenv = os.getenv
  local fresh = dir .. "/kc-scan.bin"
  os.getenv = function(k)
    if k == "SHEN_KERNEL_CACHE" then return fresh end
    if k == "SHEN_FASL" then return "off" end
    return getenv(k)
  end
  local C = require("compiler")
  local chunks = {}
  for _, name in ipairs({ "compile_top", "compile_expr_chunk" }) do
    local orig = C[name]
    C[name] = function(...)
      local src = orig(...)
      chunks[#chunks + 1] = src
      return src
    end
  end
  local shen = require("shen")
  shen.boot{ quiet = true }
  local nkernel = #chunks
  check(nkernel > 500, "the scan saw the kernel compile, got " .. nkernel)
  shen.prims.HUSH_LOAD_ECHO = true
  -- what the programs print is not what this part checks
  shen.prims.GLOBALS["*stoutput*"] = shen.call("open", "/dev/null", shen.runtime.intern("out"))
  local function quiet_load(p) return pcall(shen.call, "load", p) end
  local vmdef, util = require("jit.vmdef"), require("jit.util")
  local bcnames = vmdef.bcnames
  local function opname(ins) local i = ins % 256; return bcnames:sub(i * 6 + 1, i * 6 + 6):gsub(" ", "") end
  local function scan(proto, seen)
    local info = util.funcinfo(proto)
    for pc = 1, info.bytecodes - 1 do
      local ins = util.funcbc(proto, pc)
      if not ins then break end
      local op = opname(ins)
      if op == "GGET" or op == "GSET" then
        local d = math.floor(ins / 65536)
        seen[util.funck(proto, -d - 1)] = true
      end
    end
    for i = 1, info.gcconsts do
      local k = util.funck(proto, -i)
      if type(k) == "proto" then scan(k, seen) end
    end
  end
  quiet_load(shapes)
  quiet_load(fuzz)
  local ENV, bad, n = shen.prims.ENV, {}, 0
  for _, src in ipairs(chunks) do
    n = n + 1
    local fn = assert((loadstring or load)(src, "=scan"))
    local seen = {}
    scan(fn, seen)
    for g in pairs(seen) do
      if rawget(ENV, g) == nil and not bad[g] then bad[g] = src:sub(1, 120) end
    end
  end
  check(n > nkernel + 500, "the scan saw the test programs, got " .. (n - nkernel))
  for g, s in pairs(bad) do
    nfail = nfail + 1
    print("FAIL undeclared global " .. tostring(g) .. " in: " .. s)
  end
  if next(bad) == nil then npass = npass + 1 end
end

os.execute("rm -rf " .. sh_quote(dir))
print(("codegen_diff_spec: %d pass, %d fail"):format(npass, nfail))
os.exit(nfail == 0 and 0 or 1)
