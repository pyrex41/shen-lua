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

## Quick start

```sh
git clone https://github.com/pyrex41/shen-lua && cd shen-lua
bin/shen                            # REPL: multiline input, history, helpful errors
bin/shen -e "(+ 1 2)"               # one-liner
bin/shen examples/family.shen       # run a program (Shen Prolog in 20 lines)
luajit examples/hello_embed.lua     # embed Shen in a Lua program in ~25 lines
luajit examples/config_check.lua    # the showcase: a typed validation layer for Lua data
```

The only requirement is **LuaJIT 2.1** (`brew install luajit` /
`apt-get install luajit`); plain Lua 5.1/5.4/5.5 also works (slower — see the
compatibility tier below). The first boot compiles the kernel (~1 s); after
that the bytecode cache boots it in ~30 ms, and loaded programs are cached
fasl-style, so everything is fast from the second run on.

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

| File | Role |
|------|------|
| `runtime.lua`  | data representation, symbol interning, the KLambda reader |
| `compiler.lua` | KLambda → Lua source compiler (statement-based codegen, tail-call → loop lowering) |
| `prims.lua`    | runtime env: the primitive set, apply/curry machinery, native overrides, loader |
| `boot.lua`     | kernel loading, the bytecode + fasl caches, `shen.initialise` |
| `shen.lua`     | the public embedding API (`require("shen")`) |
| `lua_interop.lua` | the Lua ⇄ Shen bridge (`lua.call`, `lua.function`, marshaling) |
| `repl.lua`     | the interactive REPL (multiline input, error translation, backtraces) |
| `prolog_engine.lua` / `prolog_compile.lua` / `typecheck_native.lua` | the native soa32 Prolog/typecheck engine |

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

Two caches make warm starts near-instant (both content-keyed, both safe to
delete at any time):

* **Kernel bytecode cache** — the compiled kernel is `string.dump`ed after the
  first boot (`.shen-kernel-cache.bin`); warm boots load it in **~30 ms**
  instead of recompiling (~1 s).
* **User fasl cache** — `(load "prog.shen")` records its compiled chunks and
  replays them on later runs, skipping the reader, macroexpansion *and
  typechecking* (SBCL-fasl semantics: it typechecked when it compiled).
  Invalidation is make-style: edit a file and everything loaded after it
  recompiles. `SHEN_FASL=off` disables; `SHEN_FASL_DIR` relocates
  (default `~/.cache/shen-lua-fasl`).

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

The REPL reads multiline forms (it tracks paren balance through strings and
comments), keeps history (`~/.shen_history` with linenoise/readline installed,
or run under `rlwrap`), and translates Lua-level failures into useful errors:
undefined functions get a *did-you-mean* suggestion, and uncaught errors print
a backtrace of **Shen** function names with the Lua plumbing filtered out.

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

## Calling Lua from Shen (and Shen from Lua)

Every Shen value *is* a Lua value, and the bridge is first-class in both
directions (`lua_interop.lua`):

```shen
(lua.call "string.format" ["%s: %d" "answer" 42])  \\ any Lua function by dotted path
(lua.require "cjson")                              \\ modules come back as opaque boxes
(lua.method Obj "name" Args)                       \\ obj:name(...)
```

The headline feature is the **typed bridge** — `lua.function` registers a Lua
function as a real Shen function *with a declared type*, so typechecked Shen
code can call into Lua and the call sites are proved sound under `(tc +)`.
From the Lua side, `shen.fn`/`shen.call` make any Shen function (including
curried partials) an ordinary Lua callable. Marshaling rules are documented
exhaustively at the top of `lua_interop.lua`.

## Examples

| | |
|---|---|
| `examples/hello_embed.lua` | the smallest useful embedding: boot, define a typed function, call it both ways (~25 lines) |
| `examples/family.shen` | Shen Prolog in twenty lines: facts, rules, queries via `bin/shen` |
| `examples/config_check.lua` | the showcase: Shen datatypes + rules as a **typed validation layer** for nested Lua config tables — the typechecker rejects buggy rules at load time ([walkthrough](examples/README.md)) |

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

Current numbers on Apple Silicon (LuaJIT 2.1, interleaved min-of-N — the host
thermally throttles run-to-run, so timings are mins and allocation is the
deterministic metric):

| workload | time |
|----------|-----:|
| Kernel boot, cold (compile all `.kl`) | ~0.7 s |
| Kernel boot, warm (bytecode cache) | **~0.03 s** |
| **Full 41.1 test suite, warm** (kernel + fasl caches) | **~2.3 s** |
| Full 41.1 test suite, cold (caches off) | ~5.4 s |
| Reference typecheck (431,741 inferences) | ~0.061 s (8.9× vs legacy engine) |
| Typechecker allocation | ~24 B/inf (−93% vs legacy) |
| Einstein's riddle (Prolog backtracking) | ~0.002 s / solve (22× vs legacy) |
| Single-file bundle: require + boot + eval, from nothing | ~70 ms |

Measured against the fastest port — **shen-cl** on SBCL, same machine, suite in
~1.6 s — the warm-cache gap is **~1.5×**, down from 5.5× before the caching and
native-engine work. The big steps, in order: the native soa32 engine (terms as
plain numbers over flat int32 storage, continuations as integers, replacing the
allocation-bound CPS model), the kernel bytecode + user fasl caches, raising
LuaJIT's mcode/trace limits (the default 512 KB area caused constant
trace-cache flushes), and native overrides for the hottest kernel predicates.
See `PERF-HANDOFF.md` and `BENCHMARKS.md` for the full measurement history
(including the disproven levers).

The historical Shen 22.4 head-to-head versus the `shen-c` 0.2.3 interpreter (same
machine) is preserved in `BENCHMARKS.md`: fib 66–79× faster, n-queens ~2.5× faster,
Einstein's riddle ~1.5× slower.
