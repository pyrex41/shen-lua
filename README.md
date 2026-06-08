# shen-lua — a speed-focused LuaJIT port of the Shen kernel

`shen-lua` runs the [Shen](http://shenlanguage.org) language on **LuaJIT 2.1**.
Shen programs compile down to **KLambda (Kλ)** — a small, untyped Lisp kernel of
~46 primitives — and a "port" of Shen consists of (a) implementing those
primitives on a host runtime and (b) translating the kernel's `.kl` files into
that host. This port does both by **compiling KLambda to Lua source** that
LuaJIT then trace-compiles to machine code.

It targets **Shen 41.1** (via the KLambda in `ShenOSKernel-41.1/klambda`) and
passes the official 41.1 kernel test suite (134/134). Earlier versions were
certified against the Shen 22.4 kernel test suite.

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
| `runtime.lua`  | 225 | data representation, symbol interning, the KLambda reader |
| `compiler.lua` | 825 | KLambda → Lua source compiler (statement-based codegen) |
| `prims.lua`    | 719 | runtime env: the primitive set, apply/curry machinery, native overrides, loader |
| `boot.lua`     | 112 | wires up streams, platform globals, loads the 41.1 kernel `.kl` files, runs `shen.initialise` |

Data representation (chosen so hot paths stay trace-JIT-friendly):

* numbers → Lua numbers; strings → Lua strings; KL `true`/`false` → Lua booleans
* symbols → interned tables (identity `==`); `()` → a unique `NIL`
* cons → `{h, t}` with a `Cons` metatable; vectors (absvector) → a pure-array table
  with the metatable `Vmt` (`[1]` = size, KL element `i` at `[i+2]`, no hash part —
  this keeps the size-2 prolog variables off Lua's hash-part allocation path)
* functions → Lua functions, arity tracked in a weak table; exceptions → tagged tables

### Performance work

The Prolog/typechecker hot path and the most-called kernel functions are
re-implemented natively (the officially-recommended "overwrite" peephole track):

* **Native Prolog core** (`prims.install_native_prolog`): `shen.pvar?`,
  `lazyderef`, `deref` (with structure sharing), the unification core
  (`bind!`/`lzy=`/`lzy=!`/`occurs-check?`), and `newpv`/`gc` with backtrack-time
  **pvar pooling**. Cut typechecker allocation from 2344 → ~371 B/inference.
* **Native stdlib overrides** (`prims.install_native_stdlib`): the hottest
  general functions by a real 41.1 call-frequency profile (`bench/callfreq.lua`) —
  `element?`, `assoc`, `map`, `reverse`, `shen.map-h`, `fail`, etc.
* **Arithmetic / `=` inlining**: 2-arg numeric primitives compile to a
  number-guarded fast-path instead of an `F`-table dispatch, falling back to the
  real primitive (so `tonum`'s reject-non-number semantics and late binding hold).

Together these eliminate ~97M function-table dispatches across the suite.

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

The port loads and initialises the full 41.1 kernel (including `stlib` and the new
extensions) and **passes the official 41.1 kernel test suite, 134/134**:

```sh
luajit run-41.1-tests.lua    # => "passed ... 134 / failed ... 0 / pass rate ... 100%"
```

See [41.1-STATUS.md](41.1-STATUS.md) for more detail. The old
`cert-22.4-result.txt` is historical only.

## Benchmarks

Current numbers on Apple Silicon (LuaJIT 2.1, best/min of several runs — the host
thermally throttles ~2× run-to-run, so timings are min-of-N and allocation is the
deterministic metric):

| workload | shen-lua |
|----------|---------:|
| Cold startup (compile + load the full 41.1 kernel) | ~0.71 s |
| **Full 41.1 kernel test suite** (134/134) | **~15.7 s** |
| `fib(30)` / `fib(32)` (compute-bound recursion) | ~0.015 s / ~0.041 s |
| Einstein's riddle (Prolog backtracking, CPS-heavy) | ~0.052 s / solve |
| Typechecker allocation | ~371 bytes / inference |

shen-lua is fast on startup, compute-bound code, and small Prolog solves. The
remaining gap to the fastest port — **shen-cl** on SBCL (suite in 4–8 s) — is on
the allocation-bound typechecker, where every value is a Lua table (≥~98 B) versus
SBCL's native 16 B conses. That floor is structural to the host runtime; see
`PERF-HANDOFF.md` and `BENCHMARKS.md` for the full allocation analysis and the
LuaJIT trace findings.

The historical Shen 22.4 head-to-head versus the `shen-c` 0.2.3 interpreter (same
machine) is preserved in `BENCHMARKS.md`: fib 66–79× faster, n-queens ~2.5× faster,
Einstein's riddle ~1.5× slower.
