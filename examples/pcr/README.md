# Proof-carrying requests, over live facts

An authorization gateway where the client **carries the proof** and the edge
only **checks** it — against the facts current at *this* request. Every
request to `/protected/` presents a proof term in `X-Proof`; the gate builds
the judgment `(may SUBJECT ACTION RESOURCE)` and asks Shen's sequent-calculus
typechecker whether the presented term inhabits it. Fact leaves are discharged
against a **versioned live fact store** at check time, so granting a fact
makes proofs start checking, and revoking it makes the *same proof bytes*
stop checking on the very next request — on every worker. Allowed requests
log the proof, the fact-world version, and the exact fact leaves consumed:

```
authorized (may carol write doc1) by [by-delegation [by-owner [fact owns alice doc1]
  [fact same-tenant alice doc1]] [fact delegates alice carol]]
  (50 inferences, facts v1, leaves (owns alice doc1) (same-tenant alice doc1) (delegates alice carol))
```

```
luajit examples/pcr/selftest.lua          # everything below, off-nginx
SHEN_TYPECHECK_NATIVE=off luajit examples/pcr/selftest.lua   # engine-parity leg

mkdir -p examples/pcr/logs                # or serve it:
openresty -p "$PWD/examples/pcr" -c nginx.conf
```

## Check, don't search — and facts are live

Two asymmetries make this affordable and correct at request time:

* **Checking a given term** against a given type is bounded by the term's
  size; *searching* for a proof is the open-ended direction, and it never
  runs at request time. The client obtained its proof earlier — the gate's
  whole per-request price is one bounded check (~540 µs warm for the
  delegation proof, ~1.9k checks/sec/core, parse-dominated).
* **The engine memoizes no answers.** The only caches in either engine hold
  translated clause *code*, never derivations, so a fact leaf consults the
  store on every check and a revoked fact **cannot** keep proving. Verified:
  toggling a fact flips the same proof true/false on every toggle, under
  both engines, with identical inference counts.

Facts stop being axioms in the rules. One rule replaces them all
(`rules.shen`):

```
if (pcr.fact? Pred S R)
________________________
[fact Pred S R] : (Pred S R);
```

The leaf carries its ground triple — `[fact owns alice doc1]` — because a
side condition can only **check** values, never bind them: unification of
the leaf against the client's proof term grounds `Pred`, `S`, `R` before the
guard runs (a bare-token leaf breaks under `by-delegation`, where `S` is not
in the final judgment). It also makes every leaf a self-describing audit
claim.

## The revoke-then-deny transcript

```
# carol acts under alice's delegation — the nested proof is the audit chain:
$ curl -i -H 'X-Subject: carol' -H 'X-Resource: doc1' \
    -H 'X-Proof: [by-delegation [by-owner [fact owns alice doc1] [fact same-tenant alice doc1]] [fact delegates alice carol]]' \
    -X POST localhost:8093/protected/
HTTP/1.1 200 OK        X-Facts-Version: 1
# (start with PCR_DEBUG_HEADERS=1 to also get X-Proof-Checked: 50 inferences)

# revoke the delegation (admin, localhost only):
$ curl -X POST localhost:8093/admin/revoke -d '{"pred":"delegates","s":"alice","r":"carol"}'
{"ok":true,"version":2}

# the IDENTICAL bytes now fail — verified across both nginx workers,
# 30 concurrent requests, zero grace:
$ curl -i ... same request ...
HTTP/1.1 403 Forbidden
{"error":"forbidden","reason":"proof does not establish (may carol write doc1)"}

# surgical: alice's own ownership proof still passes:
$ curl -i -H 'X-Subject: alice' ... -H 'X-Proof: [by-owner [fact owns alice doc1] [fact same-tenant alice doc1]]' ...
HTTP/1.1 200 OK

# re-grant, and carol's original curl works again:
$ curl -X POST localhost:8093/admin/grant -d '{"pred":"delegates","s":"alice","r":"carol"}'
{"ok":true,"version":3}
```

A fact value may also be a **number** — an absolute expiry checked against
the live clock per request. A time-limited grant is then revocation with no
revoke call at all (selftest: "TTL facts").

## The staleness contract

All fact state lives in **one atomically-written blob** —
`{version, synced_at, facts}` in a single `lua_shared_dict` value — decoded
into a per-worker snapshot revalidated on every request (one shm get; decode
only on change). One blob means one epoch: a check can never mix two fact
worlds, an evicted or undecodable blob is a **deny**, and `synced_at`
travels inside the blob so freshness can never be stamped by a failed sync.

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

## Threat model (the proof is hostile input)

| attack | defense |
|---|---|
| present someone else's proof | bound to the **exact judgment**: alice's proof does not establish `(may bob write doc1)` |
| mint a fact or a grant | fact leaves pass a **predicate allowlist** (`owns`, `same-tenant`, `has-role`, `delegates`) — a leaf can never assert `(may ...)`; and the store, not the proof, decides whether the fact holds |
| smuggle a judgment inside the proof | proof tokenizer rejects unknown tokens (incl. `:`); underneath it, `shen.typecheck` reads one `"PROOF : TYPE"` triple and rejects any other shape |
| forge a store key | guard rejects any atom containing `/` (and all non-`[%w-._]` chars) before the lookup |
| smuggle Shen type variables as data | external atoms must be lowercase-starting (`[a-z][a-z0-9-._]*`); uppercase `S`/`A`/`R` are rejected even if they appear in the fact world |
| intern-table exhaustion (the symbol table is permanent, ~194 B/symbol) | **nothing reaches the reader un-vetted**: subject/action/resource and every proof token must be static vocabulary or an atom of the current fact world. The fact world is written only by admin grants, so the admissible-atom set is operator-controlled — an attacker's novel atoms are rejected before `read-from-string`. Selftest sends 10k distinct hostile atoms and the heap does not grow. |
| unbound-variable leaf `[fact owns X doc1]` | unbound vars reach the guard as non-strings — fail closed |
| adversarially deep / oversized terms | per-check `*maxinferences*` budget + byte cap |
| store outage mid-check | a throwing guard becomes a trapped error — deny, next request unaffected |

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
and — for the demo — headers standing in for an authenticated subject
(production: a verified JWT/session; the *proof* is exactly where it
belongs, presented by the client).

## Files

| file | what it is |
|---|---|
| `rules.shen` | the logic: ONE live-fact rule + grant rules (owner, member-read, delegation) |
| `facts.lua` | the versioned fact store: atomic epoch blob, snapshot, TTL facts, the guard, replica-pull stub |
| `app.lua` | the gateway: pre-intern gates, judgment construction, the check, admin endpoints, the audit line |
| `selftest.lua` | allow/deny/revocation-window/TTL/staleness/hostile-input/intern cases + timing, off-nginx |
| `nginx.conf` | two workers sharing one fact blob; the curl walkthrough |
