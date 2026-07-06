-- examples/pcr/app.lua — proof-carrying requests: the gateway CHECKS, never searches.
--
-- The client attaches a proof term (X-Proof) to the request. The gate builds
-- the judgment (may SUBJECT ACTION RESOURCE) from the request and asks the
-- kernel's sequent-calculus typechecker whether the presented term inhabits
-- it. Allowed requests carry their own justification — the proof term IS the
-- audit trail, and it is logged with the inference count of its checking.
--
-- The proof is UNTRUSTED input. It is read (parsed), never evaluated; the
-- judgment is built only from atoms that pass a whitelist, so request data
-- cannot smuggle syntax into the type; shen.typecheck reads "PROOF : TYPE" as
-- one triple and rejects any other shape, so a proof string cannot smuggle a
-- different judgment past the check; and a per-check inference budget makes
-- adversarially deep terms fail closed. A proof is bound to the EXACT
-- judgment: presenting alice's ownership proof on bob's request checks
-- (may bob ...), which that term does not establish.
--
-- Kernel boot + the typed load of rules.shen happen ONCE per worker.

local APP_DIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$") or "."

local shen = require("shen")
local P    = shen.prims

local cjson
do
  local ok, m = pcall(require, "cjson.safe")
  if not ok then ok, m = pcall(require, "cjson") end
  cjson = ok and m or assert(loadfile(APP_DIR .. "/json_shim.lua"))()
end

shen.boot{quiet = true}
shen.eval("(tc +)")
P.F["load"](APP_DIR .. "/rules.shen")
shen.eval("(tc -)")

-- shen.typecheck resets shen.*infs* per call, so *maxinferences* acts as a
-- per-check budget: a term needing more than this fails closed. The demo's
-- deepest proof (delegation) checks in 50 inferences.
shen.eval("(set shen.*maxinferences* 10000)")
local MAX_PROOF_BYTES = 1024

-- Judgment atoms: bare symbols only. Anything a client could use to alter
-- the shape of the type — parens, brackets, whitespace, colon, quotes —
-- is refused before the reader ever sees it.
local function atom_ok(s)
  return type(s) == "string" and s ~= "" and s:match("^[%w%-%.%_]+$") ~= nil
end

-- ---- check one request ------------------------------------------------------
-- Returns authorized(bool), reason(string), audit(table|nil).
local function check(subject, action, resource, proof)
  if not (atom_ok(subject) and atom_ok(action) and atom_ok(resource)) then
    return false, "malformed subject/action/resource", nil
  end
  if type(proof) ~= "string" or proof == "" then
    return false, "no proof presented", nil
  end
  if #proof > MAX_PROOF_BYTES then
    return false, "proof too large", nil
  end
  local judgment = "(may " .. subject .. " " .. action .. " " .. resource .. ")"
  -- pcall: an unreadable term or a smuggled extra form errors — fail closed
  local ok, res = pcall(shen.typecheck, proof, judgment)
  if not ok then
    return false, "malformed proof", nil
  end
  if res == false then
    return false, "proof does not establish " .. judgment, nil
  end
  return true, "proof checks", {
    judgment = judgment,
    proof    = proof,
    infs     = shen.value("shen.*infs*"),
  }
end

-- ---- request handling (pure; shared with selftest) --------------------------
local function dispatch(method, path, body)
  if path == "/api/check" and method == "POST" then
    body = body or {}
    local authorized, reason, audit = check(body.subject, body.action, body.resource, body.proof)
    local out = { authorized = authorized, reason = reason }
    if audit then out.judgment, out.infs = audit.judgment, audit.infs end
    return 200, out
  end
  return 404, { error = "not found" }
end

local M = { dispatch = dispatch, check = check, json = cjson }

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

-- ---- the enforcement gate (access_by_lua on /protected/) --------------------
-- Subject and resource come from headers for the demo; in production the
-- subject comes from a verified JWT/session. The PROOF though is exactly
-- where it belongs: presented by the client, per request.
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
  -- the audit line: who did what, justified by which proof, at what cost
  ngx.log(ngx.INFO, "authorized ", audit.judgment,
          " by ", audit.proof, " (", audit.infs, " inferences)")
  ngx.header["X-Proof-Checked"] = tostring(audit.infs) .. " inferences"
  -- fall through to the protected content
end

return M
