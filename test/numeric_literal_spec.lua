-- test/numeric_literal_spec.lua — PORT-AUTHORED coverage of numeric LITERAL
-- codegen (compiler.lua `cnum`) and the arithmetic that rides on it.
--
-- Regression guard for the int64 saturation bug: `cnum` rendered every
-- integral float with string.format("%d", n). On LuaJIT/5.1 (no
-- math.tointeger to guard with) that SATURATES at 2^63-1 instead of erroring,
-- so a literal outside int64 range was destroyed in the emitted Lua source,
-- at COMPILE time, before evaluation ever ran:
--
--     (> 1e300 1e100)  compiled to  APP(S(">"), 9223372036854775807,
--                                              9223372036854775807)  => false
--     (/ 1e300 1e290)  => 1        (both operands saturated to the same value)
--     (= 1e19 (* 1e18 10))         => false
--
-- Silent wrong arithmetic on ordinary FINITE literals. shen-go / shen-cl /
-- shen-rust all answer true / 10000000000 / true.
--
-- OUT OF SCOPE here (known open cross-port questions, deliberately untested):
--   * how a large finite value is RENDERED by the printer — shen-lua and
--     shen-go saturate on the print path, shen-cl and shen-rust print the full
--     positional integer;
--   * non-finite (+-inf, NaN) literals and their rendering.
-- This spec asserts only that the compiled VALUE is right.
--
--   luajit test/numeric_literal_spec.lua
local shen = require("shen")
shen.boot{ quiet = true }
local R = require("runtime")
local C = require("compiler")

local loadstr = loadstring or load

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end
local function evs(src)
  return R.to_str(shen.eval(src))
end
local function checkeq(src, want)
  local ok, got = pcall(evs, src)
  if not ok then
    nfail = nfail + 1
    io.write("FAIL: ", src, "  (raised: ", tostring(got), ")\n")
  elseif got == want then
    npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", src, "\n  want: ", want, "\n  got:  ", got, "\n")
  end
end
-- Bit-exact identity for doubles (%.17g distinguishes every distinct double).
local function same(a, b)
  return string.format("%.17g", a) == string.format("%.17g", b)
end

-- ---------------------------------------------------------------------------
-- cnum round-trip: whatever literal we emit must be VALID Lua source and must
-- parse back to the exact same double.
-- ---------------------------------------------------------------------------
local ROUNDTRIP = {
  0, 1, -1, 7, -7, 42, -42, 1000000, -1000000,
  2^31, 2^52, 2^53, -2^53,
  9223372036854774784,    -- largest double strictly below 2^63
  -9223372036854774784,
  2^63, -2^63, 2^64,      -- first values the %d path cannot represent
  1e19, -1e19, 1e100, 1e300, -1e300, 1e308,
  1e-300, 0.1, -0.5, 1.5, 3.5, 1/3, math.pi,
}
for _, v in ipairs(ROUNDTRIP) do
  local src = C.cexpr(v, {})
  local f = loadstr("return " .. src)
  if not f then
    nfail = nfail + 1
    io.write("FAIL: cnum(", string.format("%.17g", v), ") emitted invalid Lua: ", src, "\n")
  else
    local back = f()
    if same(back, v) then npass = npass + 1
    else
      nfail = nfail + 1
      io.write("FAIL: cnum round-trip for ", string.format("%.17g", v), "\n",
               "  emitted: ", src, "\n",
               "  parses back as: ", string.format("%.17g", back), "\n")
    end
  end
end

-- The specific corruption: no in-range literal may be emitted as the int64
-- saturation sentinel unless it genuinely IS that value.
for _, v in ipairs{ 1e19, 1e100, 1e300, 1e308, 2^63, 2^64 } do
  check(C.cexpr(v, {}) ~= "9223372036854775807",
        "cnum(" .. string.format("%.17g", v) .. ") must not saturate to 2^63-1")
end

-- ---------------------------------------------------------------------------
-- No regression on ordinary integer literals: they must still print exactly,
-- with no ".0" and no exponent form.
-- ---------------------------------------------------------------------------
local EXACT = {
  {0, "0"}, {1, "1"}, {-1, "-1"}, {42, "42"}, {-42, "-42"},
  {1000000, "1000000"}, {2^31, "2147483648"},
  {2^53, "9007199254740992"}, {-2^53, "-9007199254740992"},
  {9223372036854774784, "9223372036854774784"},
}
for _, p in ipairs(EXACT) do
  local got = C.cexpr(p[1], {})
  check(got == p[2],
        "cnum exact integer rendering: want " .. p[2] .. ", got " .. got)
end

-- catom and cnum are two literal paths for the same job; they must agree on
-- the value they denote (they may differ in surface form).
for _, v in ipairs(ROUNDTRIP) do
  local a = loadstr("return " .. (string.format("%.17g", v):gsub("%.0$", "")))
  local b = loadstr("return " .. C.cexpr(v, {}))
  check(a ~= nil and b ~= nil and same(a(), b()),
        "catom/cnum agree on " .. string.format("%.17g", v))
end

-- ---------------------------------------------------------------------------
-- End to end: comparisons and arithmetic over large finite literals.
-- Ground truth cross-checked against shen-go, shen-cl and shen-rust.
-- ---------------------------------------------------------------------------
checkeq("(> 1e300 1e100)", "true")
checkeq("(< 1e300 1e100)", "false")
checkeq("(< 1e100 1e300)", "true")
checkeq("(= 1e300 1e100)", "false")
checkeq("(>= 1e300 1e100)", "true")
checkeq("(<= 1e100 1e300)", "true")
checkeq("(/ 1e300 1e290)", "10000000000")
checkeq("(= 1e19 (* 1e18 10))", "true")
checkeq("(- 1e300 1e300)", "0")
checkeq("(/ 1e19 1e10)", "1000000000")
checkeq("(> 1e19 1e18)", "true")
checkeq("(/ 1e100 1e100)", "1")

-- ...and no regression on small / ordinary values.
checkeq("(+ 2 3)", "5")
checkeq("(- 5 3)", "2")
checkeq("(* 6 7)", "42")
checkeq("(= 0 0)", "true")
checkeq("(> 0.2 0.1)", "true")
checkeq("(* 1.5 2)", "3")
checkeq("(= 9007199254740992 (* 4503599627370496 2))", "true")

io.write(string.format("numeric_literal_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
