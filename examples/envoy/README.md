# Shen at the edge: Envoy in front of two Shen services

The third piece of the web trilogy. [`examples/openresty`](../openresty) is a
Shen web app; [`examples/openresty-authz`](../openresty-authz) is Shen
authorization as a proof chain. This example puts **[Envoy](https://www.envoyproxy.io)**
— the standard edge/mesh proxy — in front of both, and uses each of Envoy's two
integration seams for exactly what it is good at:

1. **`ext_authz` → the authz app.** Envoy sends every API request (method +
   path + `authorization` header, no body) to the authz service *before*
   routing it. The Prolog proof chain decides; a denial returns the discharge
   report to the client; and **every edge decision lands in the same durable
   audit log** as a direct API call. No authorization code lives in the proxy.

2. **A Lua filter → `rules.shen` inside the proxy.** Envoy's Lua filter embeds
   LuaJIT — shen-lua's primary host — so the guestbook's typed field rules run
   *in the proxy itself*: a malformed POST gets its 400 **at the edge**, with
   the same typed error strings the browser and the origin produce, before it
   costs an upstream hop.

Which makes it one `rules.shen`, enforced on **four hosts** from one typed
source: the browser (ShenScript, Ratatoskr-shaken), the Envoy edge (shen-lua on
Envoy's LuaJIT), the origin (shen-lua on OpenResty), and plain `luajit` in the
selftests. Proved sound by the sequent-calculus typechecker wherever shen-lua
loads it.

```
examples/envoy/
  envoy.yaml     the edge: ext_authz (→ authz app) + the Lua filter + routing
  filter.lua     Shen in the proxy — boots shen-lua once per worker thread,
                 loads ../openresty/rules.shen under (tc +), 400s bad bodies
  authz.conf     the authz app as ext_authz backend: same app as
                 examples/openresty-authz, on :8081, seeding a "guestbook"
                 resource (run with -p examples/envoy so its log lives here)
  selftest.lua   the whole three-layer pipeline under plain luajit — no Envoy,
                 no nginx (a faithful fake of Envoy's request_handle drives the
                 real filter.lua; the real authz app decides; only the
                 guestbook upstream is a stand-in)
```

## Try it without Envoy

```sh
luajit examples/envoy/selftest.lua
```

It runs requests through the chain in Envoy's exact filter order — ext_authz,
then the Lua filter, then the upstream — and checks *which layer* answers:

```
== gate 1: the proof chain holds the edge (ext_authz) ==
  no token                     -> 403 @ ext_authz (unauthenticated: ...)
  carol: not a member          -> 403 @ ext_authz (not a member of tenant acme)
  unmapped path fails closed   -> 403 @ ext_authz (unknown resource)
  bob (viewer) may read        -> 200 @ upstream
  bob (viewer) may NOT post    -> 403 @ ext_authz (requires the editor role)
== gate 2: typed rules.shen at the edge (the Lua filter) ==
  alice posts, missing name    -> 400 @ lua-filter (name: is required)
  ...
== every edge decision is in the durable audit log ==
  #9  carol  read  guestbook  deny   not a member of tenant acme
  ...
OK — all cases passed (ext_authz + Lua filter + upstream)
```

## Run it for real

Three processes, all from the repo root (`brew install envoy openresty` or your
platform's equivalents):

```sh
# 1. the guestbook origin, :8080 — the openresty example, unchanged
mkdir -p examples/openresty/logs
openresty -p "$PWD/examples/openresty" -c nginx.conf

# 2. the authz app as ext_authz backend, :8081
mkdir -p examples/envoy/logs
openresty -p "$PWD/examples/envoy" -c authz.conf

# 3. Envoy at the edge, :10000  (run from the repo root — filter.lua resolves
#    against the cwd; the two env vars are explained under "The mechanics
#    worth knowing", and SHEN_JIT=off matters on macOS)
SHEN_KERNEL_CACHE=examples/envoy/logs/kernel-cache.bin SHEN_JIT=off \
  envoy -c examples/envoy/envoy.yaml --concurrency 2
```

Then drive the edge:

```sh
# no token → the proof chain denies at the edge; the guestbook never sees it
curl -s localhost:10000/api/messages
# carol has no membership → denial WITH the discharge report, from ext_authz
curl -s localhost:10000/api/messages -H 'authorization: Bearer tok-carol'
# bob is a viewer: reads pass, posts need the editor role
curl -s localhost:10000/api/messages -H 'authorization: Bearer tok-bob'
curl -s localhost:10000/api/messages -H 'authorization: Bearer tok-bob' \
     -d '{"name":"bob","message":"hi"}'
# alice (editor) is authorized — but the EDGE now runs the typed rules:
# this 400 comes from Envoy's Lua filter, not the origin
curl -s localhost:10000/api/messages -H 'authorization: Bearer tok-alice' \
     -d '{"message":"no name"}'
# a valid entry survives both gates and reaches the guestbook
curl -s localhost:10000/api/messages -H 'authorization: Bearer tok-alice' \
     -d '{"name":"ada","message":"through the edge"}'
# every one of those edge decisions is durably audited in the authz app
curl -s localhost:8081/api/admin/audit -d '{"token":"tok-admin"}'
```

## How it fits together

```
                     ┌────────────── Envoy :10000 ──────────────┐
client ─ request ──► │ 1  ext_authz ────────────────────────────┼──► authz app :8081 (OpenResty)
                     │      GET /authz/api/messages             │      (route "CHECK" Path ...)
                     │      + authorization header, no body     │      the Prolog proof chain over
                     │      200 = allow; else the denial body   │      durable facts; every decision
                     │      (the discharge report) goes to      │      appended to the audit log
                     │      the client verbatim                 │
                     │ 2  lua filter: filter.lua                │
                     │      rules.shen, typed, on Envoy's       │
                     │      LuaJIT → 400 at the edge            │
                     │ 3  router                                │
                     └────────────────────┬─────────────────────┘
                                          ▼
                             guestbook :8080 (OpenResty)
                             re-runs the SAME rules.shen as the
                             authoritative check (defense in depth)
```

## What Envoy changes, coming from OpenResty

Both embed LuaJIT, but with opposite philosophies — and the split above falls
straight out of the differences:

- **Lua's role.** In OpenResty, Lua is the *application platform*: cosockets,
  `lua_shared_dict`, timers, `init_worker`. In Envoy, Lua is a *scripting
  hook* (`envoy_on_request`/`envoy_on_response`) for inspecting and mutating
  traffic; its only sanctioned I/O is `handle:httpCall()` to a configured
  cluster.
- **No shared state.** Every Envoy worker *thread* has its own Lua state —
  "there is no truly global data." No shared dict means no in-proxy store, no
  in-proxy cache, no LMDB.
- **Real logic is externalized.** Envoy's own answer to "I have serious
  request logic" is `ext_authz` / `ext_proc`: call a service. That is exactly
  where the authz app slots in — unchanged except for one new route.

So the proxy gets **only the pure typed core** (validation — per-request, no
state, no I/O), and everything stateful (the proof chain's facts, the durable
log) stays in OpenResty, where cosockets and LMDB live. The one rule from the
OpenResty examples carries over verbatim: never Shen's blocking file I/O on the
request path.

## The mechanics worth knowing

- **Boot is per worker thread.** `filter.lua`'s top level is Envoy's analogue
  of `init_worker_by_lua`: it runs once per worker thread at config load —
  never per request. `--concurrency 2` keeps the demo's boot cost and memory
  footprint small.
- **Two environment variables worth setting** (both findings from running this
  against Homebrew Envoy 1.39 on an arm64 Mac):
  - `SHEN_KERNEL_CACHE=examples/envoy/logs/kernel-cache.bin` — the bytecode
    cache is keyed to the exact LuaJIT build, and Envoy's LuaJIT is not your
    local `luajit`: with the shared default path (`.shen-kernel-cache.bin` in
    the cwd) the two hosts invalidate and rewrite each other's cache every
    time you alternate. A dedicated path gives Envoy its own warm cache.
  - `SHEN_JIT=off` — macOS's hardened runtime denies Envoy's binary executable
    trace memory, so with the JIT nominally on, every hot loop attempts a
    trace, hits `failed to allocate mcode memory`, and retries: measured, a
    20M-iteration loop ran ~550× slower than local `luajit`, and the kernel
    boot took 40–66 s. `jit.off()` makes it a clean interpreter: **~3 s to
    serving** (warm cache) and edge requests at **3–6 ms**. Boot is the only
    JIT-hungry phase — per-request validation is tiny either way. Linux Envoy
    builds can generally allocate mcode; try without it there first.
- **The check endpoint fails closed, twice.** An unmapped path maps to
  resource `""` → owner tenant `""` → `denied "unknown resource"` (the app);
  and `failure_mode_allow: false` means an unreachable authz app is a 403,
  never an allow (Envoy). The check response body is a *typed* projection —
  `check-response` in `authz.shen` is total over `decision` and structurally
  cannot include document content, so the gateway cannot become a data leak.
- **Path resolution.** `filter.lua` finds the repo via its own file path (or
  `$SHEN_LUA_ROOT`, or the cwd as a last resort). Envoy loads it with
  `default_source_code: { filename: ... }`, resolved against the cwd.
- **FFI.** The native soa32 Prolog/typecheck engine wants LuaJIT's FFI, and
  Envoy's bundled LuaJIT ships it (verified: `require("ffi")` loads and the
  typed `rules.shen` load — which runs the typechecker — works in-proxy). In a
  build without it, shen-lua falls back to the (slower, still correct) legacy
  engine.
- **`x-shen-edge`.** The filter stamps `x-shen-edge: validated` on requests it
  lets through (and `rejected` on its 400s), so the origin — and your access
  logs — can see the edge ran the rules.
