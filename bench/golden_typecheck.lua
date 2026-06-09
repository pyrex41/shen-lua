-- bench/golden_typecheck.lua — golden-corpus harness for the typechecker and
-- Prolog engine. Captures (input, result) pairs under one engine and compares
-- a later run (e.g. the native soa32 engine) against them, up to
-- alpha-renaming of prolog variables.
--
-- Usage:
--   luajit bench/golden_typecheck.lua capture   -- write bench/golden_typecheck.golden
--   luajit bench/golden_typecheck.lua compare   -- diff current results vs golden
--
-- The corpus deliberately mixes: the 431k-inference y-combinator typecheck
-- (with interpreter.shen's datatypes loaded, so search-user-datatypes runs),
-- small positive typechecks across the type-rule surface (lambda/let/if/
-- cons/tuples/higher-order), negative typechecks (must yield false), and the
-- Einstein's-riddle Prolog query (cut/member/backtracking through compiled
-- defprolog clauses).
--
-- Results are serialized with pvars alpha-normalized to ?1, ?2, ... in
-- first-occurrence order, so engines that allocate different variable tickets
-- (or different inference counts) still compare equal when semantically equal.

local P = require("boot"); local R = require("runtime")
P.load_kernel(false); P.initialise()

local ffi = require("ffi")
ffi.cdef[[int chdir(const char*); char *getcwd(char*, size_t);]]
-- resolve the golden-file path BEFORE chdir'ing into the kernel tests dir
local cwdbuf = ffi.new("char[4096]")
assert(ffi.C.getcwd(cwdbuf, 4096) ~= nil)
local ROOT = ffi.string(cwdbuf)
assert(ffi.C.chdir("../cl-source/ShenOSKernel-41.1/tests") == 0,
       "tests dir not found (expected ../cl-source/ShenOSKernel-41.1/tests)")

-- same environment fixes typecheck_alloc.lua needs
local mf = P.F["shen.macros"]
if mf and not P.GLOBALS["*macros*"] then
  P.GLOBALS["*macros*"] = R.cons(R.cons(R.cons(R.intern("shen.macros"), mf), R.NIL), R.NIL)
end
if P.GLOBALS["shen.*tc*"] ~= nil and P.GLOBALS["*tc*"] == nil then
  P.GLOBALS["*tc*"] = P.GLOBALS["shen.*tc*"]
end

P.F["load"]("interpreter.shen")

-- ---------------------------------------------------------------------------
-- serializer: deterministic, pvar-alpha-normalized
-- ---------------------------------------------------------------------------
local Symbol, Cons, Vmt, NIL = R.Symbol, R.Cons, R.Vmt, R.NIL
local shen_pvar = R.intern("shen.pvar")
local getmt = getmetatable

local function ser(x, env)
  if x == NIL then return "()" end
  local t = type(x)
  if t == "boolean" then return tostring(x) end
  if t == "number" then return string.format("%.17g", x) end
  if t == "string" then return string.format("%q", x) end
  if t == "function" then return "#<fn>" end
  local mt = getmt(x)
  if mt == Symbol then return x.name end
  if mt == Cons then
    return "(" .. ser(x[1], env) .. " . " .. ser(x[2], env) .. ")"
  end
  if mt == Vmt then
    if x[2] == shen_pvar then
      local n = env[x]
      if not n then n = env.n + 1; env.n = n; env[x] = n end
      return "?" .. n
    end
    local parts = {}
    for i = 1, (x[1] or 0) + 1 do parts[i] = ser(x[i + 1], env) end
    return "#(" .. table.concat(parts, " ") .. ")"
  end
  return "#<obj>"
end

local function serialize(x)
  return ser(x, { n = 0 })
end

-- ---------------------------------------------------------------------------
-- corpus
-- ---------------------------------------------------------------------------
local function typecheck(expr_src)
  local term = P.F["hd"](P.F["read-from-string"](expr_src))
  local A = P.F["gensym"](R.intern("A"))
  return P.F["shen.typecheck"](term, A)
end

local YCOMB = '[[[y-combinator [/. ADD [/. X [/. Y [if [= X 0] Y [[ADD [-- X]] [++ Y]]]]]]] 3] 4]'

