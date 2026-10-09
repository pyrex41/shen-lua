-- unii/host/storage.lua -- Phase 2 day-sharded journal, content-addressed
-- blobs, checkpoints and rebuildable indexes.
--
-- Interface (docs/contracts/storage.md):
--   local store, info = storage.open(dir)  -- exclusive owner; recovers tail
--   store:records()      -> { {seq=, payload=}, ... } committed, in order
--   store:append(bytes)  -> seq; durable (write-all + fsync) on return
--   store:close()
--
-- Frame: "UJ1 <seq> <len>\n" <payload> "\n" <sha256(header..payload)> "\n"
--
local posix = require("unii.host.posix")
local sha256 = require("unii.host.sha256")
local codec = require("unii.host.codec")
local Blobs = require("unii.host.storage_blobs")
local Checkpoints = require("unii.host.storage_checkpoint")
local Index = require("unii.host.storage_index")

local M = {}
M.MAX_RECORD = 16 * 1024 * 1024
M.JOURNAL = "journals/0000-00-00.uj"
M.LOCK = "LOCK"
M.SHARDS = "journals/MANIFEST"

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
function M.parse(bytes, first_seq)
  first_seq = first_seq or 1
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
    local expected = first_seq + #records
    if seq ~= expected then
      error(("journal corrupt at byte %d: sequence %d, expected %d"):format(off - 1, seq, expected), 0)
    end
    records[#records + 1] = { seq = seq, payload = payload }
    off = off + total
  end
  return records, n, nil
end

local function int(v) return codec.to_number(v) end

local function event_of(txn)
  return txn.t == "map" and txn.v.event and txn.v.event.t == "list" and txn.v.event.v or nil
end

-- Journal transactions omit the text field from message and summary events.
-- Their existing byte count and SHA-256 fields are the durable blob reference.
local function physicalize(payload, blobs)
  local decoded, txn = pcall(codec.decode, payload)
  if not decoded then return payload, {}, nil end
  local ev = event_of(txn)
  local refs, day = {}
  if ev and ev[1] and ev[1].t == "sym" then
    if ev[1].v == "message-appended" then
      local content = ev[5] and ev[5].v
      if content and #content == 4 then
        local hash, bytes, text = content[3].v, int(content[2]), content[4].v
        if #text ~= bytes or sha256.hex(text) ~= hash then error("message blob declaration mismatch", 0) end
        blobs:put(text, hash)
        content[4] = nil
        refs[#refs + 1] = { hash = hash, bytes = bytes }
      end
      local date = ev[4] and ev[4].v
      day = date and date:match("^(%d%d%d%d%-%d%d%-%d%d)") or nil
    elseif ev[1].v == "summary-completed" and #ev == 6 then
      local hash, bytes, text = ev[5].v, int(ev[4]), ev[6].v
      if #text ~= bytes or sha256.hex(text) ~= hash then error("summary blob declaration mismatch", 0) end
      blobs:put(text, hash)
      ev[6] = nil
      refs[#refs + 1] = { hash = hash, bytes = bytes }
    end
  end
  return codec.encode(txn), refs, day
end

local function hydrate(physical, blobs)
  local decoded, txn = pcall(codec.decode, physical)
  if not decoded then return physical end
  local ev = event_of(txn)
  if ev and ev[1] and ev[1].t == "sym" then
    if ev[1].v == "message-appended" then
      local content = ev[5] and ev[5].v
      if content and #content == 3 then
        content[4] = codec.text(blobs:get(content[3].v, int(content[2])))
      end
    elseif ev[1].v == "summary-completed" and #ev == 5 then
      ev[6] = codec.text(blobs:get(ev[5].v, int(ev[4])))
    end
  end
  return codec.encode(txn), txn
end

local function refs_of(physical)
  local decoded, txn = pcall(codec.decode, physical)
  if not decoded then return nil, {} end
  local refs = {}
  local ev = event_of(txn)
  if ev and ev[1] and ev[1].t == "sym" then
    if ev[1].v == "message-appended" then
      local content = ev[5] and ev[5].v
      if content and #content == 3 then refs[1] = { hash = content[3].v, bytes = int(content[2]) } end
    elseif ev[1].v == "summary-completed" and #ev == 5 then
      refs[1] = { hash = ev[5].v, bytes = int(ev[4]) }
    end
  end
  return txn, refs
end

local function read_manifest(path)
  local bytes = posix.read_file(path)
  if not bytes then return {} end
  if bytes:sub(1, 5) ~= "USM1\n" then error("journal shard manifest is corrupt (repair required)", 0) end
  local out, seen = {}, {}
  for day in bytes:sub(6):gmatch("([^\n]+)\n") do
    if not day:match("^%d%d%d%d%-%d%d%-%d%d$") or seen[day] then
      error("journal shard manifest is corrupt (repair required)", 0)
    end
    seen[day], out[#out + 1] = true, day
  end
  return out
end

local function index_txn(idx, txn, seq, refs)
  for _, ref in ipairs(refs) do
    local b = idx.blobs[ref.hash] or { bytes = ref.bytes, seqs = {} }
    b.seqs[#b.seqs + 1], idx.blobs[ref.hash] = seq, b
  end
  if not txn then return end
  local ev = event_of(txn)
  if ev and ev[1].v == "message-appended" then
    local content = ev[5].v
    idx.messages[tostring(int(ev[2]))] = {
      seq = seq, hash = content[3].v, bytes = int(content[2]), kind = ev[3].v, date = ev[4].v,
    }
  elseif ev and (ev[1].v == "summary-completed" or ev[1].v == "summary-failed") then
    idx.jobs[ev[2].v] = { status = ev[1].v == "summary-completed" and "completed" or "failed", seq = seq }
  end
  local decisions = txn.v.decisions
  if decisions and decisions.t == "list" then
    for _, d in ipairs(decisions.v) do
      if d.t == "list" and d.v[1] and d.v[1].v == "node-committed" then
        local key = d.v[2].v
        idx.nodes[int(key[2]) .. "/" .. int(key[3])] = seq
      elseif d.t == "list" and d.v[1] and d.v[1].v == "job-blocked" then
        idx.jobs[d.v[2].v] = { status = "blocked", seq = seq }
      end
    end
  end
  local commands = txn.v.commands
  if commands and commands.t == "list" then
    for _, c in ipairs(commands.v) do
      if c.t == "list" and c.v[1] and c.v[1].v == "submit-summary" then
        idx.jobs[c.v[3].v] = { status = "pending", seq = seq }
      end
    end
  end
end

local function lazy_record(store, meta)
  return setmetatable({ seq = meta.seq }, {
    __index = function(_, key)
      if key ~= "payload" then return nil end
      local physical, err = posix.read_range(meta.path, meta.payload_offset, meta.length)
      if not physical then error(err, 0) end
      return (hydrate(physical, store.blobs))
    end,
  })
end

local function recover_tail(store, path, good, size)
  local tail = posix.read_range(path, good, size - good) or ""
  local name = ("journal.tail-%d-%d.bin"):format(good, #tail)
  assert(posix.write_file_atomic(store.dir, name, tail))
  local fd = assert(posix.open(path, "append"))
  assert(posix.ftruncate(fd, good))
  assert(posix.sync_file(fd))
  posix.close(fd)
  assert(posix.fsync_dir(store.journal_dir))
  store.info.tail_isolated = store.dir .. "/" .. name
end

-- Stream one frame at a time. Only bounded record bytes, never a whole shard,
-- are resident. Record payloads returned through records() are lazy.
local function scan_shard(store, day, expected, is_last)
  local path = store.journal_dir .. "/" .. day .. ".uj"
  local f = io.open(path, "rb")
  if not f then error("journal shard " .. day .. " is missing (repair required)", 0) end
  local size, off = f:seek("end"), 0
  f:seek("set", 0)
  while off < size do
    local start = off
    local header_line = f:read("*l")
    if not header_line then break end
    off = f:seek()
    local header_had_newline = off - start == #header_line + 1
    local seqs, lens = header_line:match("^UJ1 (%d+) (%d+)$")
    local seq, len = tonumber(seqs), tonumber(lens)
    if not seq or not len or len > M.MAX_RECORD then
      f:close()
      if is_last and not header_had_newline then
        recover_tail(store, path, start, size)
        return expected
      end
      error(("journal corrupt at byte %d in shard %s: bad frame header (repair required)"):format(start, day), 0)
    end
    local payload_offset = off
    local physical, sep = f:read(len), f:read(1)
    local sum_start = f:seek()
    local sumline = f:read("*l")
    off = f:seek() or size
    local sum_had_newline = sumline and off - sum_start == #sumline + 1
    if not physical or #physical ~= len or sep ~= "\n" or not sumline or #sumline ~= 64 or not sum_had_newline then
      f:close()
      local expected_end = start + #header_line + 1 + len + 1 + 64 + 1
      if is_last and size < expected_end then recover_tail(store, path, start, size); return expected end
      error(("journal corrupt at byte %d in non-final shard %s (repair required)"):format(start, day), 0)
    end
    local header = header_line .. "\n"
    if sumline ~= sha256.hex(header .. physical) then
      f:close()
      error(("journal corrupt at byte %d (seq %d): checksum mismatch (repair required)"):format(start, seq), 0)
    end
    if seq ~= expected then
      f:close()
      error(("journal corrupt at byte %d: sequence %d, expected %d"):format(start, seq, expected), 0)
    end
    local txn, refs = refs_of(physical)
    for _, ref in ipairs(refs) do store.blobs:verify(ref.hash, ref.bytes) end
    local meta = { seq = seq, day = day, path = path, offset = start,
      payload_offset = payload_offset, length = len, physical_hash = sha256.hex(physical) }
    store.meta[#store.meta + 1] = meta
    store.recs[#store.recs + 1] = lazy_record(store, meta)
    store.idx.records[#store.idx.records + 1] = meta
    index_txn(store.idx, txn, seq, refs)
    expected = expected + 1
  end
  f:close()
  return expected
end

local function ensure_shard(store, day)
  day = day or store.active_day or "0000-00-00"
  if store.shard_set[day] then store.active_day = day; return end
  local path = store.journal_dir .. "/" .. day .. ".uj"
  local fd, err = posix.open(path, "append")
  if not fd then error(err, 0) end
  assert(posix.sync_file(fd))
  posix.close(fd)
  assert(posix.fsync_dir(store.journal_dir))
  store.shards[#store.shards + 1], store.shard_set[day] = day, true
  assert(posix.write_file_atomic(store.journal_dir, "MANIFEST",
    "USM1\n" .. table.concat(store.shards, "\n") .. "\n"))
  store.active_day = day
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
  local function build()
    local journal_dir = dir .. "/journals"
    assert(posix.mkdir_p(journal_dir))
    assert(posix.fsync_dir(dir))
    local info = {}
    local store = setmetatable({
      dir = dir, journal_dir = journal_dir, lockfd = lockfd, info = info,
      blobs = Blobs.new(dir), checkpoints = Checkpoints.new(dir),
      recs = {}, meta = {}, idx = { records = {}, messages = {}, blobs = {}, nodes = {}, jobs = {} },
    }, Store)
    store.shards = read_manifest(dir .. "/" .. M.SHARDS)
    store.shard_set = {}
    for _, day in ipairs(store.shards) do store.shard_set[day] = true end
    local expected = 1
    for i, day in ipairs(store.shards) do expected = scan_shard(store, day, expected, i == #store.shards) end
    store.next_seq, store.active_day = expected, store.shards[#store.shards]
    info.records = #store.recs
    local iok, ierr = pcall(Index.write, dir, store.idx)
    if not iok then info.index_error = tostring(ierr) end
    store.index_dirty = false
    return store, info
  end
  local bok, store, info = pcall(build)
  if not bok then posix.close(lockfd); error(store, 0) end
  return store, info
end

function Store:records() return self.recs end

function Store:iter_records(after)
  local i = (after or 0) + 1
  return function()
    local record = self.recs[i]
    i = i + 1
    return record
  end
end

local function append_unprotected(self, payload)
  if #payload > M.MAX_RECORD then error("storage: record over " .. M.MAX_RECORD .. " bytes", 0) end
  local physical, refs, day = physicalize(payload, self.blobs)
  ensure_shard(self, day)
  local seq, path = self.next_seq, self.journal_dir .. "/" .. self.active_day .. ".uj"
  local bytes = frame(seq, physical)
  local offset = posix.file_size(path) or 0
  local fd, err = posix.open(path, "append")
  if not fd then error("storage append: " .. tostring(err), 0) end
  local ok
  ok, err = posix.write_all(fd, bytes)
  if ok then ok, err = posix.sync_file(fd) end
  posix.close(fd)
  if not ok then error("storage append: " .. tostring(err), 0) end
  ok, err = posix.fsync_dir(self.journal_dir)
  if not ok then error("storage directory sync: " .. tostring(err), 0) end
  local header = ("UJ1 %d %d\n"):format(seq, #physical)
  local meta = { seq = seq, day = self.active_day, path = path, offset = offset,
    payload_offset = offset + #header, length = #physical, physical_hash = sha256.hex(physical) }
  self.meta[#self.meta + 1] = meta
  self.recs[#self.recs + 1] = lazy_record(self, meta)
  self.idx.records[#self.idx.records + 1] = meta
  local decoded, txn = pcall(codec.decode, physical)
  index_txn(self.idx, decoded and txn or nil, seq, refs)
  self.next_seq = seq + 1
  self.index_dirty = true
  if seq % 64 == 0 then
    local iok, ierr = pcall(self.rebuild_indexes, self)
    if not iok then self.info.index_error = tostring(ierr) end
  end
  return seq
end

function Store:append(payload)
  if self.poisoned then
    error("storage is poisoned after a failed mutation; close and reopen before appending", 0)
  end
  local ok, result = pcall(append_unprotected, self, payload)
  if not ok then
    -- The failure may have happened after any prefix of a frame, or after a
    -- complete frame reached the kernel but before its sync was confirmed.
    -- Continuing could append after a torn frame or reuse a committed seq.
    self.poisoned = true
    error(result, 0)
  end
  return result
end

function Store:record_anchor(seq)
  local meta = self.meta[seq]
  return meta and meta.physical_hash or nil
end

function Store:message_index() return self.idx.messages end
function Store:get_blob(hash, bytes) return self.blobs:get(hash, bytes) end
function Store:write_checkpoint(seq, payload) return self.checkpoints:write(seq, payload) end
function Store:checkpoint_candidates() return self.checkpoints:candidates() end
function Store:set_aside_checkpoint(name, reason) return self.checkpoints:set_aside(name, reason) end
function Store:rebuild_indexes()
  Index.write(self.dir, self.idx)
  self.index_dirty = false
end

function Store:close()
  if self.index_dirty then
    local ok, err = pcall(self.rebuild_indexes, self)
    if not ok then self.info.index_error = tostring(err) end
  end
  if self.lockfd then posix.unlock(self.lockfd); posix.close(self.lockfd); self.lockfd = nil end
end

return M
