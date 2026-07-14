# Proof-Carrying Tool Calls: Who Authorized Your Agent?

*2026-07-14T02:42:23Z by Showboat 0.6.1*
<!-- showboat-id: e739f604-3803-4393-bf16-f3f88308586a -->

An authorization gateway for agent tool calls where the caller **carries the
proof** and the edge only **checks** it — against the facts current at *this*
request. The authority graph under demo:

    alice (human) ──owns──> crm-contacts
      └─ delegates (full) ──> orchestrator            her agent session
           └─ delegates-read (ATTENUATED) ──> researcher   the subagent it spawned

The researcher's request presents a proof whose shape is the delegation chain
itself, assembled at runtime by the agent runtime. The gate builds the
judgment `(may researcher read crm-contacts)` and asks Shen's
sequent-calculus typechecker whether the term inhabits it. Fact leaves are
discharged against a versioned live fact store *at check time*, so revoking
one delegation edge makes every proof built through it — the whole agent
subtree — fail on the very next request, while unrelated proofs keep working.

This document is executable: `showboat verify examples/pcr/DEMO.md` re-runs
every block from the repo root and confirms the outputs still match.

## The logic: one live-fact rule, attenuation as a rule

Facts are not axioms baked into the rules. A single side-condition rule
discharges each `[fact ...]` leaf against the store; grant rules compose
them — `by-delegation` lets a proof *nest*, carrying the whole justification
chain, and `by-read-delegation` is **attenuation enforced by the type
system**: its only possible conclusion is `(may T read R)`, so a subagent
holding only a `delegates-read` edge cannot construct a write proof at all.

```bash
sed -n '/(datatype authz/,$p' examples/pcr/rules.shen
```

```output
(datatype authz
  \\ -- the ONE fact rule: a leaf is checked against the live store ----------
  if (pcr.fact? Pred S R)
  ________________________
  [fact Pred S R] : (Pred S R);

  \\ -- grant rules (universal in S, A, R, T) ---------------------------------
  \\ an owner inside the resource's tenant may take ANY action on it
  P : (owns S R); Q : (same-tenant S R);
  ======================================
  [by-owner P Q] : (may S A R);

  \\ a member inside the resource's tenant may READ it
  P : (has-role S member); Q : (same-tenant S R);
  ===============================================
  [by-member-read P Q] : (may S read R);

  \\ full delegation: whatever S may do, T may do — the delegate's proof
  \\ CONTAINS the delegator's proof, so the whole justification chain
  \\ travels with the request (alice -> her orchestrator agent)
  P : (may S A R); Q : (delegates S T);
  =====================================
  [by-delegation P Q] : (may T A R);

  \\ ATTENUATED delegation: S passes on READ and nothing else — the only
  \\ conclusion this rule can produce is (may T read R), so a subagent
  \\ holding delegates-read cannot construct a write proof AT ALL; the
  \\ attenuation is enforced by the type system, not by a runtime filter
  \\ (orchestrator -> the researcher subagent it spawns)
  P : (may S read R); Q : (delegates-read S T);
  =============================================
  [by-read-delegation P Q] : (may T read R);)
```

## The money shot: the chain checks, and it cannot escalate

`app.check(subject, action, resource, proof)` is exactly what the OpenResty
gate runs per request. The researcher's three-hop proof checks, and the audit
answers *what authority justified this call* — the exact fact leaves consumed
and the fact-world version they were judged against. Then attenuation: the
same proof cannot establish a write judgment, and a **forged** full-delegation
chain — which shape-checks — still dies, because the store, not the proof,
decides whether `(delegates orchestrator researcher)` holds.

