# shen-lua — a speed-focused LuaJIT port of the Shen kernel

`shen-lua` runs the [Shen](http://shenlanguage.org) language on **LuaJIT 2.1**.
Shen programs compile down to **KLambda (Kλ)** — a small, untyped Lisp kernel of
~46 primitives — and a "port" of Shen consists of (a) implementing those
primitives on a host runtime and (b) translating the kernel's `.kl` files into
that host. This port does both by **compiling KLambda to Lua source** that
LuaJIT then trace-compiles to machine code.

It is **certified**: it passes 100% of the Shen 22.4 kernel test suite
(24 report blocks, 130 assertions), including the typed-mode tests that exercise
the kernel's own Prolog-based type checker.

## Why a compiler (not an interpreter)

The design goal is speed, so the host backend is a **source-to-source compiler**,
not a tree-walker:

* KLambda special forms (`if`, `cond`, `let`, `do`, `and`, `or`, `trap-error`,
  `lambda`, `freeze`, `defun`, `type`) compile to **native Lua control flow**.
* Tail positions emit real Lua `return`/`if`-`elseif` chains, so deep recursion
  uses LuaJIT's **proper tail calls** (the kernel relies on TCO heavily).
* Function application uses **currying-on-demand**: when the callee's arity is
  statically known the call is a direct, exact-arity table call; otherwise a
  generic `APP` builds and applies closures.
* `type` is **erased** at the Kλ boundary (it is identity), per the porting spec —
  the actual type *checking* is the kernel's own Shen code and runs unchanged.

## Architecture

| File | Lines | Role |
|------|------:|------|
| `runtime.lua`  | 213 | data representation, symbol interning, the KLambda reader |
| `compiler.lua` | 365 | KLambda → Lua source compiler (statement-based codegen) |
| `prims.lua`    | 325 | runtime env: the primitive set, apply/curry machinery, loader |
| `boot.lua`     |  65 | wires up streams, loads the kernel `.kl` files, runs `shen.initialise` |

Data representation (chosen so hot paths stay trace-JIT-friendly):

* numbers → Lua numbers; strings → Lua strings; KL `true`/`false` → Lua booleans
* symbols → interned tables (identity `==`); `()` → a unique `NIL`
* cons → `{h, t}` with a `Cons` metatable; vectors (absvector) → `{n=size, [0..n-1]}`
* functions → Lua functions, arity tracked in a weak table; exceptions → tagged tables

## Requirements

* **LuaJIT 2.1** (Lua 5.1 semantics). On Debian/Ubuntu: `apt-get install luajit`.
* A checkout of the **Shen 22.4 kernel `.kl` files** (this repo expects them at
  `/home/claude/shen-c/shen/src/kl`; override with `SHEN_KL_DIR`).

No build step is needed — the kernel is compiled from `.kl` to Lua **on boot**
(~0.18 s, see benchmarks). 

## Running a program

```sh
# load and run a .shen file (the kernel reader handles full Shen syntax)
LUA_PATH="/path/to/shen-lua/?.lua;;" luajit run-shen.lua myprogram.shen
```

Programmatically:

```lua
local P = require("boot")
P.load_kernel(false)   -- compile + load all 18 kernel files
P.initialise()         -- (shen.initialise)
-- evaluate a Shen top-level form through the real pipeline:
local R = require("runtime")
P.F["eval"](R.read_all('(define square X -> (* X X))')[1])
print(require("runtime").to_str(P.F["square"](9)))   -- 81
```

## Certification

```sh
SHEN_TESTS=/path/to/shen-22.4/tests ./run-cert.sh
```

This loads `README.shen` (the test harness) and `tests.shen` from the **version-matched**
Shen 22.4 suite and reports a pass rate per block. Current result: **24/24 blocks at
100%, 130/130 assertions** — see `cert/cert-22.4-result.txt`.

> Note on versions: the test suite must match the kernel. shen-sources *HEAD* tests
> target a newer kernel and use constructs (e.g. `(fn F)`) that the vendored 22.4
> kernel — and shen-c itself — do not define. We therefore certify against the
> 22.4 suite, which is the apples-to-apples bar for this kernel.

## Benchmarks

See `BENCHMARKS.md` for the full report and LuaJIT trace analysis. Headline,
versus the `shen-c` 0.2.3 interpreter on the **same machine**:

* **fib** (compute-bound recursion): **66–79× faster**.
* **n-queens** (functional, allocation-heavy): **~2.5× faster**; shen-c segfaults at
  board 6 (no TCO), shen-lua completes it.
* **Einstein's riddle** (Prolog backtracking, CPS + heavy allocation): **~1.5× slower** —
  the one workload class where a low-constant-factor C interpreter wins. Honest analysis
  in `BENCHMARKS.md`.
