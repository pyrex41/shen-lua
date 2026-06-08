# shen-lua benchmarks

All numbers are **same-machine** comparisons against the reference interpreter
**shen-c 0.2.3 (Shen 22.4)**, built here with `gcc -O3 -fno-optimize-sibling-calls
-fsigned-char`. Host: Ubuntu 24.04, 1 vCPU, x86_64. LuaJIT 2.1.1703358377 (Lua 5.1).

Timing methodology:

* **Compute time** for fib/queens uses the kernel's own `(time EXPR)` (= `get-time run`,
  i.e. CPU seconds) on the LuaJIT side, and wall-clock with baseline subtraction where
  shen-c's `(time)` output was unreliable (shen-c block-buffers stdout and segfaults on
  EOF teardown, so its last lines are often lost).
* fib is measured **after** a JIT warm-up call.
* shen-c is always run through `stdbuf -oL`; the EOF segfault is cosmetic (it occurs
  after the work completes).

---

## 1. Cold startup

| | mean of 5 runs |
|---|---:|
| shen-c 0.2.3 | **0.235 s** |
| shen-lua | **0.247 s** |

Essentially equal. Notable because shen-c loads a *pre-rendered* KLambda image, whereas
shen-lua **re-reads and compiles all 18 kernel `.kl` files (838 top-level forms) to Lua
on every boot**. Compiling the kernel from source is roughly as cheap as the C
interpreter's startup. (Caching the generated Lua would cut this further; not yet done.)

---

## 2. Workload 1 — `fib` (compute-bound recursion)

`fib` is defined through the **real Shen pipeline**: the source
`(define fib 0 -> 0 1 -> 1 N -> (+ (fib (- N 1)) (fib (- N 2))))` is read, macro-expanded,
and pattern-compiled by the kernel itself into
`(defun fib (V) (cond ((= 0 V) 0) ((= 1 V) 1) (true (+ (fib (- V 1)) (fib (- V 2))))))`,
which our backend turns into native Lua `if/elseif` with direct table dispatch. This is
the certifiable, apples-to-apples number.

| n | shen-c | shen-lua (certified) | speedup |
|---|---:|---:|---:|
| 25 | 0.531 s | 0.009 s | ~59× |
| 28 | 2.145 s | 0.040 s | ~54× |
| 30 | 5.247 s | 0.100 s | ~52× |
| 32 | 13.771 s | 0.291 s | ~47× |

**~50–60× faster.** This is the trace JIT's sweet spot: a tight, monomorphic,
allocation-free recursive loop. LuaJIT compiles it to clean machine code with **zero
trace aborts**.

*Idealized upper bound:* a hand-written KL fib with explicit `if` and direct upvalue
recursion (no `F[...]` table dispatch) runs ~3–4× faster still (≈200× vs shen-c). The
gap between that and the certified number is the cost of the kernel's real calling
convention — every call is an `F["name"]` hash lookup and every arithmetic op goes
through the generic primitive. Resolving statically-known calls to upvalues is the
obvious next optimization (see §5).

---

## 3. Workload 2 — allocation- and Prolog-heavy programs

These reflect the "real character" of Shen: pattern matching, list building, and the
Prolog/unification engine.

### 3a. n-queens (functional, allocation-heavy, but no CPS)

Exhaustive solution enumeration; builds and discards many lists, dispatches through the
pattern matcher. Board 5, ×100 iterations, wall-clock with baseline subtracted:

| | compute (100×) | per solve |
|---|---:|---:|
| shen-c | 4.09 s | 40.9 ms |
| shen-lua | **1.62 s** | **16.2 ms** |

**~2.5× faster.** The list-building loops trace well and LuaJIT's allocation sinking +
fast GC keep up.

**Robustness:** at **board 6, shen-c segfaults** — the deep non-tail recursion overflows
its C stack (it is compiled `-fno-optimize-sibling-calls`, and `n-queens-loop` conses
around its recursive call so it cannot be a tail call). **shen-lua completes board 6**
(~0.23 s/enumeration) because LuaJIT gives us real tail calls and a large growable stack.

