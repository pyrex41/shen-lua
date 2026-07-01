-- examples/openresty-authz/store.lua
-- Durable, event-sourced fact store + append-only proof log for the authz demo.
--
-- The log is the source of truth; the in-memory view is a cache rebuilt by
-- replaying the log on open. That IS the "durable execution" property: kill the
-- process, reopen the same log, replay, and you are in the exact same state —
-- facts AND the audit trail. Nothing lives only in RAM.
--
-- Two backends behind one tiny interface (append + iterate):
--   file : append-only JSONL on disk. Durable across process restarts and the
--          path exercised by selftest.lua and CI under plain LuaJIT.
--   lmdb : the same event log in lua-resty-lmdb (the memory-mapped, MVCC,
--          zero-copy KV that Kong ships). Production path under OpenResty.
--
-- LuaJIT perf: reads hit plain hash tables (O(1), trace-friendly); the log
-- append is off the read/authorize path. Under OpenResty the module loads once
-- per worker and every authorize is pure table lookups + one Prolog query.

local M = {}

-- ---- the materialized view (derived state) ---------------------------------
local function new_view()
  return {
    tokens    = {},   -- token -> { user=, admin=bool }
    member    = {},   -- user  -> { tenant -> role }
    owner     = {},   -- res   -> tenant
    content   = {},   -- res   -> string
    revoked   = {},   -- user  -> { res -> true }
    decisions = {},   -- ordered audit trail: { seq,user,action,resource,decision,reason }
  }
end

-- fold one event into the view. Pure; used identically on replay and on append.
local function apply(view, e)
  local t = e.t
  if t == "token" then
    view.tokens[e.token] = { user = e.user, admin = e.admin == true }
  elseif t == "grant" then
    local m = view.member[e.user]; if not m then m = {}; view.member[e.user] = m end
    m[e.tenant] = e.role or "viewer"
  elseif t == "create" then
    view.owner[e.resource]   = e.tenant
    view.content[e.resource] = e.content or ""
  elseif t == "revoke" then
    local r = view.revoked[e.user]; if not r then r = {}; view.revoked[e.user] = r end
    r[e.resource] = true
  elseif t == "decision" then
    view.decisions[#view.decisions + 1] =
      { e.seq, e.user, e.action, e.resource, e.decision, e.reason }
  end
end

-- ---- backends: each(fn) replays stored lines in order; append(line) adds one
local function file_backend(path)
  local be = { path = path }
  function be:each(fn)
    local f = io.open(self.path, "r")
    if not f then return end
    for line in f:lines() do if line ~= "" then fn(line) end end
    f:close()
  end
  function be:append(line)
    local f = self.fh
    if not f then f = assert(io.open(self.path, "a")); self.fh = f end
    f:write(line, "\n"); f:flush()
  end
  return be
end

-- Faithful adapter for lua-resty-lmdb (production, under OpenResty). Kept
-- deliberately small: the event log is `evt:<n>` with an `evtseq` counter,
-- written in one ACID transaction. selftest.lua exercises THIS code path
-- in-process against a faithful fake of resty.lmdb (get + transaction commit);
-- only the real memory-mapped, MVCC environment needs OpenResty.
local function lmdb_backend()
  local lmdb = require("resty.lmdb")
  local txn  = require("resty.lmdb.transaction")
  local be = {}
  function be:each(fn)
    local n = tonumber(lmdb.get("evtseq")) or 0
    for i = 1, n do
      local v = lmdb.get("evt:" .. i)
      if v then fn(v) end
    end
  end
  function be:append(line)
    local n = (tonumber(lmdb.get("evtseq")) or 0) + 1
    local t = txn.begin()
    t:set("evt:" .. n, line)
    t:set("evtseq", tostring(n))
    local ok, err = t:commit()
    if not ok then error("lmdb commit failed: " .. tostring(err)) end
  end
  return be
end

-- ---- the store --------------------------------------------------------------
-- opts = { codec = <cjson-like {encode,decode}>, backend = "file"|"lmdb",
--          path = <file backend log path> }
function M.new(opts)
  opts = opts or {}
  local codec = assert(opts.codec, "store.new: a JSON codec is required")
  local backend = (opts.backend == "lmdb") and lmdb_backend()
                  or file_backend(opts.path or "authz-log.jsonl")

  local view = new_view()
  local seq  = 0

  -- replay the durable log into the view (this is the crash-recovery path)
  backend:each(function(line)
    local e = codec.decode(line)
    if type(e) == "table" then seq = math.max(seq, e.seq or 0); apply(view, e) end
  end)

  local S = {}

  -- append: stamp a monotonic seq, persist, THEN apply. If the process dies
  -- mid-call, either the line is on disk (replayed next open) or it is not
  -- (never happened) — no torn state, because the view is only ever rebuilt
  -- from what the backend actually stored.
  local function append(e)
    seq = seq + 1
    e.seq = seq
    backend:append(codec.encode(e))
    apply(view, e)
    return seq
  end

  -- facts (Shen reads these through host.* via lua.call; all return plain
  -- strings/booleans so the marshaler stays on the fast path)
  function S.token_user(token)  local x = view.tokens[token]; return x and x.user or "" end
  function S.is_admin(token)    local x = view.tokens[token]; return x ~= nil and x.admin == true end
  function S.owner_tenant(res)  return view.owner[res] or "" end
  function S.member(user, tenant)
    local m = view.member[user]; return m ~= nil and m[tenant] ~= nil
  end
  function S.role(user, tenant, role)
    local m = view.member[user]; return m ~= nil and m[tenant] == role
  end
  function S.revoked(user, res)
    local r = view.revoked[user]; return r ~= nil and r[res] == true
  end
  function S.content(res) return view.content[res] or "" end

  -- mutations (durable)
  function S.seed_token(token, user, admin) return append{ t="token", token=token, user=user, admin=admin } end
  function S.grant(user, tenant, role)      return append{ t="grant", user=user, tenant=tenant, role=role } end
  function S.revoke(user, res)              return append{ t="revoke", user=user, resource=res } end
  function S.create(tenant, res, content)   return append{ t="create", tenant=tenant, resource=res, content=content } end

  -- the proof log: every authorize decision is a durable event
  function S.log_decision(user, action, res, decision, reason)
    return append{ t="decision", user=user, action=action, resource=res,
                   decision=decision, reason=reason }
  end

  -- audit trail as a Lua array of rows, for GET /api/audit
  function S.audit()
    local out = {}
    for i, d in ipairs(view.decisions) do out[i] = d end
    return out
  end

  S.seq = function() return seq end
  return S
end

return M
