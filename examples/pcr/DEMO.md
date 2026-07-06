# Proof-Carrying Requests over Live Facts

*2026-07-06T22:56:42Z by Showboat 0.6.1*
<!-- showboat-id: ce7c186d-2418-4269-9535-72a0b236a195 -->

An authorization gateway where the client **carries the proof** and the edge
only **checks** it — against the facts current at *this* request. The client
attaches a proof term; the gate builds the judgment `(may SUBJECT ACTION
RESOURCE)` and asks Shen's sequent-calculus typechecker whether the term
inhabits it. Fact leaves are discharged against a versioned live fact store
*at check time*, so granting a fact makes proofs start checking and revoking
it makes the **same proof bytes** stop checking on the very next request.

This document is executable: `showboat verify examples/pcr/DEMO.md` re-runs
every block from the repo root and confirms the outputs still match.

## The logic: one live-fact rule

Facts are not axioms baked into the rules. A single side-condition rule
discharges each `[fact ...]` leaf against the store, and three grant rules
compose them — `by-delegation` lets a proof *nest*, carrying the whole
justification chain. The leaf carries its ground triple because a side
condition can only **check** values, never bind them.

```bash
sed -n '/(datatype authz/,/by-delegation P Q/p' examples/pcr/rules.shen
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

  \\ whatever S may do, S may delegate: the delegate's proof CONTAINS the
  \\ delegator's proof — the full justification chain travels with the request
  P : (may S A R); Q : (delegates S T);
  =====================================
  [by-delegation P Q] : (may T A R);)
```

## The money shot: same proof bytes, valid then revoked

`app.check(subject, action, resource, proof)` is exactly what the OpenResty
gate runs per request. Watch one proof term's fate as the fact it depends on
is revoked and restored — the proof never changes, only the fact world does.
Revocation is instant because neither engine memoizes derivations: a fact
leaf is re-consulted on every check.

```bash
luajit -e '
package.path = "examples/pcr/?.lua;" .. package.path
local app = require("app")
local deleg = "[by-delegation [by-owner [fact owns alice doc1] "
           .. "[fact same-tenant alice doc1]] [fact delegates alice carol]]"
local owner = "[by-owner [fact owns alice doc1] [fact same-tenant alice doc1]]"
local function show(label, subject, action, resource, proof)
  local ok, reason = app.check(subject, action, resource, proof)
  print(("%-34s %-5s  %s"):format(label, ok and "ALLOW" or "DENY", reason))
end
show("carol writes (via delegation)", "carol", "write", "doc1", deleg)
app.facts.revoke("delegates", "alice", "carol")
print("-- admin revokes alice->carol delegation --")
show("carol, IDENTICAL proof bytes",  "carol", "write", "doc1", deleg)
show("alice, her own proof (surgical)","alice", "write", "doc1", owner)
app.facts.grant("delegates", "alice", "carol")
print("-- admin re-grants the delegation --")
show("carol writes again",            "carol", "write", "doc1", deleg)
' 2>&1 | grep -vE "run time|typechecked in|^authz#type"

```

```output
carol writes (via delegation)      ALLOW  proof checks
-- admin revokes alice->carol delegation --
carol, IDENTICAL proof bytes       DENY   proof does not establish (may carol write doc1)
alice, her own proof (surgical)    ALLOW  proof checks
-- admin re-grants the delegation --
carol writes again                 ALLOW  proof checks
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
the live revocation window, TTL expiry, replica-mode staleness hard cap,
fail-closed write failures, an undecodable-blob refusal, the hostile-input
suite (spoofed proofs, judgment/variable injection, key forgery), and a
10k-distinct-atom intern-DoS regression. Here are the sections it proves:

```bash
luajit examples/pcr/selftest.lua 2>&1 | grep -E '^==|OK — all|FAIL'

```

```output
== proofs that check against the live fact world ==
== the revocation window: identical bytes, next check ==
== fact-store write failures fail closed ==
== TTL facts: expiry is revocation with no revoke call ==
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
would otherwise parse as a Shen type variable, and a grant attempted over a
deliberately corrupted fact blob (which must refuse, not silently reset):

```bash
luajit -e '
package.path = "examples/pcr/?.lua;" .. package.path
local app = require("app")
local owner = "[by-owner [fact owns alice doc1] [fact same-tenant alice doc1]]"
local function try(label, subject, action, resource, proof)
  local ok, reason = app.check(subject, action, resource, proof)
  print(("%-30s %-5s  %s"):format(label, ok and "ALLOW" or "DENY", reason))
end
try("spoof: alices proof, as bob", "bob",   "write", "doc1", owner)
try("uppercase S (a type var)",    "S",     "write", "doc1", owner)
try("unknown principal (mallory)", "mallory","write","doc1", owner)
app.facts._test.corrupt_blob()
local status = app.dispatch("POST", "/admin/grant", {pred="owns", s="alice", r="doc9"})
print(("%-30s HTTP %d  (grant over a corrupt blob is refused, not reset)"):format("corrupt-blob mutate", status))
' 2>&1 | grep -vE "run time|typechecked in|^authz#type"

```

```output
spoof: alices proof, as bob    DENY   proof does not establish (may bob write doc1)
uppercase S (a type var)       DENY   malformed subject/action/resource
unknown principal (mallory)    DENY   unknown subject/action/resource
corrupt-blob mutate            HTTP 507  (grant over a corrupt blob is refused, not reset)
```

## Over the wire

The same `check()` runs behind the OpenResty gate on `/protected/`, driven by
the `X-Subject` / `X-Resource` / `X-Proof` headers. Two workers share one
versioned fact blob, so a revoke through either is seen by both on the next
request. See [`README.md`](README.md) for the full curl transcript — allow,
revoke, identical bytes returning 403 across both workers, surgical survival
of alice's own proof, re-grant — and `nginx.conf` for the server wiring.

Everything above is reproducible: run `showboat verify examples/pcr/DEMO.md`
from the repo root to re-run every block and diff the output against what is
recorded here.
