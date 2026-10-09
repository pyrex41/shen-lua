-- unii/host/posix.lua -- the only module that touches POSIX file APIs.
-- All durability boundaries pass through the fault hook below. Tests use it
-- to emulate process death, short/torn writes and ENOSPC without weakening
-- production error handling.
local ffi = require("ffi")

ffi.cdef [[
  int open(const char *path, int flags, ...);
  int close(int fd);
  long write(int fd, const void *buf, unsigned long n);
  long read(int fd, void *buf, unsigned long n);
  int fsync(int fd);
  int flock(int fd, int op);
  int ftruncate(int fd, long length);
  int rename(const char *from, const char *to);
  int mkdir(const char *path, unsigned int mode);
  long lseek(int fd, long offset, int whence);
  int fcntl(int fd, int cmd, ...);
  char *strerror(int errnum);
]]

local C = ffi.C
local M = {}

local FLAGS = {
  ["Linux/x64"]   = { WRONLY = 1, RDWR = 2, CREAT = 0x40, APPEND = 0x400, DIRECTORY = 0x10000, CLOEXEC = 0x80000 },
  ["Linux/arm64"] = { WRONLY = 1, RDWR = 2, CREAT = 0x40, APPEND = 0x400, DIRECTORY = 0x4000, CLOEXEC = 0x80000 },
  ["OSX/x64"]     = { WRONLY = 1, RDWR = 2, CREAT = 0x200, APPEND = 0x8, DIRECTORY = 0x100000, CLOEXEC = 0x1000000 },
  ["OSX/arm64"]   = { WRONLY = 1, RDWR = 2, CREAT = 0x200, APPEND = 0x8, DIRECTORY = 0x100000, CLOEXEC = 0x1000000 },
}
local O = FLAGS[jit.os .. "/" .. jit.arch]
if not O then error("posix.lua: unsupported platform " .. jit.os .. "/" .. jit.arch) end
M.platform = jit.os .. "/" .. jit.arch
M.verified_platform = (M.platform == "Linux/x64")

local LOCK_EX, LOCK_NB, LOCK_UN = 2, 4, 8
local EINTR, EWOULDBLOCK = 4, (jit.os == "OSX") and 35 or 11
local F_FULLFSYNC = 51
local fault_hook
local fd_paths = {}

function M.set_fault_hook(fn)
  local old = fault_hook
  fault_hook = fn
  return old
end

local function hit(op, detail)
  if not fault_hook then return nil end
  return fault_hook(op, detail or {})
end

local function injected(action, op)
  if action == "crash" then error("injected crash at " .. op, 0) end
  if type(action) == "table" and action.error then
    return nil, action.error .. " (injected at " .. op .. ")"
  end
  return true
end

local function errstr(what, path)
  local e = ffi.errno()
  return ("%s(%s): %s (errno %d)"):format(what, tostring(path), ffi.string(C.strerror(e)), e), e
end

function M.open(path, mode)
  local flags
  if mode == "append" then flags = O.WRONLY + O.CREAT + O.APPEND + O.CLOEXEC
  elseif mode == "rw" then flags = O.RDWR + O.CREAT + O.CLOEXEC
  elseif mode == "write" then flags = O.WRONLY + O.CREAT + O.CLOEXEC
  elseif mode == "dir" then flags = O.DIRECTORY + O.CLOEXEC
  else error("posix.open: unknown mode " .. tostring(mode)) end
  local fd = C.open(path, flags, ffi.new("int", 420)) -- 0644
  if fd < 0 then return nil, errstr("open", path) end
  fd_paths[tonumber(fd)] = path
  return fd
end

function M.close(fd)
  if C.close(fd) ~= 0 then return nil, errstr("close", fd) end
  fd_paths[tonumber(fd)] = nil
  return true
end

-- Write every byte, retrying short writes and EINTR.
function M.write_all(fd, s)
  local buf = ffi.cast("const char *", s)
  local off, n = 0, #s
  while off < n do
    local op = "write"
    local action = hit(op .. ".before", { fd = fd, path = fd_paths[tonumber(fd)], offset = off, bytes = n - off })
    local ok, err = injected(action, op .. ".before")
    if not ok then return nil, err end
    local want = n - off
    if type(action) == "table" and action.short then want = math.min(want, action.short) end
    local w = tonumber(C.write(fd, buf + off, want))
    if w < 0 then
      if ffi.errno() ~= EINTR then return nil, errstr("write", fd) end
    else
      off = off + w
      action = hit(op .. ".after", { fd = fd, path = fd_paths[tonumber(fd)], offset = off, bytes = w })
      ok, err = injected(action, op .. ".after")
      if not ok then return nil, err end
    end
  end
  return true
