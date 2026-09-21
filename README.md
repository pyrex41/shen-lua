# shen-lua

[Shen](https://shenlanguage.org) on **LuaJIT 2.1**: pattern matching, optional
sequent types, and Prolog, compiled to Lua. Shen 42, **134/134** official
kernel tests. Embeds in any Lua host. Plain Lua 5.1/5.4/5.5 works too (slower,
still correct).

```sh
git clone https://github.com/pyrex41/shen-lua && cd shen-lua
bin/shen                            # REPL
bin/shen -e "(+ 1 2)"               # one-liner
bin/shen examples/family.shen       # a program (Shen Prolog in 20 lines)
luajit examples/hello_embed.lua     # embed in Lua, ~25 lines
```

Need only LuaJIT (`brew install luajit` / `apt-get install luajit`). First boot
compiles the kernel (~1 s); after that the bytecode cache boots in ~30 ms.
Loaded programs are cached fasl-style. Cross-port agreement lives in
[Bifrost](https://github.com/pyrex41/bifrost). New to Shen?
[shenlanguage.org](https://shenlanguage.org).

## How it works

KLambda (the ~46-primitive untyped kernel) is compiled to Lua source; LuaJIT
trace-compiles that to machine code. Special forms become native `if`/`return`;
tail calls are real Lua TCO (and self-tails become loops). `type` is erased at
the Kλ boundary — type *checking* is the kernel’s own Shen, unchanged.

| File | Role |
|------|------|
| `runtime.lua` | values, intern, KLambda reader |
| `compiler.lua` | KLambda → Lua |
| `prims.lua` | primitives, apply/curry, native overrides |
| `boot.lua` | kernel load, bytecode + fasl caches |
| `shen.lua` | embedding API (`require("shen")`) |
| `lua_interop.lua` | Lua ⇄ Shen |
| `repl.lua` | REPL |
| `prolog_engine.lua` / `prolog_compile.lua` / `typecheck_native.lua` | native Prolog / typecheck |

Numbers, strings, and booleans are Lua’s. Symbols are interned (identity `==`).
`()` is a unique `NIL`. Cons is `{h,t}`; vectors are array tables.

## CLI

```sh
bin/shen                       # REPL (multiline, history, Shen backtraces)
bin/shen prog.shen ...         # (load) each file
bin/shen -e "(+ 1 2)"          # eval and print
bin/shen --hush-load prog.shen # run a program; no load echo (use this for golden suites)
bin/shen -q prog.shen          # *hush*: silences load echo *and* (output ...)
```

`--hush-load` (or `SHEN_HUSH_LOAD=1`) is what batch runners want: the program’s
own output stays, load chatter does not. `-q` sets `*hush*`, which on kernel 42
gates `pr` itself.

The launcher finds the vendored `klambda/` next to the checkout, so `bin/shen`
works from any cwd.

## Embed

```lua
local shen = require("shen")
shen.boot{ quiet = true }
shen.eval('(define square X -> (* X X))')
print(shen.call("square", 9))         --> 81
local sq = shen.fn("square")          -- ordinary Lua callable
shen.typecheck("[1 2]", "(list number)")
```

`shen.prims` / `shen.runtime` expose `F`, the reader, and the printer.

From Shen: `(lua.call "string.format" ["%s: %d" "answer" 42])`. `lua.function`
registers a Lua function as a typed Shen function so `(tc +)` can prove call
sites. Details at the top of [`lua_interop.lua`](lua_interop.lua).

## Examples

| | |
|---|---|
| [`examples/hello_embed.lua`](examples/hello_embed.lua) | boot, define, call both ways |
| [`examples/family.shen`](examples/family.shen) | Prolog facts and queries |
| [`examples/config_check.lua`](examples/config_check.lua) | typed validation of Lua tables |
| [`examples/openresty/`](examples/openresty/) | guestbook: one `rules.shen` on OpenResty and in the browser |

More under [`examples/`](examples/README.md). A full tour:
[`demo/walkthrough.md`](demo/walkthrough.md).

## Tests

```sh
make test                      # port specs (test/*_spec.lua)
luajit run-kernel-tests.lua    # official 42 suite → 134/134
```

The kernel suite is vendored in `tests/`. Port specs cover primitives, REPL,
interop, tail-call lowering, boot caches.

## Install

```sh
luarocks install shen                       # launcher + modules
luarocks make --local shen-scm-1.rockspec   # this tree
```

LuaJIT required (`lua == 5.1`). Rocks: **0.10.1** is kernel **42**; **0.9.0**
was 41.1. Or grab `shen-bundle.lua` from
[Releases](https://github.com/pyrex41/shen-lua/releases/latest) — one file,
`require("shen-bundle")`.

```sh
luajit build/make-bundle.lua    # → build/shen-bundle.lua
```

## Performance

| workload | time |
|----------|-----:|
| Kernel boot, warm | ~0.03 s |
| Kernel boot, cold | ~0.7 s |
| 42 suite, warm (fasl) | ~2–5 s |
| Reference typecheck (431,741 infs) | ~0.06 s |
| Einstein’s riddle | ~0.002 s / solve |

Prolog and the typechecker run on a native engine (`prolog_engine.lua`); the
portable kernel predicates that show up on compile and execution paths are
overridden in `prims.lua`. Caches (kernel bytecode, stdlib image, user fasl)
are content-keyed and safe to delete. Internals:
[`doc/PERF-HANDOFF.md`](doc/PERF-HANDOFF.md),
[`doc/BENCHMARKS.md`](doc/BENCHMARKS.md).

## Requirements

LuaJIT 2.1. Kernel sources are in `klambda/` (see
[`klambda/PROVENANCE.md`](klambda/PROVENANCE.md)). `SHEN_KL_DIR` can point at
another tree.

**PUC Lua 5.1/5.4/5.5:** same 134/134. No FFI → legacy Prolog engine; no `bit`
→ caches off. Lua 5.3+ arithmetic is forced to floats so it matches LuaJIT.

**Old LuaJIT on aarch64** (2.1.0-beta3): boot-time JIT crash, fixed upstream.
Use a current rolling LuaJIT, or `SHEN_JIT=off`.

## Nix

Optional. `nix develop` or `direnv allow` for a pinned toolchain.
`packages.toolchain` is what [Bifrost](https://github.com/pyrex41/bifrost)
composes.
