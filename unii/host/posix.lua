-- unii/host/posix.lua -- the only module that touches POSIX file APIs.
-- LuaJIT FFI bindings for open/write/fsync/flock/ftruncate/rename and a
-- directory fsync. Flag values are per platform; only Linux x86_64 has been
-- exercised by the tests (see docs/contracts/storage.md for guarantees).
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
  return fd
end

function M.close(fd)
  if C.close(fd) ~= 0 then return nil, errstr("close", fd) end
  return true
end

-- Write every byte, retrying short writes and EINTR.
function M.write_all(fd, s)
  local buf = ffi.cast("const char *", s)
  local off, n = 0, #s
  while off < n do
    local w = tonumber(C.write(fd, buf + off, n - off))
    if w < 0 then
      if ffi.errno() ~= EINTR then return nil, errstr("write", fd) end
    else
      off = off + w
    end
  end
  return true
end

function M.fsync(fd)
  if C.fsync(fd) ~= 0 then return nil, errstr("fsync", fd) end
  return true
end

function M.fsync_dir(path)
  local fd, err = M.open(path, "dir")
  if not fd then return nil, err end
  local ok, e2 = M.fsync(fd)
  C.close(fd)
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
  if C.ftruncate(fd, len) ~= 0 then return nil, errstr("ftruncate", fd) end
  return true
end

function M.rename(from, to)
  if C.rename(from, to) ~= 0 then return nil, errstr("rename", from) end
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

-- Write a whole file durably: temp file, write-all, fsync, rename, fsync dir.
function M.write_file_atomic(dir, name, bytes)
  local tmp = dir .. "/." .. name .. ".tmp"
  local fd, err = M.open(tmp, "write")
  if not fd then return nil, err end
  local ok, e = M.ftruncate(fd, 0)
  if ok then ok, e = M.write_all(fd, bytes) end
  if ok then ok, e = M.fsync(fd) end
  C.close(fd)
  if not ok then return nil, e end
  ok, e = M.rename(tmp, dir .. "/" .. name)
  if not ok then return nil, e end
  return M.fsync_dir(dir)
end

return M
