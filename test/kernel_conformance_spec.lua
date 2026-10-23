-- test/kernel_conformance_spec.lua — the native typechecker against more
-- than one kernel.
--
--   luajit test/kernel_conformance_spec.lua
--
-- The native typechecker (typecheck_native.lua) translates the kernel's
-- t-star.kl drivers and hand-ports a few kernel defuns. A kernel whose
-- type-checker defuns differ from what the port expects must make it either
-- follow the kernel or fall back to the kernel's own KL typechecker, loudly.
-- It must never keep running and return a different verdict: that is what a
-- ShenOSKernel 43.1 with the deref hoist used to do (its new
-- shen.by-hypothesis-h was called as nil(...), the Lua error surfaced as an
-- ordinary Shen exception, and a caller's trap-error read it as "does not
-- typecheck").
--
-- Each case boots a child process on a kernel directory (SHEN_KL_DIR, with the
-- kernel and fasl caches off so nothing shared is touched), runs a battery of
-- typechecks, and compares the verdicts with the same battery run on the
-- kernel's KL typechecker (SHEN_TYPECHECK_NATIVE=off) and with fixed
-- expectations.
--
-- Kernels:
--   vendored    klambda/ (ShenOSKernel 43.1 at upstream ec16a9f: the deref hoist
--               plus an empty-list guard, shen-sources#117)
--   hoist       43.1 with the deref hoist (test/fixtures/kernel-43.1-deref-hoist)
--   mutated     43.1 whose shen.search-user-datatypes never consults a
--               datatype: the hand port no longer implements it
--   moved       hoist, with shen.by-hypothesis-h moved out of t-star.kl: a
--               driver now calls a predicate the port cannot translate

local here = arg[0]:gsub("test/[^/]*$", "")
if here == "" then here = "./" end

-- ---------------------------------------------------------------------------
-- child mode: boot, run the battery, print one line per verdict
-- ---------------------------------------------------------------------------
if arg[1] == "--child" then
  package.path = here .. "?.lua;" .. package.path
  local shen = require("shen")
  shen.boot{ quiet = true }
  local R = require("runtime")
  local TN = require("typecheck_native")
  local opts = {}
  for i = 2, #arg do opts[arg[i]] = true end

  -- "raw" calls the kernel entry directly: shen.typecheck (the Lua API)
  -- fails closed, turning any error into false
  local function raw_typecheck(expr, ty)
    local f = shen.prims.F["read-from-string"](expr .. " : " .. ty)
    return shen.prims.F["shen.typecheck"](f[1], f[2][2][1])
  end
  local function tc(expr, ty)
    local ok, r = pcall(opts.raw and raw_typecheck or shen.typecheck, expr, ty)
    if not ok then
      local msg = (getmetatable(r) == R.Excn) and tostring(r.msg) or tostring(r)
      return "ERROR " .. msg:gsub("\n", " ")
    end
    return r == false and "false" or R.to_str(r)
  end

  shen.eval([[
(define spec.holds?
  Premise -> (trap-error (= true (eval Premise)) (/. E false)))
(datatype spec-discharge-verified
  if (spec.holds? Premise)
  ______________________
  Premise : verified;)
(datatype spec-box
  X : string;
  (not (= X "")) : verified;
  ================
  [X] : spec-box;)
]])
  local battery = {
    { "(/. X (+ X 1))", "(number --> number)" },
    { "(/. X Y (@p X Y))", "(number --> (string --> (number * string)))" },
    { "(/. X (+ X \"a\"))", "(number --> number)" },
    { "[1 2 3]", "(list number)" },
    { "(let X 1 (+ X X))", "number" },
    { "(/. F X (F (F X)))", "((number --> number) --> (number --> number))" },
    { "(/. X Y (if (= X Y) X Y))", "(symbol --> (symbol --> symbol))" },
    { "[\"hi\"]", "spec-box" },
    { "[\"\"]", "spec-box" },
    { "[37]", "spec-box" },
  }
  if opts["drop-np"] then
    -- warm the drivers, then lose one: the next query must miss loudly
    tc("1", "number")
    rawset(require("prolog_engine").NativePred, "shen.by-hypothesis", nil)
  end
  for i, c in ipairs(battery) do
    io.write("V", i, "\t", c[1], " : ", c[2], "\t", tc(c[1], c[2]), "\n")
  end
  if TN.drivers then
    io.write("PROBLEMS\t", TN.native_problems and #TN.native_problems or 0, "\n")
    io.write("ADDED\t", table.concat(TN.drivers_added, ","), "\n")
    -- the by-hypothesis comparison must stay on the arena (E.eqterm)
    local PC = require("prolog_compile")
    local defs = TN.defuns_of(io.open((os.getenv("SHEN_KL_DIR") or (here .. "klambda"))
                                      .. "/t-star.kl"):read("*a"))
    for _, name in ipairs({ "shen.by-hypothesis", "shen.by-hypothesis-h" }) do
      if defs[name] then
        local _, _, src = PC.translate_defun(defs[name])
        io.write("EQTERM\t", name, "\t", (src and src:find("EQTERM(", 1, true)) and "yes" or "no", "\n")
      end
    end
  end
  os.exit(0)
end

-- ---------------------------------------------------------------------------
-- parent
-- ---------------------------------------------------------------------------
local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end

local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local LUA = os.getenv("LUA")
if not LUA or LUA == "" then LUA = "luajit" end

local function slurp(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a"); f:close()
  return s
end
local function spit(path, s)
  local f = assert(io.open(path, "w"))
  f:write(s); f:close()
end

local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p " .. sh_quote(tmp))

local KERNEL_FILES = {
  "core", "declarations", "dict", "extension-expand-dynamic",
  "extension-features", "extension-launcher", "extension-namespaces",
  "extension-programmable-pattern-matching", "extension-type-annotations",
  "init", "load", "macros", "prolog", "reader", "sequent", "stlib", "sys",
  "t-star", "toplevel", "track", "types", "writer", "yacc",
}
-- a kernel dir: the vendored files, with `edits[name] = function(src) -> src`
local function kernel(name, edits)
  local dir = tmp .. "/" .. name
  os.execute("mkdir -p " .. sh_quote(dir))
  for _, f in ipairs(KERNEL_FILES) do
    local src = slurp(here .. "klambda/" .. f .. ".kl")
    if edits[f] then src = edits[f](src) end
    spit(dir .. "/" .. f .. ".kl", src)
  end
  return dir
end

local HOIST = slurp(here .. "test/fixtures/kernel-43.1-deref-hoist/t-star.kl")

-- replace / remove the single-line (defun NAME ...) of a .kl source
local function defun_line(src, name)
  local pat = "\n%(defun " .. name:gsub("%p", "%%%0") .. " %([^\n]*"
  local s, e = src:find(pat)
  assert(s, "no defun " .. name)
  return s, e
end
local function replace_defun(src, name, with)
  local s, e = defun_line(src, name)
  return src:sub(1, s) .. with .. src:sub(e + 1)
end

local KDIR = {
  vendored = nil,
  hoist = kernel("hoist", { ["t-star"] = function() return HOIST end }),
  mutated = kernel("mutated", { ["t-star"] = function(src)
    return replace_defun(src, "shen.search-user-datatypes",
      "(defun shen.search-user-datatypes (V1 V2 V3 V4 V5 V6 V7) false)")
  end }),
}
do
  local s, e = defun_line(HOIST, "shen.by-hypothesis-h")
  local helper = HOIST:sub(s + 1, e)
  KDIR.moved = kernel("moved", {
    ["t-star"] = function() return HOIST:sub(1, s) .. HOIST:sub(e + 1) end,
    ["sys"] = function(src) return src .. "\n" .. helper .. "\n" end,
  })
end

local function child(kdir, env, opts)
  local cmd = "env " .. (kdir and "" or "-u SHEN_KL_DIR ")
    .. "SHEN_KERNEL_CACHE=off SHEN_FASL=off "
    .. (kdir and ("SHEN_KL_DIR=" .. sh_quote(kdir) .. " ") or "")
    .. (env or "") .. " " .. LUA .. " " .. sh_quote(here .. "test/kernel_conformance_spec.lua")
    .. " --child " .. (opts or "") .. " 2>" .. sh_quote(tmp .. "/stderr")
  local h = io.popen(cmd)
  local out = h:read("*a") or ""
  h:close()
  local res = { verdicts = {}, eqterm = {}, out = out, stderr = slurp(tmp .. "/stderr") }
  for line in out:gmatch("[^\n]+") do
    local f = {}
    for x in line:gmatch("[^\t]+") do f[#f + 1] = x end
    if f[1]:match("^V%d+$") then res.verdicts[#res.verdicts + 1] = f[2] .. " => " .. (f[3] or "")
    elseif f[1] == "PROBLEMS" then res.problems = tonumber(f[2])
    elseif f[1] == "ADDED" then res.added = f[2] or ""
    elseif f[1] == "EQTERM" then res.eqterm[f[2]] = f[3] end
  end
  return res
end

local WANT = {
  "(/. X (+ X 1)) : (number --> number) => (number --> number)",
  "(/. X Y (@p X Y)) : (number --> (string --> (number * string))) => (number --> (string --> (number * string)))",
  "(/. X (+ X \"a\")) : (number --> number) => false",
  "[1 2 3] : (list number) => (list number)",
  "(let X 1 (+ X X)) : number => number",
  "(/. F X (F (F X))) : ((number --> number) --> (number --> number)) => ((number --> number) --> (number --> number))",
  "(/. X Y (if (= X Y) X Y)) : (symbol --> (symbol --> symbol)) => (symbol --> (symbol --> symbol))",
  "[\"hi\"] : spec-box => spec-box",
  "[\"\"] : spec-box => false",
  "[37] : spec-box => false",
}

local function same_list(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end
local function show(r) return table.concat(r.verdicts, " | ") .. "\n" .. r.out .. r.stderr end

local NOTICE = "native typechecker unavailable"

-- vendored and hoisted kernels: native, with no fallback, and the same
-- verdicts as the kernel's KL typechecker
for _, k in ipairs({ "vendored", "hoist" }) do
  local native = child(KDIR[k])
  local legacy = child(KDIR[k], "SHEN_TYPECHECK_NATIVE=off")
  check(same_list(legacy.verdicts, WANT), k .. ": KL typechecker verdicts as expected\n" .. show(legacy))
  check(same_list(native.verdicts, legacy.verdicts), k .. ": native verdicts == KL verdicts\n" .. show(native))
  check(native.problems == 0, k .. ": native typechecker conforms (" .. tostring(native.problems) .. " problems)\n" .. native.stderr)
  check(not native.stderr:find(NOTICE, 1, true), k .. ": no fallback notice\n" .. native.stderr)
  local strict = child(KDIR[k], "SHEN_TYPECHECK_NATIVE=require")
  check(same_list(strict.verdicts, WANT), k .. ": verdicts under SHEN_TYPECHECK_NATIVE=require\n" .. show(strict))
end

do
  -- klambda/ is upstream ec16a9f (the 43.1 release plus shen-sources#117):
  -- the deref-hoisted drivers, plus an empty-list guard in
  -- shen.by-hypothesis / shen.search-user-datatypes
  local v = child(KDIR.vendored)
  check(v.added == "shen.by-hypothesis-h", "vendored: driver closure adds shen.by-hypothesis-h (" .. tostring(v.added) .. ")")
  check(v.eqterm["shen.by-hypothesis-h"] == "yes", "vendored: by-hypothesis-h compares on the arena")
  local h = child(KDIR.hoist)
  check(h.added == "shen.by-hypothesis-h", "hoist: driver closure adds shen.by-hypothesis-h (" .. tostring(h.added) .. ")")
  check(h.eqterm["shen.by-hypothesis-h"] == "yes", "hoist: by-hypothesis-h compares on the arena")
end

-- a hand-ported defun the kernel changed: fall back to the KL typechecker
-- (same verdicts as the changed kernel), say so, and refuse under require
do
  local legacy = child(KDIR.mutated, "SHEN_TYPECHECK_NATIVE=off")
  local native = child(KDIR.mutated)
  check(legacy.verdicts[8] == "[\"hi\"] : spec-box => false",
        "mutated: the changed kernel consults no datatype\n" .. show(legacy))
  check(same_list(native.verdicts, legacy.verdicts), "mutated: native verdicts == mutated kernel's\n" .. show(native))
  check(native.stderr:find(NOTICE, 1, true) and native.stderr:find("shen.search-user-datatypes", 1, true),
        "mutated: stderr names the changed defun\n" .. native.stderr)
  local strict = child(KDIR.mutated, "SHEN_TYPECHECK_NATIVE=require", "raw")
  check(strict.verdicts[1] and strict.verdicts[1]:find("ERROR", 1, true)
        and strict.verdicts[1]:find("SHEN_TYPECHECK_NATIVE=require", 1, true),
        "mutated: require mode raises\n" .. show(strict))
end

-- a driver that calls a predicate outside t-star.kl: caught before any query
do
  local legacy = child(KDIR.moved, "SHEN_TYPECHECK_NATIVE=off")
  local native = child(KDIR.moved)
  check(same_list(legacy.verdicts, WANT), "moved: KL typechecker verdicts as expected\n" .. show(legacy))
  check(same_list(native.verdicts, WANT), "moved: native falls back with the right verdicts\n" .. show(native))
  check(native.stderr:find("calls shen.by-hypothesis-h, which is neither", 1, true),
        "moved: stderr names the unresolvable call\n" .. native.stderr)
end

-- a predicate lost at run time: the query misses loudly and is rerun on the
-- KL engine, never answered from a nil call
do
  local native = child(nil, nil, "drop-np")
  check(same_list(native.verdicts, WANT), "drop-np: verdicts unchanged\n" .. show(native))
  check(native.stderr:find("no native predicate shen.by-hypothesis", 1, true),
        "drop-np: stderr names the missing predicate\n" .. native.stderr)
end

os.execute("rm -rf " .. sh_quote(tmp))
io.write(string.format("kernel_conformance_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
