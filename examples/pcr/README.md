# Proof-carrying requests: who authorized your agent's tool call?

Your agent spawned a subagent, and the subagent just called your CRM. Three
questions every platform team hits within a week of shipping that:

* **What authority justified this exact call?** A log line saying `200 OK`
  is not an answer — and neither OAuth scopes nor a policy engine's boolean
  preserves the chain *user → agent → subagent* that actually made the call
  legitimate.
* **Can a subagent get *less* power than the agent that spawned it** —
  attenuation, without minting new credentials at every spawn?
* **When you kill one delegation, does everything downstream of it die** —
  instantly, mid-run — **while everything else keeps working?**

This demo answers all three with one move: **the tool call carries its own
authorization.** The caller presents a proof term in `X-Proof`; the gateway
*checks* it — never searches for it — against the facts current at *this*
request. If TLS is how a server learns *who* (the presenter carries the
certificate chain; the verifier checks it against trusted roots and live
revocation), this is the same architecture for *may*: the caller carries the
authority chain, the gateway checks it against operator-controlled rules and
live, revocable facts.

```
alice (human) ──owns──> crm-contacts
  └─ delegates (full) ──> orchestrator            her agent session
       └─ delegates-read (ATTENUATED) ──> researcher   the subagent it spawned
```

The researcher's request presents a proof whose *shape is the delegation
chain itself* — assembled at runtime, by the runtime, out of edges the
gateway never saw pre-assembled:

```
X-Proof: [by-read-delegation
           [by-delegation
             [by-owner [fact owns alice crm-contacts] [fact same-tenant alice crm-contacts]]
             [fact delegates alice orchestrator]]
           [fact delegates-read orchestrator researcher]]
```

The gate builds the judgment `(may researcher read crm-contacts)` and asks
Shen's sequent-calculus typechecker whether the presented term inhabits it.
Every `[fact ...]` leaf is discharged against a **versioned live fact store**
at check time. An allowed call logs the proof, the fact-world version, and
the exact facts consumed — so "what authority justified this call?" is
answered by the audit line, months later, offline:

```
authorized (may researcher read crm-contacts) by [by-read-delegation ...]
  (71 inferences, facts v1, leaves (owns alice crm-contacts)
   (same-tenant alice crm-contacts) (delegates alice orchestrator)
   (delegates-read orchestrator researcher))
```

```
luajit examples/pcr/selftest.lua          # everything below, off-nginx
SHEN_TYPECHECK_NATIVE=off luajit examples/pcr/selftest.lua   # engine-parity leg

mkdir -p examples/pcr/logs                # or serve it:
openresty -p "$PWD/examples/pcr" -c nginx.conf
```

An executable walkthrough lives in [`DEMO.md`](DEMO.md): `showboat verify
examples/pcr/DEMO.md` (from the repo root) re-runs every block — the
three-hop chain, the attenuation denials, the mid-run revocation, the full
battery, the hostile-input defenses — and diffs the output against what is
recorded.

## The transcript: allow, attenuate, revoke mid-run

```
# the researcher subagent reads the CRM — its proof IS the delegation chain:
$ curl -i -H 'X-Subject: researcher' -H 'X-Resource: crm-contacts' \
    -H 'X-Proof: [by-read-delegation [by-delegation [by-owner [fact owns alice crm-contacts] [fact same-tenant alice crm-contacts]] [fact delegates alice orchestrator]] [fact delegates-read orchestrator researcher]]' \
    localhost:8093/protected/
HTTP/1.1 200 OK        X-Facts-Version: 1
# (start with PCR_DEBUG_HEADERS=1 to also get X-Proof-Checked: 71 inferences)

# attenuation: the SAME proof cannot escalate to a write (POST maps to write) —
# delegates-read can only ever conclude (may _ read _), so there is NO term
# the researcher can construct for a write judgment; the type system, not a
# runtime filter, is what says no:
$ curl -i ... same headers ... -X POST localhost:8093/protected/
HTTP/1.1 403 Forbidden
{"error":"forbidden","reason":"proof does not establish (may researcher write crm-contacts)"}

# incident: kill the agent session's authority (admin, localhost only):
$ curl -X POST localhost:8093/admin/revoke -d '{"pred":"delegates","s":"alice","r":"orchestrator"}'
{"ok":true,"version":2}

# the researcher's IDENTICAL proof bytes now fail — the whole subtree built
# through that edge is dead on the very next request, on every worker,
# 30 concurrent requests, zero grace:
$ curl -i ... the researcher's original request ...
HTTP/1.1 403 Forbidden
{"error":"forbidden","reason":"proof does not establish (may researcher read crm-contacts)"}

# surgical: alice's own proof never used that edge — she keeps working:
$ curl -i -H 'X-Subject: alice' -H 'X-Resource: crm-contacts' \
    -H 'X-Proof: [by-owner [fact owns alice crm-contacts] [fact same-tenant alice crm-contacts]]' \
    -X POST localhost:8093/protected/
HTTP/1.1 200 OK

# re-grant, and the researcher's original curl works again:
$ curl -X POST localhost:8093/admin/grant -d '{"pred":"delegates","s":"alice","r":"orchestrator"}'
{"ok":true,"version":3}
```

