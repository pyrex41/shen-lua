-- test/interop_spec.lua — tests for lua_interop.lua (the Lua<->Shen bridge).
-- Needs the full kernel (the typed-bridge tests drive the typechecker):
--   luajit test/interop_spec.lua
-- Works with the fasl cache on or off (loads use throwaway tmp files whose
-- content is unique per run, so nothing is ever replayed from cache).
package.path = (arg[0]:gsub("test/[^/]*$", "")) .. "?.lua;" .. package.path

local P = require("boot")
P.load_kernel(false)
P.initialise()

local I = require("lua_interop")
local R = require("runtime")
local C = require("compiler")
local F = P.F

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end

-- silence the (load)/(tc) chatter from the kernel during the spec
local function hushed(f)
  F["set"](R.intern("*hush*"), true)
  local ok, r = pcall(f)
  F["set"](R.intern("*hush*"), false)
  if not ok then error(r, 0) end
  return r
end

-- load Shen source text through the real (load) path (typechecks when the
-- tc snapshot at load start is +). Unique header comment defeats fasl reuse.
local loadn = 0
local function load_shen(src)
  loadn = loadn + 1
  local path = os.tmpname() .. "-interop-spec-" .. loadn .. ".shen"
  local fh = assert(io.open(path, "w"))
  fh:write("\\\\ " .. path .. " " .. tostring(os.time()) .. " " ..
           tostring(math.random(1e9)) .. "\n" .. src)
  fh:close()
  local ok, err = pcall(function() return hushed(function() return F["load"](path) end) end)
  os.remove(path)
  return ok, err
end

