-- Rebuildable projections. These files are never authoritative: startup
-- validates the journal and blobs first, then replaces all indexes.
local posix = require("unii.host.posix")

local M = {}

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
  return out
end

function M.write(root, idx)
  local dir = root .. "/indexes"
  assert(posix.mkdir_p(dir))
  assert(posix.fsync_dir(root))

  local journal = { "UIX1\n" }
  for _, r in ipairs(idx.records) do
    journal[#journal + 1] = ("%d\t%s\t%d\t%d\n"):format(r.seq, r.day, r.offset, r.length)
  end
  assert(posix.write_file_atomic(dir, "journal.idx", table.concat(journal)))

  local messages = { "UMX1\n" }
  for _, id in ipairs(sorted_keys(idx.messages)) do
    local m = idx.messages[id]
    messages[#messages + 1] = ("%s\t%d\t%s\t%d\t%s\t%s\n")
      :format(id, m.seq, m.hash, m.bytes, m.kind, m.date)
  end
  assert(posix.write_file_atomic(dir, "messages.idx", table.concat(messages)))

  local blobs = { "UBX1\n" }
  for _, hash in ipairs(sorted_keys(idx.blobs)) do
    local b = idx.blobs[hash]
    blobs[#blobs + 1] = ("%s\t%d\t%s\n"):format(hash, b.bytes, table.concat(b.seqs, ","))
  end
  assert(posix.write_file_atomic(dir, "blobs.idx", table.concat(blobs)))

  local nodes = { "UNX1\n" }
  for _, key in ipairs(sorted_keys(idx.nodes)) do
    nodes[#nodes + 1] = ("%s\t%d\n"):format(key, idx.nodes[key])
  end
  assert(posix.write_file_atomic(dir, "nodes.idx", table.concat(nodes)))

  local jobs = { "UJX1\n" }
  for _, job in ipairs(sorted_keys(idx.jobs)) do
    local j = idx.jobs[job]
    jobs[#jobs + 1] = ("%s\t%s\t%d\n"):format(job, j.status, j.seq)
  end
  assert(posix.write_file_atomic(dir, "jobs.idx", table.concat(jobs)))
end

return M
