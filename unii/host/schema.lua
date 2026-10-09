-- unii/host/schema.lua -- record schemas mirroring unii/core/types.shen.
--
-- A record is a Shen list headed by its constructor symbol with positional
-- fields. On the Lua side it is a table {_ = "name", field = value, ...}:
--   nat     Lua number in [0, 2^31-1], or canonical decimal text (preferred
--           for anything that arrived from outside the process)
--   text    valid UTF-8 string        sym/enum  string naming a symbol
--   hex64   64 lowercase hex digits   bool      boolean
--   list(T) array                     opt(T)    nil = absent, else a value
--   one(names...)  a nested record whose constructor is one of `names`
-- opt(T) encodes as [none] or [some X] so absent stays distinct from (),
-- false and "" in Shen.
local codec = require("unii.host.codec")
local sha256 = require("unii.host.sha256")

local M = {}
M.MAX_ID = 2147483647

local function nat()          return { k = "nat" } end
local function text()         return { k = "text" } end
local function hex64()        return { k = "hex64" } end
local function sym()          return { k = "sym" } end
local function bool()         return { k = "bool" } end
local function enum(set)      return { k = "enum", set = set } end
local function list(t)        return { k = "list", of = t } end
local function opt(t)         return { k = "opt", of = t } end
local function one(...)       return { k = "one", names = { ... } } end
M.T = { nat = nat, text = text, hex64 = hex64, sym = sym, bool = bool,
        enum = enum, list = list, opt = opt, one = one }

local KINDS = { user = true, assistant = true, ["tool-call"] = true,
                ["tool-result"] = true, report = true, ["imported-note"] = true }
local CLASSES = { retryable = true, permanent = true }
M.KINDS, M.CLASSES = KINDS, CLASSES

-- name -> ordered list of {field, type}
local R = {}
M.records = R

local function rec(name, fields) R[name] = fields end

rec("key", { { "level", nat() }, { "index", nat() } })
rec("view-budget", { { "low", nat() }, { "high", nat() } })
rec("queue-limits", { { "max_inflight", nat() }, { "lead_window", nat() }, { "max_attempts", nat() },
                      { "max_frontier", nat() }, { "chunk_max", nat() } })
rec("config", { { "epoch", nat() }, { "leaf_cap", nat() }, { "budget", one("view-budget") },
                { "limits", one("queue-limits") } })
rec("content", { { "bytes", nat() }, { "sha256", hex64() }, { "text", text() } })
rec("message-appended", { { "id", nat() }, { "kind", enum(KINDS) }, { "date", text() },
                          { "content", one("content") } })
rec("summary-completed", { { "job", text() }, { "attempt", nat() }, { "bytes", nat() },
                           { "sha256", hex64() }, { "text", text() } })
rec("summary-failed", { { "job", text() }, { "attempt", nat() }, { "class", enum(CLASSES) } })
rec("exact-leaf", {})
rec("joined", {})
rec("summarized", { { "job", text() }, { "attempt", nat() } })
rec("first-attempt", {})
rec("retry-too-long", { { "bytes", nat() } })
rec("retry-after-failure", { { "class", sym() } })
rec("attempt", { { "n", nat() }, { "retry", one("first-attempt", "retry-too-long", "retry-after-failure") } })
rec("leaf-input", { { "message", nat() }, { "kind", enum(KINDS) }, { "sha256", hex64() } })
rec("merge-input", { { "left", one("key") }, { "left_text", text() },
                     { "right", one("key") }, { "right_text", text() } })
rec("view-changed", { { "rev", nat() }, { "bytes", nat() }, { "lines", nat() } })
rec("memory-blocked", { { "job", text() }, { "reason", text() } })
rec("input-rejected", { { "reason", text() } })
rec("submit-summary", { { "cmd", text() }, { "job", text() }, { "key", one("key") },
                        { "attempt", one("attempt") }, { "input", one("leaf-input", "merge-input") } })
rec("emit-client-event", { { "cmd", text() },
                           { "event", one("view-changed", "memory-blocked", "input-rejected") } })
