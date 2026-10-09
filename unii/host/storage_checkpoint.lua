-- Durable checkpoint files and their small manifest. Checkpoints are
-- accelerators; a bad or stale one is set aside and an older candidate is
-- tried before falling back to full journal replay.
local posix = require("unii.host.posix")
local sha256 = require("unii.host.sha256")

local M = {}
local MAGIC = "UC1 "

local function frame(payload)
  local header = MAGIC .. #payload .. "\n"
  return header .. payload .. "\n" .. sha256.hex(header .. payload) .. "\n"
end

local function parse(bytes)
  local nl = bytes:find("\n", 1, true)
  if not nl then return nil, "missing header" end
  local len = tonumber(bytes:sub(1, nl):match("^UC1 (%d+)\n$"))
  if not len then return nil, "bad header" end
  local payload = bytes:sub(nl + 1, nl + len)
  local sep = bytes:sub(nl + len + 1, nl + len + 1)
  local sum = bytes:sub(nl + len + 2, nl + len + 65)
  local final = bytes:sub(nl + len + 66)
  if #payload ~= len or sep ~= "\n" or #sum ~= 64 or final ~= "\n" then
    return nil, "truncated"
  end
  if sum ~= sha256.hex(bytes:sub(1, nl) .. payload) then return nil, "checksum mismatch" end
  return payload
end

local Checkpoints = {}
Checkpoints.__index = Checkpoints

function M.new(root)
  local dir = root .. "/checkpoints"
  assert(posix.mkdir_p(dir))
  assert(posix.fsync_dir(root))
  return setmetatable({ root = root, dir = dir, manifest = dir .. "/MANIFEST" }, Checkpoints)
end

function Checkpoints:names()
  local bytes = posix.read_file(self.manifest)
  if not bytes then return {} end
  if bytes:sub(1, 5) ~= "UCM1\n" then return {} end
  local out = {}
  for name in bytes:sub(6):gmatch("([^\n]+)\n") do
    if name:match("^checkpoint%-%d+%-%x+%.uc$") then out[#out + 1] = name end
  end
  return out
end

function Checkpoints:write(seq, payload)
  local digest = sha256.hex(payload)
  local name = ("checkpoint-%d-%s.uc"):format(seq, digest:sub(1, 16))
  assert(posix.write_file_atomic(self.dir, name, frame(payload)))
  local names, next_names = self:names(), { name }
  for _, old in ipairs(names) do
    if old ~= name and #next_names < 4 then next_names[#next_names + 1] = old end
  end
  assert(posix.write_file_atomic(self.dir, "MANIFEST", "UCM1\n" .. table.concat(next_names, "\n") .. "\n"))
  return name
end

function Checkpoints:set_aside(name, reason)
  local suffix = sha256.hex(reason):sub(1, 8)
  local ok = posix.rename(self.dir .. "/" .. name, self.dir .. "/" .. name .. ".invalid-" .. suffix)
  if ok then
    assert(posix.fsync_dir(self.dir))
    local kept = {}
    for _, candidate in ipairs(self:names()) do
      if candidate ~= name then kept[#kept + 1] = candidate end
    end
    assert(posix.write_file_atomic(self.dir, "MANIFEST", "UCM1\n" .. table.concat(kept, "\n")
      .. (#kept > 0 and "\n" or "")))
  end
end

function Checkpoints:candidates()
  local out = {}
  for _, name in ipairs(self:names()) do
    local bytes = posix.read_file(self.dir .. "/" .. name)
    if bytes then
      local payload, err = parse(bytes)
      out[#out + 1] = { name = name, payload = payload, error = err }
    else
      out[#out + 1] = { name = name, error = "missing checkpoint file" }
    end
  end
  return out
end

M.frame, M.parse = frame, parse
return M
