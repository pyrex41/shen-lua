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

The headline: **the Prolog engine and typechecker run on a native soa32
substrate** that replaces the compiled-KL CPS execution model entirely —
designed around what LuaJIT's tracing JIT rewards:

* **`prolog_engine.lua` — the soa32 substrate.** Terms are plain Lua numbers,
  range-tagged (atom < 2²⁴ ≤ var < 2²⁵ ≤ cons) over `int32_t` FFI arrays; tag
  tests are `<` compares, payloads are subtractions, **zero bit ops and zero
  64-bit cdata** (int64 tag-packing measured 2.2× slower — see
  `bench/wam_poc_v4.lua`). Iterative explicit-stack unification with batch
  trail unwind; **defunctionalized continuations** (integer handles into an
  int32 capture buffer — no freeze closures); choice points live in Lua stack
  frames as plain-local marks; cut is a 1:1 transcription of the kernel's
  lock algorithm.
* **`prolog_compile.lua` — the clause compiler retarget.** The kernel's own
  `shen.compile-prolog` still runs (its output is the spec); its emitted
  define-form is *translated* into direct-coded Lua against the substrate ABI,
  lazily on first dispatch. Covers `defprolog`, `prolog?` queries, datatype
  rules, and asserta/retract through one seam, with the legacy CPS engine
  dual-registered as the per-predicate fallback.
* **`typecheck_native.lua` — the t-star driver.** The ~16 CPS driver functions
  are machine-translated from `klambda/t-star.kl` through the same translator
  (they share the goal vocabulary); the four that escape it (entry,
  signature lookup, datatype search, spy display) are hand-ported. The 162
  kernel signatures are harvested from `init.kl` into a native table. The
  native driver performs the **byte-identical inference sequence** to the
  legacy engine (431,741 inferences on the reference typecheck, exactly).
* **Legacy native overrides** (`prims.lua`): native Prolog deref core with
  pvar pooling, native stdlib (`element?`, `assoc`, `map`, …), and
  arithmetic/`=` inlining (~97M dispatches eliminated) — these still serve
  the `SHEN_PROLOG_ENGINE=legacy` fallback path.

`SHEN_PROLOG_ENGINE=legacy` disables the engine; `SHEN_TYPECHECK_NATIVE=off`
and `SHEN_PROLOG_NATIVE=off` disable the typechecker/query routing
individually. Correctness never depends on native coverage: anything the
translator refuses simply keeps its legacy definition.

## Requirements

* **LuaJIT 2.1** (Lua 5.1 semantics). On Debian/Ubuntu: `apt-get install luajit`.
* Nothing else — the **Shen 41.1 KLambda sources** (`klambda/`) are vendored in this
  repository for a self-contained clone-and-run experience. You can still point
  `SHEN_KL_DIR` at an external checkout if you are working against a different
  ShenOSKernel tree.

No build step is needed — the kernel is compiled from `.kl` to Lua **on boot**. 

### PUC-Lua compatibility tier

The port also runs on **plain PUC Lua** (tested: 5.1.5, 5.4.8, 5.5.0), passing
the same 134/134 kernel test suite. Everything JIT-specific is feature-detected
at boot and degrades gracefully:

* **Prolog/typecheck engine** — the native soa32 engine needs the LuaJIT FFI;
  without it the port automatically falls back to the compiled-KL CPS engine
  (the same path as `SHEN_PROLOG_ENGINE=legacy`).
* **Kernel bytecode cache + user fasl cache** — keyed by FNV-1a hashes that use
  LuaJIT's `bit` library; without it both caches self-disable (pure perf
  features — the kernel just recompiles on every boot, ~0.4s).
* **Lua 5.3+ integer subtype** — Lua 5.3+ int64 arithmetic *wraps* on overflow,
  while the kernel assumes the IEEE-double model (LuaJIT/5.1); on 5.3+ the
  arithmetic primitives compute in the float domain, reproducing LuaJIT's
  number model exactly.

Expect roughly **2x slower** than LuaJIT on the suite (legacy engine, no
caches) — correct, but LuaJIT remains the recommended runtime.

