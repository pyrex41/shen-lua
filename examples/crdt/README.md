# CRDT sync hub — convergence you can prove

A conflict-free replicated data type (CRDT) lets replicas edit independently
and merge with **no coordination**, always converging to the same state. The
correctness rests on three algebraic laws on `merge` — commutativity,
associativity, idempotence — which are exactly the axioms of a
**join-semilattice**. This example puts that merge in one typed Shen file and
shows the laws holding at three increasing levels of assurance.

```
luajit examples/crdt/selftest.lua          # convergence + laws + proofs, no deps
```

To serve the two-replica web demo under OpenResty:

```
mkdir -p examples/crdt/logs
openresty -p "$PWD/examples/crdt" -c nginx.conf
# open http://127.0.0.1:8090/ in two tabs, edit each, Sync — they converge
```

## The data types

| CRDT | what it is | merge (the join) |
|---|---|---|
| **G-Counter** | grow-only counter, per-replica tallies | pointwise `max` |
| **LWW-Register** | a value indivisible from its `(timestamp, id)` clock | greater clock wins |
| **LWW-Map** (`doc`) | a record: field → `LWW-Register` | per-field, merged independently |

The `doc` is the demoable one: two clients edit the same record offline and it
converges field by field. The **register's value cannot exist without its
clock** (it's one datatype), so a merge that "forgets" to compare clocks is not
expressible — the type rules it out.

## Three tiers of assurance

The whole point of this example is that "frightening correctness" is not one
thing — it's a ladder, and you pick the rung the stakes justify.

**(a) Structure — free, always on.** `crdt.shen` loads under `(tc +)`. The
datatypes make illegal states unrepresentable and every merge/value/law
function is proved well-typed before anything runs. Zero extra work.

**(b) Laws by execution — the default.** `gc-commutative?`,
`gc-associative?`, `gc-idempotent?`, their LWW equivalents, and `doc-*` (the
laws for the CRDT the demo actually uses) are ordinary Shen predicates that run
the laws over states, identically on every port. `selftest.lua` runs them two
ways: on a handful of hand-picked states (including adversarial malformed ones —
duplicate keys, clock ties), and then **property-based** over 2000 random states
each (a seeded PRNG, so a failure prints a reproducible counterexample). This
earns its keep: while building the example it caught a real bug where `gc-merge`
duplicated one replica's keys and dropped the other's. Types were perfectly
happy (both results are well-typed `gcounter`s); `gc-commutative? = false` is
what flagged it. That is the exact bug class — silent replica divergence — these
laws exist to kill. Running over thousands of random states, including the
shipped `doc-merge`, is the cheapest way to narrow the model↔code gap that
tier (c) below is honest about not closing.

**(c) Laws by proof — `crdt_laws.shen`.** Universally quantified, no inputs.
The three semilattice laws are encoded as a `datatype` (an equational logic:
`refl`/`sym`/`trans`/`cong` + the axioms), and Shen's sequent-calculus type
checker **verifies a proof term** for each theorem — including a real two-step
derivation of *absorption* (`(join (join a b) b) = (join a b)`: re-merging
already-merged state is a no-op, a convergence/stability fact). A wrong proof
is a type error that aborts the load. Run it and watch the proofs check:

```
bin/shen -e '(tc +) (load "examples/crdt/crdt_laws.shen")'
```

### Honest scope of tier (c)

This is the answer to "is the sequent calculus enough to *prove* things, not
just type them?" — **yes**: free variables in a rule are universally quantified,
`>>` gives hypothetical reasoning, and a proof is a term whose type is the
proposition (Curry–Howard). But be precise about what's proved:

- The three laws are taken as **axioms** here — what any CRDT merge must
  satisfy. Tier (c) proves universal *consequences* of them. Tier (b) is what
  certifies the *executable* `gc-merge` actually satisfies them.
- Re-deriving the axioms from `gc-merge`'s definition (induction over the
  tally-list representation) would *close* the model↔code gap, but that is real
  proof engineering and is deliberately out of scope. Tier (b)'s property run
  *narrows* it — the executable merges are checked on thousands of random states
  — without claiming a universal proof over the representation.
- The trade versus Coq/Agda is **trust, automation, and totality**, not
  expressiveness: you author the logic's rules (and could make them unsound),
  there are no tactics, and Shen does not check termination. What you get is a
  machine-checked derivation a theorem prover would recognize — stronger than
  tests-on-one-host, short of a verified extraction to the running port.

## Files

| file | what it is |
|---|---|
| `crdt.shen` | the typed kernel: G-Counter, LWW-Register, LWW-Map, merges, and the tier-(b) law checks (`gc-*`, `lww-*`, `doc-*`). Pure portable Shen — the same source every port runs. |
| `crdt_laws.shen` | tier (c): the equational logic + machine-checked proofs of the merge laws. |
| `app.lua` | OpenResty glue: marshals the JSON document ↔ the Shen `doc`, calls `doc-merge` as the authoritative convergence point, stores the canonical doc in a `lua_shared_dict`. |
| `nginx.conf` | serves the API and the two-replica page; boots Shen once per worker. |
| `selftest.lua` | runs convergence (sync in different orders → identical doc), the tier-(b) laws (hand-picked + property-based over 2000 random states each), and the tier-(c) proof load — no nginx, no network. |
| `public/index.html` | two replicas you edit offline and Sync; they converge. |
| `json_shim.lua` | a tiny JSON codec for running off-nginx (OpenResty bundles cjson). |
