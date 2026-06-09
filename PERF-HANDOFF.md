# Typechecker performance — execution handoff

> **SUPERSEDED (2026-06-09, branch `perf/native-engine`).** The incremental
> program below ended with a full architectural replacement: the typechecker
> and Prolog engine now run on a **native soa32 substrate**
> (`prolog_engine.lua` + `prolog_compile.lua` + `typecheck_native.lua`),
> validated by the WAM PoC (`bench/wam_poc_v4.lua`). Results vs the legacy
> CPS engine, same session: reference typecheck **0.061s vs 0.543s (8.9×)**,
> allocation **24 vs 344 B/inf (−93%)**, einstein **22× faster**, inference
> sequence **byte-identical (431,741)**, suite 134/134 + golden corpus 27/27
> in both engine modes. `SHEN_PROLOG_ENGINE=legacy` keeps everything below
> alive as the fallback path. The analysis below remains the measurement
> record that motivated and de-risked the rewrite.

Goal: close the gap to the Go/Rust ports (~7–10 s suite) from where we are now.

## Where we are (branch `perf/typechecker-allocation`, 134/134)

| metric | orig baseline | 68% cut (branch start) | **after B+C+D (now)** |
|---|---:|---:|---:|
| allocation / inference | 2344 B | 742 B | **~385 B** (min-of-5) |
| isolated typecheck (min-of-5, interleaved) | ~2.9 s | (branch start) | **~38% faster than branch start** |

Cumulative this branch (B+C+D): **742 → ~385 B/inf (−48%)**; matched-pair same-session
alloc 823 → 372 (−55%); isolated typecheck min-of-5 ~1.68 s → ~1.03 s (−38%). 134/134
throughout, inferences=431741 invariant held at every step.

Update log (this branch, newest first):
- **D (pvar pooling on backtrack) — DONE & committed** (`fc38255`). Freelist recycles
  the 2-slot pvar table when `gc` reclaims a failed branch's ticket (LIFO; success
  never pools). −137 B/inf (522→385). Inference count byte-identical → no exercised
  unification path perturbed. Residual escape hazard (findall snapshotting unbound
  pvars) documented inline in `prims.lua`; re-validate before reusing the pool.
- **C (native unification core) — DONE & committed** (`e39d106`). Native Lua
  `bind!`/`bindv`/`unwind`/`occurs-check?`/`lzy=`/`lzy=!`/`newpv`/`gc` in
  `install_native_prolog`, calling each other directly (no F-table dispatch, no
  KL `trap-error`-wrapped `pvar?`). −179 B/inf (701→522), ~14% faster isolated.
- **B (compact pvar/absvector) — DONE & committed** (`cddfefd`). Pure-array `Vmt`
  layout (length at `[1]`, KL elt i at `[i+2]`, no `n` hash key). −42 B/inf, ~6%
  faster, inferences unchanged. Real-base change ALSO updated `install_native_prolog`'s
  `is_pvar`/`lazyderef`/`deref` (tag at `[2]`, ticket at `[3]`, binding `v[t+2]`).
- **A (lambda → array tables) — DISPROVEN, dropped.** Implemented + validated
  134/134 but measured +1350 B/inf WORSE (cross-checked `-joff`). Tables only beat
  closures at HIGH capture counts (freeze=7–8); lambdas capture 1–5, where a LuaJIT
  closure is cheaper. Do not redo the table rep; see memory `lambda-array-table-regression`.

Hot path = the Shen typechecker, a recursive CPS Prolog engine (`klambda/t-star.kl` +
`klambda/prolog.kl`), ~990k inferences (same as every port). The cost is **per-inference
table-creation churn**, not GC sweeping and not JIT (proven: GC-stopped ≈ GC-on; trampoline
measured 45% *slower*; dispatch inlining neutral).

## Step 1 (DONE): real attribution of the current 742 B/inf

Measured (probe `/tmp/reattr.lua` + `/tmp/reattr2.lua`; reproduce with the count+size
patterns in `bench/`). Per inference:

| source | /inf | B/inf | % | notes |
|---|---:|---:|---:|---|
| **BIND freeze thunks** | 1.06 | **205** | 28% | array tables `{fn,caps…}`; dominated by 7-cap (170 B) & 8-cap (234 B) |
| **pvar absvector** | 1.29 | **189** | 25% | 100% size-2 `{n=2,[0],[1]}` = 146 B (hash-part heavy) |
| **mkfun / λ closures** | 0.75 | **166** | 22% | upval histogram 1–5 caps; each upval is a ~56 B GCupval box |
| cons | 0.36 | 35 | 5% | was 1.32/inf — structure-sharing deref cut it 73% |
| residual | — | ~147 | 20% | size-estimate slack (upval-box size, table power-of-2 rounding) + small allocators |

The three big targets — **BIND thunks 205, pvar 189, λ closures 166** — are 75% of allocation.
Note the original 5-step plan MISSED that **λ closures (166) are a top-3 target**, and that
the same array-table trick that fixed freeze thunks applies to them.

Before optimizing further: if you want to chase the ~147 residual, hook `MKLIST`/`MKTREE`
(found ~0 here) and measure GCupval-box size precisely (`debug.getupvalue` count × measured
box size); it's most likely just my size-model slack, not a hidden allocator.

## Methodology (this Mac throttles 2× run-to-run — non-negotiable)
- **Allocation B/inf is deterministic** — immune to thermal/contention. Trust it.
  `luajit bench/typecheck_alloc.lua`.
- **Timing**: thermal-controlled **interleaved A/B only** — alternate baseline↔change
  *single runs* via `git stash`↔pop, compare medians/mins. Never two separate batches.
  `bench/typecheck_time.lua` (isolated, startup excluded, min-of-5). Full-suite wall =
  best-of-3 headline only. `bench/native_deref_ab.lua` shows in-process prim A/B.
- Re-confirm `pass rate ... 100%` (134/134) after EVERY change.

## Execution playbook (revised order, by measured payoff × safety)

### A. λ closures → array tables — ❌ DISPROVEN (regression). DO NOT REDO.
Implemented and validated 134/134, but measured **+1350 B/inf WORSE** (cross-checked
with `luajit -joff`: identical numbers, so raw allocation volume, not a JIT artifact).
The premise is false for shen-lua: tables beat closures only at HIGH capture counts
(freeze = 7–8 caps), but lambdas capture only 1–5, where a LuaJIT closure is cheaper
than a metatable-tagged array-table. If revisiting lambda allocation, beta-reduce
immediately-applied monomorphic `((lambda V B) A)` at compile time instead. Original
(now-falsified) rationale preserved below for context.

<details><summary>original step A (falsified)</summary>

Same win as freeze thunks, applied to `(lambda V BODY)`. Currently
`compiler.lua` `cexpr` lambda branch (~line 599) emits
`MKFUN(1, function(V) BODY end)` capturing free vars as upvalues → ~56 B/upval box AND a
per-eval FNEW. Instead:
1. Hoist `BODY` to a chunk-constant in the `KC` table (reuse the `freeze`/control-form
   mechanism): `function(cap1..capN, V) <cexpr BODY> end`, free vars + the param `V`.
2. At the use site emit a 1-arity closure-as-data value, e.g. `LAM(KC[i], cap1..capN)`
   where `LAM` builds `setmetatable({fn,caps…}, Lambda)` with arity 1 (mirror the `Thunk`
   machinery in `prims.lua`).
3. Teach `APP` (prims.lua:44) to handle a `Lambda`-tagged table: `getmetatable(f)==Lambda`
   → call `f[1](unpack(f,2,#f), ...)`; handle under-application (extend caps, like PARTIAL)
   and exact/over-application. This generalizes the `Thunk` 0-arg case already added.
Gotcha: APP is the hottest dispatch — order the metatable check AFTER `type(f)=="function"`
(most calls are plain compiled fns). Validate the lambda-heavy tests
(`montague`, `interpreter`, the prolog interps) + 134/134. Expected: removes upval boxing
+ per-eval FNEW for lambdas.

</details>