local CORPUS = {
  -- positive typechecks across the rule surface
  { "tc-number",      function() return typecheck('5') end },
  { "tc-string",      function() return typecheck('"hello"') end },
  { "tc-boolean",     function() return typecheck('(= 1 2)') end },
  { "tc-list",        function() return typecheck('[1 2 3]') end },
  { "tc-arith",       function() return typecheck('(+ 1 2)') end },
  { "tc-id-lambda",   function() return typecheck('(/. X X)') end },
  { "tc-mono-lambda", function() return typecheck('(/. X (+ X 1))') end },
  { "tc-twice",       function() return typecheck('(/. F (/. X (F (F X))))') end },
  { "tc-compose",     function() return typecheck('(/. F (/. G (/. X (F (G X)))))') end },
  { "tc-cons",        function() return typecheck('(cons 1 [2 3])') end },
  { "tc-tuple",       function() return typecheck('(@p 1 "a")') end },
  { "tc-nested-tuple",function() return typecheck('(@p (@p 1 2) "x")') end },
  { "tc-if",          function() return typecheck('(if true 1 2)') end },
  { "tc-let",         function() return typecheck('(let X 3 (+ X 1))') end },
  { "tc-let-shadow",  function() return typecheck('(let X 1 (let X "s" X))') end },
  { "tc-map",         function() return typecheck('(map (/. X (* X X)) [1 2 3])') end },
  { "tc-reverse",     function() return typecheck('(reverse [1 2 3])') end },
  { "tc-hd",          function() return typecheck('(hd [1 2])') end },
  { "tc-append",      function() return typecheck('(append [1] [2 3])') end },
  { "tc-poly-pair",   function() return typecheck('(/. X (@p X X))') end },
  -- negative typechecks (engine must agree on failure)
  { "tcfail-arith",   function() return typecheck('(+ 1 "a")') end },
  { "tcfail-hd",      function() return typecheck('(hd 5)') end },
  { "tcfail-if",      function() return typecheck('(if 1 2 3)') end },
  { "tcfail-branch",  function() return typecheck('(if true 1 "s")') end },
  { "tcfail-list",    function() return typecheck('[1 "a"]') end },
  -- the heavyweight: y-combinator against interpreter.shen's datatypes
  { "tc-ycombinator", function() return typecheck(YCOMB) end },
  -- Prolog: Einstein's riddle through compiled defprolog clauses
  { "prolog-einstein", function()
      P.F["load"]("einsteins-riddle.shen")
      return P.run_kl_string([[
        ((lambda V (lambda L (lambda K (lambda C
           (do (shen.incinfs) (riddle V L K C))))))
         (shen.prolog-vector) (@v true (@v 0 (vector 0))) 0 (freeze true))
      ]])
  end },
}

-- ---------------------------------------------------------------------------
-- capture / compare
-- ---------------------------------------------------------------------------
local GOLDEN = ROOT .. "/" .. (arg[0]:gsub("[^/]*$", "")) .. "golden_typecheck.golden"
local mode = arg[1] or "compare"

local results = {}
for _, entry in ipairs(CORPUS) do
  local name, fn = entry[1], entry[2]
  local ok, res = pcall(fn)
  results[name] = ok and serialize(res) or ("#<error: " .. tostring(res) .. ">")
end

if mode == "capture" then
  local f = assert(io.open(GOLDEN, "w"))
  for _, entry in ipairs(CORPUS) do
    local name = entry[1]
    f:write(name, "\t", results[name], "\n")
  end
  f:close()
  io.write("captured ", tostring(#CORPUS), " golden entries -> ", GOLDEN, "\n")
elseif mode == "compare" then
  local golden = {}
  local f = assert(io.open(GOLDEN, "r"), "no golden file; run `capture` first")
  for line in f:lines() do
    local name, val = line:match("^([^\t]+)\t(.*)$")
    if name then golden[name] = val end
  end
  f:close()
  local pass, fail = 0, 0
  for _, entry in ipairs(CORPUS) do
    local name = entry[1]
    if golden[name] == nil then
      fail = fail + 1
      io.write("MISSING ", name, " (not in golden file)\n")
    elseif golden[name] ~= results[name] then
      fail = fail + 1
      io.write("FAIL ", name, "\n  golden:  ", golden[name], "\n  current: ", results[name], "\n")
    else
      pass = pass + 1
    end
  end
  io.write(string.format("golden compare: %d pass, %d fail\n", pass, fail))
  os.exit(fail == 0 and 0 or 1)
else
  io.write("usage: luajit bench/golden_typecheck.lua capture|compare\n")
  os.exit(2)
end
