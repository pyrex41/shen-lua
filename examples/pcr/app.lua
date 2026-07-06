-- examples/pcr/app.lua — proof-carrying requests over LIVE facts.
--
-- The client attaches a proof term (X-Proof). The gate builds the judgment
-- (may SUBJECT ACTION RESOURCE) from the request and asks the kernel's
-- sequent-calculus typechecker whether the presented term inhabits it. Fact
-- leaves ([fact owns alice doc1]) are discharged against the versioned fact
-- store (facts.lua) AT CHECK TIME, so granting a fact makes proofs start
-- checking and revoking it makes the same proof bytes stop checking on the
-- next request — the engine memoizes no answers. Allowed requests log their
-- proof, the fact-store version it was judged against, and the exact fact
-- leaves consumed: the audit trail is the justification itself.
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

-- the demo fact base; add-if-absent so racing nginx workers seed once
facts.seed{
  ["owns/alice/doc1"]        = true,
  ["same-tenant/alice/doc1"] = true,
  ["has-role/bob/member"]    = true,
  ["same-tenant/bob/doc1"]   = true,
  ["delegates/alice/carol"]  = true,
}

-- ---- pre-intern gates ---------------------------------------------------------
-- Nothing reaches the Shen reader unless every atom in it is already known:
-- rule names + predicates + actions (static vocabulary) or an atom of the
-- current fact world. A bounded budget of distinct admitted tokens
-- backstops any gate/reader divergence: exhaust it and the gate denies
-- everything rather than leak interned symbols forever.
local STATIC_VOCAB = {
  ["fact"] = true, ["by-owner"] = true, ["by-member-read"] = true,
  ["by-delegation"] = true,
  ["owns"] = true, ["same-tenant"] = true, ["has-role"] = true,
  ["delegates"] = true,
  ["read"] = true, ["write"] = true, ["delete"] = true, ["member"] = true,
}

local ATOM_BUDGET = 4096
local seen_atoms, seen_count = {}, 0

-- The gate is an intern-DoS backstop, not authorization: an atom admitted
-- once is already interned, so admission is MONOTONE — revoking a
-- subject's last fact does not make them "unknown" here; it makes their
-- proofs fail at the type level, with the honest reason.
local function admit(token, snap)
  if STATIC_VOCAB[token] or seen_atoms[token] then return true end
  if not snap.atoms[token] then return false end
  if seen_count >= ATOM_BUDGET then return false end
  seen_count = seen_count + 1
  seen_atoms[token] = true
  return true
end

local function atom_ok(s)
  return type(s) == "string" and s ~= "" and s:match("^[%w%-%.%_]+$") ~= nil
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
    local v = facts.grant(body.pred, body.s, body.r, tonumber(body.expiry))
    return 200, { ok = true, version = v }
  end
  if path == "/admin/revoke" and method == "POST" then
    body = body or {}
    if not (atom_ok(body.pred) and atom_ok(body.s) and atom_ok(body.r)) then
      return 400, { error = "revoke needs pred/s/r atoms" }
    end
    local v = facts.revoke(body.pred, body.s, body.r)
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
-- subject comes from a verified JWT/session. The PROOF is exactly where it
-- belongs: presented by the client, per request, judged against the facts
-- current at THIS moment.
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
  ngx.header["X-Proof-Checked"] = tostring(audit.infs) .. " inferences"
  ngx.header["X-Facts-Version"] = tostring(audit.facts_version)
  -- fall through to the protected content
end

return M
