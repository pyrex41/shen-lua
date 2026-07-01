# Typed config compiler — validate, then generate

A config compiler that takes one high-level service config and, **only if it
validates**, emits deployment artifacts — a Kubernetes `Deployment` and an
nginx server block — from that single source. Validation and generation are one
typed Shen file (`configc.shen`), loaded under `(tc +)`, so a bug in a
*generator* is a type error at load, before any config is ever compiled.

```
luajit examples/configc/configc.lua        # compile good/bad configs on the CLI
```

Or the live web preview under OpenResty:

```
mkdir -p examples/configc/logs
openresty -p "$PWD/examples/configc" -c nginx.conf
# open http://127.0.0.1:8092/ — edit the config, watch the artifacts regenerate
```

## What it shows

`compile-config : val --> output` returns **either** the validation errors
**or** the generated files — a sum type (`[invalid Errs]` / `[compiled Files]`),
never half of each. So "was it valid?" and "what did it generate?" can't drift
apart: an invalid config produces no manifest, by construction.

The generators (`emit-k8s`, `emit-nginx`) are **typed over the config's `val`
structure**. They read fields through typed accessors with defaults and build
strings with `cn`/`str`. Feed a number where a string is expected and it does
not compile — see `configc_broken.shen`, whose only sin is `(cn "listen " Port)`
with `Port` a number. In an untyped templating engine that is a runtime crash
(or a silently corrupt config file) on first generation; here the CLI run ends
with:

```
rejected by the typechecker: type error in rule 1 of bad-listen
```

Everything is pure, portable Shen (`cn`/`str`/`n->string` only, no host
bridges), so the identical compiler runs on the CLI, in this OpenResty preview,
in a CI step, or at a Kubernetes admission webhook (via `shen-go`) — one
definition of "valid", one definition of "what it generates", everywhere. That
is the payoff: the config schema and the manifest templates stop being two
artifacts that drift, and become one typed function.

## Files

| file | what it is |
|---|---|
| `configc.shen` | the compiler: the `val`/`output`/`artifact` types, the validators, the k8s + nginx generators, and `compile-config`. |
| `configc_broken.shen` | the same shape with one planted generator type bug, to show the typechecker rejecting it at load. |
| `configc.lua` | the CLI: marshals Lua config tables, compiles them, prints artifacts or errors, and proves the broken generator is rejected. |
| `app.lua` | OpenResty glue: marshals a JSON config and returns generated artifacts (or errors) for the live preview. |
| `nginx.conf` | serves the `/api/compile` endpoint and the preview page. |
| `public/index.html` | edit a config, see the generated manifests update live. |
| `json_shim.lua` | a tiny JSON codec for running off-nginx. |
