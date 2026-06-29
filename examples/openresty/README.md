# A web app in Shen, on OpenResty

A small but complete web app whose **server-side logic is written in Shen** and
runs on [OpenResty](https://openresty.org) (nginx + LuaJIT). It's a guestbook:
a JSON API plus a one-file front end. The point isn't the guestbook — it's the
shape of a real Shen web app and the handful of rules that make it work.

OpenResty is nginx embedding **LuaJIT 2.1**, which is exactly shen-lua's primary
host, so the backend can literally be Shen with a thin Lua glue layer. The front
end runs Shen too: the browser validates with a build of the **same**
`rules.shen`, compiled to JavaScript by
[ShenScript](https://github.com/pyrex41/ShenScript) and tree-shaken by
[Ratatoskr](https://github.com/pyrex41/ratatoskr), so the field rules are
checked client-side AND server-side from one source of truth.

```
examples/openresty/
  rules.shen      the TYPED core — field rules, proved sound at load time;
                  loaded by the server AND shaken into the browser build
  app.shen        the router — dispatch + storage orchestration (untyped shell)
  app.lua         the glue — boots Shen, marshals JSON <-> Shen, the handler
  nginx.conf      OpenResty config: boot once per worker, serve rules.shen
  public/         the front end (imports the shaken validator module)
  public/vendor/shen-rules.client.js  the shaken+compiled client validator
                  (~140 KB, generated from rules.shen — see "Front end" below)
  scripts/        build-client.sh + helpers that regenerate that module
  selftest.lua    drives the whole app under plain luajit, no nginx needed
  json_shim.lua   a tiny JSON codec used only off-nginx (OpenResty has cjson)
```

## Try it without nginx

The Shen code and all of its routing/validation logic run under plain LuaJIT:

```sh
luajit examples/openresty/selftest.lua
```

```
== guestbook API (in-memory store) ==
GET empty list               -> 200  {"messages":[]}
POST valid                   -> 201  {"ok":true}
GET list (2 rows)            -> 200  {"messages":[{"name":"ada",...}]}
POST missing name            -> 400  {"errors":["name: is required"]}
POST blank message           -> 400  {"errors":["message: must be 1..280 characters"]}
POST not an object           -> 400  {"errors":["body: must be a JSON object"]}
unknown route -> 404         -> 404  {"error":"not found"}
OK — all cases passed
```

## Run it under OpenResty

The browser validator (`public/vendor/shen-rules.client.js`) is committed, so
there is nothing to vendor — just run it. With `openresty` on your PATH, from
the repo root:

```sh
mkdir -p examples/openresty/logs
openresty -p "$PWD/examples/openresty" -c nginx.conf
```

Then open <http://127.0.0.1:8080/> and sign the guestbook. The API is also
reachable directly:

```sh
curl -s localhost:8080/api/messages
curl -s localhost:8080/api/messages -d '{"name":"ada","message":"hi"}'
curl -s localhost:8080/api/messages -d '{"message":"no name"}'   # -> 400 + typed errors
```

(`-p` sets the nginx prefix to this directory, so `logs/` and `public/` resolve
here; `init_by_lua` derives the repo root from the prefix to put shen-lua on
`package.path`.)

## How it fits together

```
browser ─ validate-message in a shaken build of rules.shen ─ instant feedback
   │  HTTP (only client-valid requests)
   ▼
nginx location /api/  ──> app.lua: handle()
                              │  JSON  -> Shen `val`
                              ▼
                      (route Method Path Body)   app.shen   [untyped shell]
                              │  └─ (validate-message Body)  rules.shen [typed core]
                              │  └─ (lua.call "host.store_*") -> lua_shared_dict
                              ▼
                          [Status BodyVal]
                              │  Shen `val` -> JSON
                              ▼
                          HTTP response

The browser runs validate-message from a tree-shaken build of rules.shen before
posting; the server re-runs rules.shen as the authoritative check. One source,
both ends.
```

### Boot once per worker — the one rule that matters

Booting the Shen kernel (and typechecking `rules.shen`) costs real time —
tens of ms warm from the bytecode cache, ~1 s cold. `nginx.conf` does it in
`init_worker_by_lua`, so it happens **once per worker, never per request**. A
warm worker handles requests with no per-call boot cost.

### Typed core, untyped shell

- **`rules.shen` loads under `(tc +)`.** Its field rules are checked by
  Shen's sequent-calculus typechecker *at load time* — a type error in a
  validator aborts startup, before the server ever takes a request (the same
  guarantee as [`examples/config_rules.shen`](../config_rules.shen)). It is
  pure, portable Shen (`cn`/`str`/`tlstr` only, no host bridges), which is
  exactly why the browser can load the same file.
- **`app.shen` loads under `(tc -)`.** Routing and storage are effectful (they
  touch nginx and a shared dict), so this half is untyped on purpose. It still
  calls the typed validators directly — both files load into one environment.

### Crossing the Lua boundary

`app.lua` marshals a cjson-decoded request body into the tagged `val` shape
(`"x"` → `[s "x"]`, `8080` → `[n 8080]`, objects → `[obj [[k v] ...]]`) that the
Shen rules pattern-match, and marshals the `[Status BodyVal]` result back to
JSON. Storage is reached the other way: the Shen router calls
`(lua.call "host.store_add" ...)` against plain Lua functions backed by a
`lua_shared_dict`. See [`lua_interop.lua`](../../lua_interop.lua) for the
marshaling rules. (The browser does the same marshaling in JS — see
`public/index.html`, where two form strings become a `val` for the in-browser
`validate-message`.)

## Things to know before building on this

- **Never use Shen's native file I/O for DB/network calls** — it's blocking and
  would stall nginx's event loop. Reach the outside world through OpenResty's
  non-blocking cosocket libraries (`lua-resty-mysql`, `lua-resty-http`, …)
  called from Shen via `lua.call`, exactly as storage is here.
- **CPU-bound Shen blocks the worker.** A heavy Prolog query or typecheck holds
  the worker until it returns. Fine for routing/validation; mind anything long.
- **Kernel state is per worker.** Globals don't cross workers — use
  `lua_shared_dict`, Redis, or a DB for shared state (storage here is a shared
  dict, so it's visible to every worker).
- **The bytecode cache** (`.shen-kernel-cache.bin`) is written in the worker's
  cwd (the nginx prefix) on first boot; it's gitignored.

## The front end: Shen in the browser, tree-shaken

`public/index.html` runs Shen **in the browser**. It imports
`public/vendor/shen-rules.client.js`, calls `createValidator()`, and uses the
result to check the form *in the browser* (an invalid entry never reaches the
network); only a client-valid entry is POSTed, where the server re-runs
`rules.shen` as the authoritative check.

That client module is not the whole ShenScript kernel — it is a **tree-shaken
build of `rules.shen`**:

1. [Ratatoskr](https://github.com/pyrex41/ratatoskr), a Shen tree-shaker, walks
   the kernel call graph and emits only the ~100 kernel functions these rules
   can reach. Because the rules never touch `eval`/`read`/`tc`, the reader, the
   macro expander, the typechecker and `eval` itself all fall away
   (`needs-eval=false` in the manifest).
2. [ShenScript](https://github.com/pyrex41/ShenScript) compiles that slice to
   JavaScript ahead of time, and `scripts/build-client.mjs` wraps it as a
   self-contained ES module that exports `createValidator()`.

The result is ~140 KB and inits in tens of milliseconds, versus ~660 KB and
~2.3 s for the full ShenScript kernel bundle. It embeds ShenScript's pure
`runtime.js`/`overrides.js`, so it needs no ShenScript checkout or npm install
at runtime — just the committed file.

This is the payoff of shen-lua (server) and ShenScript (browser) being two
ports of the **same language**: the field rules live in one typed `.shen` file,
proved sound at server startup and *generated into* the client build — one type
system, no client/server drift. The only browser-only code is the marshaling
glue ([`scripts/client.glue.shen`](scripts/client.glue.shen), four lines that
turn two form strings into the tagged `val` the rules match); everything about
*what counts as valid* lives in `rules.shen`.

### Regenerating the client module

The committed `shen-rules.client.js` is generated; rerun the build whenever
`rules.shen` changes so client and server stay in lockstep:

```sh
examples/openresty/scripts/build-client.sh
```

It needs sibling checkouts of [Ratatoskr](https://github.com/pyrex41/ratatoskr)
(the `ratatoskr` binary) and [ShenScript](https://github.com/pyrex41/ShenScript),
plus `luajit` (the shake host) and Node 20+. Override locations with
`$RATATOSKR` and `$SHENSCRIPT_DIR`. The script concatenates `rules.shen` +
`scripts/client.glue.shen`, shakes the slice, and compiles it to the module.

The running page is self-documenting too: a "What this demonstrates" panel with
a browser→server flow diagram, links to the live `/rules.shen`, and an
expandable view of the rule source — so anyone opening the example sees the
rules and the architecture without reading the code.
