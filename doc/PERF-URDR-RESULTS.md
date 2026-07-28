# Urdr pure-Shen SHA workload — port-side performance results

Branch: `perf/urdr-workload`  
Host: macOS arm64, LuaJIT 2.1 rolling (`/Users/reuben/.local/Homebrew/bin/luajit`)  
Pins: urdr suites under `shen/tests/{prng,world,search}`; shen-cl baseline
`urdr-shen-cl-41.2/bin/sbcl/shen script …`.

Invocation (warm fasl; no `script` subcommand on shen-lua):

```bash
export PATH="/Users/reuben/.local/Homebrew/bin:$PATH"
export SHEN_LUA=/Users/reuben/projects/shen-lua/bin/shen
export SHEN_CL=/Users/reuben/projects/urdr-shen-cl-41.2/bin/sbcl/shen
cd /Users/reuben/projects/urdr
/usr/bin/time -lp $SHEN_LUA shen/tests/prng/run-tests.shen
/usr/bin/time -lp $SHEN_CL script shen/tests/prng/run-tests.shen
```

Wall times are thermally noisy on this host; prefer **user+sys CPU**,
**min-of-N / median of serial warm runs**, and dual-cache interleaved A/B
when comparing two SHAs.

## Series on this branch (vs `main` @ c85ad7e)

| Commit | Change | Primary measured effect |
|--------|--------|-------------------------|
| `58c3d9c` | fasl lambdatable-by-name (SHENFASL5) | trivial startup **1.5s → 0.34s** warm; 21/21 StLib fasl-cacheable |
| `913bc99` | `--hush-load` / `SHEN_HUSH_LOAD=1` | silence load echo only; golden runners usable (issue #46 item 3) |
| `d3ecc91` | codegen exact-arity `(cons A B)` inline | prng wall best-of-5 **3.20s → 1.43s (−55%)**; 0 blacklisted traces |
| `082e872` | default GC pause 400 (`SHEN_GC`) | ~−15% prng / −20% world CPU; peak RSS ~30→60 MB |
| `b396fed` | native `fn` fast path | prng CPU **~−27%**, world **~−12%** (interleaved A/B) |
| *(this)* | native iterative `append` | prng CPU med **~−3%**, mean **~−4 to −8%**; world med **~−19%** (serial warm) |

## Current tip vs shen-cl (warm, this session)

| Suite | shen-lua (user+sys, serial warm med) | shen-cl (`script`, wall) |
|-------|--------------------------------------|---------------------------|
| `shen/tests/prng` | ~0.87–1.0 s CPU (tip after append) | ~1.1–1.3 s wall / ~1.0 s CPU |
| `shen/tests/world` | ~2–3 s CPU (high variance) | ~1.75–1.85 s wall / ~1.6 s CPU |

Gap to CL is now roughly **1–2×** on prng (was ~12× at branch start with cold
fasl / uncached StLib). Remaining cost is dominated by pure-Shen bit-list
SHA-256 / bigint arithmetic, not load or `fn`.

## Profiling snapshot (prng warm, after `fn` fix, before append)

`jit.p` modes (suite load only, post-boot):

| mode | top signals |
|------|-------------|
| `v` | ~38% Compiled / ~29% Interpreted / ~28% GC / ~5% JIT |
| `Fl` (leaf) | `byte.bits` 22%, `byte.bits.weights` 13%, `list.take` 11%, **`append` 10%**, EQ 4%, APP 4%, `bits.xor` 4%, `cons?` 3%, `hd` 3% |

`fn` is no longer in the leaf top (prior fix). After native `append`, leaf
share of append drops modestly; remaining time is user list recursion + GC
cons churn (bits as cons lists).

## Tried / not shipped this session

1. **Relax `pure_tail_self` for bare `(shen.f-error name)`**  
   Multi-clause `define` ends in `(shen.f-error <name>)`; treating the bare
   name as residual recursion blocked loop lowering on pure-tail helpers
   (`list.drop`, `list.nth`, …). Fix correctly emits `LOOP` for those. On
   this SHA suite (short lists, N≈8–32) serial warm prng **mean regressed
   ~+14%** — short tail-call chains already JIT well; the loop form did not
   pay. Left unmerged. Still a good lever for deep-iteration code; re-open
   with a depth heuristic or workload-specific gate if needed.

2. **Codegen inline `hd` / `tl` / `cons?`**  
   Same late-binding tradeoff as `cons`. Combined package was within noise /
   slightly mean-regressive on prng; not shipped alone.

3. **Default GC pause 800**  
   Med ~−12% prng CPU vs 400, but peak RSS ~60→106 MB (world ~110→216 MB).
   Keep `SHEN_GC=800` as documented batch override; default stays 400.

## Remaining headroom / risks

- **Structural**: urdr represents words as 32-element bit lists; `list.take`,
  `bits.xor`, `byte.bits.weights` dominate. Port opts cannot change digest
  semantics or golden outputs. Host-SHA primitives are explicitly out of
  scope unless vector-gated and trivial.
- **Tail-recursion modulo cons** for `(cons H (self …))` (append / take /
  map-like) would target the remaining non-tail list constructors without
  host SHA.
- **Interpreter share still ~25–30%** on prng — further trace-friendly
  inlining of tiny prims may help, but measure carefully (short-list loops
  can regress).
- **Thermal noise**: single-run wall times vary ~2×; always A/B with dual
  `SHEN_FASL_DIR` / `SHEN_KERNEL_CACHE` and report med/mean of N≥6.
- **Issue #46**: cold-start and hush-load items addressed; suite compute gap
  largely structural.

## Gates

- `make test`: **500 pass / 0 fail**
- `luajit run-kernel-tests.lua`: **134 passed / 0 failed, ok**
- urdr prng / world: **ALL PASS**; stdout byte-identical to pre-change warm
  golden (modulo `run time:` banners)
