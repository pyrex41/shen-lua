# Examples

Smallest first. The listed CLI runs and web-app selftests use `luajit` or
`bin/shen` without nginx or network dependencies. Serving the web apps needs
their documented hosts; browser builds and production adapters need additional
tooling.

| | |
|---|---|
| [`hello_embed.lua`](hello_embed.lua) | the smallest useful embedding: boot, define a typed Shen function, call it from Lua, pass lists both ways. `luajit examples/hello_embed.lua` |
| [`family.shen`](family.shen) | Shen Prolog in twenty lines — facts, rules, yes/no and binding queries. `bin/shen examples/family.shen` |
| [`config_check.lua`](config_check.lua) | the interop showcase, walked through below. `luajit examples/config_check.lua` |
| [`configc/`](configc/) | a typed config **compiler**: one config validates *and* generates a Kubernetes Deployment + nginx server block; a generator type-bug is caught at load. `luajit examples/configc/configc.lua` |
| [`policy/`](policy/) | a typed **authorization** gateway: runtime rules enforced at the OpenResty edge and previewed in the browser, plus a separate proof-term model of permissions. `luajit examples/policy/selftest.lua` |
| [`crdt/`](crdt/) | a **CRDT** sync hub: typed merges tested for convergence and algebraic laws on sampled states; separate machine-checked derivations follow from axioms, not from the merge implementation. `luajit examples/crdt/selftest.lua` |
| [`pcr/`](pcr/) | **proof-carrying requests over live facts**: the client attaches a proof term, the OpenResty gate *checks* it — never searches — against a versioned fact store consulted at proof time, so revoking one fact makes the same proof bytes fail on the next request while delegation chains stay composable and every allow logs its full justification. `luajit examples/pcr/selftest.lua` |
| [`openresty/`](openresty/) | a complete web app — typed Shen validators + a Shen router on OpenResty (nginx + LuaJIT), with a front end that runs the **same** rules in the browser (Yggdrasil-shaken, ShenScript-compiled). Runs standalone via `luajit examples/openresty/selftest.lua`; see [its README](openresty/README.md) to serve it. |
| [`openresty-authz/`](openresty-authz/) | multi-tenant **authorization**: a Prolog decision chain (`token → user → tenant → resource`), a typed response projection, and an append-only file store; the LMDB adapter is exercised with a fake off-nginx. Runs standalone via `luajit examples/openresty-authz/selftest.lua`; see [its README](openresty-authz/README.md). |
| [`envoy/`](envoy/) | **Shen at the edge**: Envoy in front of both apps above — its `ext_authz` filter sends every request through the authz app's proof chain (edge decisions land in the same durable audit log), and an Envoy **Lua filter** runs the guestbook's typed `rules.shen` *inside the proxy* (LuaJIT), rejecting malformed bodies at the edge with the origin's exact error strings. One typed rule file, four hosts. Runs standalone via `luajit examples/envoy/selftest.lua`; see [its README](envoy/README.md). |

`configc/`, `policy/`, and `crdt/` illustrate different assurance levels:
typed Shen source, executable rules and tests, and separately encoded proof
terms. A checked type or proof establishes a property of its encoded model;
host glue, dynamic facts, generated artifacts, and correspondence with the
executed algorithm still need their own validation. See each example's README.

---

# Lua ⇄ Shen interop: a typed validation layer for Lua config tables

Run from the repo root (or anywhere — the script finds its way home):

```
luajit examples/config_check.lua
```

No external dependencies, no network. First run boots the kernel from
source (a few seconds); after that the kernel/fasl caches make it quick.

## What you'll see

```
== loading examples/config_rules.shen under (tc +) ==
(fn validate-config) : (val --> (list string))
(fn valid-config?) : (val --> boolean)
...
typechecked in 2842 inferences

== validating configs ==
good         OK
bad          5 problem(s):
    - service: "Web Frontend!" is not a valid service name
    - port: 70000 is not an integer in 1..65535
    - replicas: 0.5 must be a positive integer
    - tls.cert: required (a .pem path) when tls.enabled is true
    - hosts: every element must be a string

== loading examples/config_rules_broken.shen (one bug planted) ==
rejected by the typechecker: type error in rule 1 of broken-check-port
```

