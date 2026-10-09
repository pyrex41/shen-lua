-- unii/test/lib.lua -- minimal assertion helpers shared by the test files.
local M = {}

function M.eq(a, b, msg)
  if a ~= b then
    error((msg or "values differ") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
  end
end

function M.ok(v, msg)
  if not v then error(msg or "expected truthy", 2) end
  return v
end

-- Assert that f raises and that the message contains `pattern` (plain).
function M.raises(f, pattern, msg)
  local ok, err = pcall(f)
  if ok then error((msg or "expected an error") .. " (none raised)", 2) end
  if type(err) == "table" then err = require("lua_interop").error_message(err) end
  err = tostring(err)
  if pattern and not err:find(pattern, 1, true) then
    error((msg or "wrong error") .. ": wanted '" .. pattern .. "' in: " .. err, 2)
  end
  return err
end

function M.tmpdir(tag)
  local p = io.popen("mktemp -d /tmp/unii-" .. (tag or "t") .. ".XXXXXX")
  local d = p:read("*l")
  p:close()
  return d
end

function M.rm(path) os.execute(("rm -rf %q"):format(path)) end

function M.root()
  return debug.getinfo(1, "S").source:sub(2):match("^(.*)/unii/test/lib%.lua$")
end

function M.sh(cmd)
  local p = io.popen("( " .. cmd .. " ) 2>&1; echo \"__EXIT=$?\"")
  local out = p:read("*a")
  p:close()
  local code = tonumber(out:match("__EXIT=(%d+)\n?$"))
  out = out:gsub("__EXIT=%d+\n?$", "")
  return out, code == 0, code
end

-- Shared booted core (one Shen environment per test process).
local core_instance
function M.core()
  if not core_instance then core_instance = require("unii.host.core").boot() end
  return core_instance
end

-- Event builders.
local sha256 = require("unii.host.sha256")
local schema = require("unii.host.schema")
function M.msg(id, kind, text, date)
  return { _ = "message-appended", id = tostring(id), kind = kind or "user",
           date = date or "2026-10-09T00:00:00Z",
           content = { _ = "content", bytes = #text, sha256 = sha256.hex(text), text = text } }
end
function M.done(cmd, text)
  return { _ = "summary-completed", job = cmd.job, attempt = cmd.attempt.n, bytes = #text,
           sha256 = sha256.hex(text), text = text }
end
function M.failed(cmd, class)
  return { _ = "summary-failed", job = cmd.job, attempt = cmd.attempt.n, class = class }
end
function M.tag(ev) return schema.encode("event", ev) end

-- Drive a Core directly (no journal): returns a small harness object.
function M.engine(cfg)
  local C = M.core()
  local e = { C = C, state = C:init(schema.config(cfg or {})), pending = {}, log = {} }
  function e:apply(ev)
    local st, out = C:transition(self.state, M.tag(ev))
    self.state = st
    for _, c in ipairs(out.commands) do
      if c._ == "submit-summary" then self.pending[#self.pending + 1] = c end
    end
    self.log[#self.log + 1] = out
    return out
  end
  function e:status() return C:status(self.state) end
  function e:invariants() return C:invariant_errors(self.state) end
  function e:take(i) return table.remove(self.pending, i or 1) end
  return e
end

function M.decision_names(out)
  local t = {}
  for _, d in ipairs(out.decisions) do t[#t + 1] = d._ end
  return table.concat(t, ",")
end

function M.has_decision(out, name)
  for _, d in ipairs(out.decisions) do if d._ == name then return d end end
  return nil
end

return M