### 3b. Einstein's riddle (Prolog backtracking — CPS + heavy allocation)

The kernel's Prolog engine: logic variables (`pvar`s, heap vectors), a mutable binding
trail, and **continuation-passing** where every choice point allocates a `freeze` thunk.
×10 solves, wall-clock with baseline subtracted:

| | compute (10×) | per solve |
|---|---:|---:|
| shen-c | **12.4 s** | **1.24 s** |
| shen-lua | 18.2 s | 1.82 s |

**~1.5× slower.** This is the one workload class where the C interpreter wins, and the
reason is instructive (§4).

---

## 4. Honest JIT analysis — what didn't trace well, and why

Both fib and Einstein were profiled with `luajit -jv`:

| | trace events | aborts |
|---|---:|---:|
| fib | 1463 | **0** |
| Einstein | 3355 | **0** |

The Prolog code **does not suffer trace aborts** — it is not an NYI/bailout problem. The
slowdown is **allocation and GC pressure**, which the trace JIT cannot remove because the
allocations are *semantically required*:

* **Measured: a single Einstein solve allocates ≈343 MB.** Every unification step conses,
  every logic variable is a freshly-allocated absvector, the binding trail churns, and
  every Prolog choice point allocates a fresh `freeze` closure (continuation). At ~1.8 s
  and 343 MB/solve, the bottleneck is the allocator and the GC sweep, not arithmetic.
* **Trace explosion from polymorphism.** 3355 trace events vs fib's 1463: the Prolog
  dispatch is highly polymorphic (the generic `APP` is called with many different callee
  shapes; `deref`/`lazyderef` see cons / pvar / atom interchangeably), so LuaJIT spawns
  many short root+side traces and spends proportionally more time at trace transitions
  and in the interpreter between them.
* **Indirect dispatch.** Continuations are invoked through `thaw`/`APP` (an indirect call
  through a value of unknown arity), which is far less trace-friendly than fib's
  statically-resolved `F["fib"]` self-calls.

By contrast, shen-c is a straightforward C tree-walker with a **mature, tuned GC and very
low per-operation constant factors**; on an allocation-bound workload it has nothing to
JIT-compile *away* but also no JIT/trace overhead, and its allocator simply wins.

**Summary of the performance profile:**

| workload character | example | result |
|---|---|---|
| tight numeric recursion | fib | LuaJIT dominates (~50–60×) |
| functional, list-building | n-queens | LuaJIT wins (~2.5×) + more robust |
| CPS + heavy allocation | Prolog (Einstein) | C interpreter wins (~1.5×) |

The takeaway matches LuaJIT's known strengths: it converts computation into fast machine
code spectacularly, but it cannot optimize away allocation that the program's semantics
demand, and a low-overhead C interpreter with a good GC is hard to beat on allocation-bound
logic programming.

---

## 5. Known limitations / next optimizations

* **Static call resolution.** Hot self/mutual recursive calls still go through
  `F["name"]` hash lookups and arithmetic through generic primitives. Caching known-arity
  callees as chunk-local upvalues and inlining `+ - = < >` on numbers would close most of
  the gap to the idealized fib (≈3–4× on compute-bound code).
* **Reduced allocation in the Prolog path.** Representing logic variables more cheaply
  (e.g. a single trail array with integer indices instead of per-pvar absvectors) and
  pooling/avoiding continuation closures would directly attack the 343 MB/solve figure.
* **Kernel image caching.** Generated Lua could be cached to disk to drop startup toward
  the LuaJIT process floor.
* **shen-sbcl upper-reference baseline** (offered in the brief) was not built; SBCL is
  installed and this remains available as a native-compilation reference point.

## Reproducing

```sh
# fib (certified pipeline)
luajit bench_fib_cert.lua ; luajit bench_fib32.lua
# n-queens / einstein (both engines) — see bench/w2/
# certification
SHEN_TESTS=/path/to/shen-22.4/tests ./run-cert.sh
```