end

function M.fsync(fd)
  local action = hit("fsync.before", { fd = fd, path = fd_paths[tonumber(fd)] })
  local ok, err = injected(action, "fsync.before")
  if not ok then return nil, err end
  if C.fsync(fd) ~= 0 then return nil, errstr("fsync", fd) end
  action = hit("fsync.after", { fd = fd, path = fd_paths[tonumber(fd)] })
  ok, err = injected(action, "fsync.after")
  if not ok then return nil, err end
  return true
end

-- macOS fsync does not request a drive-cache flush. F_FULLFSYNC does. It is
-- used for regular files when available; directory descriptors still use
-- fsync because F_FULLFSYNC is not defined for them.
function M.sync_file(fd)
  if jit.os ~= "OSX" then return M.fsync(fd) end
  local action = hit("fullfsync.before", { fd = fd, path = fd_paths[tonumber(fd)] })
  local ok, err = injected(action, "fullfsync.before")
  if not ok then return nil, err end
  if C.fcntl(fd, F_FULLFSYNC) ~= 0 then return nil, errstr("fcntl(F_FULLFSYNC)", fd) end
  action = hit("fullfsync.after", { fd = fd, path = fd_paths[tonumber(fd)] })
  ok, err = injected(action, "fullfsync.after")
  if not ok then return nil, err end
  return true
end

function M.fsync_dir(path)
  local fd, err = M.open(path, "dir")
  if not fd then return nil, err end
  local ok, e2 = M.fsync(fd)
  M.close(fd)
  return ok, e2
end

-- Non-blocking exclusive advisory lock held for the life of the fd.
function M.try_lock(fd)
  if C.flock(fd, LOCK_EX + LOCK_NB) ~= 0 then
    local msg, e = errstr("flock", fd)
    return nil, msg, e == EWOULDBLOCK
  end
  return true
end

function M.unlock(fd) return C.flock(fd, LOCK_UN) == 0 end

function M.ftruncate(fd, len)
  local action = hit("truncate.before", { fd = fd, length = len })
  local ok, err = injected(action, "truncate.before")
  if not ok then return nil, err end
  if C.ftruncate(fd, len) ~= 0 then return nil, errstr("ftruncate", fd) end
  action = hit("truncate.after", { fd = fd, length = len })
  ok, err = injected(action, "truncate.after")
  if not ok then return nil, err end
  return true
end

function M.rename(from, to)
  local action = hit("rename.before", { from = from, to = to })
  local ok, err = injected(action, "rename.before")
  if not ok then return nil, err end
  if C.rename(from, to) ~= 0 then return nil, errstr("rename", from) end
  action = hit("rename.after", { from = from, to = to })
  ok, err = injected(action, "rename.after")
  if not ok then return nil, err end
  return true
end

function M.mkdir_p(path)
  local acc = path:sub(1, 1) == "/" and "" or "."
  for part in path:gmatch("[^/]+") do
    acc = acc .. "/" .. part
    if C.mkdir(acc, 493) ~= 0 and ffi.errno() ~= 17 then -- 0755, EEXIST
      return nil, errstr("mkdir", acc)
    end
  end
  return true
end

function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

function M.file_size(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local n = f:seek("end")
  f:close()
  return n
end

function M.read_range(path, offset, len)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local ok = f:seek("set", offset)
  if not ok then f:close(); return nil, "seek failed for " .. path end
  local s = f:read(len)
  f:close()
  if not s or #s ~= len then return nil, "short read from " .. path end
  return s
end

-- Write a whole file durably: temp file, write-all, fsync, rename, fsync dir.
function M.write_file_atomic(dir, name, bytes)
  local tmp = dir .. "/." .. name .. ".tmp"
  local fd, err = M.open(tmp, "write")
  if not fd then return nil, err end
  local ok, e = M.ftruncate(fd, 0)
  if ok then ok, e = M.write_all(fd, bytes) end
  if ok then ok, e = M.sync_file(fd) end
  M.close(fd)
  if not ok then return nil, e end
  ok, e = M.rename(tmp, dir .. "/" .. name)
  if not ok then return nil, e end
  return M.fsync_dir(dir)
end

return M
