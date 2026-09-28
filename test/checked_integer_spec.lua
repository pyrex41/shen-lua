-- Check original decimal text before it enters either floating-point reader.
local shen = require("shen")
local checked = require("checked_integer")
shen.boot{ quiet = true }

local pass, fail = 0, 0
local function check(ok, label)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label) end
end
local function rejects(f, needle, label)
  local ok, err = pcall(f)
  local message = type(err) == "table" and err.msg or tostring(err)
  check(not ok and message:find(needle, 1, true) ~= nil, label)
end

check(shen.checked_integer("9007199254740991") == checked.MAX, "positive boundary")
check(shen.checked_integer("-9007199254740991") == -checked.MAX, "negative boundary")
check(shen.checked_integer("+000042") == 42, "sign and leading zeros")
check(shen.checked_integer("-0") == 0, "negative zero")
check(shen.checked_integer("0009007199254740991") == checked.MAX, "padded boundary")
rejects(function() shen.checked_integer("9007199254740992") end, "outside exact range", "positive overflow")
rejects(function() shen.checked_integer("-9007199254740992") end, "outside exact range", "negative overflow")
rejects(function() shen.checked_integer("9007199254740993") end, "outside exact range", "rounded alias rejected")
rejects(function() shen.checked_integer("99999999999999999999999999999999999") end,
        "outside exact range", "very long decimal rejected before conversion")
for _, text in ipairs{ "", "+", "1.0", "1e2", "12x", " 1", "1 2" } do
  rejects(function() shen.checked_integer(text) end, "expected signed decimal text", "invalid text " .. text)
end
rejects(function() shen.checked_integer(9007199254740993) end,
        "expected signed decimal text", "rounded Lua input refused")

check(shen.checked_add(checked.MAX - 1, 1) == checked.MAX, "add boundary")
check(shen.checked_sub(-checked.MAX + 1, 1) == -checked.MAX, "sub boundary")
check(shen.checked_mul(30000000, 30000000) == 900000000000000, "mul within range")
rejects(function() shen.checked_add(checked.MAX, 1) end, "expected an integer", "add overflow")
rejects(function() shen.checked_sub(-checked.MAX, 1) end, "expected an integer", "sub overflow")
rejects(function() shen.checked_mul(checked.MAX, 2) end, "expected an integer", "mul overflow")
rejects(function() shen.checked_add(1.5, 2) end, "expected an integer", "fraction refused")
rejects(function() shen.checked_mul(math.huge, 2) end, "expected an integer", "infinity refused")

local function ev(source) return shen.eval(source) end
check(ev('(lua.checked-integer "9007199254740991")') == checked.MAX,
      "Shen checked decimal ingress")
check(ev('(lua.checked-add (lua.checked-integer "9007199254740990") 1)') == checked.MAX,
      "Shen checked arithmetic")
check(ev('(lua.checked-sub 10 3)') == 7, "Shen checked subtraction")
check(ev('(lua.checked-mul 10 3)') == 30, "Shen checked multiplication")
rejects(function() ev('(lua.checked-integer "9007199254740993")') end,
        "outside exact range", "Shen reader preserves quoted decimal")
rejects(function() ev('(lua.checked-integer 9007199254740993)') end,
        "expected signed decimal text", "Shen numeric token refused after rounding")
rejects(function() ev('(lua.checked-add (lua.checked-integer "9007199254740991") 1)') end,
        "expected an integer", "Shen checked overflow")
check(ev('(trap-error (lua.checked-integer "9007199254740993") (lambda E true))') == true,
      "Shen can trap checked error")
check(shen.typecheck('(lua.checked-integer "42")', 'number') ~= false,
      "checked decimal entry point has a Shen type")
check(shen.typecheck('(lua.checked-add 1 2)', 'number') ~= false,
      "checked arithmetic has a Shen type")
check(shen.typecheck('(lua.checked-integer 42)', 'number') == false,
      "typed Shen rejects numeric input before execution")
-- Ordinary Shen numeric behavior remains compatible with the official suite.
check(ev('(= 9007199254740992 9007199254740993)') == true,
      "ordinary floating-point semantics unchanged")

print(string.format("checked_integer_spec: %d pass, %d fail", pass, fail))
os.exit(fail == 0 and 0 or 1)
