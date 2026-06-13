-- test/cli_spec.lua — PORT-AUTHORED CLI/launcher coverage, mirroring shen-go's
-- cmd/shen/main_test.go. Drives the real `bin/shen` launcher as a subprocess
-- (io.popen / os.execute) and asserts on its stdout and exit code.
--
-- Covers:
--   * `-e EXPR` prints the value and exits 0;
--   * positional FILE is (load)ed, then a following `-e` sees its definitions;
--   * mixed FILE + -e run in command-line order;
--   * stdin EOF exits the REPL cleanly (echo '(+ 1 2)' | bin/shen prints 3 and
--     exits 0) — the guard against the historical infinite-EOF loop;
--   * the REPL survives adversarial input (apply-non-function) and keeps going;
--   * an adversarial `-e` exits nonzero with a clean error (no Lua traceback);
--   * unknown option exits 2;
--   * the *hush*/-q divergence: on shen-lua, `-q` SILENCES pr to file streams,
--     producing a ZERO-BYTE file, whereas without -q the file gets the payload.
--     (This is the documented cross-impl divergence vs shen-cl/shen-go/ShenScript,
--     which route pr to files regardless of *hush*.)
--
-- Every subprocess is wrapped in `timeout` when available, so an EOF-loop
-- regression FAILS (nonzero/empty output) rather than HANGS the whole suite.
--
--   luajit test/cli_spec.lua
--
-- (Pure subprocess driver — does NOT require the kernel in-process.)

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end

-- Locate bin/shen relative to this spec.
local here = arg[0]:gsub("test/[^/]*$", "")
if here == "" then here = "./" end
local SHEN = here .. "bin/shen"

-- A wall-clock cap so an EOF-loop or hang surfaces as a failed assertion
-- instead of wedging the runner. Prefer GNU timeout / gtimeout if present.
local function have(cmd)
  local h = io.popen("command -v " .. cmd .. " 2>/dev/null")
  if not h then return false end
  local out = h:read("*a"); h:close()
  return out ~= nil and out:match("%S") ~= nil
end
local TIMEOUT = have("timeout") and "timeout 60 " or (have("gtimeout") and "gtimeout 60 " or "")

local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- Run a shell command line, capture stdout+stderr, and return (output, exitcode).
-- LuaJIT's io.popen():close() does NOT report the child's exit status, so we
-- append a sentinel `EXIT:<code>` line in the shell and parse it out — this is
-- the portable way to recover the exit code across Lua 5.1/LuaJIT.
local function run(cmdline)
  local full = "{ " .. TIMEOUT .. cmdline .. " ; } 2>&1; echo \"__EXIT__:$?\""
  local h = io.popen(full, "r")
  local out = h:read("*a") or ""
  h:close()
  local code = tonumber(out:match("__EXIT__:(%d+)%s*$")) or -1
  out = out:gsub("__EXIT__:%d+%s*$", "")
  return out, code
end

-- Run with given stdin piped in.
local function run_stdin(stdin, cmdline)
  local tmp = os.tmpname()
  local f = io.open(tmp, "w"); f:write(stdin); f:close()
  local out, code = run(cmdline .. " < " .. sh_quote(tmp))
  os.remove(tmp)
  return out, code
end

-- ---------------------------------------------------------------------------
-- -e EXPR prints the value, exit 0
-- ---------------------------------------------------------------------------
do
  local out, code = run(SHEN .. " -e " .. sh_quote("(+ 1 2)"))
  check(out:find("3", 1, true) ~= nil, "-e prints the result (3)")
  check(code == 0, "-e exits 0")
end

-- ---------------------------------------------------------------------------
-- positional FILE is loaded; a following -e sees its definitions
-- ---------------------------------------------------------------------------
do
  local fpath = os.tmpname() .. ".shen"
  local f = io.open(fpath, "w")
  f:write("(define cli-spec-sq X -> (* X X))")
  f:close()
  local out, code = run(SHEN .. " " .. sh_quote(fpath) .. " -e " .. sh_quote("(cli-spec-sq 4)"))
  check(out:find("16", 1, true) ~= nil, "FILE then -e: definition is visible (16)")
  check(code == 0, "FILE + -e exits 0")
  os.remove(fpath)
end

-- ---------------------------------------------------------------------------
-- mixed FILE + -e run in command-line ORDER: load, eval, then a SECOND file's
-- def that overrides, then eval again -> the second value wins.
-- ---------------------------------------------------------------------------
do
  local f1 = os.tmpname() .. ".shen"
  local f2 = os.tmpname() .. ".shen"
  local h1 = io.open(f1, "w"); h1:write("(define cli-spec-k -> 1)"); h1:close()
  local h2 = io.open(f2, "w"); h2:write("(define cli-spec-k -> 2)"); h2:close()
  local out, code = run(SHEN
    .. " " .. sh_quote(f1)
    .. " -e " .. sh_quote("(cli-spec-k)")
    .. " " .. sh_quote(f2)
    .. " -e " .. sh_quote("(cli-spec-k)"))
  -- ordered output must contain BOTH 1 then 2 (the redefinition took effect)
  local p1 = out:find("1", 1, true)
  local p2 = out:find("2", p1 and p1 + 1 or 1, true)
  check(p1 ~= nil and p2 ~= nil and p1 < p2,
        "mixed FILE/-e: actions run in command-line order (1 then 2)")
  check(code == 0, "mixed FILE/-e exits 0")
  os.remove(f1); os.remove(f2)