A fact value may also be a **number** — an absolute expiry checked against
the live clock per request. A time-boxed agent session (a one-hour on-call
grant) is then revocation with no revoke call at all (selftest: "TTL facts").

## Why the caller carries the proof

* **The chain exists at the caller, not the server.** Agent runtimes create
  delegation edges dynamically — an orchestrator spawns a researcher that
  didn't exist five seconds ago. Server-side policy evaluation (OPA, Zanzibar)
  must have the whole graph shipped to it and *search* it per request; here
  the runtime hands each spawned agent its proof (parent proof + one rule
  application), and the gateway's whole per-request price is one **bounded**
  check — bounded by the term's size, ~750 µs warm for the three-hop chain
  (~1.3k checks/sec/core, parse-dominated). Searching is the open-ended
  direction, and it never runs at request time.
* **The proof is the audit artifact.** A policy engine logs a boolean; this
  logs the *derivation* — who authorized what through whom, against which
  fact-world version — replayable offline against an archived fact world.
* **Capability ergonomics without the capability flaw.** The proof travels
  like a bearer capability (composable, attenuable offline), but every leaf
  re-grounds against live facts, so revocation is instant — the classic
  weakness of macaroon/Biscuit-style tokens, closed.

## Why this is sound

### Check, don't search — and facts are live

**The engine memoizes no answers.** The only caches in either engine hold
translated clause *code*, never derivations, so a fact leaf consults the
store on every check and a revoked fact **cannot** keep proving. Verified:
toggling a fact flips the same proof true/false on every toggle, under both
engines, with identical inference counts.

Facts stop being axioms in the rules. One rule replaces them all
(`rules.shen`):

```
if (pcr.fact? Pred S R)
________________________
[fact Pred S R] : (Pred S R);
```

The leaf carries its ground triple — `[fact owns alice crm-contacts]` —
because a side condition can only **check** values, never bind them:
unification of the leaf against the client's proof term grounds `Pred`, `S`,
`R` before the guard runs (a bare-token leaf breaks under `by-delegation`,
where `S` is not in the final judgment). It also makes every leaf a
self-describing audit claim.

Attenuation is likewise a *rule*, not a filter: `by-read-delegation`'s only
possible conclusion is `(may T read R)`, so a principal holding only a
`delegates-read` edge cannot construct a write proof at all — the selftest's
"forged chain" case shows the stronger claim: a proof that *shape-checks*
under full `by-delegation` still dies because the store, not the proof,
decides whether `(delegates orchestrator researcher)` holds.

### The staleness contract

All fact state lives in **one atomically-written blob** —
`{version, synced_at, facts}` in a single `lua_shared_dict` value — decoded
into a per-worker snapshot revalidated on every request (one shm get; decode
only on change). One blob means one epoch: a check can never mix two fact
worlds, an evicted or undecodable blob is a **deny** on the read side and a
**refused write** on the mutate side (a grant/revoke over an undecodable blob
returns an error rather than silently resetting the fact world and rewinding
the version), and `synced_at` travels inside the blob so freshness can never
be stamped by a failed sync.

* **Demo (authoritative mode):** `/admin` writes the blob synchronously —
  staleness is structurally zero; the next check anywhere sees the new
  world. Grant/revoke endpoints return success only after the blob write
  succeeds; shared-dict pressure or another persistence failure returns a
  non-200 JSON error and leaves the previous fact world in force.
* **Production (replica mode):** the store mirrors an external DB via a
  periodic pull of period `W` (stub in `facts.lua`; `synced_at` is stamped
  only inside a *successful* pull and successful blob write). A revoked fact
  stops authorizing within `W`. The window is **hard-capped at 3W**: when
  `now − synced_at > 3W` the gate denies everything — a partitioned DB, dead
  timer, failed write, or evicted blob degrades to denial, never to frozen
  grants (selftest: "replica mode").

