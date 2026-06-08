# Typechecker performance — execution handoff

Goal: close the gap to the Go/Rust ports (~7–10 s suite) from where we are now.

## Where we are (branch `perf/typechecker-allocation`, 134/134)

| metric | baseline | now |
|---|---:|---:|
| allocation / inference | 2344 B | **742 B** (−68%) |
| isolated typecheck (GC on) | ~2.9 s | **~1.14 s** |
| full suite, best of 3 | ~40 s | **~22 s** |

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

### A. λ closures → array tables (NEW; ~166 → ~80 B/inf; med risk, high value)
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

### B. Compact pvar / absvector representation (−63 B/inf measured; med risk)
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
