-- test/io_spec.lua — PORT-AUTHORED I/O primitive coverage, mirroring shen-go's
-- kl/io_coverage_test.go. Drives the real kernel through shen.eval against real
-- temp files. Covers: open(out)/write-byte/close -> open(in)/read-byte round
-- trip, read-byte EOF returns -1, read-file-as-string, and get-time.
--
-- This is NOT the canonical kernel certification suite (run-kernel-tests.lua).
--
--   luajit test/io_spec.lua
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
local function evs(src) return R.to_str(shen.eval(src)) end

-- A throwaway temp path that is removed at the end of each `do` block.
local function tmppath() return os.tmpname() end

-- ---------------------------------------------------------------------------
-- write-byte -> close -> read-byte round trip, with EOF == -1.
-- "Hi" = bytes 72, 105.
-- ---------------------------------------------------------------------------
do
  local p = tmppath()
  -- open out, write two bytes, close. open returns a stream; the let body
  -- returns () after close.
  shen.eval(string.format(
    [[(let S (open "%s" out)
        (do (write-byte 72 S) (write-byte 105 S) (close S)))]], p))

  -- open in, read three bytes (the third is past EOF -> -1), close.
  local got = evs(string.format(
    [[(let S (open "%s" in)
        (let A (read-byte S)
          (let B (read-byte S)
            (let C (read-byte S)
              (do (close S) [A B C])))))]], p))
  check(got == "(72 105 -1)", "write-byte/read-byte round trip with EOF -1 (got " .. got .. ")")
  os.remove(p)
end

-- ---------------------------------------------------------------------------
-- read-byte at EOF on an empty file returns -1 immediately.
-- ---------------------------------------------------------------------------
do
  local p = tmppath()
  local f = io.open(p, "w"); f:close()           -- zero-byte file
  local got = evs(string.format(
    "(let S (open \"%s\" in) (let B (read-byte S) (do (close S) B)))", p))
  check(got == "-1", "read-byte on empty file returns -1 (got " .. got .. ")")
  os.remove(p)
end

-- ---------------------------------------------------------------------------
-- read-file-as-string reads the whole file back.
-- ---------------------------------------------------------------------------
do
  local p = tmppath()
  local f = io.open(p, "w"); f:write("AB"); f:close()
  local got = evs(string.format('(read-file-as-string "%s")', p))
  check(got == '"AB"', "read-file-as-string returns file contents (got " .. got .. ")")
  os.remove(p)
end

-- ---------------------------------------------------------------------------
-- close is idempotent / the stream is usable up to close: writing then reading
-- the SAME bytes back proves the byte path end-to-end. Already covered above;
-- here we additionally assert a multi-byte payload preserves order.
-- ---------------------------------------------------------------------------
do
  local p = tmppath()
  shen.eval(string.format(
    [[(let S (open "%s" out)
        (do (write-byte 83 S) (write-byte 104 S) (write-byte 101 S)
            (write-byte 110 S) (close S)))]], p))   -- "Shen"
  local got = evs(string.format(
    [[(let S (open "%s" in)
        (let A (read-byte S) (let B (read-byte S)
          (let C (read-byte S) (let D (read-byte S)
            (do (close S) [A B C D]))))))]], p))
  check(got == "(83 104 101 110)", "ordered multi-byte round trip (got " .. got .. ")")
  os.remove(p)
end

-- ---------------------------------------------------------------------------
-- get-time: unix wall clock and run-time both return numbers.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Relative file names resolve against *home-directory*, which `cd` sets
-- (issue #86): open, read-file, read-file-as-string/-bytelist and load. A
-- file of the same name in the process cwd must not shadow the one in the
-- home directory (the native fast paths used to try the cwd first).
-- ---------------------------------------------------------------------------
do
  local dir = os.tmpname(); os.remove(dir)
  os.execute("mkdir -p '" .. dir .. "'")
  local base = dir:match("[^/]*$") .. "-io86.shen"
  local function put(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
  put(dir .. "/" .. base, "(+ 1 2)")
  put(base, "(cwd copy)")                         -- the shadow in the cwd
  put(dir .. "/loadme.shen", "(define io86-loaded -> home)")
  shen.eval(string.format('(cd "%s")', dir))
  check(evs(string.format('(read-file "%s")', base)) == "((+ 1 2))",
        "#86: read-file resolves against *home-directory*")
  check(shen.eval(string.format('(read-file-as-string "%s")', base)) == "(+ 1 2)",
        "#86: read-file-as-string resolves against *home-directory*")
  check(evs(string.format('(length (read-file-as-bytelist "%s"))', base)) == "7",
        "#86: read-file-as-bytelist resolves against *home-directory*")
  check(evs(string.format('(let S (open "%s" in) (let B (read-byte S) (do (close S) B)))', base))
        == "40", "#86: open resolves against *home-directory*")
  shen.eval('(trap-error (load "loadme.shen") (/. E skip))')
  check(evs("(io86-loaded)") == "home", "#86: load resolves against *home-directory*")
  check(shen.eval(string.format('(read-file-as-string "%s/%s")', dir, base)) == "(+ 1 2)",
        "#86: an absolute name is used as given after cd")
  shen.eval('(cd "")')
  check(shen.eval(string.format('(read-file-as-string "%s")', base)) == "(cwd copy)",
        "#86: (cd \"\") resolves against the process cwd again")
  os.remove(base)
  os.remove(dir .. "/" .. base); os.remove(dir .. "/loadme.shen"); os.remove(dir)
end

check(type(shen.eval("(get-time run)")) == "number", "get-time run returns a number")
check(type(shen.eval("(get-time unix)")) == "number", "get-time unix returns a number")

io.write(string.format("io_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