end

-- ---------------------------------------------------------------------------
-- stdin EOF exits the REPL cleanly. This guards the historical infinite-EOF
-- loop: `echo '(+ 1 2)' | bin/shen` must print 3 and EXIT (0), not spin.
-- If the loop regresses, `timeout` kills it -> nonzero code -> this fails.
-- ---------------------------------------------------------------------------
do
  local out, code = run_stdin("(+ 1 2)\n", SHEN)
  check(out:find("3", 1, true) ~= nil, "piped stdin: prints 3")
  check(code == 0, "piped stdin EOF exits cleanly (exit 0, no infinite loop)")
  -- a timeout-kill exit (124) would mean the EOF loop regressed
  check(code ~= 124, "piped stdin did NOT hit the timeout (no EOF loop)")
end

-- empty stdin (immediate EOF) also exits cleanly
do
  local out, code = run_stdin("", SHEN)
  check(code == 0, "empty stdin EOF exits cleanly")
  check(code ~= 124, "empty stdin did NOT hang")
end

-- ---------------------------------------------------------------------------
-- REPL survives adversarial input: apply a non-function, then a valid form.
-- The REPL must print an error and continue to evaluate `(+ 40 2)` -> 42,
-- never dumping a Lua traceback.
-- ---------------------------------------------------------------------------
do
  local out, code = run_stdin("(overflow->str)\n(+ 40 2)\n", SHEN)
  check(out:find("not a function: overflow->str", 1, true) ~= nil,
        "REPL prints the catchable error for apply-non-function")
  check(out:find("42", 1, true) ~= nil, "REPL keeps going and evaluates 42")
  check(code == 0, "adversarial REPL session still exits 0")
  -- A Lua traceback (stack dump) in user-facing output is the regression we refuse.
  check(out:find("stack traceback", 1, true) == nil,
        "REPL did not leak a Lua stack traceback")
end

-- ---------------------------------------------------------------------------
-- adversarial `-e`: must exit NONZERO with a clean error line, no traceback.
-- ---------------------------------------------------------------------------
do
  local out, code = run(SHEN .. " -e " .. sh_quote("(overflow->str)"))
  check(code ~= 0, "adversarial -e exits nonzero")
  check(out:find("not a function: overflow->str", 1, true) ~= nil,
        "adversarial -e prints the clean error message")
  check(out:find("stack traceback", 1, true) == nil,
        "adversarial -e did not leak a Lua traceback")
end

-- ---------------------------------------------------------------------------
-- unknown option exits 2
-- ---------------------------------------------------------------------------
do
  local out, code = run(SHEN .. " --no-such-option")
  check(code == 2, "unknown option exits 2")
  check(out:find("unknown option", 1, true) ~= nil, "unknown option prints usage")
end

-- ---------------------------------------------------------------------------
-- THE -q / *hush* DIVERGENCE.  On shen-lua, -q sets *hush*, which SILENCES pr
-- to file streams -> a ZERO-BYTE file. Without -q the file gets "payload".
-- This intentionally differs from shen-cl/shen-go/ShenScript, which write the
-- payload regardless of *hush*. Lock in shen-lua's documented behavior.
-- ---------------------------------------------------------------------------
do
  local pq = os.tmpname()
  local expr = '(let S (open "' .. pq .. '" out) (do (pr "payload" S) (close S)))'
  local _, codeq = run(SHEN .. " -q -e " .. sh_quote(expr))
  check(codeq == 0, "-q pr-to-file exits 0")
  -- read the file size
  local sizeq = 0
  local hf = io.open(pq, "rb")
  if hf then local d = hf:read("*a") or ""; sizeq = #d; hf:close() end
  check(sizeq == 0, "-q SILENCES pr to file (zero-byte file) — documented divergence")
  os.remove(pq)

  -- without -q, the same write produces the payload
  local pn = os.tmpname()
  local expr2 = '(let S (open "' .. pn .. '" out) (do (pr "payload" S) (close S)))'
  local _, coden = run(SHEN .. " -e " .. sh_quote(expr2))
  check(coden == 0, "no-q pr-to-file exits 0")
  local content = ""
  local hf2 = io.open(pn, "rb")
  if hf2 then content = hf2:read("*a") or ""; hf2:close() end
  check(content == "payload", "without -q, pr writes the payload to the file")
  os.remove(pn)
end

io.write(string.format("cli_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
