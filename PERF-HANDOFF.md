# Typechecker performance — handoff

Goal: close the remaining gap to the Go/Rust ports on the 41.1 kernel test suite.

## Where we are

Branch `perf/typechecker-allocation`. All numbers vs the pre-branch baseline, **134/134**:

| metric | baseline | now |
|---|---:|---:|
| allocation / inference | 2344 B | **745 B** (−68%) |
| isolated typecheck (GC on) | ~2.9 s | **~1.14 s** |
| full suite, best of 3 | ~40 s | **~22 s** |

The hot path is the Shen typechecker = recursive continuation-passing-style Prolog
(`klambda/t-star.kl` + `klambda/prolog.kl`), same ~990k inference count as every other
port. **The cost is per-inference table-creation churn through LuaJIT's allocator**, not
GC sweeping (GC-stopped time ≈ GC-on time) and not JIT non-engagement (JIT-on was only
~23% faster than -joff; a trampoline was measured 45% *slower*).

## Realistic target

shen-cl's ~2 s is an **SBCL outlier**. Even AOT-compiled shen-rust/shen-go run the suite
in ~7 s (~3.5× slower than SBCL). They allocate per-inference too — they just use compact
reps (16–24 B cons vs our 98 B; ~48 B pvar vs our 146 B) + native deref loops. **Target:
the ~7–10 s Rust/Go ballpark.** We need roughly another 2–3×; it's in reach but the last
push needs object-size cuts, which is where Lua fights back (a `{}`-table is ~56–98 B min).

## How to measure (READ THIS FIRST — the methodology is the hard part)

This Mac thermally throttles hard; the same test varies 2× run-to-run. Rules:
- **Allocation (B/inf) is deterministic** — immune to thermal/contention. Trust it. Use
  `luajit bench/typecheck_alloc.lua` (collectgarbage stop + count() delta / inferences).
- **Timing is noisy.** For A/B, use the **thermal-controlled interleaved** method: alternate
  baseline vs change *single runs* (`git stash` ↔ pop) and compare medians/mins. Never
  compare two separate batches. `bench/typecheck_time.lua` = one isolated 431k-inf
  typecheck, startup excluded, min-of-5.
- Full-suite wall (`/usr/bin/time -p luajit run-41.1-tests.lua`) is best-of-3 only, for the
  headline — too noisy for deltas.
- `bench/native_deref_ab.lua [current|native]` patterns show how to A/B a prim override
  in-process. `bench/trampoline_microbench.lua` is the standalone shape experiment.
- Always re-confirm `pass rate ... 100%` (134/134) after every change.

## Next levers (ranked: do them in this order)

### 1. RE-ATTRIBUTE the new 745 B/inf FIRST (cheap, high value)
At 2344 B/inf the dominant source (freeze-body `KB` table rebuilt per impl call) was
*invisible* until directly hunted — it could happen again. Before optimizing, re-run the
attribution at 745 B/inf: instrument `R.cons`, `F["absvector"]`, `ENV.BIND`/`MKFUN`, and
**stub-bisect** (stub a constructor to a shared object, measure the total-B/inf drop = its
share). The original stub-bisection agent died on a session limit, so this was never
finished. Find the new dominant source before guessing. Probes to copy: `bench/*` +
the patterns in the `shen-lua-perf-tracing-jit` memory.

### 2. Compact pvar / absvector representation (−63 B/inf, measured; med risk)
The size-2 prolog variable is **146 B** because `{n=2,[0],[1]}` forces a hash part (the
string key `n` alone does it). A pure-array layout (store length at slot 1, KL index `i`
at `[i+2]`, no `n` key) is ~98 B — an agent verified a maximal-array variant kept the
typecheck correct and dropped total 2345→2282. pvars are 1.29/inf, so this is ~189→~127
B/inf. Touch points that hard-code `{n,[0..n-1]}`: `prims.lua` `absvector`/`<-address`/
`address->`/`absvector?`/`vector`, the vector branch of `equal` (~prims.lua:80), `to_str`
(runtime.lua ~208), **and** the native prims in `install_native_prolog` (they read
`x.n`/`x[0]`/`x[1]`). Change them atomically. Use a fresh unique `Vmt` metatable for
`absvector?` (distinct from Cons/Stream/Excn), since the current discriminator is
`getmetatable(x)==nil`.