**New Enemy analysis** (Zanzibar's framing): variant 1 — a check against
pre-revocation facts — is bounded by `W` and cannot be extended by caching
(no derivation memoization exists). Variant 2 — an *old fact world* applied
to *new content* — is **not** closed by default: within `W`, content written
and immediately re-ACLed can be served under facts up to `W` stale relative
to that write. The named path to closing it is zookie-style: content stores
the `facts_version` at write time, and the gate requires the judgment's
version ≥ it — the numeric version already in every audit line makes that
implementable. Archiving `{version, facts}` per bump makes any logged
`(proof, judgment, version)` triple offline-replayable.

### Threat model (the proof is hostile input)

| attack | defense |
|---|---|
| present someone else's proof | bound to the **exact judgment**: alice's proof does not establish `(may bob write crm-contacts)` |
| escalate past an attenuated grant | `by-read-delegation` can only conclude `read`; a forged full-delegation leaf is decided by the **store**, not the proof |
| mint a fact or a grant | fact leaves pass a **predicate allowlist** (`owns`, `same-tenant`, `has-role`, `delegates`, `delegates-read`) — a leaf can never assert `(may ...)`; and the store, not the proof, decides whether the fact holds |
| smuggle a judgment inside the proof | proof tokenizer rejects unknown tokens (incl. `:`); underneath it, `shen.typecheck` reads one `"PROOF : TYPE"` triple and rejects any other shape |
| forge a store key | guard rejects any atom containing `/` (and all non-`[%w-._]` chars) before the lookup |
| smuggle Shen type variables as data | external atoms must be lowercase-starting (`[a-z][a-z0-9-._]*`); uppercase `S`/`A`/`R` are rejected even if they appear in the fact world |
| intern-table exhaustion (the symbol table is permanent, ~194 B/symbol) | **nothing reaches the reader un-vetted**: subject/action/resource and every proof token must be static vocabulary or an atom of the current fact world. The fact world is written only by admin grants, so the admissible-atom set is operator-controlled — an attacker's novel atoms are rejected before `read-from-string`. Selftest sends 10k distinct hostile atoms and the heap does not grow. |
| unbound-variable leaf `[fact owns X crm-contacts]` | unbound vars reach the guard as non-strings — fail closed |
| adversarially deep / oversized terms | per-check `*maxinferences*` budget + byte cap |
| store outage mid-check | a throwing guard becomes a trapped error — deny, next request unaffected |

### Engine parity and trusted base

**Engine parity is a tested invariant, not an assumption**: side-condition
rules MUST go through the typed `lua.function` bridge (a raw `P.F` side
condition was observed to pass the native engine and fail CPS for a
byte-identical rule); the parity selftest leg asserts identical verdicts
*and inference counts* under `SHEN_TYPECHECK_NATIVE=off`.

Two conventions the implementation depends on: the bridge captures the
function **value** at registration, so `pcr.factq` is a stable trampoline
into mutable `facts.lua` state (never reassigned); and fact-base *reloading
as datatypes* is disqualified by measurement (hundreds of ms per reload, a
permanent per-reload leak, and a compiler wall near 200 axioms) — the
datatype compiles once, the *store* is what changes.

What remains trusted: the rules file, `facts.lua` + the ~40-line gate glue,
and — for the demo — headers standing in for an authenticated principal
(production: a verified JWT/session for a human, workload identity for an
agent; the *proof* is exactly where it belongs, presented by the caller).

## Files

| file | what it is |
|---|---|
| `rules.shen` | the logic: ONE live-fact rule + grant rules (owner, member-read, full delegation, **attenuated read-only delegation**) |
| `facts.lua` | the versioned fact store: atomic epoch blob, snapshot, TTL facts, the guard, replica-pull stub |
| `app.lua` | the gateway: pre-intern gates, judgment construction, the check, admin endpoints, the audit line |
| `selftest.lua` | allow/attenuation/revocation-window/TTL/staleness/hostile-input/write-failure/corrupt-blob/intern cases + engine-parity + timing, off-nginx |
| `nginx.conf` | two workers sharing one fact blob; the curl walkthrough |
| `DEMO.md` | an executable showboat walkthrough — every block re-runs and diffs under `showboat verify` |
