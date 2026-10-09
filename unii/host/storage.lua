-- unii/host/storage.lua -- storage adapter interface and its first
-- implementation: a single framed append journal per chat directory.
--
-- Interface (docs/contracts/storage.md):
--   local store, info = storage.open(dir)  -- exclusive owner; recovers tail
--   store:records()      -> { {seq=, payload=}, ... } committed, in order
--   store:append(bytes)  -> seq; durable (write-all + fsync) on return
--   store:close()
--
-- Frame: "UJ1 <seq> <len>\n" <payload> "\n" <sha256(header..payload)> "\n"
--
-- Not yet implemented (Phase 2): content-addressed blobs, checkpoints,
-- rebuildable indexes, day-sharded journals, backup/restore, and fault
-- injection at every storage boundary.
local posix = require("unii.host.posix")
local sha256 = require("unii.host.sha256")

local M = {}
M.MAX_RECORD = 16 * 1024 * 1024
M.JOURNAL = "journal.uj"
M.LOCK = "LOCK"

local Store = {}
Store.__index = Store

local function frame(seq, payload)
  local header = ("UJ1 %d %d\n"):format(seq, #payload)
  return header .. payload .. "\n" .. sha256.hex(header .. payload) .. "\n"
end
M.frame = frame

-- Parse journal bytes. Returns records, the byte offset where committed
-- data ends, and either nil (clean), "tail" (incomplete final frame) or
-- raises on corruption that is not a crash tail.
function M.parse(bytes)
  local records, off, n = {}, 1, #bytes
  while off <= n do
    local nl = bytes:find("\n", off, true)
    if not nl or nl - off > 64 then
      if n - off + 1 < 64 and not nl then return records, off - 1, "tail" end
      error(("journal corrupt at byte %d: no frame header (repair required)"):format(off - 1), 0)
    end
    local header = bytes:sub(off, nl)
    local seq, len = header:match("^UJ1 (%d+) (%d+)\n$")
    if not seq then
      error(("journal corrupt at byte %d: bad frame header (repair required)"):format(off - 1), 0)
    end
    seq, len = tonumber(seq), tonumber(len)
    if len > M.MAX_RECORD then
      error(("journal corrupt at byte %d: record length %d over bound"):format(off - 1, len), 0)
    end
    local total = #header + len + 1 + 64 + 1
    if off + total - 1 > n then return records, off - 1, "tail" end
    local payload = bytes:sub(nl + 1, nl + len)
    local sep1 = bytes:sub(nl + len + 1, nl + len + 1)
    local sum = bytes:sub(nl + len + 2, nl + len + 65)
    local sep2 = bytes:sub(nl + len + 66, nl + len + 66)
    if sep1 ~= "\n" or sep2 ~= "\n" or sum ~= sha256.hex(header .. payload) then
      error(("journal corrupt at byte %d (seq %d): checksum mismatch (repair required)"):format(off - 1, seq), 0)
    end
    if seq ~= #records + 1 then
      error(("journal corrupt at byte %d: sequence %d, expected %d"):format(off - 1, seq, #records + 1), 0)
    end
    records[#records + 1] = { seq = seq, payload = payload }
    off = off + total
  end
  return records, n, nil
end

function M.open(dir)
  assert(posix.mkdir_p(dir))
  local lockfd, err = posix.open(dir .. "/" .. M.LOCK, "rw")
  if not lockfd then error(err, 0) end
  local ok, lerr, busy = posix.try_lock(lockfd)
  if not ok then
    posix.close(lockfd)
    error(busy and ("chat " .. dir .. " is owned by another process") or lerr, 0)
  end

  local path = dir .. "/" .. M.JOURNAL
  local existed = posix.read_file(path) ~= nil
  local bytes = posix.read_file(path) or ""
  local pok, records, good, state = pcall(M.parse, bytes)
  if not pok then
    posix.close(lockfd)
    error(records, 0)
  end
  local info = { records = #records }

  local fd, oerr = posix.open(path, "append")
  if not fd then posix.close(lockfd); error(oerr, 0) end
  if state == "tail" then
    -- Isolate the uncommitted crash tail for diagnostics, then drop it.
    local tail = bytes:sub(good + 1)
    local name = ("journal.tail-%d-%d.bin"):format(good, #tail)
    assert(posix.write_file_atomic(dir, name, tail))
    assert(posix.ftruncate(fd, good))
    assert(posix.fsync(fd))
    info.tail_isolated = dir .. "/" .. name
  end
  if not existed then assert(posix.fsync(fd)); assert(posix.fsync_dir(dir)) end

  return setmetatable({ dir = dir, fd = fd, lockfd = lockfd, recs = records,
                        next_seq = #records + 1 }, Store), info
end

function Store:records() return self.recs end

function Store:append(payload)
  if #payload > M.MAX_RECORD then error("storage: record over " .. M.MAX_RECORD .. " bytes", 0) end
  local seq = self.next_seq
  local ok, err = posix.write_all(self.fd, frame(seq, payload))
  if not ok then error("storage append: " .. err, 0) end
  ok, err = posix.fsync(self.fd)
  if not ok then error("storage sync: " .. err, 0) end
  self.recs[#self.recs + 1] = { seq = seq, payload = payload }
  self.next_seq = seq + 1
  return seq
end

function Store:close()
  if self.fd then posix.close(self.fd); self.fd = nil end
  if self.lockfd then posix.unlock(self.lockfd); posix.close(self.lockfd); self.lockfd = nil end
end

return M
