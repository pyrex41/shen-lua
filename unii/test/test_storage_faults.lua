local T = require("unii.test.lib")
local storage = require("unii.host.storage")
local posix = require("unii.host.posix")
local codec = require("unii.host.codec")
local schema = require("unii.host.schema")
local supervisor = require("unii.host.supervisor")
local mock = require("unii.host.mock.summarizer")

local function transaction(text)
  return codec.encode(codec.map {
    kind = codec.sym("event"),
    event = schema.encode("event", T.msg(0, "user", text, "2026-10-11T00:00:00Z")),
    commands = codec.list {},
    decisions = codec.list {},
  })
end

local function with_hook(fn, body)
  posix.set_fault_hook(fn)
  local ok, a, b = pcall(body)
  posix.set_fault_hook(nil)
  if not ok then error(a, 0) end
  return a, b
end

return {
  { "blob, journal and directory durability boundaries occur in commit order", function()
    local dir = T.tmpdir("fault-order")
    local store = storage.open(dir)
    local trace = {}
    with_hook(function(op, detail)
      trace[#trace + 1] = { op = op, path = detail.path, from = detail.from, to = detail.to }
    end, function() store:append(transaction("ordered blob")) end)
    store:close()

    local blob_sync, journal_write, journal_sync, directory_sync
    for i, e in ipairs(trace) do
      if e.op == "fsync.after" and e.path and e.path:find("/blobs/.", 1, true) then blob_sync = blob_sync or i end
      if e.op == "write.before" and e.path and e.path:match("%.uj$") then journal_write = journal_write or i end
      if journal_write and i > journal_write and e.op == "fsync.after"
          and e.path and e.path:match("%.uj$") then journal_sync = journal_sync or i end
      if journal_sync and i > journal_sync and e.op == "fsync.after"
          and e.path and e.path:match("/journals$") then directory_sync = directory_sync or i end
    end
    T.ok(blob_sync and journal_write and journal_sync and directory_sync,
      "missing durability boundary in trace")
    T.ok(blob_sync < journal_write and journal_write < journal_sync and journal_sync < directory_sync,
      "commit order was not blob -> journal -> directory")
    T.rm(dir)
  end },

  { "crash injection at every observed write, sync and rename boundary recovers a prefix", function()
    local payload = transaction("boundary-" .. ("x"):rep(700))
    local probe = T.tmpdir("fault-probe")
    local probe_store = storage.open(probe)
    local events = {}
    with_hook(function(op, detail)
      if op:find("write", 1, true) or op:find("fsync", 1, true) or op:find("rename", 1, true) then
        events[#events + 1] = { op = op, path = detail.path, from = detail.from, to = detail.to }
      end
    end, function()
      probe_store:append(payload)
      probe_store:rebuild_indexes()
    end)
    probe_store:close()
    T.rm(probe)
    T.ok(#events > 20, "fault harness did not observe all storage layers")

    for target = 1, #events do
      local dir = T.tmpdir("fault-each")
      local store = storage.open(dir)
      local seen = 0
      posix.set_fault_hook(function(op)
        if op:find("write", 1, true) or op:find("fsync", 1, true) or op:find("rename", 1, true) then
          seen = seen + 1
          if seen == target then return "crash" end
        end
      end)
      pcall(function()
        store:append(payload)
        store:rebuild_indexes()
      end)
      posix.set_fault_hook(nil)
      store:close()
      local reopened = storage.open(dir)
      local records = reopened:records()
      T.ok(#records == 0 or #records == 1, "non-prefix recovery at boundary " .. target)
      if #records == 1 then T.eq(records[1].payload, payload, "committed record at boundary " .. target) end
      reopened:close()
      T.rm(dir)
    end
  end },

  { "checkpoint crash injection at every boundary falls back to journal replay", function()
    local function open_sup(dir)
      return supervisor.open(dir, {
        core = T.core(), provider = mock.new { cap = 512 }, checkpoint_interval = 0,
      })
    end
    local probe = T.tmpdir("fault-cp-probe")
    local probe_sup = open_sup(probe)
    probe_sup:submit(T.msg(0, "user", "checkpoint boundary"))
    local events = {}
    with_hook(function(op)
      if op:find("write", 1, true) or op:find("fsync", 1, true) or op:find("rename", 1, true) then
        events[#events + 1] = op
      end
    end, function() probe_sup:checkpoint() end)
    probe_sup:close()
    T.rm(probe)
    T.ok(#events >= 8)

    for target = 1, #events do
      local dir = T.tmpdir("fault-cp")
      local sup = open_sup(dir)
      sup:submit(T.msg(0, "user", "checkpoint boundary"))
      local expected = sup:state_hash()
      local seen = 0
      posix.set_fault_hook(function(op)
        if op:find("write", 1, true) or op:find("fsync", 1, true) or op:find("rename", 1, true) then
          seen = seen + 1
          if seen == target then return "crash" end
        end
      end)
      pcall(sup.checkpoint, sup)
      posix.set_fault_hook(nil)
      sup:close()
      local again = open_sup(dir)
      T.eq(again:state_hash(), expected, "checkpoint boundary " .. target)
      again:close()
      T.rm(dir)
    end
  end },

  { "torn journal write is isolated and never becomes a committed record", function()
    local dir = T.tmpdir("fault-torn")
    local store = storage.open(dir)
    local wrote = false
    posix.set_fault_hook(function(op, detail)
      if detail.path and detail.path:match("%.uj$") then
        if op == "write.before" and not wrote then wrote = true; return { short = 7 } end
        if op == "write.after" and wrote then return { error = "EIO torn write" } end
      end
    end)
    T.raises(function() store:append(transaction("torn")) end, "EIO torn write")
    posix.set_fault_hook(nil)
    store:close()
    local reopened, info = storage.open(dir)
    T.eq(#reopened:records(), 0)
    T.ok(info.tail_isolated)
    reopened:close()
    T.rm(dir)
  end },

  { "full disk during blob or journal commit refuses without in-memory mutation", function()
    local dir = T.tmpdir("fault-full")
    local store = storage.open(dir)
    posix.set_fault_hook(function(op, detail)
      if op == "write.before" and detail.path and detail.path:find("/blobs/", 1, true) then
        return { error = "ENOSPC full disk" }
      end
    end)
    T.raises(function() store:append(transaction("full disk")) end, "ENOSPC")
    posix.set_fault_hook(nil)
    T.eq(#store:records(), 0)
    posix.set_fault_hook(function(op, detail)
      if op == "write.before" and detail.path and detail.path:match("%.uj$") then
        return { error = "ENOSPC full disk" }
      end
    end)
    T.raises(function() store:append(transaction("journal full disk")) end, "ENOSPC")
    posix.set_fault_hook(nil)
    T.eq(#store:records(), 0)
    store:close()
    local reopened = storage.open(dir)
    T.eq(#reopened:records(), 0)
    reopened:close()
    T.rm(dir)
  end },
}
