-- test/repl_spec.lua — unit tests for the REPL helpers (repl.lua) and the
-- error-quality seams in prims.lua (translate_error, shen: chunknames).
-- Pure Lua: requires runtime/compiler/prims but NOT the kernel.
--   luajit test/repl_spec.lua
package.path = (arg[0]:gsub("test/[^/]*$", "")) .. "?.lua;" .. package.path

local M = require("repl")
local P = require("prims")
local R = require("runtime")

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end
local function checkeq(got, want, name)
  if got == want then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n  want: ", tostring(want), "\n  got:  ", tostring(got), "\n")
  end
end

-- ---------------------------------------------------------------------------
-- paren balancer (strings, escapes, comments)
-- ---------------------------------------------------------------------------
do
  local cases = {
    -- { input, balanced?, label }
    { "(+ 1 2)",                true,  "simple form" },
    { "(define f X ->",         false, "unclosed paren" },
    { "(f (g 1) 2)",            true,  "nested" },
    { "((",                     false, "two opens" },
    { ")",                      true,  "stray closer is complete (reader reports it)" },
    { "",                       true,  "empty buffer" },
    { "abc",                    true,  "bare atom" },
    -- strings
    { '(f "(" )',               true,  "open paren inside string" },
    { '(f ")")',                true,  "close paren inside string" },
    { '"abc',                   false, "unclosed string" },
    { '"abc\ndef"',             true,  "string spanning newline" },
    { '(f "ab\\")',             true,  "backslash in string is literal, quote closes" },
    { '"\\\\"',                 true,  "string of two backslashes is not a comment" },
    { '(f "x\\\\ (")',          true,  "backslashes inside string never start a comment" },
    -- single-line comments
    { "(f) \\\\ (g",            true,  "line comment hides open paren" },
    { "(f \\\\ )\n)",           true,  "line comment hides closer until newline" },
    { "\\\\ just a comment",    true,  "comment-only line is complete" },
    { '\\\\ comment with "quote\n(f)', true, "quote inside line comment ignored" },
    -- block comments
    { "\\* (unclosed *\\ ()",   true,  "block comment hides paren" },
    { "\\* ( ",                 false, "open block comment is incomplete" },
    { "\\* \\* x *\\ ( *\\ ()", true,  "nested block comments" },
    { "\\* \\* x *\\ (",        false, "outer block still open after inner closes" },
    { '\\* " *\\ (f)',          true,  "quote inside block comment ignored" },
    -- mixes
    { "(let X 1\n   (+ X\n      2))", true, "multiline form" },
    { "(let X 1\n   (+ X",      false, "multiline incomplete" },
  }
  for _, c in ipairs(cases) do
    checkeq(M.balanced(c[1]), c[2], "balanced: " .. c[3])
  end

  -- depth/mode introspection
  local d, m = M.input_state("((")
  check(d == 2 and m == "code", "input_state depth 2")
  d, m = M.input_state('("')
  check(d == 1 and m == "string", "input_state inside string")
  d, m = M.input_state("\\* \\*")
  check(m == "block", "input_state inside nested block")
end

