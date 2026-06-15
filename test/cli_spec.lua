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
--   * pr-to-file under -q/*hush* (issue #22): -q sets *hush*, but *hush* only
--     suppresses writes to STANDARD OUTPUT. A `pr` to a FILE stream writes the
--     payload regardless of *hush*, matching shen-cl/shen-go/ShenScript. (This
--     used to diverge: -q produced a zero-byte file; fixed in #22.)
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
-- pr-to-file under -q / *hush* (issue #22 regression).  -q sets *hush*, but
-- *hush* must suppress only STANDARD-OUTPUT writes — a `pr` to a FILE stream
-- writes the payload regardless of *hush*, matching shen-cl/shen-go/ShenScript.
-- (Pre-#22 this produced a ZERO-BYTE file.)
-- ---------------------------------------------------------------------------
do
  local pq = os.tmpname()
  local expr = '(let S (open "' .. pq .. '" out) (do (pr "payload" S) (close S)))'
  local _, codeq = run(SHEN .. " -q -e " .. sh_quote(expr))
  check(codeq == 0, "-q pr-to-file exits 0")
  -- read the file back
  local contentq = ""
  local hf = io.open(pq, "rb")
  if hf then contentq = hf:read("*a") or ""; hf:close() end
  check(contentq == "payload",
        "issue #22: -q (*hush*) does NOT silence pr to a file stream — payload is written")
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

-- ---------------------------------------------------------------------------
-- issue #22 (other half): *hush* STILL silences standard-output writes. With
-- -q, a `pr` to (stoutput) must produce no stdout — only the file path above
-- is exempted, not the gate itself.
-- ---------------------------------------------------------------------------
do
  -- `pr` returns its string argument, and `-e` echoes the expression's value,
  -- so the pr text would appear in stdout via the echo regardless of *hush*.
  -- Return a DISTINCT value (99) so the only way the marker can appear is the
  -- pr write itself — which must be silenced under -q.
  local marker = "NOISE_22_MARKER"
  local expr = '(do (pr "' .. marker .. '" (stoutput)) 99)'
  local outq, codeq = run(SHEN .. " -q -e " .. sh_quote(expr))
  check(codeq == 0, "-q pr-to-stdout exits 0")
  check(outq:find(marker, 1, true) == nil,
        "issue #22: -q (*hush*) still silences pr to standard output")
  -- and without -q the marker IS written to stdout (sanity: the gate exists)
  local outn = run(SHEN .. " -e " .. sh_quote(expr))
  check(outn:find(marker, 1, true) ~= nil,
        "without -q, pr to standard output is written")
end

-- ---------------------------------------------------------------------------
-- *hush* gates ONLY standard output: a `pr` to the *sterror* (error/diagnostic)
-- stream must STILL be written under -q, like file streams. This locks in the
-- policy that quiet mode silences stdout chatter only, not diagnostics.
-- run() captures stdout+stderr combined, so the marker appears via stderr.
-- ---------------------------------------------------------------------------
do
  local marker = "ERR_22_MARKER"
  -- distinct return value (99) so the marker can only come from the pr write,
  -- not the -e value echo.
  local expr = '(do (pr "' .. marker .. '" (value *sterror*)) 99)'
  local outq, codeq = run(SHEN .. " -q -e " .. sh_quote(expr))
  check(codeq == 0, "-q pr-to-stderr exits 0")
  check(outq:find(marker, 1, true) ~= nil,
        "-q (*hush*) does NOT silence pr to *sterror* — diagnostics still write")
end

io.write(string.format("cli_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