```bash
luajit -e '
package.path = "examples/pcr/?.lua;" .. package.path
local app = require("app")
local owner = "[by-owner [fact owns alice crm-contacts] [fact same-tenant alice crm-contacts]]"
local agent = "[by-delegation " .. owner .. " [fact delegates alice orchestrator]]"
local sub   = "[by-read-delegation " .. agent .. " [fact delegates-read orchestrator researcher]]"
local forged = "[by-delegation " .. agent .. " [fact delegates orchestrator researcher]]"
local function show(label, subject, action, resource, proof, want_audit)
  local ok, reason, audit = app.check(subject, action, resource, proof)
  print(("%-38s %-5s  %s"):format(label, ok and "ALLOW" or "DENY", reason))
  if ok and want_audit then
    print("    audit: facts v" .. audit.facts_version ..
          ", leaves " .. table.concat(audit.leaves, " "))
  end
end
show("subagent reads (three-hop chain)", "researcher", "read", "crm-contacts", sub, true)
print("-- attenuation: no write proof exists for a read-only delegate --")
show("subagent WRITE, its own proof",   "researcher", "write", "crm-contacts", sub)
show("subagent WRITE, forged full chain","researcher", "write", "crm-contacts", forged)
' 2>&1 | grep -vE "run time|typechecked in|^authz#type"
```

```output
subagent reads (three-hop chain)       ALLOW  proof checks
    audit: facts v1, leaves (owns alice crm-contacts) (same-tenant alice crm-contacts) (delegates alice orchestrator) (delegates-read orchestrator researcher)
-- attenuation: no write proof exists for a read-only delegate --
subagent WRITE, its own proof          DENY   proof does not establish (may researcher write crm-contacts)
subagent WRITE, forged full chain      DENY   proof does not establish (may researcher write crm-contacts)
```

## Revoke one edge, kill the subtree — mid-run, surgically

The proof never changes; only the fact world does. Revoking the single
`delegates alice orchestrator` edge makes every proof built through it —
the agent's AND the spawned subagent's — fail on the immediately-next check,
because neither engine memoizes derivations: a fact leaf is re-consulted on
every check. Alice's own proof never used that edge, so she keeps working.

```bash
luajit -e '
package.path = "examples/pcr/?.lua;" .. package.path
local app = require("app")
local owner = "[by-owner [fact owns alice crm-contacts] [fact same-tenant alice crm-contacts]]"
local agent = "[by-delegation " .. owner .. " [fact delegates alice orchestrator]]"
local sub   = "[by-read-delegation " .. agent .. " [fact delegates-read orchestrator researcher]]"
local function show(label, subject, action, resource, proof)
  local ok, reason = app.check(subject, action, resource, proof)
  print(("%-38s %-5s  %s"):format(label, ok and "ALLOW" or "DENY", reason))
end
show("subagent reads",                    "researcher",   "read",  "crm-contacts", sub)
app.facts.revoke("delegates", "alice", "orchestrator")
print("-- incident: operator revokes alice->orchestrator (one edge) --")
show("subagent, IDENTICAL proof bytes",   "researcher",   "read",  "crm-contacts", sub)
show("the agent session itself, dead too","orchestrator", "write", "crm-contacts", agent)
show("alice, her own proof (surgical)",   "alice",        "write", "crm-contacts", owner)
app.facts.grant("delegates", "alice", "orchestrator")
print("-- operator re-grants the delegation --")
show("the whole subtree revives",         "researcher",   "read",  "crm-contacts", sub)
' 2>&1 | grep -vE "run time|typechecked in|^authz#type"
```

```output
subagent reads                         ALLOW  proof checks
-- incident: operator revokes alice->orchestrator (one edge) --
subagent, IDENTICAL proof bytes        DENY   proof does not establish (may researcher read crm-contacts)
the agent session itself, dead too     DENY   proof does not establish (may orchestrator write crm-contacts)
alice, her own proof (surgical)        ALLOW  proof checks
-- operator re-grants the delegation --
the whole subtree revives              ALLOW  proof checks
```

## Both engines agree — byte for byte

Side-condition rules go through the typed `lua.function` bridge, which the
native (soa32) and legacy (CPS) type engines execute identically. The
selftest is the invariant: run it under both engines and every verdict *and
inference count* must match. This is the only guard against a rule silently
diverging between engines.

```bash
FILT='run time|us/check|heap|typechecked in|^authz#type'
a=$(luajit examples/pcr/selftest.lua 2>&1 | grep -vE "$FILT")
b=$(SHEN_TYPECHECK_NATIVE=off luajit examples/pcr/selftest.lua 2>&1 | grep -vE "$FILT")
if [ "$a" = "$b" ]; then
  echo "native and legacy CPS engines: byte-identical verdicts and inference counts"
  printf '%s\n' "$a" | tail -1
else
  echo "MISMATCH between engines"; fi
```

