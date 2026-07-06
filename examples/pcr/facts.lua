-- examples/pcr/facts.lua — the versioned live fact store behind pcr.fact?.
--
-- All fact state lives in ONE atomically-written blob:
--     { version = N, synced_at = T, facts = { ["owns/alice/doc1"] = true|expiry } }
-- kept in ngx.shared.pcr_facts under a single key (falling back to a plain
-- Lua cell under plain luajit, so the selftest exercises the same code).
-- One blob means one epoch: a per-check snapshot can never mix two fact
-- worlds (no torn reads), a missing/undecodable blob is a deny (no
-- fail-open on shm eviction), and synced_at travels INSIDE the blob so
-- freshness can never be stamped by a failed sync.
--
-- A fact value of `true` holds until revoked; a NUMBER is an absolute
-- expiry (epoch seconds) checked against the live clock per request — a
-- time-limited grant that needs no revoke call.
--
-- Modes: "authoritative" (default; the store IS the source of truth —
-- /admin writes land here synchronously, staleness is structurally zero)
-- or "replica" (the store mirrors an external DB via a periodic pull of
-- period W; snapshot() then HARD-DENIES when now - synced_at > 3W, so a
-- dead timer or partitioned DB degrades to denial, never frozen grants).
-- start_sync_timer() is the replica-mode pull stub.

local M = {}

local DIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$") or "."

local json
do
  local ok, m = pcall(require, "cjson.safe")
  if not ok then ok, m = pcall(require, "cjson") end
  json = ok and m or assert(loadfile(DIR .. "/json_shim.lua"))()
end

-- the live clock; selftest overrides M.now to drive TTL/staleness cases
function M.now()
  return ngx and ngx.now() or os.time()
end

M.mode = "authoritative"
M.W    = 1        -- replica sync period (seconds); staleness hard cap = 3W

-- ---- the blob cell -----------------------------------------------------------
-- One key, whole-blob set/get: atomic under ngx.shared, trivial under the
-- plain-Lua fallback. LuaJIT interns strings, so the per-request "did the
-- blob change" test below is a pointer compare after the get.
local shm = ngx and ngx.shared and ngx.shared.pcr_facts
local cell = { v = nil }   -- fallback store
M._simulate_write_failure = nil   -- selftest hook; normal plain-Lua fallback still succeeds

local function blob_get()
  if shm then return shm:get("blob") end
  return cell.v
end

local function blob_set(s)
  if M._simulate_write_failure then return false, M._simulate_write_failure end
  if shm then
    local ok, err = shm:set("blob", s)
    if not ok then return false, err or "unknown shared-dict set failure" end
    return true
  end
  cell.v = s; return true
end

-- ---- writes (authority side) -------------------------------------------------
local function decode_blob()
  local raw = blob_get()
  if not raw then return nil end
  local ok, t = pcall(json.decode, raw)
  if not ok or type(t) ~= "table" or type(t.facts) ~= "table" then return nil end
  return t
end

local function write(facts, version)
  local blob = json.encode{ version = version, synced_at = M.now(), facts = facts }
  local ok, err = blob_set(blob)
  if not ok then
    return false, nil, "fact store write failed: " .. tostring(err)
  end
  return true, version
end

-- Seed only if no blob exists yet (both nginx workers race at init).
function M.seed(facts)
  if blob_get() then return false end
  return write(facts, 1)
end

local function mutate(f)
  local t = decode_blob() or { version = 0, facts = {} }
  f(t.facts)
  return write(t.facts, t.version + 1)
end

function M.grant(pred, s, r, expiry)
  return mutate(function(facts) facts[pred .. "/" .. s .. "/" .. r] = expiry or true end)
end

function M.revoke(pred, s, r)
  return mutate(function(facts) facts[pred .. "/" .. s .. "/" .. r] = nil end)
end

-- ---- the per-check snapshot ---------------------------------------------------
-- snapshot() revalidates the worker-local view against the blob (one shm
-- get + string compare per request; decode only on change) and returns
-- {facts, atoms, version, synced_at} or nil, reason (DENY). The snapshot
-- and the known-atom set derived from it swap together — one epoch for
-- the guard and the request gates.
local SNAP, SNAP_RAW = nil, nil

local function atoms_of(facts)
  local atoms = {}
  for key in pairs(facts) do
    for part in key:gmatch("[^/]+") do atoms[part] = true end
  end
  return atoms
end

function M.snapshot()
  local raw = blob_get()
  if not raw then return nil, "fact store empty or evicted" end
  if raw ~= SNAP_RAW then
    local ok, t = pcall(json.decode, raw)
    if not ok or type(t) ~= "table" or type(t.facts) ~= "table"
       or type(t.version) ~= "number" or type(t.synced_at) ~= "number" then
      return nil, "fact store undecodable"
    end
    SNAP = { facts = t.facts, atoms = atoms_of(t.facts),
             version = t.version, synced_at = t.synced_at }
    SNAP_RAW = raw
  end
  if M.mode == "replica" and M.now() - SNAP.synced_at > 3 * M.W then
    return nil, "fact store stale (sync older than 3W)"
  end
  return SNAP
end

-- ---- the guard ----------------------------------------------------------------
-- pcr.fact? lands here (via the stable trampoline app.lua registers — the
-- lua.function bridge captures the function VALUE at registration, so all
-- dynamism must live in the state this reads, never in rebinding it).
-- Runs DURING typechecking, so it must fail closed on everything: unbound
-- type variables arrive as tables (not strings), "/" in an atom would
-- forge a different store key, and only fact predicates are consultable —
-- a proof leaf can never assert a grant judgment like (may ...).
local PRED_ALLOW = { ["owns"] = true, ["same-tenant"] = true,
                     ["has-role"] = true, ["delegates"] = true }

local LEAVES = {}

function M.reset_leaves() LEAVES = {} end
function M.leaves() return LEAVES end

local function atom_ok(x)
  return type(x) == "string" and x ~= "" and x:match("^[a-z][a-z0-9%-%.%_]*$") ~= nil
end

function M.factq(pred, s, r)
  if not (atom_ok(pred) and atom_ok(s) and atom_ok(r)) then return false end
  if not PRED_ALLOW[pred] then return false end
  local snap = SNAP   -- frozen view: check() took the snapshot this request
  if not snap then return false end
  local v = snap.facts[pred .. "/" .. s .. "/" .. r]
  local held
  if v == true then held = true
  elseif type(v) == "number" then held = v >= M.now()   -- TTL fact
  else held = false end
  LEAVES[#LEAVES + 1] = ("(%s %s %s)%s"):format(pred, s, r, held and "" or "!")
  return held
end

-- ---- replica-mode pull stub ----------------------------------------------------
-- Production shape: one worker pulls {version, facts} from the source of
-- truth every W seconds and writes the blob (synced_at stamped only inside
-- a SUCCESSFUL pull — a failing pull leaves the old stamp to age toward
-- the 3W deny). `fetch` returns facts-table or nil on failure.
function M.start_sync_timer(fetch)
  if not (ngx and ngx.timer) then return false end
  local function pull(premature)
    if premature then return end
    local ok, facts = pcall(fetch)
    if ok and type(facts) == "table" then
      local t = decode_blob()
      local wrote, _, err = write(facts, ((t and t.version) or 0) + 1)
      if not wrote then
        ngx.log(ngx.ERR, err)
      end
    elseif not ok then
      ngx.log(ngx.ERR, "pcr fact sync fetch failed: ", tostring(facts))
    end
  end
  ngx.timer.every(M.W, pull)
  return true
end

return M