-- ---------------------------------------------------------------------------
-- error translator (Lua error -> Shen-speak, original preserved)
-- ---------------------------------------------------------------------------
do
  local T = P.translate_error
  local cases = {
    -- LuaJIT / Lua 5.1 message order
    { "foo.lua:3: attempt to call field 'my-fn' (a nil value)",
      "my-fn is undefined (Lua: foo.lua:3: attempt to call field 'my-fn' (a nil value))" },
    { "x:1: attempt to call global 'foo' (a nil value)",
      "foo is undefined (Lua: x:1: attempt to call global 'foo' (a nil value))" },
    { "x:1: attempt to call local 'x' (a nil value)",
      "x is undefined (Lua: x:1: attempt to call local 'x' (a nil value))" },
    -- Lua 5.4 message order (the other arrangement)
    { "x:1: attempt to call a nil value (field 'bar')",
      "bar is undefined (Lua: x:1: attempt to call a nil value (field 'bar'))" },
    -- unnamed
    { "attempt to call a nil value",
      "attempt to call an undefined function (Lua: attempt to call a nil value)" },
    { "x:1: attempt to call a number value",
      "attempt to call a number value as a function (Lua: x:1: attempt to call a number value)" },
    -- arithmetic
    { "f.lua:9: attempt to perform arithmetic on a string value",
      "arithmetic on a string value: expected a number (Lua: f.lua:9: attempt to perform arithmetic on a string value)" },
    { "f.lua:9: attempt to perform arithmetic on local 'x' (a nil value)",
      "arithmetic on a nil value ('x'): expected a number (Lua: f.lua:9: attempt to perform arithmetic on local 'x' (a nil value))" },
    { "f.lua:9: attempt to perform arithmetic on a string value (field 'k')",
      "arithmetic on a string value ('k'): expected a number (Lua: f.lua:9: attempt to perform arithmetic on a string value (field 'k'))" },
    -- indexing
    { "t.lua:2: attempt to index field 'foo' (a nil value)",
      "foo is nil and cannot be indexed (Lua: t.lua:2: attempt to index field 'foo' (a nil value))" },
    { "attempt to index a nil value (global 'foo')",
      "foo is nil and cannot be indexed (Lua: attempt to index a nil value (global 'foo'))" },
    { "t.lua:2: attempt to index a number value",
      "attempt to index a number value (Lua: t.lua:2: attempt to index a number value)" },
    -- concatenation / comparison / length
    { "x:1: attempt to concatenate a table value",
      "string concatenation on a table value: expected a string (Lua: x:1: attempt to concatenate a table value)" },
    { "x:1: attempt to compare table with number",
      "comparison between a table and a number: expected numbers (Lua: x:1: attempt to compare table with number)" },
    { "x:1: attempt to compare two table values",
      "comparison between two table values: expected numbers (Lua: x:1: attempt to compare two table values)" },
    { "x:1: attempt to get length of a number value",
      "length of a number value (Lua: x:1: attempt to get length of a number value)" },
    -- pass-through: unknown shapes untouched
    { "some random error", "some random error" },
    { "h is not a list", "h is not a list" },
  }
  for i, c in ipairs(cases) do
    checkeq(T(c[1]), c[2], "translate[" .. i .. "]: " .. c[1])
  end
  -- non-strings pass through untouched
  local t = {}
  check(T(t) == t, "translate: non-string passes through")
  check(T(42) == 42, "translate: number passes through")

  -- live check: a genuine Lua nil-call crossing trap-error gets translated
  -- and wrapped as an Excn (this is exactly the trap-error seam, TOEXCN).
  local F = {}
  local ok, e = pcall(function() return F["no-such-fn"](1) end)
  check(not ok, "live nil-call errors")
  local excn = (function()
    -- mimic what compiled trap-error does: TOEXCN is not exported, but
    -- error-to-string of the translated message goes through translate_error
    return P.translate_error(tostring(e))
  end)()
  check(excn:find("no%-such%-fn is undefined") == 1, "live nil-call translates to 'is undefined'")
  check(excn:find("attempt to call", 1, true) ~= nil, "live translation preserves original text")
end

