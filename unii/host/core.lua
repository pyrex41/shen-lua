-- unii/host/core.lua -- boot the pinned Shen runtime, load the typed rule
-- bundle once, and call it with data. Never evaluates user, model or
-- summary text as Shen: events cross as tagged values via host/codec.lua.
local codec = require("unii.host.codec")
local schema = require("unii.host.schema")
local sha256 = require("unii.host.sha256")
local manifest = require("unii.manifest")

local M = {}

local function read_file(path)
  local f, err = io.open(path, "rb")
  if not f then error(err, 2) end
  local s = f:read("*a")
  f:close()
  return s
end
M.read_file = read_file

function M.unii_dir()
  local info = debug.getinfo(1, "S").source:sub(2)
  local dir = info:match("^(.*)/host/core%.lua$")
  if not dir then error("core.lua: cannot locate unii/ from " .. info) end
  return dir
end

-- Bundle hash: format version plus every core file, in load order.
function M.bundle_hash(dir)
  dir = dir or M.unii_dir()
  local parts = { "unii-bundle/" .. manifest.bundle_format .. "\n" }
  for _, name in ipairs(manifest.core_files) do
    local src = read_file(dir .. "/core/" .. name)
    parts[#parts + 1] = name .. "\n" .. #src .. "\n" .. src
  end
  return sha256.hex(table.concat(parts))
end

function M.stamp_path(dir)
  return (dir or M.unii_dir()) .. "/build/bundle.stamp"
end

function M.read_stamp(dir)
  local f = io.open(M.stamp_path(dir), "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s:match("bundle (%x+)")
end

local shen, F, iop

local function boot_shen()
  if shen then return end
  shen = require("shen")
  shen.boot { quiet = true, hush_load = true }
  iop = require("lua_interop")
  F = shen.prims.F
  codec.bind(shen)
end

function M.shen() boot_shen(); return shen end

function M.error_message(e)
  if iop then return iop.error_message(e) end
  return tostring(e)
end

-- Load the bundle with the typechecker on. Errors carry the file and the
-- kernel's message.
function M.load_bundle(dir, opts)
  boot_shen()
  dir = dir or M.unii_dir()
  shen.eval("(tc +)")
  for _, name in ipairs(manifest.core_files) do
    local ok, err = pcall(F["load"], dir .. "/core/" .. name)
    if not ok then
      shen.eval("(tc -)")
      error("rule bundle: " .. name .. ": " .. M.error_message(err), 0)
    end
  end
  shen.eval("(tc -)")
end

local Core = {}
Core.__index = Core

-- Boot: reject a rule bundle that does not match the last typechecked
-- build, then load it once and resolve the functions the host calls.
function M.boot(opts)
  opts = opts or {}
  local dir = M.unii_dir()
  local hash = M.bundle_hash(dir)
  local stamp = M.read_stamp(dir)
  if stamp ~= hash then
    error(("rule bundle %s has not passed the typechecked build (stamp: %s); run `unii/bin/unii build`")
      :format(hash:sub(1, 16), stamp and stamp:sub(1, 16) or "missing"), 0)
  end
  M.load_bundle(dir)
  local self = setmetatable({ bundle_hash = hash, shen = shen }, Core)
  local function fn(name)
    local f = F[name]
    if not f then error("rule bundle does not define " .. name, 0) end
    return function(...) return shen.prims.APP(f, ...) end
  end
  self.f = {
    init = fn("unii.init"), transition = fn("unii.transition"),
    config_errors = fn("unii.config-errors"), view_lines = fn("unii.view-lines"),
    status = fn("unii.status"), invariant_errors = fn("unii.invariant-errors"),
    view_ready = fn("unii.view-ready?"), merge_to_count = fn("unii.merge-keys-to-count"),
  }
  return self
end

local function call(self, name, ...)
  local ok, res = pcall(self.f[name], ...)
  if not ok then error("core " .. name .. " failed: " .. M.error_message(res), 0) end
  return res
end

local function totable(l)
  return shen.totable(l)
end

-- Config: Lua record -> Shen; returns state or raises with the core's
-- validation messages.
function Core:init(config)
  local cfg = codec.to_shen(schema.encode("config", config))
  local errs = totable(call(self, "config_errors", cfg))
  if #errs > 0 then error("invalid configuration: " .. table.concat(errs, "; "), 0) end
  return call(self, "init", cfg)
end

-- One pure transition. Returns the new state and the tagged + decoded
-- commands and decisions.
function Core:transition(state, event_tagged)
  local res = call(self, "transition", state, codec.to_shen(event_tagged))
  -- res = [result State Commands Decisions]
  local parts = totable(res)
  local cmds_t = codec.from_shen(parts[3])
  local decs_t = codec.from_shen(parts[4])
  local cmds, decs = {}, {}
  for i, c in ipairs(cmds_t.v) do cmds[i] = schema.decode("command", c) end
  for i, d in ipairs(decs_t.v) do decs[i] = schema.decode("decision", d) end
  return parts[2], { commands = cmds, decisions = decs, commands_tagged = cmds_t, decisions_tagged = decs_t }
end

-- Canonical view bytes, cross-checked against the core's byte accounting.
function Core:render(state)
  local lines = totable(call(self, "view_lines", state))
  local text = table.concat(lines)
  local st = self:status(state)
  if #text ~= st.view_bytes then
    error(("view byte accounting mismatch: rendered %d, core says %d"):format(#text, st.view_bytes), 0)
  end
  return text, #lines - 2
end

function Core:status(state)
  local s = totable(call(self, "status", state))
  return {
    count = s[1], covered = s[2], view_bytes = s[3], view_lines = s[4], rev = s[5],
    batch = s[6] == 1, queued = s[7], dispatched = s[8], blocked = s[9],
  }
end

function Core:ready(state) return call(self, "view_ready", state) end

function Core:invariant_errors(state)
  return totable(call(self, "invariant_errors", state))
end

-- Canonical bytes of the whole state (storage encoding of its tagged form).
function Core:state_bytes(state)
  return codec.encode(codec.from_shen(state))
end

function Core:state_hash(state)
  return sha256.hex(self:state_bytes(state))
end

-- Line-count policy over plain key lists (oracle comparisons): keys are
-- {level, index} pairs; returns the new key list and merged parents.
function Core:merge_to_count(keys, total, budget)
  local items = {}
  for i, k in ipairs(keys) do
    items[i] = codec.list({ codec.sym("key"), codec.int_of(k[1]), codec.int_of(k[2]) })
  end
  local res = call(self, "merge_to_count", codec.to_shen(codec.list(items)), total, budget)
  local view = codec.from_shen(F["fst"](res))
  local merged = codec.from_shen(F["snd"](res))
  local function back(l)
    local out = {}
    for i, k in ipairs(l.v) do out[i] = { codec.to_number(k.v[2]), codec.to_number(k.v[3]) } end
    return out
  end
  return back(view), back(merged)
end

return M
