-- examples/pcr/app.lua — proof-carrying tool calls over LIVE facts.
--
-- The caller (a human's client, an agent, a spawned subagent) attaches a
-- proof term (X-Proof). The gate builds the judgment (may SUBJECT ACTION
-- RESOURCE) from the request and asks the kernel's sequent-calculus
-- typechecker whether the presented term inhabits it. Fact leaves
-- ([fact owns alice crm-contacts]) are discharged against the versioned
-- fact store (facts.lua) AT CHECK TIME, so granting a fact makes proofs
-- start checking and revoking it makes the same proof bytes stop checking
-- on the next request — the engine memoizes no answers. Allowed requests
-- log their proof, the fact-store version it was judged against, and the
-- exact fact leaves consumed: the audit trail is the justification itself.
--
-- The proof is UNTRUSTED input: judgment atoms and every proof token must
-- pass allowlists BEFORE anything reaches the reader (the symbol table is
-- permanent, so unvetted atoms are a memory leak — a bounded distinct-atom
-- budget backstops even a tokenizer/reader divergence); the typecheck
-- triple shape blocks smuggling a different judgment; reader errors,
-- oversized terms and over-budget terms all fail closed.
--
-- Boot order matters: the pcr.fact? bridge is registered BEFORE rules.shen
-- loads under (tc +) — and it is a stable trampoline into facts.lua state,
-- because lua.function captures the function VALUE at registration.

local APP_DIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$") or "."
package.path = APP_DIR .. "/?.lua;" .. package.path

local shen  = require("shen")
local P     = shen.prims
local facts = require("facts")

local cjson
do
  local ok, m = pcall(require, "cjson.safe")
  if not ok then ok, m = pcall(require, "cjson") end
  cjson = ok and m or assert(loadfile(APP_DIR .. "/json_shim.lua"))()
end

-- the stable trampoline: registered once, reads live facts.lua state
pcr = { factq = function(pred, s, r) return facts.factq(pred, s, r) end }

shen.boot{quiet = true}
shen.eval('(lua.function pcr.fact? "pcr.factq" [symbol --> symbol --> symbol --> boolean])')
shen.eval("(tc +)")
P.F["load"](APP_DIR .. "/rules.shen")
shen.eval("(tc -)")

-- per-check inference budget (shen.typecheck resets the counter per call)
shen.eval("(set shen.*maxinferences* 10000)")
local MAX_PROOF_BYTES = 1024
local DEBUG_HEADERS   = os.getenv("PCR_DEBUG_HEADERS") == "1"

-- The demo authority graph; add-if-absent so racing nginx workers seed once.
--
--   alice (human) ──owns──> crm-contacts
--     └─delegates (full)──> orchestrator (her agent session)
--          └─delegates-read (attenuated)──> researcher (spawned subagent)
--   bob (human teammate) has the member role: may read, never write.
--
-- Both agents are REGISTERED tenant principals (same-tenant facts) but hold
-- no authority of their own: researcher's ONLY capability is the
-- read-attenuated edge from orchestrator, whose ONLY capability is alice's
-- delegation. Revoking delegates/alice/orchestrator therefore kills every
-- proof built through it (the whole agent subtree, mid-run) at the TYPE
-- layer ("proof does not establish") — the agents stay known atoms — while
-- alice's and bob's own proofs keep working.
facts.seed{
  ["owns/alice/crm-contacts"]                = true,
  ["same-tenant/alice/crm-contacts"]         = true,
  ["has-role/bob/member"]                    = true,
  ["same-tenant/bob/crm-contacts"]           = true,
  ["delegates/alice/orchestrator"]           = true,
  ["same-tenant/orchestrator/crm-contacts"]  = true,
  ["delegates-read/orchestrator/researcher"] = true,
  ["same-tenant/researcher/crm-contacts"]    = true,
}

-- ---- pre-intern gate ----------------------------------------------------------
-- Nothing reaches the Shen reader unless every atom in it is already known:
-- rule names + predicates + actions (static vocabulary) or an atom of the
-- CURRENT fact world. That is what bounds the permanent symbol table — the
-- fact world is written only by admin grants (facts.lua validates every
-- pred/s/r), so the set of admissible atoms is operator-controlled and an
-- attacker's novel atoms are rejected here, before read-from-string.
local STATIC_VOCAB = {
  ["fact"] = true, ["by-owner"] = true, ["by-member-read"] = true,
  ["by-delegation"] = true, ["by-read-delegation"] = true,
  ["owns"] = true, ["same-tenant"] = true, ["has-role"] = true,
  ["delegates"] = true, ["delegates-read"] = true,
  ["read"] = true, ["write"] = true, ["delete"] = true, ["member"] = true,
}

local function atom_ok(s)
  return type(s) == "string" and s ~= "" and s:match("^[a-z][a-z0-9%-%.%_]*$") ~= nil
end

-- Stateless on purpose. An earlier version kept a per-worker monotone
-- seen-set with a fixed cap; the cap never bounded the attacker (fact-world
-- membership already does) but DID false-deny legitimate atoms once a worker
-- had handled more than the cap's worth of distinct principals. A principal
-- whose facts are all revoked is simply unknown to this fact world and denies
-- here; a production gateway wanting a type-level reason for recently-revoked
-- principals would add an LRU grace set (see the Garmr implementation note).
local function admit(token, snap)
  return atom_ok(token) and (STATIC_VOCAB[token] == true or snap.atoms[token] == true)
end

-- every proof token must be a known word; brackets are structure
local function proof_tokens_ok(proof, snap)
  for token in proof:gmatch("[^%s%[%]]+") do
    if not admit(token, snap) then return false, token end
  end
  return true
end

-- ---- check one request ---------------------------------------------------------
-- Returns authorized(bool), reason(string), audit(table|nil).
local function check(subject, action, resource, proof)
  local snap, why = facts.snapshot()
  if not snap then
    return false, "fact store unavailable: " .. tostring(why), nil
  end
  if not (atom_ok(subject) and atom_ok(action) and atom_ok(resource)) then
    return false, "malformed subject/action/resource", nil
  end
  if not (admit(subject, snap) and admit(action, snap) and admit(resource, snap)) then
    return false, "unknown subject/action/resource", nil
  end
  if type(proof) ~= "string" or proof == "" then
    return false, "no proof presented", nil
  end
  if #proof > MAX_PROOF_BYTES then
    return false, "proof too large", nil
  end
  local tok_ok, bad = proof_tokens_ok(proof, snap)
  if not tok_ok then
    return false, "unknown token in proof: " .. tostring(bad), nil
  end
  local judgment = "(may " .. subject .. " " .. action .. " " .. resource .. ")"
  facts.reset_leaves()
  -- pcall: an unreadable term or a smuggled extra form errors — fail closed
  local ok, res = pcall(shen.typecheck, proof, judgment)
  if not ok then
    return false, "malformed proof", nil
  end
  if res == false then
    return false, "proof does not establish " .. judgment, nil
  end
  return true, "proof checks", {
    judgment      = judgment,
    proof         = proof,
    infs          = shen.value("shen.*infs*"),
    facts_version = snap.version,
    sync_age      = facts.now() - snap.synced_at,
    leaves        = facts.leaves(),
  }
end

-- ---- request handling (pure; shared with selftest) -----------------------------
local function dispatch(method, path, body)
  if path == "/api/check" and method == "POST" then
    body = body or {}
    local authorized, reason, audit = check(body.subject, body.action, body.resource, body.proof)
    local out = { authorized = authorized, reason = reason }
    if audit then
      out.judgment, out.infs = audit.judgment, audit.infs
      out.facts_version, out.leaves = audit.facts_version, audit.leaves
    end
    return 200, out
  end
  if path == "/admin/grant" and method == "POST" then
    body = body or {}
    if not (atom_ok(body.pred) and atom_ok(body.s) and atom_ok(body.r)) then
      return 400, { error = "grant needs pred/s/r atoms" }
    end
    local ok, v, err = facts.grant(body.pred, body.s, body.r, tonumber(body.expiry))
    if not ok then
      return 507, { ok = false, error = "grant failed", reason = err }
    end
    return 200, { ok = true, version = v }
  end
  if path == "/admin/revoke" and method == "POST" then
    body = body or {}
    if not (atom_ok(body.pred) and atom_ok(body.s) and atom_ok(body.r)) then
      return 400, { error = "revoke needs pred/s/r atoms" }
    end
    local ok, v, err = facts.revoke(body.pred, body.s, body.r)
    if not ok then
      return 507, { ok = false, error = "revoke failed", reason = err }
    end
    return 200, { ok = true, version = v }
  end
  return 404, { error = "not found" }
end

local M = { dispatch = dispatch, check = check, json = cjson, facts = facts }

function M.handle()
  local method = ngx.req.get_method()
  local decoded
  if method == "POST" then
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if raw and raw ~= "" then
      local d = cjson.decode(raw)
      if d == nil then
        ngx.status = 400; ngx.header.content_type = "application/json"
        ngx.say(cjson.encode({ error = "invalid JSON" })); return
      end
      decoded = d
    end
  end
  local status, body = dispatch(method, ngx.var.uri, decoded)
  ngx.status = status
  ngx.header.content_type = "application/json"
  ngx.say(cjson.encode(body))
end

-- ---- the enforcement gate (access_by_lua on /protected/) -----------------------
-- Subject and resource come from headers for the demo; in production the
-- subject comes from a verified identity (JWT/session for a human, workload
-- identity for an agent). The PROOF is exactly where it belongs: presented
-- by the caller, per request, judged against the facts current at THIS
-- moment.
function M.gate()
  local h = ngx.req.get_headers()
  local action = ngx.req.get_method() == "GET" and "read" or "write"
  local authorized, reason, audit =
    check(h["x-subject"], action, h["x-resource"], h["x-proof"])
  if not authorized then
    ngx.status = 403
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode({ error = "forbidden", reason = reason }))
    return ngx.exit(403)
  end
  -- the audit line: who did what, justified how, against which fact world
  ngx.log(ngx.INFO, "authorized ", audit.judgment,
          " by ", audit.proof,
          " (", audit.infs, " inferences, facts v", audit.facts_version,
          ", leaves ", table.concat(audit.leaves, " "), ")")
  -- X-Facts-Version is a legitimate protocol element (the consistency token a
  -- client uses to reason about staleness); the inference count is internal
  -- detail, exposed only when PCR_DEBUG_HEADERS=1.
  ngx.header["X-Facts-Version"] = tostring(audit.facts_version)
  if DEBUG_HEADERS then
    ngx.header["X-Proof-Checked"] = tostring(audit.infs) .. " inferences"
  end
  -- fall through to the protected content
end

return M
