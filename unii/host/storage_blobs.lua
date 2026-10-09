-- Content-addressed immutable blobs. A blob is durable before its hash can
-- appear in a journal frame: temp write, file sync, rename, directory sync.
local posix = require("unii.host.posix")
local sha256 = require("unii.host.sha256")

local M = {}

local function assert_ok(ok, err)
  if not ok then error("blob storage: " .. tostring(err), 0) end
end

function M.new(root)
  local dir = root .. "/blobs"
  assert_ok(posix.mkdir_p(dir))
  assert_ok(posix.fsync_dir(root))
  return setmetatable({ root = root, dir = dir }, { __index = M })
end

function M:path(hash)
  return self.dir .. "/" .. hash
end

function M:put(bytes, expected)
  local hash = sha256.hex(bytes)
  if expected and hash ~= expected then error("blob hash does not match journal reference", 0) end
  local path = self:path(hash)
  local old = posix.read_file(path)
  if old then
    if #old ~= #bytes or sha256.hex(old) ~= hash then
      error("corrupted existing blob " .. hash .. "; refusing to overwrite", 0)
    end
    return hash
  end
  assert_ok(posix.write_file_atomic(self.dir, hash, bytes))
  return hash
end

function M:get(hash, expected_size)
  local path = self:path(hash)
  local bytes = posix.read_file(path)
  if not bytes then error("missing committed blob " .. hash .. " (repair required)", 0) end
  if expected_size and #bytes ~= expected_size then
    error(("corrupted blob %s: size %d, expected %d (repair required)")
      :format(hash, #bytes, expected_size), 0)
  end
  if sha256.hex(bytes) ~= hash then
    error("corrupted blob " .. hash .. ": checksum mismatch (repair required)", 0)
  end
  return bytes
end

function M:verify(hash, expected_size)
  self:get(hash, expected_size)
  return true
end

return M
