# Examples

Three examples, smallest first (all run with plain `luajit`/`bin/shen`,
no external dependencies, no network):

| | |
|---|---|
| `hello_embed.lua` | the smallest useful embedding: boot, define a typed Shen function, call it from Lua, pass lists both ways. `luajit examples/hello_embed.lua` |
| `family.shen` | Shen Prolog in twenty lines — facts, rules, yes/no and binding queries. `bin/shen examples/family.shen` |
| `config_check.lua` | the showcase, walked through below. `luajit examples/config_check.lua` |

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
