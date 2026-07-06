# Proof-carrying requests

An authorization gateway where the client **carries the proof** and the edge
only **checks** it. Every request to `/protected/` presents a proof term in
`X-Proof`; the gate builds the judgment `(may SUBJECT ACTION RESOURCE)` from
the request and asks Shen's sequent-calculus typechecker whether the presented
term inhabits it. No proof that checks, no access — and every allowed request
is logged **with its proof**: the audit trail is the justification itself,
machine-checked at the moment of use.

```
luajit examples/pcr/selftest.lua          # everything below, off-nginx

mkdir -p examples/pcr/logs                # or serve it:
openresty -p "$PWD/examples/pcr" -c nginx.conf
```

## The idea: check, don't search

[`examples/policy/policy_proof.shen`](../policy/policy_proof.shen) shows
authorization as type inhabitation — a permission *is* a proof, checked
offline when the file loads. This example promotes that from a demonstration
to a **wire protocol**, and the move that makes it affordable at request time
is an asymmetry:

* **Searching** for a proof (is `(may S A R)` inhabited at all?) is the
  open-ended, expensive direction.
* **Checking** a *given* term against a *given* type is bounded by the size
  of the term.

So search never runs at request time. The client obtained its proof earlier —
at token issuance, from a policy service, or built from the same rules
client-side (the [`openresty/`](../openresty/) example runs Shen rules in the
browser) — and the gate's entire per-request cost is one bounded check:
the demo's deepest proof (a delegation chain) checks in **50 inferences,
~400 µs warm** on this port, several thousand checks per second per core.
That fits anywhere an LLM call, a database query, or a network hop is already
in the loop — agent/MCP tool gates, internal APIs, admin planes.

## Proofs compose: delegation as an audit chain

The payoff of carrying proofs instead of booleans or bearer scopes is that
proofs **compose**. `rules.shen` has a delegation rule:

```
P : (may S A R); Q : (delegates S T);
=====================================
[by-delegation P Q] : (may T A R);
```

so carol's authority to write `doc1` is the *nested* term

```
[by-delegation [by-owner [owns-fact] [alice-tenant]] [deleg-fact]]
```

— readable, machine-checked provenance: carol may write **because** alice
delegated to her **and** alice owns it **and** alice is in the resource's
tenant. A bearer token says *that* you may; a proof term says *why*, and the
why is re-verified on every use. Swap the inner proof for bob's read-only one
and the chain no longer connects (`[deleg-fact]` proves `(delegates alice
carol)`, not bob) — the check fails. Run the selftest to see it.

## Threat model (the proof is hostile input)

The proof term is attacker-controlled, so the gate treats it accordingly —
each line is a selftest case:

| attack | defense |
|---|---|
| present someone else's proof | a proof is bound to the **exact judgment**: alice's ownership proof does not establish `(may bob write doc1)` — denied |
| smuggle a different judgment inside the proof string | `shen.typecheck` reads `"PROOF : TYPE"` as one triple and rejects any other shape — denied as malformed |
| inject syntax through subject/action/resource | judgment atoms pass a bare-symbol whitelist before the reader ever sees them — parens, brackets, colons, whitespace never reach the type |
| unreadable / unbalanced term | reader error is trapped — fail closed |
| adversarially deep term | `*maxinferences*` acts as a **per-check budget** (the helper resets the counter per call) — fail closed, next request unaffected |
| oversized term | byte cap before parsing |
| evaluate something | proofs are **read, never evaluated** — a term is syntax judged by the typechecker |

What remains trusted: the rules file (loaded under `(tc +)` at worker start),
the ~30-line gate glue, and — for this demo — the headers standing in for an
authenticated subject. In production the subject comes from a verified
JWT/session; the *proof* is exactly where it belongs, presented by the client.

## The two tiers compose

This is the runtime half of a staged architecture. For decisions over a
**finite, statically known** domain, compile the policy to a certified
decision procedure at deploy time and pay nanoseconds per request (the
[`policy/`](../policy/) example's `decide` is that tier). Proof-carrying
requests are the tier for what that cannot cover: judgments over **dynamic
data** — delegation chains, per-request facts, open-ended agent tool calls —
where enumeration is impossible but checking a presented justification is
cheap, bounded, and leaves an audit artifact.

## Files

| file | what it is |
|---|---|
| `rules.shen` | the logic: facts, grant rules, delegation — a term of `(may S A R)` is a permission |
| `app.lua` | the gateway: judgment construction, hostile-input handling, the check, the audit log |
| `selftest.lua` | every allow/deny/attack case off-nginx, plus the warm timing loop |
| `nginx.conf` | the OpenResty wiring and curl walkthrough |
