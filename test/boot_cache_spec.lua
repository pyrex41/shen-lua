-- test/boot_cache_spec.lua — PORT-AUTHORED coverage for the boot caches
-- (pyrex41/shen-lua#46).
--
-- Two layers of the boot are cached, and each replaces work that used to be
-- redone on every single start:
--
--   * the kernel bytecode cache (.shen-kernel-cache.<build>.bin) holds the
--     compiled ShenOSKernel 42.2 modules, including the precompiled stdlib
--     (klambda/stlib.kl);
--   * its sidecar (<kernel cache>.stlib) holds the 290 standard-library type
--     signatures that (stlib.initialise-types) declares, as dumped prolog
--     abstractions, plus the gensym / inference counters `declare` advances;
--   * two kernel functions that used to run the compiler at boot,
--     shen.lambda-entry and shen.assoc->, are native.
--
-- The single property that makes all of that legitimate is that a CACHED boot
-- and an UNCACHED one must be indistinguishable at the Shen level. That is what
-- this spec pins, end to end, by booting subprocesses in every cache
-- configuration and diffing a state fingerprint — plus the two natives against
-- the compiled-KL definitions they replace, in process.
--
--   luajit test/boot_cache_spec.lua

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end

local here = arg[0]:gsub("test/[^/]*$", "")
if here == "" then here = "./" end

local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function run(cmd)
  local h = io.popen(cmd .. " 2>&1")
  if not h then return "", -1 end
  local out = h:read("*a") or ""
  h:close()
  return out
end

-- ---------------------------------------------------------------------------
-- Part 1 — a cached boot is indistinguishable from an uncached one.
--
-- The fingerprint covers exactly the state the caches reconstruct rather than
-- recompute: shen.*sigf* (the 161 signatures, by name AND order — assoc-> order
-- is observable), the lambda table size, the datatype tables, and the two
-- counters (`declare` and shen.lambda-function used to consume gensyms that a
-- cached boot never spends, so they are recorded and restored). It also runs a
-- real typecheck, so a signature closure that replayed to something merely
-- shaped right still fails here.
-- ---------------------------------------------------------------------------
local FINGERPRINT = [[
package.path = %s .. "?.lua;" .. package.path
local R = require("runtime")
local P = require("boot")
P.load_kernel(false); P.initialise()
local function names(l)
  local out = {}
  while R.is_cons(l) do
    local e = l[1]
    out[#out+1] = R.is_cons(e) and (R.is_symbol(e[1]) and e[1].name or "?")
                  or (R.is_symbol(e) and e.name or "?")
    l = l[2]
  end
  return out
end
local sig = names(P.GLOBALS["shen.*sigf*"])
print("sigf " .. #sig .. " " .. table.concat(sig, ","))
print("userdefs " .. #names(P.GLOBALS["shen.*userdefs*"]))
print("arity " .. tostring(P.F["arity"](R.intern("filter"))))
print("alldatatypes " .. table.concat(names(P.GLOBALS["shen.*alldatatypes*"]), ","))
print("datatypes " .. table.concat(names(P.GLOBALS["shen.*datatypes*"]), ","))
print("gensym " .. tostring(P.GLOBALS["shen.*gensym*"]))
print("infs " .. tostring(P.GLOBALS["shen.*infs*"]))
P.GLOBALS["*hush*"] = true
local forms = P.F["read-from-string"](
  [==[(tc +) (define bcs-sq {number --> number} X -> (* X X)) (bcs-sq 7)]==])
local last
while R.is_cons(forms) do last = P.F["eval"](forms[1]); forms = forms[2] end
print("typecheck " .. tostring(last))
]]

do
  local script = os.tmpname() .. ".lua"
  local h = io.open(script, "w")
  h:write(FINGERPRINT:format(string.format("%q", here)))
  h:close()

  -- Every configuration gets a private fasl dir, so "cold" really is cold and
  -- the developer's ~/.cache state cannot make this pass or fail.
  local function fresh() local d = os.tmpname(); os.remove(d); return d end
  local kcache = os.tmpname(); os.remove(kcache)
  local function boot(env)
    return run("env " .. env .. " luajit " .. sh_quote(script))
  end

  local d1, d2 = fresh(), fresh()
  -- (a) nothing cached at all: the reference
  local ref = boot("SHEN_KERNEL_CACHE=off SHEN_FASL=off")
  -- (b) kernel bytecode cache + stdlib signature sidecar cold, then warm
  local kc = "SHEN_KERNEL_CACHE=" .. sh_quote(kcache)
  local kcold = boot(kc .. " SHEN_FASL_DIR=" .. sh_quote(d1))
  local sidecar = io.open(kcache .. ".stlib", "rb")
  local sidecar_data = sidecar and sidecar:read("*a")
  if sidecar then sidecar:close() end
  local kwarm = boot(kc .. " SHEN_FASL_DIR=" .. sh_quote(d1))
  local kwarm2 = boot(kc .. " SHEN_FASL_DIR=" .. sh_quote(d2))

  -- 163 kernel + 3 features + 2 pattern-matching + 4 checked-integer + 290
  -- stdlib (shen-scheme 0.50 reports 458: the same minus checked-integer)
  check(ref:find("sigf 462 ", 1, true) ~= nil,
        "#46: uncached boot registers kernel, extension, checked-integer and stdlib signatures")
  check(ref:find("typecheck 49", 1, true) ~= nil,
        "#46: uncached boot typechecks a user definition")
  check(ref:find("arity 2", 1, true) ~= nil,
        "#46: stdlib functions are registered (arity filter = 2)")
  check(kcold == ref, "#46: cold kernel-bytecode-cache boot == uncached boot")
  check(sidecar_data ~= nil and sidecar_data:sub(1, 8) == "SHENSIG1",
        "#46: a cold boot writes the stdlib signature sidecar")
  check(kwarm == ref, "#46: WARM kernel-bytecode-cache + signature sidecar boot == uncached boot")
  check(kwarm2 == ref, "#46: warm boot with a fresh fasl dir == uncached boot")

  -- A damaged sidecar must be a miss (the real declares run), never an error
  -- or a half-applied replay.
  do
    local w = io.open(kcache .. ".stlib", "wb")
    w:write((sidecar_data or "SHENSIG1\n"):sub(1, 4000)); w:close()
    local damaged = boot(kc .. " SHEN_FASL_DIR=" .. sh_quote(d1))
    check(damaged == ref, "#46: a truncated signature sidecar falls back to the real declares")
    local again = boot(kc .. " SHEN_FASL_DIR=" .. sh_quote(d1))
    check(again == ref, "#46: the sidecar is rewritten after a miss")
  end

  os.remove(script); os.remove(kcache); os.remove(kcache .. ".stlib")
  for _, d in ipairs({ d1, d2 }) do os.execute("rm -rf " .. sh_quote(d)) end
end

-- ---------------------------------------------------------------------------
-- Part 2 — the two natives against the compiled-KL definitions they replace.
--
-- shen.assoc-> (reader.kl) and shen.lambda-entry (declarations.kl) are now Lua.
-- Both are load-bearing for shen.*lambdatable* / shen.*sigf* / shen.*datatypes*,
-- so compile the kernel's own definitions under an alias and compare.
-- ---------------------------------------------------------------------------
package.path = here .. "?.lua;" .. package.path
local R = require("runtime")
local C = require("compiler")
local P = require("boot")
P.load_kernel(false)
P.initialise()
local F = P.F

do
  -- shen.assoc->: compile the kernel definition under an alias name.
  local src = assert(io.open(here .. "klambda/reader.kl", "rb")):read("*a")
  for _, f in ipairs(R.read_all(src)) do
    if R.is_cons(f) and R.is_symbol(f[1]) and f[1].name == "defun"
       and R.is_cons(f[2]) and R.is_symbol(f[2][1])
       and f[2][1].name == "shen.assoc->" then
      P.load_chunk(C.compile_top(f):gsub("shen%.assoc%->", "spec.assoc->"), "alias")()
    end
  end
  local kl = F["spec.assoc->"]
  check(kl ~= nil, "#46: kernel shen.assoc-> compiled under an alias")

  local S = R.intern
  local function list(...)
    local t, a = R.NIL, {...}
    for i = #a, 1, -1 do t = R.cons(a[i], t) end
    return t
  end
  local pair = R.cons
  local cases = {
    { S"a", 1, R.NIL },                                     -- empty list
    { S"a", 1, list(pair(S"a", 9)) },                        -- replace only
    { S"b", 2, list(pair(S"a", 9)) },                        -- append at end
    { S"c", 3, list(pair(S"a",9), pair(S"b",8), pair(S"c",7), pair(S"d",6)) },
    { S"a", 3, list(pair(S"a",9), pair(S"b",8), pair(S"a",7)) },  -- first wins
    { S"z", 3, list(pair(S"a",9), pair(S"b",8)) },
    { S"z", 3, list(S"not-a-pair", pair(S"b",8)) },          -- non-pair entry
    { 5,    3, list(pair(5,9), pair(6,8)) },                 -- numeric keys
    { "s",  3, list(pair("s",9)) },                          -- string keys
    { S"a", 1, R.cons(pair(S"b",1), S"improper") },          -- improper tail
    { S"a", 1, S"improper" },                                -- not a list
  }
  local bad = 0
  for i, c in ipairs(cases) do
    local ok1, r1 = pcall(kl, c[1], c[2], c[3])
    local ok2, r2 = pcall(F["shen.assoc->"], c[1], c[2], c[3])
    -- errors: both must fail (the message names the alias in one case, so the
    -- comparison is on success/failure plus the value)
    if ok1 ~= ok2 then bad = bad + 1
    elseif ok1 and R.to_str(r1) ~= R.to_str(r2) then bad = bad + 1 end
    if bad > 0 and i == #cases then break end
  end
  check(bad == 0, "#46: native shen.assoc-> matches the compiled-KL definition")
end

do
  -- shen.lambda-entry: rebuild the KL result (eval-kl of shen.lambda-function)
  -- and compare full application, partial application, and the arity 0 / -1
  -- cases, over a spread of live arities.
  local function kl_entry(name)
    local ar = F["arity"](name)
    if ar == -1 or ar == 0 then return R.NIL end
    return R.cons(name, F["eval-kl"](
      F["shen.lambda-function"](R.cons(name, R.NIL), ar)))
  end
  local probes = {
    { "hd",           { R.cons(1, R.cons(2, R.NIL)) } },
    { "cons",         { 1, R.NIL } },
    { "append",       { R.cons(1, R.NIL), R.cons(2, R.NIL) } },
    { "shen.assoc->", { R.intern("k"), 1, R.NIL } },
    { "reverse",      { R.cons(1, R.cons(2, R.NIL)) } },
    { "nth",          { 1, R.cons(7, R.NIL) } },
    { "map",          { R.intern("hd"), R.cons(R.cons(1, R.NIL), R.NIL) } },
    { "+",            { 2, 3 } },
  }
  local bad, npartial, nprobed = 0, 0, 0
  for _, p in ipairs(probes) do
    local sym = R.intern(p[1])
    local a, b = kl_entry(sym), F["shen.lambda-entry"](sym)
    if not (R.is_cons(a) and R.is_cons(b)) then
      -- both must agree that this name has no lambda table entry
      if R.is_cons(a) ~= R.is_cons(b) then bad = bad + 1 end
      goto continue
    end
    nprobed = nprobed + 1
    local function apply_all(fn)
      local cur = fn
      for _, x in ipairs(p[2]) do cur = P.APP(cur, x) end
      return cur
    end
    local ok1, r1 = pcall(apply_all, a[2])
    local ok2, r2 = pcall(apply_all, b[2])
    if ok1 ~= ok2 or (ok1 and R.to_str(r1) ~= R.to_str(r2)) then bad = bad + 1 end
    if #p[2] > 1 then
      -- a partial application must still be a function on both sides
      npartial = npartial + 1
      if type(P.APP(a[2], p[2][1])) ~= type(P.APP(b[2], p[2][1])) then bad = bad + 1 end
    end
    ::continue::
  end
  check(bad == 0, "#46: native shen.lambda-entry matches the compiled-KL definition")
  check(nprobed >= 6, "#46: lambda-entry differential covered the probe set (" .. nprobed .. ")")
  check(npartial > 0, "#46: lambda-entry partial application was exercised")
  check(F["shen.lambda-entry"](R.intern("stinput")) == R.NIL,
        "#46: lambda-entry is () for an arity-0 name")
  check(F["shen.lambda-entry"](R.intern("no-such-function-xyz")) == R.NIL,
        "#46: lambda-entry is () for an unknown name")
end

io.write(("boot_cache_spec: %d pass, %d fail\n"):format(npass, nfail))
os.exit(nfail == 0 and 0 or 1)