### B. Compact pvar / absvector representation — ✅ DONE (committed; −42 B/inf min-of-5)
The size-2 pvar is 146 B because `{n=2,[0],[1]}` forces a hash part (string key `n` alone
does it). Pure-array layout (KL index `i` → array slot `[i+2]`, length at `[1]`, no `n`
key) → ~98 B. An agent verified a maximal-array variant kept the typecheck correct
(total 2345→2282). Touch atomically (all hard-code `{n,[0..n-1]}`):
`prims.lua` `absvector`/`<-address`/`address->`/`absvector?`/`vector`, the vector branch of
`equal` (~prims.lua:80), `to_str` (`runtime.lua` ~208), **and** the native prims in
`install_native_prolog` (read `x.n`/`x[0]`/`x[1]`). Use a fresh unique `Vmt` metatable for
`absvector?` (current discriminator is `getmetatable(x)==nil`).

### C. Native unification core (dispatch + cons; med risk)
Extend `install_native_prolog` (prims.lua) to `shen.bind!`, `shen.lzy=`, `shen.lzy=!`,
`shen.unify`, `shen.newpv` (see `klambda/prolog.kl`). Per-inference, compiled-KL dispatch +
the cons `lzy=` builds for tail-unification continuations. Native tight versions cut
dispatch and let you structure-share. This is what shen-c's `overwrite.c` does. Semantics
must match EXACTLY: occurs check (`shen.*occurs*`), binding trail / `shen.unwind`. Doing
`newpv` natively here also sets up D.

### D. pvar pooling (after C; high risk, eliminates most of the 189 B/inf)
pvars have a lifetime bounded by the prolog ticket/backtrack system: `newpv`/`nextticket`
allocate, `shen.gc`/`shen.unwind` reclaim on backtrack. A freelist keyed on ticket
reclamation reuses the 2-slot vectors instead of allocating. SAFER than thunk pooling
(thunks can be re-thaw'd on backtracking; pvars have explicit reclamation). Prototype behind
a flag; validate hard on `einsteins-riddle` + the prolog tests + 134/134. (BIND thunks at
205 B/inf are NOT poolable — continuations may be thaw'd multiple times — and are near-
minimal as tables; leave them unless you can reduce freeze captures algorithmically.)

### E. FFI tagged-value arena (separate project; the only way past the 98 B cons floor)
A Lua-table cons can't go below ~98 B. To match Go/Rust's 16–24 B, represent the prolog
binding store + pvars as flat LuaJIT **FFI `cdata`** with NaN-boxed/tagged 64-bit values and
a bump arena, bypassing the Lua allocator + GC for the hot region. Scope to the prolog
engine only; do NOT rewrite the whole value layer. Biggest ceiling, biggest effort.

### Also: re-check JIT engagement
Allocation is now 3× lower → traces may stay hotter. `luajit -jv run-41.1-tests.lua 2>&1 |
grep -c flush` (290 at baseline → ~84 after IIFE work). Re-test `-O` cache params and the
JIT on/off ratio; could be a free win now.

## Gotchas (don't relearn these)
- An **inline** Lua function literal allocates ~40 B even with **zero upvalues** (FNEW runs
  per eval). Only a function created **once at load** (chunk-scope `KC` table) is free.
- LuaJIT boxes **each captured upvalue as a separate ~56 B object** — capturing N vars costs
  ~56N B. Array tables `{a,b,c}` are far cheaper. (Why thunks/λ become tables; and why
  "extend BIND's explicit arms to n≤8" made things WORSE — more upval boxes. Don't redo it.)
- Dispatch inlining (`F["="]`→`EQ`) is **neutral** on LuaJIT; localizing globals is
  **negative** (bloats closures). Don't redo.
- `deref` structure-sharing (return the original cons when nothing changed) is semantically
  transparent and cut cons 73%. Apply the same idea anywhere a prim rebuilds structure.
- The `cbodies`→`KC` chunk-scope hoist is the canonical "create once, not per call" pattern.

## Key files
- `compiler.lua` — `cexpr` (control-form/`freeze`/`lambda` branches), `cdefun` (KC emit), `new_ctx`.
- `prims.lua` — `BIND`/`thaw`/`APP` + `Thunk`; `install_native_prolog`. Add `Lambda` here for A.
- `boot.lua` — `P.install_native_prolog()` at end of `load_kernel`.
- `bench/` — harness. Memory `shen-lua-perf-tracing-jit` — full findings log.