### 3. Native unification core (dispatch + cons cut; med risk)
Extend `install_native_prolog` to `shen.bind!`, `shen.lzy=`, `shen.lzy=!`, `shen.unify`
(see `klambda/prolog.kl`). These run per inference as compiled KL (F-dispatch + the cons
that `lzy=` builds for tail-unification continuations). Native tight versions cut dispatch
and let you structure-share like `deref`. This is what shen-c's `overwrite.c` does. Verify
each against 134/134 — unification semantics (occurs check via `shen.*occurs*`, binding
trail/unwind) must match exactly.

### 4. pvar pooling (big win, HIGH risk)
pvars (1.29/inf, the biggest object churn) have a lifetime bounded by the prolog
ticket/backtrack system: `shen.newpv`/`shen.nextticket` allocate, `shen.gc`/`shen.unwind`
reclaim on backtrack. A freelist keyed on ticket reclamation could reuse the 2-slot
vectors instead of allocating fresh — potentially −127+ B/inf and the creation cost. The
hazard: reusing a pvar that's still referenced in a surviving branch. Prototype behind a
flag, validate hard against the prolog-heavy tests (einsteins-riddle, the prolog interp
tests) + 134/134. Make `newpv`/`gc` native first (#3) so the pool is in one place.

### 5. FFI tagged-value arena (research; the only path to truly match Go/Rust cons size)
cons is 98 B (Lua table + metatable) vs 16–24 B in C/Rust and **cannot shrink** as a Lua
table. The "no Lua port has done this" idea: represent prolog-internal data (binding store,
pvars, maybe cons) as flat LuaJIT **FFI `cdata`** with NaN-boxed/tagged 64-bit values and a
bump arena, bypassing the Lua allocator + GC for the hot region. Huge effort, biggest
ceiling. Scope it to the prolog engine only (don't rewrite the whole value layer). Treat
as a separate project after 1–4.

### Also worth a quick look
- **Re-check JIT engagement** now that allocation is 3× lower: `luajit -jv run-41.1-tests.lua
  2>&1 | grep -c flush` (was 290 at baseline, ~84 after IIFE work). Fewer allocations on a
  trace = traces may now stay hot; re-test `-O` cache params and JIT on/off ratio. Could be
  a free win.
- **Profile the FULL suite allocation**, not just the one typecheck — other tests
  (einstein, prolog interps) may now be a meaningful slice of the 22 s.

## Gotchas learned (don't relearn these the hard way)
- An **inline** Lua function literal allocates ~40 B even with **zero upvalues** (FNEW runs
  per eval). Only a function created **once at load** (chunk scope / `KC` table) is free.
- LuaJIT boxes **each closed-over upvalue as a separate ~56 B GCupval** — so capturing N
  vars in a closure costs ~56N B. Array tables `{a,b,c}` are far cheaper than an N-upvalue
  closure. (This is why freeze thunks became `{fn,caps...}` tables, and why "extend BIND's
  explicit arms" made things *worse* — more upvalue boxes.)
- Dispatch inlining (`F["="]`→`EQ`) is **neutral** on LuaJIT (the JIT already specializes
  it). Localizing globals to upvalues is **negative** (bloats closures). Don't redo these.
- `deref` structure-sharing (return the original cons when nothing changed) is semantically
  transparent and saves most of deref's cons — c/rust don't do it.
- The compiler's `cbodies`→`KC` chunk-scope hoist is the pattern for "create once, not per
  call"; reuse it for any new per-call closure you find.

## Key files
- `compiler.lua` — `cexpr` control-form + `freeze` branches (KC hoist), `cdefun` (KC table emit), `new_ctx`.
- `prims.lua` — `BIND`/`thaw`/`APP` (array-table `Thunk`), `install_native_prolog` (native deref core).
- `boot.lua` — calls `P.install_native_prolog()` at end of `load_kernel`.
- `bench/` — measurement harness. Memory `shen-lua-perf-tracing-jit` — full findings log.
