-- test/reader_native_spec.lua — PORT-AUTHORED coverage for the native reader
-- sequence rules (pyrex41/shen-lua#88).
--
-- prims.lua replaces shen.<s-exprs>, shen.cons-form, shen.<strcontents>,
-- shen.<alphanums> and shen.<whitespaces> (reader.kl) with iterative Lua,
-- because the KL recurses once per token / per character and a list literal
-- past ~1550 elements overflowed LuaJIT's fixed stack. Two parts:
--
--   (1) differential: the kernel's own KL definitions, compiled under
--       `spec.` aliases, against the natives on every .shen file under
--       tests/ and examples/ plus edge cases (unclosed brackets, the
--       `[a | b c]` error, $, :=, {}, comments, c#NN; escapes, empty input).
--       Same value, or the same error message.
--   (2) sizes the KL could not read: 1600..3000-element list literals,
--       a 14 KB string literal, deep bracket nesting.
--
--   luajit test/reader_native_spec.lua
local here = arg[0]:gsub("test/[^/]*$", "")
if here == "" then here = "./" end
package.path = here .. "?.lua;" .. package.path

local shen = require("shen")
shen.boot{ quiet = true }
local R = require("runtime")
local C = require("compiler")
local P = shen.prims
local F = P.F

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end

-- ---------------------------------------------------------------------------
-- Part 1 — differential against the kernel's KL.
-- ---------------------------------------------------------------------------
-- Every rule the natives replace, plus the rules that reach them (<atom>,
-- <str>, <sym>), so the aliased KL never calls a native one.
local ALIASED = {
  "shen.<s-exprs>", "shen.<s-exprs1>", "shen.<s-exprs2>", "shen.cons-form",
  "shen.<whitespaces>", "shen.<atom>", "shen.<str>", "shen.<sym>",
  "shen.<strcontents>", "shen.<alphanums>",
}
do
  local src = assert(io.open(here .. "klambda/reader.kl", "rb")):read("*a")
  local function alias(text)
    for _, name in ipairs(ALIASED) do
      local pat = name:gsub("[%p]", "%%%0")
      -- whole symbol only: the next character must end the symbol
      text = text:gsub(pat .. "([%s%)])", "spec." .. name:sub(6) .. "%1")
    end
    return text
  end
  local wanted = {}
  for _, name in ipairs(ALIASED) do wanted["spec." .. name:sub(6)] = true end
  local n = 0
  for _, f in ipairs(R.read_all(alias(src))) do
    if R.is_cons(f) and R.is_symbol(f[1]) and f[1].name == "defun"
       and R.is_cons(f[2]) and R.is_symbol(f[2][1]) and wanted[f[2][1].name] then
      P.load_chunk(C.compile_top(f), "alias")()
      n = n + 1
    end
  end
  check(n == #ALIASED, "#88: every aliased reader rule compiled (" .. n .. ")")
  check(F["spec.<s-exprs>"] ~= nil and F["spec.<s-exprs>"] ~= F["shen.<s-exprs>"],
        "#88: spec.<s-exprs> is the kernel KL, not the native")
end

local function errmsg(e)
  if type(e) == "table" then
    local ok, s = pcall(F["error-to-string"], e)
    if ok then return s end
  end
  return tostring(e)
end
local function run(fn, codes)
  local ok, r = pcall(fn, codes)
  if ok then return "ok " .. R.to_str(r) end
  return "error " .. errmsg(r)
end

local compared, kl_overflow = 0, 0
local function same(src, name)
  local codes = F["shen.str->bytes"](src)
  local want = run(F["spec.<s-exprs>"], codes)
  if want:find("stack overflow", 1, true) then
    kl_overflow = kl_overflow + 1   -- too big for the KL: covered by part 2
    return
  end
  local got = run(F["shen.<s-exprs>"], codes)
  compared = compared + 1
  if got ~= want then
    check(false, "#88: native <s-exprs> == KL on " .. name
          .. "\n  want: " .. want:sub(1, 300) .. "\n  got:  " .. got:sub(1, 300))
  else
    check(true, name)
  end
end

local EDGE = {
  "", " ", "\n\t ", "a", "[", "(", "]", ")", "[a", "(a", "[a)", "(a]",
  "[a | b]", "[a | b c]", "[a |]", "[| a]", "[a b | c]", "[[a | b] | [c | d]]",
  "[a | b c] [d | e f]", "[[a | b c] x] [d | e f]",
  "$abc", "($ abc)", "[$ abc]", "a := b", "a :=", "a : b", "a: b", ":", ":=",
  "{a --> b}", "{ }", "a | b", "a, b; c", ";;", ",,",
  "\\* c *\\ x", "\\* a \\* b *\\ x", "\\\\ c\n x", "\\\\ c", "x \\\\",
  "\"a c#65; b\"", "\"c#10;\"", "\"unterminated", "\"\"", "\"a\"\"b\"",
  "1.5e3 -2 +3 - +", "-1.5 1e-2 .5 5.", "<> [<>]", "true false", "Xy _ x_1",
  "[1 [2 (3 4] 5)]", "(a [b) c]", "[[[]]]", "((()))", "[] ()",
  "(define f X -> [X | X])", "(a b) junk ) (c)", "a\r\nb", "é \"ü\" ß",
}
for i, s in ipairs(EDGE) do same(s, "edge case " .. i .. " " .. string.format("%q", s)) end

local function shen_files(dir, out)
  local h = io.popen("find " .. "'" .. here .. dir .. "' -name '*.shen' -type f 2>/dev/null | sort")
  for line in h:lines() do out[#out + 1] = line end
  h:close()
  return out
end
local files = shen_files("examples", shen_files("tests", {}))
for _, path in ipairs(files) do
  local fh = io.open(path, "rb")
  local data = fh:read("*a"); fh:close()
  same(data, path:sub(#here + 1))
end
io.write(string.format("differential: %d inputs compared, %d too big for the KL\n",
                       compared, kl_overflow))
check(compared >= #EDGE + 40,
      "#88: compared " .. compared .. " inputs (" .. kl_overflow .. " too big for the KL)")

-- ---------------------------------------------------------------------------
-- Part 2 — inputs past the KL's stack limit.
-- ---------------------------------------------------------------------------
local function nums(n)
  local t = {}
  for i = 1, n do t[i] = tostring(i) end
  return table.concat(t, " ")
end
for _, n in ipairs({ 1600, 2000, 3000 }) do
  local got = R.to_str(shen.eval("(length [" .. nums(n) .. "])"))
  check(got == tostring(n), "#88: a " .. n .. "-element list literal evaluates (got " .. got .. ")")
end
do
  -- (read-from-string "[1 ... 3000]"): a ~14 KB string literal, then a
  -- 3000-element list
  local got = R.to_str(shen.eval('(length (eval (hd (read-from-string "[' .. nums(3000) .. ']"))))'))
  check(got == "3000", "#88: read-from-string of a 14 KB string literal (got " .. got .. ")")
  local deep = string.rep("[", 3000) .. string.rep("]", 3000)
  local forms = F["read-from-string-unprocessed"](deep)
  -- [[...]] reads as (cons (cons ... ()) ()): follow the first element
  local d, x = 0, forms[1]
  while R.is_cons(x) do d = d + 1; x = x[2][1] end
  check(d == 2999, "#88: 3000-deep bracket nesting reads (depth " .. d .. ")")
  local sym = string.rep("a", 20000)
  check(R.to_str(shen.eval("(length (explode (str " .. sym .. ")))")) == "20000",
        "#88: a 20000-character symbol reads")
end
do
  -- read-file: a stack overflow is reported as one, not as a reader error
  local path = os.tmpname()
  local fh = io.open(path, "w"); fh:write("(+ 1 2) [a b]"); fh:close()
  check(R.to_str(F["read-file"](path)) == "((+ 1 2) (cons a (cons b ())))",
        "#88: read-file still reads through the native rules")
  os.remove(path)
end

io.write(string.format("reader_native_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