```output
native and legacy CPS engines: byte-identical verdicts and inference counts
OK — all checks passed
```

## The full battery

The selftest exercises every behavior and every defense as a named category —
the three-hop chain, type-layer attenuation, the live revocation window
(one edge kills the subtree, surgically), TTL-boxed agent sessions,
replica-mode staleness hard cap, fail-closed write failures, an
undecodable-blob refusal, the hostile-input suite (spoofed proofs,
judgment/variable injection, key forgery), and a 10k-distinct-atom
intern-DoS regression. Here are the sections it proves:

```bash
luajit examples/pcr/selftest.lua 2>&1 | grep -E '^==|OK — all|FAIL'
```

```output
== proofs that check against the live fact world ==
== attenuation: a read-only subagent cannot escalate ==
== the revocation window: identical bytes, next check ==
== fact-store write failures fail closed ==
== TTL facts: a time-boxed agent needs no revoke call ==
== replica mode: staleness hard cap fails closed ==
== denials: the proof is bound to the exact judgment ==
== denials: hostile input fails closed ==
== the guard itself (defense under the tokenizer) ==
== intern regression: distinct hostile atoms stay bounded ==
== warm cost of checking (the whole per-request price) ==
== undecodable blob: reads deny, mutate refuses (no reset) ==
OK — all checks passed
```

## The proof is hostile input

The proof term is attacker-controlled, so every defense is exercised. A few
fired live — a proof bound to someone else's judgment, an uppercase atom that
would otherwise parse as a Shen type variable, a leaf that tries to assert a
grant judgment directly, and a grant attempted over a deliberately corrupted
fact blob (which must refuse, not silently reset):

```bash
luajit -e '
package.path = "examples/pcr/?.lua;" .. package.path
local app = require("app")
local owner = "[by-owner [fact owns alice crm-contacts] [fact same-tenant alice crm-contacts]]"
local function try(label, subject, action, resource, proof)
  local ok, reason = app.check(subject, action, resource, proof)
  print(("%-32s %-5s  %s"):format(label, ok and "ALLOW" or "DENY", reason))
end
try("spoof: alices proof, as bob", "bob",     "write", "crm-contacts", owner)
try("uppercase S (a type var)",    "S",       "write", "crm-contacts", owner)
try("unknown principal (mallory)", "mallory", "write", "crm-contacts", owner)
try("leaf asserts a grant",        "researcher", "write", "crm-contacts",
    "[fact may researcher write crm-contacts]")
app.facts._test.corrupt_blob()
local status = app.dispatch("POST", "/admin/grant", {pred="owns", s="alice", r="crm-notes"})
print(("%-32s HTTP %d  (grant over a corrupt blob is refused, not reset)"):format("corrupt-blob mutate", status))
' 2>&1 | grep -vE "run time|typechecked in|^authz#type"
```

```output
spoof: alices proof, as bob      DENY   proof does not establish (may bob write crm-contacts)
uppercase S (a type var)         DENY   malformed subject/action/resource
unknown principal (mallory)      DENY   unknown subject/action/resource
leaf asserts a grant             DENY   unknown token in proof: may
corrupt-blob mutate              HTTP 507  (grant over a corrupt blob is refused, not reset)
```

## Over the wire

The same `check()` runs behind the OpenResty gate on `/protected/`, driven
by the `X-Subject` / `X-Resource` / `X-Proof` headers (GET maps to
`read`, POST to `write`). Two workers share one versioned fact blob, so a
revoke through either is seen by both on the next request. See
[`README.md`](README.md) for the full curl transcript — the three-hop
allow with its audit line, the attenuation 403, the mid-run revoke, the
surgical survival of alice's own proof, the re-grant — and `nginx.conf`
for the server wiring.

Everything above is reproducible: run `showboat verify examples/pcr/DEMO.md`
from the repo root to re-run every block and diff the output against what is
recorded here.
