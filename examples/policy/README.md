# Authorization gateway — one typed rule set, enforced and proved

Authorization is the textbook drift bug: the edge, the service, and the admin
UI each re-implement "who may do what", and they disagree. Here it is **one
typed Shen file**, loaded under `(tc +)`, that runs as the edge enforcement
gate *and* drives a live preview UI — and whose model has a second life as a
logic where **a permission is a proof term**.

```
luajit examples/policy/selftest.lua        # decisions + permission proofs, no deps
```

Serve the gateway + explorer under OpenResty:

```
mkdir -p examples/policy/logs
openresty -p "$PWD/examples/policy" -c nginx.conf
# open http://127.0.0.1:8091/  — set subject/action/resource, watch the verdict
```

The same `decide()` guards `/protected/` as an `access_by_lua` gate:

```
# allowed (admin in tenant t1):
curl -i -H 'X-Subject: boss' -H 'X-Role: admin' -H 'X-Tenant: t1' \
     -H 'X-Res-Owner: ada' -H 'X-Res-Tenant: t1' localhost:8091/protected/
# denied (cross-tenant) — 403 with the reason:
curl -i -H 'X-Subject: boss' -H 'X-Role: admin' -H 'X-Tenant: t2' \
     -H 'X-Res-Owner: ada' -H 'X-Res-Tenant: t1' localhost:8091/protected/
```

## The two halves

**`policy.shen` — the decision engine (what the edge runs).** Typed datatypes
for `principal`, `resource`, and `decision`; a total `decide` function that
returns allow/deny **with the reason**. Tenant isolation is checked first and
is absolute — no role, not even admin, crosses a tenant boundary. Because the
type checker proves `decide` covers every case, "what about this combination?"
has an answer at compile time, not in an incident.

**`policy_proof.shen` — authorization as type inhabitation (the idea with
teeth).** The same model as a logic: a term of type `(may S A R)` is a *proof*
that subject `S` may take action `A` on resource `R`. Grant rules are inference
rules; ownership/role/tenancy facts are axioms. Then:

- a request is **authorized exactly when `(may S A R)` is inhabited**, and the
  inhabiting term is the justification — a checkable audit trail of *why*;
- a **denied** request is an **uninhabited type** — no rule builds the term, so
  it cannot typecheck. "Deny by default" is not a line you can forget to write;
  it is the absence of a proof. (`perm-bob-delete`, commented out, is a type
  error if you uncomment it.)

This is the same sequent-calculus mechanism the CRDT example uses for its merge
laws (see `examples/crdt/`), pointed at access control. The honest scope is the
same too: the proof certifies the request against the *encoded* rules and facts;
trusting it means trusting that encoding (you author the rules, there are no
tactics, totality isn't enforced). It is stronger than a runtime `if`, short of
a Coq-extracted gate.

## Files

| file | what it is |
|---|---|
| `policy.shen` | the typed decision engine: `principal`/`resource`/`decision`, `decide`, `allowed?`, `why`. Portable — the edge and a ShenScript preview run the same source. |
| `policy_proof.shen` | authorization as type inhabitation: grant rules, facts, and permissions as checked proof terms. |
| `app.lua` | OpenResty glue: the `/api/check` preview endpoint and the `/protected/` `access_by_lua` enforcement gate, both calling `decide`. |
| `nginx.conf` | wires the API, the gate, and the explorer page; boots Shen once per worker. |
| `selftest.lua` | drives `decide` over a request table and loads the permission proofs — no nginx, no network. |
| `public/index.html` | the live explorer: pick a triple, see the verdict and reason. |
| `json_shim.lua` | a tiny JSON codec for running off-nginx. |