## Installation & embedding

### The `shen` module

```lua
local shen = require("shen")          -- with the repo (or install) on package.path
shen.boot{quiet=true}                 -- load kernel + (shen.initialise); idempotent
shen.eval('(define square X -> (* X X))')   -- full Shen syntax; returns last value
print(shen.call("square", 9))         --> 81  (curried if given fewer args)
local sq = shen.fn("square")          -- plain Lua callable (tracks redefinition)
shen.list({1,2,3})                    -- Lua array  -> cons list
shen.totable(shen.eval("[a b c]"))    -- cons list  -> Lua array
shen.sym("foo")                       -- interned symbol
shen.value("*version*")               -- Shen global
shen.tostring(x)                      -- render any Shen value
```

`shen.prims` / `shen.runtime` expose the underlying layers (function table
`prims.F`, reader, printer) for advanced embedding.

### The `bin/shen` launcher

```sh
bin/shen                       # interactive REPL
bin/shen prog.shen ...         # (load) each file, then exit
bin/shen -e "(+ 1 2)"          # evaluate and print (mixes with files, in order)
bin/shen -q prog.shen          # -q hushes load echo
```

### luarocks

```sh
luarocks make --local shen-scm-1.rockspec   # installs the modules + the `shen` launcher
```

(LuaJIT required — declared as `lua == 5.1`; run the launcher with a
luarocks tree whose interpreter is LuaJIT.)

### Single-file bundle

```sh
luajit build/make-bundle.lua    # -> build/shen-bundle.lua (~6 MB, self-contained)
```

`shen-bundle.lua` embeds the Lua modules, the precompiled kernel bytecode and
the `.kl` sources (fallback for a different LuaJIT build). Drop the one file
anywhere and:

```lua
local shen = require("shen-bundle")
shen.boot{quiet=true}            -- boots from embedded bytecode in ~tens of ms
print(shen.eval("(+ 1 2)"))      --> 3
```

## Running a program

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
lua    run-41.1-tests.lua    # same result on PUC Lua 5.1 / 5.4 / 5.5 (slower)
```

(The driver chdirs into the test directory via the FFI under LuaJIT; under PUC
Lua it uses `lfs` if available, else transparently prefixes relative paths in
the `open` primitive. `SHEN_TESTS_DIR` overrides the test-suite location.)

See [41.1-STATUS.md](41.1-STATUS.md) for more detail. The old
`cert-22.4-result.txt` is historical only.

## Benchmarks

Current numbers on Apple Silicon (LuaJIT 2.1, best/min of several runs — the host
thermally throttles ~2× run-to-run, so timings are min-of-N and allocation is the
deterministic metric):

| workload | legacy engine | **native soa32 engine** |
|----------|--------------:|------------------------:|
| Cold startup (compile + load the full 41.1 kernel) | ~0.71 s | ~0.71 s |
| **Full 41.1 kernel test suite** (134/134) | ~16 s | **~11 s** |
| Reference typecheck (431,741 inferences) | ~0.54 s | **~0.061 s (8.9×)** |
| Typechecker allocation | ~344–371 B/inf | **~24 B/inf (−93%)** |
| Einstein's riddle (Prolog backtracking) | ~0.044 s / solve | **~0.002 s / solve (22×)** |
| `fib(30)` / `fib(32)` (compute-bound recursion) | ~0.015 s / ~0.041 s | (same — not Prolog) |

The native engine closes most of the gap to the fastest port — **shen-cl** on
SBCL (suite in 4–8 s) — by removing the allocation-bound CPS execution model
(freeze-closures + currying) rather than fighting it: terms became plain
numbers over flat int32 storage, and continuations became integers. See
`PERF-HANDOFF.md` and `BENCHMARKS.md` for the measurement history that led
here (six disproven levers, the WAM PoC, and the soa32 verdict).

The historical Shen 22.4 head-to-head versus the `shen-c` 0.2.3 interpreter (same
machine) is preserved in `BENCHMARKS.md`: fib 66–79× faster, n-queens ~2.5× faster,
Einstein's riddle ~1.5× slower.
