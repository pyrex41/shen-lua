-- test/numeric_render_spec.lua — PORT-AUTHORED coverage of how a NUMBER is
-- RENDERED, on both of the port's two rendering paths:
--
--   * runtime.lua `to_str`  — the printer (REPL echo, `shen.tostring`, specs)
--   * prims.lua   `numToStr` — the Shen `str` primitive
--
-- Companion to numeric_literal_spec.lua, which covers the COMPILE-time path
-- (compiler.lua `cnum`) and deliberately left rendering out of scope.
--
-- The bug this guards: both rendering paths rendered every finite integral
-- double with string.format("%d", n). Under LuaJIT/5.1 (no math.tointeger to
-- guard with) that SATURATES at 2^63-1 rather than erroring, so every value
-- outside int64 range printed as the same sentinel:
--
--     (* 1000000000.0 10000000000.0)  =>  9223372036854775807
--     (str 1e19)                      =>  9223372036854775807
--     1e300                           =>  9223372036854775807
--
-- The value was computed correctly (that is numeric_literal_spec's job); only
-- the rendering was destroyed. shen-cl and shen-rust both print the full
-- positional integer.
--
-- CONVENTION ASSERTED HERE
--   A finite integral double renders as positional decimal digits, never an
--   exponent, at any magnitude. Below 2^63 that is the exact value (the %d
--   path, unchanged). At or above 2^63 a double is no longer exactly
--   int64-representable, so we render the SHORTEST round-trippable decimal
--   expanded positionally -- the same rule shortest_float already applies to
--   non-integral values (issue #24), and byte-identical to shen-rust.
--   Non-integral finite values and the non-finite values (inf/-inf/nan) are
--   untouched; overflow POLICY is deliberately not decided here.
--
--   luajit test/numeric_render_spec.lua
local shen = require("shen")
shen.boot{ quiet = true }
local R = require("runtime")

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end
local function fail3(what, want, got)
  nfail = nfail + 1
  io.write("FAIL: ", what, "\n  want: ", want, "\n  got:  ", got, "\n")
end

-- Assert BOTH rendering paths on the same expression, and assert they agree
-- with each other. They have diverged in this repo before, so "printer says X"
-- is not evidence that "(str ...) says X".
local function checkboth(src, want)
  local ok, printed = pcall(function() return R.to_str(shen.eval(src)) end)
  if not ok then fail3(src .. "  [to_str]", want, "raised: " .. tostring(printed))
  elseif printed ~= want then fail3(src .. "  [to_str]", want, printed)
  else npass = npass + 1 end

  local ok2, viastr = pcall(function() return shen.eval("(str " .. src .. ")") end)
  if not ok2 then fail3(src .. "  [str]", want, "raised: " .. tostring(viastr))
  elseif viastr ~= want then fail3(src .. "  [str]", want, viastr)
  else npass = npass + 1 end

  if ok and ok2 then
    check(printed == viastr,
          "to_str and (str ...) agree on " .. src ..
          "  (to_str=" .. tostring(printed) .. ", str=" .. tostring(viastr) .. ")")
  end
end

local rep = string.rep

-- ---------------------------------------------------------------------------
-- THE DEFECT: finite integral values at or above 2^63 render positionally.
-- Every expectation below was taken from shen-rust (fresh build) on the same
-- expression and is byte-for-byte identical to it.
-- ---------------------------------------------------------------------------
local BIG = {
  -- computed, not read: reader-independent anchors
  { "(* 1000000000.0 10000000000.0)",  "10000000000000000000" },
  { "(* -1000000000.0 10000000000.0)", "-10000000000000000000" },
  { "(* 4611686018427387904.0 2.0)",   "9223372036854776000" },      -- 2^63
  { "(* 4611686018427387904.0 4.0)",   "18446744073709552000" },     -- 2^64
  { "(* 3.0 4611686018427387904.0)",   "13835058055282164000" },     -- 3*2^62
  { "(* 9007199254740992.0 1048576.0)","9444732965739290000000" },   -- 2^73
  -- read from source
  { "1e19",                            "10000000000000000000" },
  { "-1e19",                           "-10000000000000000000" },
  { "1e20",                            "100000000000000000000" },
  { "1e21",                            "1000000000000000000000" },
  { "9223372036854775808",             "9223372036854776000" },
  { "18446744073709551616",            "18446744073709552000" },
  { "12345678901234567890",            "12345678901234563000" },
  { "1e100",                           "10000000000000006"  .. rep("0", 84) },
  { "1e300",                           "10000000000000002"  .. rep("0", 284) },
  { "-1e300",                         "-10000000000000002"  .. rep("0", 284) },
  { "1e308",                           "9999999999999998"   .. rep("0", 292) },
}
for _, p in ipairs(BIG) do checkboth(p[1], p[2]) end

-- Structural properties of the big-value form, asserted independently of the
-- exact digits: positional only, and it must round-trip to the same double.
for _, p in ipairs(BIG) do
  local s = p[2]
  check(not s:find("[eE]"), "no exponent in rendering of " .. p[1])
  check(not s:find("%."),   "no decimal point in rendering of " .. p[1])
  check(s ~= "9223372036854775807" and s ~= "-9223372036854775808",
        "rendering of " .. p[1] .. " is not the int64 saturation sentinel")
  check(tonumber(s) == shen.eval(p[1]),
        "rendering of " .. p[1] .. " round-trips to the same double")
end

-- 1e300 is 301 digits, 1e100 is 101 -- a magnitude sanity check that a future
-- exponent-form regression would trip even if the digits changed.
check(#(shen.eval("(str 1e300)")) == 301, "(str 1e300) is 301 digits")
check(#(shen.eval("(str 1e100)")) == 101, "(str 1e100) is 101 digits")

-- ---------------------------------------------------------------------------
-- COLLATERAL: everything the %d path already got right must be untouched.
-- ---------------------------------------------------------------------------
local SMALL = {
  { "0",                       "0" },
  { "(- 0 0)",                 "0" },
  { "42",                      "42" },
  { "-42",                     "-42" },
  { "1000000",                 "1000000" },
  { "(* 6 7)",                 "42" },
  { "9007199254740992",        "9007199254740992" },              -- 2^53
  { "(* 4503599627370496 2)",  "9007199254740992" },
  { "9223372036854774784",     "9223372036854774784" },           -- max double < 2^63
  { "(/ 1e300 1e290)",         "10000000000" },
  { "(/ 1e19 1e10)",           "1000000000" },
  { "(- 1e300 1e300)",         "0" },
  { "(* 2.5 2)",               "5" },
  -- non-integral: shortest round-trippable form (issue #24), unchanged
  { "0.1",                     "0.1" },
  { "(/ 1 3)",                 "0.3333333333333333" },
  { "(+ 0.1 0.2)",             "0.30000000000000004" },
  { "1e-300",                  "1.0000000000000022e-300" },
}
for _, p in ipairs(SMALL) do checkboth(p[1], p[2]) end

-- ---------------------------------------------------------------------------
-- NON-FINITE: unchanged, and deliberately so -- overflow policy is an open
-- cross-port question (shen-cl raises, shen-go/shen-lua/shen-rust propagate).
-- Build a genuine +inf by overflowing, never by reading a literal.
-- ---------------------------------------------------------------------------
local POSINF = "(* (/ 1.0 1e-300) (/ 1.0 1e-300))"
local NEGINF = "(- 0 " .. POSINF .. ")"
local NAN    = "(- " .. POSINF .. " " .. POSINF .. ")"
checkboth(POSINF, "inf")
checkboth(NEGINF, "-inf")
checkboth(NAN,    "nan")

-- ---------------------------------------------------------------------------
-- Direct unit coverage of the printer over raw Lua doubles, so the rule is
-- pinned independently of what the Shen reader happens to produce.
-- ---------------------------------------------------------------------------
local DIRECT = {
  { 0, "0" }, { 42, "42" }, { -42, "-42" },
  { 2^53, "9007199254740992" }, { -2^53, "-9007199254740992" },
  { 9223372036854774784, "9223372036854774784" },
  { 2^63,  "9223372036854776000" },
  { -2^63, "-9223372036854776000" },
  { 2^64,  "18446744073709552000" },
  { 1e19,  "10000000000000000000" },
  { -1e19, "-10000000000000000000" },
  { 1e300, "1" .. rep("0", 300) },   -- Lua-parsed 1e300 IS the exact power
  { math.huge, "inf" }, { -math.huge, "-inf" },
}
for _, p in ipairs(DIRECT) do
  local got = R.to_str(p[1])
  if got == p[2] then npass = npass + 1
  else fail3("to_str(" .. string.format("%.17g", p[1]) .. ")", p[2], got) end
end

io.write(string.format("numeric_render_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
