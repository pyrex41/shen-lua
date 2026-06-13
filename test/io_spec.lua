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
check(type(shen.eval("(get-time run)")) == "number", "get-time run returns a number")
check(type(shen.eval("(get-time unix)")) == "number", "get-time unix returns a number")

io.write(string.format("io_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