rec("node-committed", { { "key", one("key") }, { "origin", one("exact-leaf", "joined", "summarized") },
                        { "bytes", nat() } })
rec("view-extended", { { "key", one("key") } })
rec("view-merged", { { "key", one("key") } })
rec("batch-mode", { { "on", bool() } })
rec("view-revision", { { "rev", nat() } })
rec("job-created", { { "job", text() } })
rec("job-retried", { { "job", text() }, { "previous", text() } })
rec("job-blocked", { { "job", text() }, { "reason", text() } })
rec("event-rejected", { { "reason", text() } })
rec("completion-ignored", { { "job", text() }, { "reason", text() } })

M.unions = {
  event = { "message-appended", "summary-completed", "summary-failed" },
  command = { "submit-summary", "emit-client-event" },
  decision = { "node-committed", "view-extended", "view-merged", "batch-mode", "view-revision",
               "job-created", "job-retried", "job-blocked", "event-rejected", "completion-ignored" },
}

-- ---------------------------------------------------------------- encode

local function fail(path, msg) error("schema " .. path .. ": " .. msg, 0) end

local encode_record

local function encode_value(ty, x, path)
  local k = ty.k
  if k == "opt" then
    if x == nil then return codec.list({ codec.sym("none") }) end
    return codec.list({ codec.sym("some"), encode_value(ty.of, x, path) })
  end
  if x == nil then fail(path, "missing required field") end
  if k == "nat" then
    local v
    if type(x) == "string" then
      local ok, r = pcall(codec.int, x)
      if not ok then fail(path, r) end
      v = r
    elseif type(x) == "number" then
      local ok, r = pcall(codec.int_of, x)
      if not ok then fail(path, r) end
      v = r
    else
      fail(path, "expected a natural number")
    end
    local n = codec.to_number(v)
    if n < 0 or n > M.MAX_ID then fail(path, "natural outside [0, 2147483647]: " .. v.v) end
    return v
  elseif k == "text" then
    if type(x) ~= "string" then fail(path, "expected text") end
    local ok, r = pcall(codec.text, x)
    if not ok then fail(path, r) end
    return r
  elseif k == "hex64" then
    if type(x) ~= "string" or not x:match("^" .. ("[0-9a-f]"):rep(64) .. "$") then
      fail(path, "expected 64 lowercase hex digits")
    end
    return codec.text(x)
  elseif k == "sym" then
    local ok, r = pcall(codec.sym, x)
    if not ok then fail(path, r) end
    return r
  elseif k == "enum" then
    if not ty.set[x] then fail(path, "unexpected symbol " .. tostring(x)) end
    return codec.sym(x)
  elseif k == "bool" then
    if type(x) ~= "boolean" then fail(path, "expected boolean") end
    return codec.bool(x)
  elseif k == "list" then
    if type(x) ~= "table" then fail(path, "expected an array") end
    local out = {}
    for i = 1, #x do out[i] = encode_value(ty.of, x[i], path .. "[" .. i .. "]") end
    return codec.list(out)
  elseif k == "one" then
    if type(x) ~= "table" then fail(path, "expected a record") end
    local okname = false
    for _, n in ipairs(ty.names) do if x._ == n then okname = true end end
    if not okname then fail(path, "record " .. tostring(x._) .. " not allowed here") end
    return encode_record(x, path)
  end
  fail(path, "unknown schema type " .. tostring(k))
end

encode_record = function(x, path)
  local fields = R[x._]
  if not fields then fail(path, "unknown record " .. tostring(x._)) end
  local out = { codec.sym(x._) }
  for i, f in ipairs(fields) do
    out[i + 1] = encode_value(f[2], x[f[1]], path .. "." .. f[1])
  end
  for k in pairs(x) do
    if k ~= "_" then
      local known = false
      for _, f in ipairs(fields) do if f[1] == k then known = true end end
      if not known then fail(path, "unexpected field " .. tostring(k)) end
    end
  end
  -- The core counts bytes from the declared length and cannot hash, so the
  -- boundary binds both declarations to the text they describe.
  if x._ == "content" or x._ == "summary-completed" then
    if tonumber(x.bytes) ~= #x.text then fail(path .. ".bytes", "does not equal the text's byte length") end
    if x.sha256 ~= sha256.hex(x.text) then fail(path .. ".sha256", "does not match the text") end
  end
  return codec.list(out)
