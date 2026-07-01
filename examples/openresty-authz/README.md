# Durable multi-tenant authorization in Shen, on OpenResty

A companion to [`examples/openresty`](../openresty) (the guestbook). That one
shows the *shape* of a Shen web app and shares one typed `rules.shen` between
server and browser. This one goes after a harder problem — **authorization** —
and answers a specific design question:

> Can we get [Shen-Backpressure][sb]'s "move the invariant into a structure the
> agent cannot bypass" idea for a real, running authz endpoint — with the policy
> as a proof chain, decisions that are durable and auditable — **without**
> bolting on a new engine?

Short answer: yes, by reusing three things shen-lua already has — the
sequent-calculus typechecker, the native Prolog engine, and the Lua bridge —
and adding one small durable, event-sourced store.

[sb]: https://reubenbrooks.dev/blog/structural-backpressure-beats-smarter-agents/

```
examples/openresty-authz/
  authz.shen     the TYPED core (tc +): the `decision` verdict and the guarded
                 projection `render-doc` — content can only be serialized out of
                 a [granted ...] witness. Proved total at load time.
  app.shen       the policy (tc -): the authz PROOF CHAIN as Prolog rules, plus
                 the router. Leaf facts are read from the durable store.
  store.lua      durable, event-sourced fact store + append-only proof log.
                 File backend (tested) and an lua-resty-lmdb backend (production).
  app.lua        the glue: boots Shen, wires host bridges, marshals JSON <-> val.
  selftest.lua   drives the whole thing under plain luajit — no nginx needed.
  nginx.conf     OpenResty config: boot once per worker, replay the log, serve.
```

## Try it without nginx

```sh
luajit examples/openresty-authz/selftest.lua
```

It provisions two tenants over the JSON API, runs the proof chain (grants,
cross-tenant denials, editor-only writes, a revocation), then **reopens the
store from its on-disk log** to prove the facts and the audit trail survive a
restart, and finally prints the durable decision log.

## The policy is a proof chain (Shen-Backpressure, at runtime)

Shen-Backpressure encodes multi-tenant access as a chain where each step must
hold before the next can be built: `token → authenticated user → tenant
membership → resource access`. Here that chain is a Prolog rule in `app.shen`:

```
(defprolog can-read
  Tok R <-- (is U (host-token-user (receive Tok)))   \\ token -> user
            (when (not (= U "")))                     \\ ...authenticated
            (is T (host-owner-tenant (receive R)))    \\ resource -> tenant
            (when (not (= T "")))
            (when (host-member? U T))                 \\ user in that tenant
            (when (not (host-revoked? U (receive R)))); )
```

`can-write` is the same chain plus `(when (host-role? U T "editor"))`. The rule
**is** the policy — one place, read top to bottom.

The structural-backpressure half lives in the typed core (`authz.shen`). A
`decision` is either `[granted U T R]` or `[denied Why]`, and `render-doc` is a
*total* function over `decision` that places document content in the response
for `[granted ...]` **and no other shape**:

```
(define render-doc
  {decision --> string --> val}
  [granted U T R] Content -> [obj [... ["content" [s Content]] ...]]
  [denied Why] _          -> [obj [["ok" [b false]] ["error" [s Why]]]])
```

Shen's typechecker verifies that totality at load time, so "a document reached
the client" implies "a `granted` witness was constructed." That is
Shen-Backpressure's `shengen` guard-type idea — the constructor is the only path
to a populated value — moved to a **runtime witness** because the facts
(memberships, ownership) are dynamic. It is the honest version of the guarantee:
the *shape* is enforced by types; the *decision* is enforced by the one gate
(`authorize-*`) that every path must go through to obtain a `decision`.

## Why Prolog, and not a Datalog engine

Datalog is a subset of Prolog: ground facts, no compound terms in recursion,
"safe" rules. Authorization rules are exactly that shape, so the temptation is
to add a Datalog engine. We didn't, on purpose:

- **shen-lua already ships a Prolog engine** (`defprolog` / `(prolog? ...)`, the
  FFI/int32 soa32 machine — see [`examples/family.shen`](../family.shen)). The
  authz rules stay inside the Datalog fragment *by discipline*, so they
  terminate and stay decidable without a second engine.
