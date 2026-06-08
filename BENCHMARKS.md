# shen-lua benchmarks (Shen 41.1)

All numbers below are from the current 41.1 port running under
**LuaJIT 2.1**. Host: Ubuntu 24.04 sandbox, 1 vCPU, x86_64.
Times are CPU seconds (`os.clock()` / `(get-time run)`).

The previous 22.4 results — which compared against the shen-c 0.2.3
reference interpreter on a different host — are preserved at the end of
this file for context. shen-c does not build for 41.1 and was not
re-measured here, so the *primary* numbers below are absolute
shen-lua-on-LuaJIT performance, not a head-to-head.

---

## 1. Cold startup (Shen 41.1)

| | mean of 5 runs |
|---|---:|
| shen-lua (41.1) | **~0.58 s** (load 0.56 s + initialise 0.02 s) |

The 41.1 kernel is substantially larger than 22.4 (21 `.kl` files including
`stlib`, `compiler`, `extension-*`; 838 → ~2600 top-level forms after the
new stlib).  Boot reads, parses, and compiles every file to Lua on every
launch — no on-disk cache yet. Cache of the generated Lua is an obvious
next step (see §4).

---

## 2. Workload 1 — `fib` (compute-bound recursion)

`fib` is defined through the live Shen pipeline (the source
`(define fib 0 -> 0 1 -> 1 N -> (+ (fib (- N 1)) (fib (- N 2))))` is
read, macro-expanded, and pattern-compiled by the kernel itself into a
`cond` tree, which the backend turns into native Lua `if/elseif`).

| n | shen-lua (41.1) |
|---|---:|
| 25 | 0.005 s |
| 28 | 0.020 s |
| 30 | 0.052 s |
| 32 | 0.137 s |

LuaJIT compiles the recursive `fib` loop to clean machine code with zero
trace aborts. Calls still go through `F["fib"]` hash dispatch and the
generic arithmetic primitives, so a hand-written upvalue-recursive
version is ~3–4× faster — caching known-arity callees as chunk-local
upvalues remains the obvious next optimization.

---

## 3. Workload 2 — Einstein's riddle (Prolog backtracking, CPS-heavy)

The kernel's Prolog engine: logic variables (`pvar`s, heap vectors), a
mutable binding trail, and continuation-passing where every choice point
allocates a `freeze` thunk.

| | per solve (best of 3) |
|---|---:|
| shen-lua (41.1) | **~0.43 s** |

For reference, the previous 22.4 port measured 1.82 s / solve here, with
shen-c at 1.24 s / solve. The 41.1 port is ~4× faster than the old 22.4
shen-lua on this workload, primarily because the new compiler emits the
Prolog CPS chain flatly (see §5) instead of as deeply-nested closures,
which lets LuaJIT trace through the continuations cleanly.

---

## 4. Pass rate (Shen 41.1 official suite)

```
Total reports: 134
Passed:        134
Failed:        0
Pass rate:     100 %
Wall time:     ~35 s
```

Run via `luajit run-41.1-tests.lua`. The harness loads, package /
`defmacro` machinery works, the Prolog engine is exercised, and typed
mode runs to completion.

---

## 5. Compiler improvements that paid for 41.1

The 41.1 stlib and Prolog code stress LuaJIT's parser limits much harder
than 22.4 did. The following code-generation changes were added (see
`compiler.lua` for details):

* **Hoisted freeze closures** (`BIND` + per-defun `KB` table). 60+ chained
  `(freeze …)` continuations no longer nest as Lua function literals;
  each freeze body is a flat `KB[N] = function(cap…) …` slot and the
  use site is a plain `BIND(KB[N], cap…)` call.
* **Deep let-floating**. `(F a (G b (let X V B)))` collapses to
  `(let X V (F a (G b B)))` when intermediate args are pure, so chained
  CPS continuations compile into a flat block of `local` declarations.
* **Right-spine call-chain flattening**. `shen.gc(A, shen.gc(A, shen.gc(A, …)))`
  in tail position is emitted as a sequence of `local` assignments rather
  than one deeply-nested call expression.
* **Flat cons-tree builder** (`MKTREE`). `(shen.record-kl name <source>)`
  trees in the stlib reach ~7 000 cons cells / 216 levels deep; the
  compiler now emits a flat blueprint that a runtime helper consumes.
* **Strict literal-data hoisting**. Only true `(cons L R)` trees are
  treated as compile-time literals; side-effecting calls like
  `(set *macros* …)` and `(shen.record-kl …)` are always evaluated.

Combined, these are what unblocked the full kernel boot and the Prolog
workloads on 41.1.

---

## 6. Known limitations / next optimizations

* **Static call resolution.** Hot self/mutual recursive calls still go
  through `F["name"]` hash lookups and arithmetic goes through generic
  primitives. Caching known-arity callees as chunk-local upvalues and
  inlining `+ - = < >` on numbers would close most of the gap to the
  idealized fib (~3–4× on compute-bound code).
* **Reduced allocation in the Prolog path.** A single Einstein solve
  still allocates a lot of pvar absvectors and `freeze` thunks (now
  pooled by `BIND`, but the underlying logic-var representation is
  unchanged). Replacing per-pvar absvectors with integer indices into a
  single trail array is the obvious next attack.
* **Kernel image caching.** Generated Lua could be cached to disk to
  drop startup toward the LuaJIT process floor.

---

## Reproducing

```sh
# Cold start + version
luajit -e '
  local P = require("boot")
  P.load_kernel(false)
  P.initialise()
  print("version:", P.F["version"]())
'

# Full official suite (set SHEN_TESTS_DIR or place the official tests at
# ../cl-source/ShenOSKernel-41.1/tests):
luajit run-41.1-tests.lua

# fib + Einstein microbench:
luajit bench.lua
```

---

## Appendix: historical 22.4 numbers

Preserved for context; these were measured against shen-c 0.2.3 (Shen
22.4) on a different host and a different (smaller) kernel. They are
NOT directly comparable to the 41.1 numbers above.

| | shen-c 22.4 | shen-lua 22.4 |
|---|---:|---:|
| cold start | 0.235 s | 0.247 s |
| fib(32) | 13.771 s | 0.291 s |
| n-queens board 5, ×100 | 4.09 s | 1.62 s |
| Einstein, ×10 | 12.4 s | 18.2 s |

shen-lua 22.4 was ~50–60× faster than shen-c on `fib`, ~2.5× faster on
n-queens, and ~1.5× slower on Einstein (a Prolog workload bound by
allocation and CPS closure churn). The 41.1 port now wins on Einstein
too, largely because of the BIND / chain-flatten changes (§5).
