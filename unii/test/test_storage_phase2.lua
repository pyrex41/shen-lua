local T = require("unii.test.lib")
local storage = require("unii.host.storage")
local supervisor = require("unii.host.supervisor")
local codec = require("unii.host.codec")
local schema = require("unii.host.schema")
local sha256 = require("unii.host.sha256")
local posix = require("unii.host.posix")
local mock = require("unii.host.mock.summarizer")

local function read(path)
  local f = assert(io.open(path, "rb"))
  local bytes = f:read("*a")
  f:close()
  return bytes
end

local function write(path, bytes)
  local f = assert(io.open(path, "wb"))
  f:write(bytes)
  f:close()
end

local function open_sup(dir, extra)
  local opts = { core = T.core(), provider = mock.new { cap = 512 } }
  for k, v in pairs(extra or {}) do opts[k] = v end
  return supervisor.open(dir, opts)
end

return {
  { "message and summary bodies are blobs; physical journal contains only hashes", function()
    local dir = T.tmpdir("phase2-blobs")
    local original = "private-body-" .. ("x"):rep(900)
    local sup = open_sup(dir, { checkpoint_interval = 0 })
    sup:submit(T.msg(0, "user", original, "2026-10-09T23:59:59Z"))
    sup:pump()
    local hash = sha256.hex(original)
    local final_hash = sup:state_hash()
    sup:close()

    T.eq(read(dir .. "/blobs/" .. hash), original)
    local shard = read(dir .. "/journals/2026-10-09.uj")
    T.ok(not shard:find(original, 1, true), "message text leaked into the journal")
    local records = storage.parse(shard, 2)
    local saw_message, saw_summary = false, false
    for _, record in ipairs(records) do
      local txn = codec.decode(record.payload)
      local ev = txn.v.event and txn.v.event.v
      if ev and ev[1].v == "message-appended" then
        saw_message = true
        T.eq(#ev[5].v, 3)
        T.eq(ev[5].v[3].v, hash)
      elseif ev and ev[1].v == "summary-completed" then
        saw_summary = true
        T.eq(#ev, 5)
        T.ok(read(dir .. "/blobs/" .. ev[5].v) ~= nil)
      end
    end
    T.ok(saw_message and saw_summary)
    local again = open_sup(dir, { checkpoint_interval = 0 })
    T.eq(again:state_hash(), final_hash)
    again:close()
    T.rm(dir)
  end },

  { "daily shards retain global order and rebuild all indexes", function()
    local dir = T.tmpdir("phase2-shards")
    local sup = open_sup(dir, { checkpoint_interval = 0 })
    sup:submit(T.msg(0, "user", "day one", "2026-10-09T23:59:59Z"))
    sup:submit(T.msg(1, "assistant", "day two", "2026-10-10T00:00:01Z"))
    local state_hash = sup:state_hash()
    sup:close()
    T.eq(read(dir .. "/journals/MANIFEST"),
      "USM1\n0000-00-00\n2026-10-09\n2026-10-10\n")
    for _, name in ipairs { "journal.idx", "messages.idx", "blobs.idx", "nodes.idx", "jobs.idx" } do
      T.ok(#read(dir .. "/indexes/" .. name) >= 5, name)
    end
    T.ok(read(dir .. "/indexes/messages.idx"):find("0\t2\t", 1, true))
    T.ok(read(dir .. "/indexes/messages.idx"):find("1\t3\t", 1, true))
    local again = open_sup(dir, { checkpoint_interval = 0 })
    T.eq(again:state_hash(), state_hash)
    T.eq(again.info.replayed_records, 2)
    again:close()
    T.rm(dir)
  end },

  { "latest valid checkpoint skips old records and preserves exact hashes", function()
    local dir = T.tmpdir("phase2-checkpoint")
    local sup = open_sup(dir, { checkpoint_interval = 4 })
    for i = 0, 11 do sup:submit(T.msg(i, "user", "checkpoint " .. i)) end
    sup:checkpoint()
    local state_hash, view, view_hash = sup:state_hash(), sup:view()
    local last = sup.store.next_seq - 1
    sup:close()

    local again = open_sup(dir, { checkpoint_interval = 4 })
    T.eq(again.info.checkpoint_seq, last)
    T.eq(again.info.replayed_records, 0)
    T.eq(again:state_hash(), state_hash)
    local view2, hash2 = again:view()
    T.eq(view2, view); T.eq(hash2, view_hash)
    again:close()
    T.rm(dir)
  end },

  { "dispatch intent restored from checkpoint becomes uncertain and is never resent", function()
    local dir = T.tmpdir("phase2-dispatch-checkpoint")
    local first = mock.new { cap = 512 }
    local sup = supervisor.open(dir, {
      core = T.core(), provider = first, checkpoint_interval = 3,
      config = schema.config { max_inflight = 1 },
    })
    sup:submit(T.msg(0, "user", ("in flight "):rep(100)))
    T.eq(sup:dispatch_pending(), 1)
    T.eq(first.calls, 1)
    T.eq(#first.network.hits, 0, "provider has not been stepped")
    T.eq(sup.store.next_seq - 1, 3, "init, event, dispatch")
    T.eq(sup.info.checkpoint_error, nil)
    sup:close() -- crash after the dispatch record/checkpoint, before any outcome

    local second = mock.new { cap = 512 }
    sup = supervisor.open(dir, {
      core = T.core(), provider = second, checkpoint_interval = 3,
    })
    T.eq(sup.info.checkpoint_seq, 3)
    T.eq(sup.info.replayed_records, 0)
    T.eq(#sup:orphans(), 1, "dispatch intent survived checkpoint restore")
    sup:pump()
    T.eq(second.calls, 0, "uncertain command was not sent to the provider")
    T.eq(#second.network.hits, 0)
    T.eq(sup:status().uncertain, 1)
    T.eq(sup:outstanding_count(), 0)
    sup:close()
    T.ok(read(dir .. "/indexes/jobs.idx"):find("\tuncertain\t", 1, true))
    T.rm(dir)
  end },

  { "stale checkpoint is set aside and an older valid checkpoint is used", function()
    local dir = T.tmpdir("phase2-stale")
    local sup = open_sup(dir, { checkpoint_interval = 4 })
    for i = 0, 8 do sup:submit(T.msg(i, "user", "stale " .. i)) end
    local expected = sup:state_hash()
    sup:close()

    local store = storage.open(dir)
    local candidates = store:checkpoint_candidates()
    T.ok(#candidates > 0)
    local cp = codec.decode(candidates[1].payload)
    cp.v.anchor = codec.text(("0"):rep(64))
    store:write_checkpoint(store.next_seq - 1, codec.encode(cp))
    store:close()

    local again = open_sup(dir, { checkpoint_interval = 4 })
    T.ok(again.info.checkpoint_rejected and again.info.checkpoint_rejected:find("stale journal anchor", 1, true))
    T.ok(again.info.checkpoint_seq, "older checkpoint was not used")
    T.eq(again:state_hash(), expected)
    again:close()
    T.rm(dir)
  end },

  { "missing or corrupted committed blobs refuse recovery without changing journal", function()
    local dir = T.tmpdir("phase2-badblob")
    local text = "blob source"
    local hash = sha256.hex(text)
    local sup = open_sup(dir, { checkpoint_interval = 0 })
    sup:submit(T.msg(0, "user", text))
    sup:close()
    local journal_path = dir .. "/journals/2026-10-09.uj"
    local journal = read(journal_path)
    local blob_path = dir .. "/blobs/" .. hash
    assert(os.rename(blob_path, blob_path .. ".missing"))
    T.raises(function() storage.open(dir) end, "missing committed blob")
    T.eq(read(journal_path), journal)
    assert(os.rename(blob_path .. ".missing", blob_path))
    write(blob_path, "corrupt")
    T.raises(function() storage.open(dir) end, "corrupted blob")
    T.eq(read(journal_path), journal)
    T.rm(dir)
  end },

  { "recovery streams shards and lazy records instead of reading journal files whole", function()
    local dir = T.tmpdir("phase2-stream")
    local store = storage.open(dir)
    for i = 1, 200 do store:append(("record-%04d-"):format(i) .. ("z"):rep(2000)) end
    store:close()
    local real = posix.read_file
    posix.read_file = function(path)
      if path:match("%.uj$") then error("whole journal read attempted: " .. path, 0) end
      return real(path)
    end
    local ok, reopened = pcall(storage.open, dir)
    posix.read_file = real
    if not ok then error(reopened, 0) end
    T.eq(#reopened:records(), 200)
    T.eq(reopened:records()[200].payload:sub(1, 11), "record-0200")
    reopened:close()
    T.rm(dir)
  end },
}