- **A ground authz query wants top-down evaluation.** You ask one specific goal
  — `can-read? this-token this-resource` — which is SLD resolution's sweet spot.
  A Datalog engine optimizes the opposite job: materializing *all* derivable
  facts bottom-up. For "is this one request allowed?", Prolog is the better fit,
  not a compromise.
- **The one thing worth borrowing from Datalog** — stratified negation for
  deny/revoke rules — we take carefully: negation only on *ground* goals
  (`(not (host-revoked? U R))` with `U`, `R` bound), which is well-defined.

The facts are **not** asserted into the engine. Prolog composes; the durable
store supplies each leaf fact through `lua.call` (`host-member?`,
`host-owner-tenant`, …). So the store stays the single source of truth and no
per-worker fact cache can drift.

## Durable execution: the log is the state

`store.lua` is **event-sourced**. Every mutation (grant, revoke, create) and
every authorization decision is appended to a log; the in-memory view everyone
reads is a *cache* rebuilt by replaying that log on open. That is the
durable-execution property, stated plainly:

> Kill the process, reopen the same log, replay — you are in the exact same
> state, facts **and** audit trail. Nothing lives only in RAM.

`selftest.lua` demonstrates it literally: it builds up state, throws the store
object away, constructs a fresh one over the same file, and shows a prior
revocation still denies access.

Two backends sit behind one `append` + `each` interface:

- **file** — append-only JSONL on disk. Durable across restarts; this is the
  path `selftest.lua` and CI exercise under plain LuaJIT.
- **lmdb** — the same log in [`lua-resty-lmdb`][lmdb] (memory-mapped, MVCC,
  ACID, zero-copy FFI reads — the store Kong ships). Production path under
  OpenResty; `nginx.conf` shows the two-line swap.

[lmdb]: https://github.com/openresty/lua-resty-lmdb

The decision events double as the **discharge report** from Shen-Backpressure:
`GET /api/audit` returns, for every decision, which premise carried it or which
one failed (`not a member of tenant acme`, `requires the editor role`, `access
… was revoked`). "Why was this allowed?" is answerable from durable state.

## Leaning on LuaJIT

- The Prolog engine is the FFI/int32 soa32 machine — no boxing on the reasoning
  hot path; it JITs.
- `authorize` is, per request, a handful of plain-hash-table lookups (the
  materialized view) plus one ground Prolog query. The log append — the only
  allocation-heavy step — is off the read/decide path.
- Kernel boot + the typed load of `authz.shen` happen **once per worker** in
  `init_worker_by_lua`, never per request; log replay happens once at that boot.
- Under the lmdb backend, fact reads are zero-copy through the resty.lmdb FFI.

## Running under OpenResty

```sh
mkdir -p examples/openresty-authz/logs
openresty -p "$PWD/examples/openresty-authz" -c nginx.conf
```

The worker seeds a demo world on first boot (tokens `tok-admin`, `tok-alice`,
`tok-bob`, `tok-carol`; tenants `acme`/`globex`; docs `doc-1`/`doc-2`).

```sh
# alice (editor@acme) reads an acme doc — granted
curl -s localhost:8080/api/read  -d '{"token":"tok-alice","resource":"doc-1"}'
# carol (no membership) — denied, with the discharge report
curl -s localhost:8080/api/read  -d '{"token":"tok-carol","resource":"doc-1"}'
# bob (viewer) cannot write — needs the editor role
curl -s localhost:8080/api/write -d '{"token":"tok-bob","resource":"doc-1","content":"x"}'
# the durable decision log
curl -s localhost:8080/api/audit
```

## Things to know before building on this

- **Single worker as written.** The materialized view is per-worker state, so
  with `worker_processes > 1` a mutation on one worker is not visible to another
  until it re-replays. LMDB gives you the shared, durable substrate to fix that
  (re-read on its txn id, or query it directly); the file backend does not.
- **Tokens stand in for JWTs.** `host-token-user` is a table lookup here; in
  production it verifies a signature and returns the subject. The proof chain
  above is unchanged — only the leaf fact gets more honest.
- **Never use Shen's blocking file I/O under nginx.** The file backend is for
  the off-nginx demo; under OpenResty use the lmdb backend (or reach a DB via
  the non-blocking cosocket libraries), exactly as the guestbook README warns.
