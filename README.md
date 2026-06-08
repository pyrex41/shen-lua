# shen-lua — a speed-focused LuaJIT port of the Shen kernel

`shen-lua` runs the [Shen](http://shenlanguage.org) language on **LuaJIT 2.1**.
Shen programs compile down to **KLambda (Kλ)** — a small, untyped Lisp kernel of
~46 primitives — and a "port" of Shen consists of (a) implementing those
primitives on a host runtime and (b) translating the kernel's `.kl` files into
that host. This port does both by **compiling KLambda to Lua source** that
LuaJIT then trace-compiles to machine code.

It targets **Shen 41.1** (via the KLambda in `ShenOSKernel-41.1/klambda`).
Earlier versions were certified against the Shen 22.4 kernel test suite.

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
| `boot.lua`     |  80 | wires up streams, platform globals, loads the 41.1 kernel `.kl` files, runs `shen.initialise` |

Data representation (chosen so hot paths stay trace-JIT-friendly):

* numbers → Lua numbers; strings → Lua strings; KL `true`/`false` → Lua booleans
* symbols → interned tables (identity `==`); `()` → a unique `NIL`
* cons → `{h, t}` with a `Cons` metatable; vectors (absvector) → `{n=size, [0..n-1]}`
* functions → Lua functions, arity tracked in a weak table; exceptions → tagged tables

## Requirements

* **LuaJIT 2.1** (Lua 5.1 semantics). On Debian/Ubuntu: `apt-get install luajit`.
* Nothing else — the **Shen 41.1 KLambda sources** (`klambda/`) are vendored in this
  repository for a self-contained clone-and-run experience. You can still point
  `SHEN_KL_DIR` at an external checkout if you are working against a different
  ShenOSKernel tree.

No build step is needed — the kernel is compiled from `.kl` to Lua **on boot**. 

## Running a program

```sh
# load and run a .shen file (the kernel reader handles full Shen syntax)
LUA_PATH="/path/to/shen-lua/?.lua;;" luajit run-shen.lua myprogram.shen
```

Programmatically:

```lua
local P = require("boot")
P.load_kernel(false)   -- compile + load the 41.1 kernel (~21 .kl files incl. stlib)
P.initialise()         -- (shen.initialise) — required before most kernel services work
-- evaluate a Shen top-level form through the real pipeline:
local R = require("runtime")
P.F["eval"](R.read_all('(define square X -> (* X X))')[1])
print(require("runtime").to_str(P.F["square"](9)))   -- 81
```

## Certification / Testing

See [41.1-STATUS.md](41.1-STATUS.md) for the current state of the 41.1 port,
including what works, what is broken, and how to run the official test suite.

The port loads and initialises the full 41.1 kernel (including `stlib` and the new
extensions). However, the test harness does not yet run successfully (see the status
doc for details and error symptoms).

The old `cert-22.4-result.txt` is historical only.

## Benchmarks

See `BENCHMARKS.md` for the historical (Shen 22.4) report and LuaJIT trace analysis.
The numbers below are from that era; re-benchmarking against a current `shen-c` built
for 41.1 would be the fair comparison.

Headline versus the `shen-c` 0.2.3 interpreter on the **same machine** (22.4 baseline):

* **fib** (compute-bound recursion): **66–79× faster**.
* **n-queens** (functional, allocation-heavy): **~2.5× faster**; shen-c segfaults at
  board 6 (no TCO), shen-lua completes it.
* **Einstein's riddle** (Prolog backtracking, CPS + heavy allocation): **~1.5× slower** —
  the one workload class where a low-constant-factor C interpreter wins. Honest analysis
  in `BENCHMARKS.md`.