-- ---------------------------------------------------------------------------
-- did-you-mean (edit distance, top 3)
-- ---------------------------------------------------------------------------
do
  checkeq(M.edit_distance("map", "map"), 0, "distance identical")
  checkeq(M.edit_distance("map", "mpa", 3), 2, "distance transposition (as 2 edits)")
  checkeq(M.edit_distance("kitten", "sitting", 5), 3, "distance kitten/sitting")
  check(M.edit_distance("abc", "xyzzy", 2) > 2, "distance capped early-exit")

  local names = { "map", "mapcan", "print", "reverse", "rever", "revert" }
  local s = M.did_you_mean("mpa", names)
  checkeq(s[1], "map", "suggests map for mpa")
  s = M.did_you_mean("revrese", names)
  checkeq(s[1], "reverse", "suggests reverse for revrese")
  s = M.did_you_mean("zzzzzzz", names)
  checkeq(#s, 0, "no suggestion for garbage")
  s = M.did_you_mean("rever", { "rever1", "rever2", "rever3", "rever4" })
  checkeq(#s, 3, "at most 3 suggestions")
  -- key-set form (P.F-like table)
  s = M.did_you_mean("conz", { ["cons"] = true, ["cn"] = true, ["car"] = true })
  checkeq(s[1], "cons", "key-set table form works")
end

-- ---------------------------------------------------------------------------
-- chunknames + Shen-level backtrace (uses the real compile pipeline,
-- no kernel needed: prims can compile a defun standalone)
-- ---------------------------------------------------------------------------
do
  -- NB: the (+ 1 ...) wrappers keep the calls out of tail position — LuaJIT
  -- proper tail calls would otherwise erase the frames entirely (that is a
  -- documented property of the port, not a backtrace bug).
  P.eval(R.read_all("(defun repl-spec-inner (X) (+ 1 (hd X)))")[1])
  P.eval(R.read_all("(defun repl-spec-outer (X) (+ 1 (repl-spec-inner X)))")[1])
  check(type(P.F["repl-spec-outer"]) == "function", "defuns compiled")

  local info = debug.getinfo(P.F["repl-spec-inner"], "S")
  checkeq(info.source, "shen:repl-spec-inner", "compiled chunk carries shen:<fnname> chunkname")

  -- (hd 5) raises through ERR; capture the Shen frames from the error site
  local captured
  local ok = xpcall(function() return P.F["repl-spec-outer"](5) end,
                    function(e)
                      captured = { e = e, frames = M.shen_backtrace(P, 2) }
                      return e
                    end)
  check(not ok, "outer(5) raises")
  local pos = {}
  for i, f in ipairs(captured.frames) do pos[f] = i end
  check(pos["repl-spec-inner"] ~= nil, "backtrace contains inner")
  check(pos["repl-spec-outer"] ~= nil, "backtrace contains outer")
  check((pos["repl-spec-inner"] or 99) < (pos["repl-spec-outer"] or 0),
        "inner appears before outer (most recent first)")
  check(pos["hd"] ~= nil, "primitive frame named via F reverse map")

  -- describe_error: Excn message + backtrace lines, no Lua plumbing
  local desc = M.describe_error(P, captured.e, captured.frames)
  check(desc:find("hd of non%-cons") ~= nil, "describe shows the kernel message")
  check(desc:find("repl%-spec%-outer") ~= nil, "describe shows Shen frames")
  check(desc:find("xpcall", 1, true) == nil, "describe suppresses Lua plumbing")

  -- did-you-mean wired into describe_error for undefined functions
  P.eval(R.read_all("(defun repl-spec-target (X) X)")[1])
  local desc2 = M.describe_error(P, R.mkexcn("not a function: repl-spec-targt"), {})
  check(desc2:find("did you mean:", 1, true) ~= nil, "describe suggests on undefined")
  check(desc2:find("repl-spec-target", 1, true) ~= nil, "suggestion includes near match")

  -- backtrace depth cap: mutually-recursive NON-tail calls (operands of +)
  -- stack 40 alternating Shen frames; the filtered trace must cap at 12.
  P.eval(R.read_all("(defun repl-spec-deep-a (X) (if (= X 0) (hd 5) (+ 1 (repl-spec-deep-b (- X 1)))))")[1])
  P.eval(R.read_all("(defun repl-spec-deep-b (X) (+ 1 (repl-spec-deep-a X)))")[1])
  local frames2, more2
  xpcall(function() return P.F["repl-spec-deep-a"](20) end,
         function() frames2, more2 = M.shen_backtrace(P, 2) end)
  check(#frames2 == 12, "backtrace depth is capped at 12 (got " .. tostring(frames2 and #frames2) .. ")")
  check(more2 == true, "cap reports truncation")
end

io.write(string.format("repl_spec: %d passed / %d failed\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