end

-- Encode a Lua record into a tagged value, checking it against `union`
-- (a key of M.unions or a record name).
function M.encode(union, x)
  local names = M.unions[union] or { union }
  return encode_value({ k = "one", names = names }, x, union)
end

-- ---------------------------------------------------------------- decode

local decode_record

local function decode_value(ty, v, path)
  local k = ty.k
  if k == "opt" then
    if v.t ~= "list" or #v.v == 0 or v.v[1].t ~= "sym" then fail(path, "expected [none] or [some X]") end
    if v.v[1].v == "none" and #v.v == 1 then return nil end
    if v.v[1].v == "some" and #v.v == 2 then return decode_value(ty.of, v.v[2], path) end
    fail(path, "expected [none] or [some X]")
  elseif k == "nat" then
    if v.t ~= "int" then fail(path, "expected int") end
    local n = codec.to_number(v)
    if n < 0 or n > M.MAX_ID then fail(path, "natural outside [0, 2147483647]") end
    return n
  elseif k == "text" or k == "hex64" then
    if v.t ~= "text" then fail(path, "expected text") end
    if k == "hex64" and not v.v:match("^" .. ("[0-9a-f]"):rep(64) .. "$") then fail(path, "expected hex64") end
    return v.v
  elseif k == "sym" or k == "enum" then
    if v.t ~= "sym" then fail(path, "expected symbol") end
    if k == "enum" and not ty.set[v.v] then fail(path, "unexpected symbol " .. v.v) end
    return v.v
  elseif k == "bool" then
    if v.t ~= "bool" then fail(path, "expected boolean") end
    return v.v
  elseif k == "list" then
    if v.t ~= "list" then fail(path, "expected list") end
    local out = {}
    for i = 1, #v.v do out[i] = decode_value(ty.of, v.v[i], path .. "[" .. i .. "]") end
    return out
  elseif k == "one" then
    if v.t ~= "list" or #v.v == 0 or v.v[1].t ~= "sym" then fail(path, "expected a record") end
    local name = v.v[1].v
    local okname = false
    for _, n in ipairs(ty.names) do if n == name then okname = true end end
    if not okname then fail(path, "record " .. name .. " not allowed here") end
    return decode_record(v, path)
  end
  fail(path, "unknown schema type " .. tostring(k))
end

decode_record = function(v, path)
  local name = v.v[1].v
  local fields = R[name]
  if not fields then fail(path, "unknown record " .. name) end
  if #v.v ~= #fields + 1 then fail(path, name .. ": expected " .. #fields .. " fields, got " .. (#v.v - 1)) end
  local out = { _ = name }
  for i, f in ipairs(fields) do out[f[1]] = decode_value(f[2], v.v[i + 1], path .. "." .. f[1]) end
  return out
end

function M.decode(union, v)
  local names = M.unions[union] or { union }
  return decode_value({ k = "one", names = names }, v, union)
end

-- Register an extra record (tests use this to exercise optional fields).
function M.define(name, fields) R[name] = fields end

-- --------------------------------------------------------------- helpers

function M.config(t)
  t = t or {}
  local function g(k, d) local v = t[k]; if v == nil then return d end; return v end
  return {
    _ = "config", epoch = g("epoch", 1), leaf_cap = g("leaf_cap", 512),
    budget = { _ = "view-budget", low = g("low", 64000), high = g("high", 128000) },
    limits = { _ = "queue-limits", max_inflight = g("max_inflight", 8), lead_window = g("lead_window", 8),
               max_attempts = g("max_attempts", 5), max_frontier = g("max_frontier", 4096),
               chunk_max = g("chunk_max", 16384) },
  }
end

function M.key_address(k)
  local count = 2 ^ k.level
  return string.format("%.0f+%.0f", k.index * count, count)
end

return M
