# Native guard follow-up: one accepted optimization

The active runtime change compares an eligible native engine term with the
literal interned colon directly in the arena. It removes the lifted guard call
and materialization for that comparison. The earlier cons-shape and protected
error-boundary prototypes are not part of the final runtime.

Baseline: 908b25d. Accepted runtime: 5b74916, with only prolog_compile.lua changed
relative to the baseline runtime. Both use exact upstream kernel ec16a9f.
The isolated branch is perf/arena-guards. The original foundation worktree,
sibling worktrees, experiment/protected-boundary branch at 38e04cc and all
negative experiments are preserved.

## Complete-query measurements

Each accepted time cohort alternates seven pairs of fresh LuaJIT processes.
Each process loads the same three authenticated typed application fixtures and
checks the same 20 judgments, once first and 50 persistent requests each.
Both kernel and FASL caches are off; GC remains enabled. Actual native routing
is required for every query. Complete results and inference counts match the
baseline in every process; runtime/kernel/harness source hashes stay unchanged.

| Configuration | Persistent complete-corpus median speedup | Smaller 19-case median speedup | Complete-corpus wins |
| --- | ---: | ---: | ---: |
| Source, cohort 1 | 1.46× | 1.39× | 7/7 |
| Source, independent repeat | 1.54× | 0.95× | 6/7 |
| Standalone bundles | 1.40× | 1.19× | 6/7 |

Speedups are medians of paired baseline/candidate CPU ratios. The 14 source
pairs have a combined median speedup of 1.50× (about 33% less CPU). The bundle
median corresponds to about 28% less CPU. The heavy inferred interpreter case
improves in 13/14 source pairs and 6/7 bundle pairs, with all 431,741 inferences
preserved per request. It dominates the total; smaller-case results do not
establish a uniform improvement. Typed fixture-load ratios are 1.07×, 1.02×
and 0.97× respectively: no material front-end gain is claimed.

The host remains uncontrolled. Full-corpus source speedups range from 0.51×
to 2.37×, and bundle speedups from 0.45× to 2.43×. Slower candidate processes
remain in all statistics. These are complete typechecking requests, not a
claim about general application execution, numerics or universal port speed.

The independent allocation diagnostic stops GC only during individual queries
and is excluded from accepted timing. Three pairs show essentially unchanged
Lua heap growth (whole-corpus candidate/base median 1.006). FFI arena allocation
is outside that measure. A diagnostic counter run over 1,900 smaller judgments
shows materialization entry calls falling from 80,600 to 51,200, including removal
of the 27,500 calls at shen.system-S and 1,900 at shen.by-hypothesis-h. These
are call counts, not allocated-byte counts. The benefit is avoiding guard and
materialization work; no meaningful heap-allocation saving is established.

## Semantics and qualification

Only exact-arity equality with `(intern ":")` on the right is eligible. The
left must be a bare engine term or an exact dereference through the query's
vector. This mirrors the existing KL compiler's primitive equality inlining
and compile-time interning contract. Other arities and malformed shapes keep
the ordinary lifted path. After lazy dereferencing, only the colon atom's
handle can match: lists, numbers, strings, vectors and unbound variables reject
without exporting or inspecting children. Binding and backtracking behavior
remain unchanged. EQTERM for two engine terms is retained as before.

Focused regression: 22 checks cover complete result equivalence, bound-variable
chains, rollback, long open lists, opaque values and translation eligibility.
Validation on the final runtime:

- make test-all: 1,855 port checks / zero failures across 33 specs; community 154/0.
- Separate strict-native community suite: 154/0; pure-KL Prolog control: 154/0.
- Genuine PUC Lua 5.4.7: all 20 complete legacy golden verdicts.
- Source and bundle: native/legacy complete corpora in private off/cold/hit
  states, including retained prime processes and verified actual cache routing.
- Standalone bundle: native accepted/rejected judgments pass from another
  directory with an intentionally nonexistent external kernel path.
- All 23 vendored KL and 73 community test files authenticate against the pinned
  upstream ec16a9f archive. Conformance tests also retain earlier hoist controls.

Shared primitive overrides remain shared; native/legacy agreement alone is
not an independent oracle for them. The pure-KL control and root-level focused
comparisons supplement that boundary. Broader routing remains with #72 and
remaining allocation/boundary work with #73.

## Preserved, unadopted experiments

- Direct arena cons-shape guard: passed its focused semantics checks but was
  slower (five-pair median speedups 0.64× whole / 0.54× smaller). Rejected.
- Root-only cons witness, preserving the guard call: mixed gains, with a 0.86×
  typed-load ratio. Not adopted.
- Consolidated native protected-call boundary: focused error identity, cleanup
  and reentry tests passed. The five-pair pilot improved, but a seven-pair repeat
  did not reproduce an overall gain (0.92× full corpus). Not adopted. The local
  prototype commit remains at 38e04cc; production retains its original boundary.

The first guard diagnostic used a nonexistent pretty-printer and failed before
qualification; the corrected run and original failure output are retained.
The first guard timing collector's broad working-diff check noticed concurrent
test additions. All measured runtime/kernel/harness bytes were manually
reverified unchanged, and its recovered summary is explicitly a rejection;
no adopted performance claim depends on that cohort.

## Remaining comparison with Shen-Scheme

A fresh seven-pair packaged comparison with pyrex41/shen-scheme
v0.52-pyrex41.5 (Chez 10.3.0, identical ec16a9f kernel) passes all 7,140 complete
judgments on each port. Lua/Scheme median paired CPU ratios in this cohort are
2.05× persistent checking and 5.54× typed fixture loading. Scheme remains ahead.

Do not divide that result by the earlier historical 1.35× comparison and call
it a regression or improvement: they are different noisy cohorts. The matched
old/new Lua cohorts above measure this change. The refreshed cross-port samples
are retained to show the remaining gap rather than projecting an old ratio.
The front-end and smaller-query gaps remain open, and no 7× gap-closure claim
is made.

## Reproduction and receipts

Create isolated baseline and candidate checkouts at the source commits above.
From the candidate root:

```sh
python3 bench/compare_lua.py --baseline /absolute/path/to/baseline \
  --pairs 7 --repeats 51 --out .work/new-source-pairs
```

For packaged timing, build a bundle from each checkout, then supply both
`--baseline-bundle /path/to/base.lua` and
`--candidate-bundle /path/to/candidate.lua`. Use `--mode alloc` in a separate
cohort for the GC-stopped Lua heap diagnostic. The reusable runner has a
successful one-pair complete-corpus smoke; the exact original cohort runners
are also preserved in the archive. Commands and settings are retained per
process, with original and portable source hashes.

`arena-guards-statistics.json` contains every paired ratio, rejected experiment
summary and refreshed Scheme comparison. `arena-guards-evidence.tar.gz` retains
complete outputs, all process/query samples, source identities, kernel settings,
focused/full validation and rejected patches. Its adjacent SHA-256 and internal
per-file index verify the portable archive. Paths are normalized, with original
and portable hashes retained; generated caches/bundles and downloaded binaries
remain local, with identities recorded. Profiling, allocation and validation
cohorts are not accepted time samples.
