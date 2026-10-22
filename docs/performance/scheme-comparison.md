# Shen-Lua versus Shen-Scheme: matched typechecking measurements

Measured 2026-10-22 on this macOS arm64 host. Shen-Scheme wins the checking
and typed source-loading measurements; Shen-Lua's standalone bundle starts
faster. These results cover this typechecking corpus, not general application
execution or numerical performance.

Both use upstream ShenOSKernel ec16a9fa4fc2e87e2aa336fb1ae30e8ac2266394,
reporting 43.1. Lua is bc6ab7a with LuaJIT 2.1.1785763465 and the authenticated
standalone bundle. Scheme is the published pyrex41/shen-scheme
v0.52-pyrex41.5 package (680e2e95ed9dd0ca6d2f688453efca2a37e50021), based on
tizoc's port, with Chez 10.3.0. It does not include the separate Chez-first
numerical experiments. The source archive's Makefile pins the identical
upstream kernel archive used to authenticate Lua's 23 KL files.

| CPU measurement | Lua median | Scheme median | Median paired Lua / Scheme |
| --- | ---: | ---: | ---: |
| Launch to ready, separate minimal processes | 144.6 ms | 216.9 ms | 0.65× |
| Load, typecheck and compile the three source fixtures | 638.8 ms | 95.6 ms | 6.68× |
| First judgment of each of 20 cases, summed | 33.1 ms | 16.7 ms | 2.02× |
| 1,000 persistent judgments (50 per case), summed | 1.165 s | 0.882 s | 1.35× |
| Other 19 cases, 950 persistent judgments, excluding inferred Y case | 132.8 ms | 17.9 ms | 7.61× |

A ratio above one means Lua uses more CPU. Ratios are medians of seven
paired ratios, not ratios of displayed medians. Fixture loading includes
reading, typechecking, lowering, host compilation and initialization; it is not
an isolated host compiler microbenchmark. Lua additionally spends a median
19.5 ms compiling native checker drivers before the corpus; Scheme has no
corresponding separate driver compilation. Reading the 20 judgments is timed
separately (Lua 19.5 ms, Scheme 0.707 ms); both read expression and type together
in judgment context.

The heavy inferred Y-combinator case has 431,741 inferences on both ports and
dominates aggregate checking time. It must not stand in for smaller application
judgments. The other-19 row is an explicit alternate aggregation, with the
heavy case still retained in every process and in the full-corpus total.

| Persistent case, per request | Lua median | Scheme median | Paired Lua / Scheme |
| --- | ---: | ---: | ---: |
| Inferred interpreter Y case | 20.85 ms | 17.29 ms | 1.25× |
| Explicitly typed interpreter Y case | 995 µs | 146 µs | 6.61× |
| Interpreter call judgment | 115 µs | 23.4 µs | 5.10× |
| Calculator call judgment | 21.7 µs | 8.66 µs | 1.98× |
| Parser call judgment | 71.5 µs | 6.98 µs | 9.76× |

These are typechecks of application calls, not executions of those calls.
All 20 cases, including genuine accepted and rejected application judgments,
are in `bench/typecheck_corpus.lua`; the checked golden file contains the full
expected types. Every measured result matches the same complete golden verdict.
Each port executes 7,140 measured judgments across seven fresh processes.
Lua uses require mode and every measured judgment reports actual native routing;
Scheme uses its ordinary KL typechecker. All inference counts are retained.
Lua records +2 for `map` and +1 for nine signature-using cases relative to
Scheme; other counts match. These are the existing native accounting differences
also recorded against Lua legacy in issue 98, not equal-work proof from counts.

Seven fresh process pairs alternate Lua/Scheme order. Each case has one first
request and 50 persistent requests; GC stays enabled, with ordinary runtime/JIT
settings and no profiling. Both source caches are disabled for Lua. Scheme
loads the fixtures from source in each fresh process. Kernel runtimes are
precompiled packages on both sides. A separate seven-pair launch-to-ready
cohort runs minimal package commands without corpus authentication overhead.
The pilot is retained and excluded from the accepted timing summary.

The host is uncontrolled. Full-corpus persistent ratios range from 1.12× to
3.52×; Scheme wins all seven pairs. Source-loading ratios range from 5.99× to
7.96×. Launch CPU ratios range from 0.54× to 0.77×; Lua wins all seven pairs.
One Lua process has substantially higher query CPU; it remains in all samples.
Small cases have microsecond-scale clock overhead; use the repeated sums and
ranges rather than treating individual timings as precise constants. Timings
are evidence for this host and corpus, not universal backend ratios.

The instrumented corpus process CPU/wall totals are retained for audit, but
are not used as a clean end-to-end comparison: Lua's harness also runs Python
input authentication and verifies embedded KL against disk, whereas Scheme's
package provenance is authenticated by the parent. The internal Lua bootstrap
phase likewise excludes some harness overhead. Use the separate minimal
launch cohort for startup comparisons. Native-driver compilation, fixture
loading, query parsing and checking remain separate measurements.

## Reproduction and evidence

Download the macOS arm64 binary from the user's fork release
`pyrex41/shen-scheme`, tag `v0.52-pyrex41.5`. Verify archive SHA-256:
`1dbbdfd4dbfc64383edf2ee08a788cb410bb3f5104e3b6b32204e443baeb3ff9`.
The source archive SHA-256 is
`c57f47586894534b9797daf5c0cc65c58dc6fb89d6ea6f0c2b48ac64de66d010`.
The archive names, binary/runtime/boot-file hashes and source pin verification
are retained with the receipts. Lua's selected source/kernel/fixture bytes and
bundle bytes are authenticated; source identities stay unchanged through the
cohort, and fixture identities were verified again afterward.

From the repository root:

```sh
luajit build/make-bundle.lua /absolute/path/shen.lua
python3 bench/compare_scheme.py \
  --scheme /absolute/path/shen-scheme-v0.52-pyrex41.5-macOS-bin/bin/shen-scheme \
  --bundle /absolute/path/shen.lua \
  --pairs 7 --repeats 51 --out .work/new-scheme-comparison
```

`scheme-comparison-statistics.json` contains all paired ratios and per-case
samples. `scheme-comparison-evidence.tar.gz` preserves complete stdout/stderr,
per-query verdicts/inference counts/routes, process samples/settings, generated
Scheme driver, the accepted runner, minimal launch runner and package identities.
Adjacent SHA-256 and the internal per-file index authenticate the portable
archive. Home/checkout/ephemeral paths are normalized; original and normalized
hashes are recorded. No source fixtures or sibling worktrees were modified.