-- ---------------------------------------------------------------------------
-- marshaling round-trips
-- ---------------------------------------------------------------------------
do
  -- scalars are themselves, both ways
  check(I.to_lua(42) == 42 and I.to_shen(42) == 42, "numbers unchanged")
  check(I.to_lua("x") == "x" and I.to_shen("x") == "x", "strings unchanged")
  check(I.to_lua(true) == true and I.to_shen(false) == false, "booleans unchanged")

  -- symbol -> string (one way only: strings never auto-intern back)
  check(I.to_lua(R.intern("hello")) == "hello", "symbol -> its print name")
  check(I.to_shen("hello") == "hello", "string stays a string (no auto-intern)")
  check(R.is_symbol(I.sym("hello")), "M.sym interns explicitly")

  -- () <-> nil at the boundary; () == empty array as data
  check(I.to_lua(R.NIL) == nil, "() -> nil in return/argument position")
  check(I.to_shen(nil) == R.NIL, "nil -> ()")
  check(I.to_shen({}) == R.NIL, "empty array table -> ()")

  -- dense array <-> proper list, deep
  local lst = I.to_shen({ 1, "two", { 3, 4 } })
  check(getmetatable(lst) == R.Cons, "array -> cons list")
  check(R.to_str(lst) == '(1 "two" (3 4))', "nested array -> nested list")
  local back = I.to_lua(lst)
  check(type(back) == "table" and back[1] == 1 and back[2] == "two"
        and type(back[3]) == "table" and back[3][2] == 4, "list -> array round-trip")

  -- () as a list ELEMENT is an empty table, not nil (lists stay dense)
  local withnil = I.to_lua(R.cons(R.NIL, R.cons(2, R.NIL)))
  check(type(withnil[1]) == "table" and next(withnil[1]) == nil and withnil[2] == 2,
        "() as element -> {}")

  -- M.list / M.array helpers
  check(R.to_str(I.list({ 1, 2 })) == "(1 2)", "M.list")
  local arr = I.array(I.list({ 1, 2 }))
  check(arr[1] == 1 and arr[2] == 2 and #arr == 2, "M.array")
  check(#I.array(R.NIL) == 0, "M.array of () is {}")

  -- non-array tables, tables with holes, tables with metatables -> opaque box
  local hash = { a = 1 }
  local b = I.to_shen(hash)
  check(I.is_box(b) and I.unbox(b) == hash, "hash table boxed, identity kept")
  check(I.to_lua(b) == hash, "box -> original value")
  local holes = {}; holes[1] = "x"; holes[3] = "y"
  check(I.is_box(I.to_shen(holes)), "array with holes boxed")
  check(I.is_box(I.to_shen(setmetatable({ 1, 2 }, {}))), "metatabled array boxed")
  check(I.unbox(7) == 7, "unbox passes non-boxes through")

  -- Shen data crossing Lua -> Shen is untouched
  local sym = R.intern("s")
  check(I.to_shen(sym) == sym, "symbol untouched by to_shen")
  local cons = R.cons(1, R.NIL)
  check(I.to_shen(cons) == cons, "cons untouched by to_shen")

  -- improper list refuses to marshal
  local ok = pcall(I.to_lua, R.cons(1, 2))
  check(not ok, "improper list -> error")
end

-- ---------------------------------------------------------------------------
-- Shen -> Lua: lua.require / lua.global / lua.call / lua.method / lua.index
-- ---------------------------------------------------------------------------
do
  -- the surface is registered with arities for direct-call codegen
  for name, ar in pairs({ ["lua.require"] = 1, ["lua.global"] = 1,
                          ["lua.call"] = 2, ["lua.method"] = 3,
                          ["lua.index"] = 2, ["lua.setindex"] = 3,
                          ["lua.function"] = 3 }) do
    check(type(F[name]) == "function" and C.ARITY[name] == ar
          and P.FA[F[name]] == ar, "registered with arity: " .. name)
  end

  check(I.unbox(I.eval('(lua.require "string")')) == string, "lua.require string lib")
  local ok = pcall(I.eval, '(lua.require "no-such-module-xyz")')
  check(not ok, "lua.require of missing module errors")

  check(I.unbox(I.eval('(lua.global "math")')) == math, "lua.global namespace boxed")
  check(I.eval('(lua.global "math.pi")') == math.pi, "lua.global dotted scalar")

  check(I.eval('(lua.call "string.rep" ["ab" 3])') == "ababab", "lua.call string path")
  check(I.eval('(lua.call string.rep ["ab" 2])') == "abab", "lua.call symbol path")
  check(I.eval('(lua.call "math.max" [1 5 3])') == 5, "lua.call varargs")
  check(I.eval('(lua.call "type" [()])') == "nil", "() argument crosses as nil")
  check(I.eval('(lua.call "string.find" ["abc" "b"])') == 2,
        "only the FIRST return value crosses")
  check(I.unbox(I.eval('(lua.call "require" ["os"])')) == os,
        "non-list table result comes back boxed")
  check(type(I.eval('(lua.call "string.gmatch" ["ab" "."])')) == "function",
        "function result passes through unconverted")

  -- lua.call with a function VALUE (here: a box made on the Lua side)
  check(P.F["lua.call"](I.box(function(a, b) return a .. b end),
                        I.list({ "x", "y" })) == "xy", "lua.call boxed function")

  check(I.eval('(lua.method "hello" "rep" [2])') == "hellohello", "lua.method on string")

  -- index/setindex against a live Lua table
  local t = { a = 1 }
  check(F["lua.index"](I.box(t), "a") == 1, "lua.index read")
  check(F["lua.index"](I.box(t), "zz") == R.NIL, "lua.index missing key -> ()")
  F["lua.setindex"](I.box(t), "b", I.list({ 1, 2 }))
  check(type(t.b) == "table" and t.b[2] == 2, "lua.setindex marshals the value")
  F["lua.setindex"](I.box(t), "a", R.NIL)
  check(t.a == nil, "lua.setindex with () erases the key")
end

-- ---------------------------------------------------------------------------
-- arity edge cases: currying through the bridge, both directions
-- ---------------------------------------------------------------------------
do
  -- Shen-side partial application of a bridge entry (generic APP + PARTIAL)
  check(I.eval('((lua.call "string.rep") ["ha" 3])') == "hahaha",
        "partial application of lua.call from Shen")

  -- Lua-side curry awareness of M.call / M.fn
  hushed(function() return I.eval("(define spec-add3 X Y Z -> (+ X (+ Y Z)))") end)
  check(I.call("spec-add3", 1, 2, 3) == 6, "M.call exact arity")
  local p = I.call("spec-add3", 1)
  check(type(p) == "function", "M.call underapplication -> Lua function")
  check(p(2, 3) == 6, "partial completes across the boundary")
  check(I.call("spec-add3", 1, 2)(3) == 6, "two-step curry")
  check(I.fn("spec-add3")(10, 20, 30) == 60, "M.fn wrapper")

  -- arguments to M.call are marshaled (array -> list)
  hushed(function() return I.eval("(define spec-second [_ X | _] -> X)") end)
  check(I.call("spec-second", { "a", "b", "c" }) == "b", "M.call marshals args")

  -- M.wrap: a Lua function Shen can call with Shen data
  local w = I.wrap(function(xs) return #xs end, 1)
  check(P.APP(w, I.list({ 1, 2, 3 })) == 3, "M.wrap marshals into the Lua fn")
  check(I.call("map", w, { { 1 }, { 2, 2 } })[2] == 2, "M.wrap under shen map")
end

-- ---------------------------------------------------------------------------
-- error propagation, both directions
-- ---------------------------------------------------------------------------
do
  -- Lua error -> trappable Shen error carrying the message
  local msg = I.eval(
    [[(trap-error (lua.call "error" ["boom"]) (/. E (error-to-string E)))]])
  check(type(msg) == "string" and msg:find("boom", 1, true) ~= nil,
        "Lua error trapped by trap-error, message kept: " .. tostring(msg))

  local msg2 = I.eval(
    [[(trap-error (lua.method "s" "no-such-method" []) (/. E (error-to-string E)))]])
  check(type(msg2) == "string" and msg2:find("no%-such%-method") ~= nil,
        "lua.method failure trapped")

  local msg3 = I.eval(
    [[(trap-error (lua.call "no.such.path" []) (/. E (error-to-string E)))]])
  check(type(msg3) == "string" and msg3:find("no.such.path", 1, true) ~= nil,
        "bad path reported")

  -- a Shen error crossing Lua frames stays a Shen error (re-raised unchanged)
  local msg4 = I.eval(
    [[(trap-error (lua.call (/. X (simple-error "from shen")) [1])
                  (/. E (error-to-string E)))]])
  check(msg4 == "from shen", "Shen error through Lua frames keeps identity")

  -- Shen error -> Lua: pcall-able, message recoverable
  hushed(function() return I.eval([[(define spec-throw X -> (simple-error "bad news"))]]) end)
  local ok, err = pcall(I.call, "spec-throw", 0)
  check(not ok and I.error_message(err) == "bad news", "Shen error -> Lua pcall")
  local ok2, msg5 = I.pcall("spec-throw", 0)
  check(ok2 == false and msg5 == "bad news", "M.pcall yields the message")
  local ok3, v3 = I.pcall("spec-add3", 1, 2, 3)
  check(ok3 == true and v3 == 6, "M.pcall success path")

  -- improper argument list refused at the boundary
  local ok4 = pcall(F["lua.call"], "string.rep", R.cons("x", 2))
  check(not ok4, "improper argument list refused")
end

-- ---------------------------------------------------------------------------
-- the typed bridge: lua.function + declare under tc+
-- ---------------------------------------------------------------------------
do
  -- registration is reachable from Shen source itself (untyped load),
  -- which also exercises the fasl declare-path composition
  local ok = load_shen([[(lua.function spec.upper "string.upper" [string --> string])]])
  check(ok, "lua.function from a loaded file")
  check(F["spec.upper"] ~= nil and C.ARITY["spec.upper"] == 1,
        "bridged fn registered, arity from signature")
  check(F["spec.upper"]("abc") == "ABC", "bridged fn callable, marshals")

  -- flat [A --> B --> C] means arity 2 (every top-level --> is an argument)
  I.eval([[(lua.function spec.fmt "string.format" [string --> string --> string])]])
  check(C.ARITY["spec.fmt"] == 2, "flat signature arity")
  check(F["spec.fmt"]("n=%s", "7") == "n=7", "bridged 2-arg call")

  -- explicitly curried [A --> [B --> C]] means arity 1
  I.eval([=[(lua.function spec.upper1 "string.upper" [string --> [string --> string]])]=])
  check(C.ARITY["spec.upper1"] == 1, "curried signature arity")

  -- (fn name) yields a real curried closure (the kernel's own
  -- update-lambda-table stores a broken pair here; we bypass it)
  check(I.eval([[((fn spec.fmt) "k=%s" "v")]]) == "k=v",
        "(fn bridged-name) is applicable (curried)")

  -- ...and therefore TYPECHECKED code can call it: tc+ call sites compile
  -- declare-only functions to ((fn name) A B). `load` snapshots the tc mode
  -- at load start, so it is switched on here, around the loads.
  I.eval("(tc +)")
  local okT = load_shen([[
(define spec-shout
  {string --> string}
  S -> (spec.fmt "%s!" (spec.upper S)))]])
  check(okT, "typed define over bridged fns typechecks and loads")
  check(F["spec-shout"]("ok") == "OK!", "typechecked code calls through bridge")

  -- the declared signature is ENFORCED: a number where string is declared
  local okBad, err = load_shen([[
(define spec-bad
  {number --> string}
  N -> (spec.upper N))]])
  check(not okBad, "type-wrong use of bridged fn rejected under tc+")
  check(I.error_message(err):find("type error", 1, true) ~= nil,
        "rejection is a type error: " .. tostring(I.error_message(err)))

  -- partial application of a bridged function in TYPED code
  local okP = load_shen([[
(define spec-prefixer
  {string --> (string --> string)}
  P -> (spec.fmt (cn P "%s")))]])
  check(okP, "partial application of bridged fn typechecks")
  check(P.APP(F["spec-prefixer"]("pre-"), "x") == "pre-x",
        "typed partial over the bridge evaluates")
  I.eval("(tc -)")

  -- name can be given as a string too; errors inside stay trappable
  I.eval([[(lua.function "spec.err" "error" [string --> string])]])
  local msg = I.eval(
    [[(trap-error (spec.err "kapow") (/. E (error-to-string E)))]])
  check(type(msg) == "string" and msg:find("kapow", 1, true) ~= nil,
        "bridged fn error trapped in Shen")

  -- a non-function signature is refused
  local okSig = pcall(I.eval, [[(lua.function spec.x "math.pi" [number])]])
  check(not okSig, "signature without --> refused")
end

-- make sure the spec leaves the typechecker off for whoever runs next
I.eval("(tc -)")

io.write(string.format("interop_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
