# A web app in Shen, on OpenResty

A small but complete web app whose **server-side logic is written in Shen** and
runs on [OpenResty](https://openresty.org) (nginx + LuaJIT). It's a guestbook:
a JSON API plus a one-file front end. The point isn't the guestbook — it's the
shape of a real Shen web app and the handful of rules that make it work.

OpenResty is nginx embedding **LuaJIT 2.1**, which is exactly shen-lua's primary
host, so the backend can literally be Shen with a thin Lua glue layer.

```
examples/openresty/
  validate.shen   the TYPED core — field rules, proved sound at load time
  app.shen        the router — dispatch + storage orchestration (untyped shell)
  app.lua         the glue — boots Shen, marshals JSON <-> Shen, the handler
  nginx.conf      OpenResty config: boot once per worker, two locations
  public/         the front end (plain HTML+fetch; the ShenScript slot)
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

With `openresty` on your PATH, from the repo root:

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
browser ──HTTP──> nginx location /api/  ──> app.lua: handle()
                                              │  JSON  -> Shen `val`
                                              ▼
                                      (route Method Path Body)   app.shen   [untyped shell]
                                              │  └─ (validate-message Body)  validate.shen [typed core]
                                              │  └─ (lua.call "host.store_*") -> lua_shared_dict
                                              ▼
                                          [Status BodyVal]
                                              │  Shen `val` -> JSON
                                              ▼
                                          HTTP response
```

### Boot once per worker — the one rule that matters

Booting the Shen kernel (and typechecking `validate.shen`) costs real time —
tens of ms warm from the bytecode cache, ~1 s cold. `nginx.conf` does it in
`init_worker_by_lua`, so it happens **once per worker, never per request**. A
warm worker handles requests with no per-call boot cost.

### Typed core, untyped shell

- **`validate.shen` loads under `(tc +)`.** Its field rules are checked by
  Shen's sequent-calculus typechecker *at load time* — a type error in a
  validator aborts startup, before the server ever takes a request (the same
  guarantee as [`examples/config_rules.shen`](../config_rules.shen)).
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
marshaling rules and the typed `(lua.function ...)` bridge.

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

## The front end and ShenScript

`public/index.html` is plain HTML + `fetch()` so the example runs with nothing
but OpenResty. That hand-written JS is precisely the layer
[ShenScript](https://github.com/pyrex41/ShenScript) (Shen → JavaScript) would
replace. Because shen-lua (server) and ShenScript (browser) are two ports of
the **same language**, you can lift the field rules out of `validate.shen` into
a shared `.shen` module, compile it to JS for instant client-side validation,
and run the identical file on the server as the authoritative check — one type
system, no client/server drift.