Three things are happening, and the third is the one a plain Lua
validation library cannot do:

1. **Lua → Shen.** A nested Lua config table is marshaled into Shen data
   and validated by `validate-config`, a Shen function called from Lua as
   an ordinary callback (`shen.fn("validate-config")`). The errors come
   back as a plain Lua array of strings.

2. **Shen → Lua.** The rules call *back* into Lua through the **typed
   bridge**: `string.format` builds the error messages, and
   `host.matches` — a function defined *by the host Lua script* — does
   Lua-pattern matching, which Shen's stdlib doesn't have. Every one of
   those call sites is typechecked against the declared signature.

3. **The typechecker.** `config_rules.shen` is loaded with `(tc +)`: the
   `datatype val` declarations give the marshaled Lua data a *type*, and
   every rule is proved sound against it at **load time**.
   `config_rules_broken.shen` contains one classic bug — a number fed to
   a `%q`/string formatter — which plain Lua only discovers at runtime,
   on the first invalid config that happens to reach that line. Shen
   rejects the rules file before a single config is validated.

## The files

| file | what it is |
|---|---|
| `config_check.lua` | the host program: boots Shen, registers the bridges, marshals configs, reports |
| `config_rules.shen` | the typed rules: `datatype val`, the checkers, `validate-config` |
| `config_rules_broken.shen` | same port rule with the planted type bug |

## How the bridge is set up (the interesting 15 lines)

```lua
local P = require("boot")
P.load_kernel(false)
P.initialise()
local shen = require("lua_interop")     -- the bridge module IS the Lua API

host = { matches = function(s, p) return string.match(s, p) ~= nil end }

shen.eval [[
  (lua.function lua.format   "string.format" [string --> string --> string])
  (lua.function host.matches "host.matches"  [string --> string --> boolean])
]]

shen.eval("(tc +)")
P.F["load"]("examples/config_rules.shen")   -- typechecked load

local validate = shen.fn("validate-config")
local errs = validate(shen_value_of_config) or {}   -- () is nil at the boundary
```

`(lua.function Name Path Sig)` is the **typed bridge**: it installs
`Name` as a real Shen function (a marshaling wrapper around the Lua
function at `Path`), registers its arity (one per top-level `-->` in
`Sig`), and `declare`s `Sig` so the typechecker holds every Shen call
site to it. Note that `(tc +)` is issued *before* the `load` — Shen's
`load` snapshots the tc mode once, at load start.

The untyped relatives, for scripting without signatures:

```
(lua.require "mod")             (lua.global "math.pi")
(lua.call "string.rep" ["ab" 3])      (lua.call F Args) — F may be a value
(lua.method Obj "name" Args)          Obj:name(Args...)
(lua.index Obj Key)                   (lua.setindex Obj Key V)
```

## Marshaling rules (the exact contract)

Defined and documented in `lua_interop.lua`. The short version:

* **Shen → Lua:** numbers/strings/booleans unchanged; symbols → their
  print names; proper lists → dense Lua array tables (deep); `()` → `nil`
  in argument/return position, `{}` as a list *element*; opaque boxes →
  the original Lua value; improper lists refuse to cross.
* **Lua → Shen:** `nil` → `()`; scalars unchanged (strings are **never**
  auto-interned to symbols — that direction is ambiguous); metatable-free
  dense arrays → proper lists (deep); every other table, userdata or
  cdata → an **opaque box** that round-trips by identity; only the first
  of multiple return values crosses.
* **Errors:** a Lua error becomes an ordinary trappable Shen error
  (`trap-error` / `error-to-string`); a Shen error crossing Lua frames is
  re-raised unchanged; on the Lua side use `pcall` +
  `shen.error_message(e)`.
* **Functions** cross either way as themselves. Shen functions are
  curry-aware from Lua: `shen.call("f", a)` on a 2-ary `f` returns a Lua
  function awaiting the rest. `shen.wrap(luafn, arity)` makes a Lua
  function that receives/returns *marshaled* Shen data.

## Try the failure mode yourself

Open `examples/config_rules.shen` and change `check-host`'s
`[(lua.format "hosts: %q is not a hostname" H)]` to format `42` instead
of `H`, then rerun. The file no longer loads — that's the point.
