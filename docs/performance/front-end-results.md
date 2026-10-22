# Typed source-loading investigation

No additional runtime optimization was adopted. The literal-colon guard from
bad0eba remains active; the mapper and tree-walker prototypes below were all
restored after measurement. The branch `perf/typed-front-end` adds source-load
measurement receipts, routing regressions and preserved experimental evidence.
All runs use the exact selected upstream ec16a9f kernel, reporting version 43.1.

## Profile and scope

The baseline diagnostic loads the authenticated interpreter, calculator and
parser fixtures with typechecking enabled. It records 222,231, 2,221 and 12,029
inferences respectively. Macro expansion accounts for 0.702 seconds inclusive,
source-form walking for 0.689 seconds, source lowering for 0.343 seconds and
23 typechecks for 0.391 seconds. The actual captured Lua loader compiles 95
chunks in 0.00534 seconds. These diagnostic times overlap and are excluded
from timing cohorts; their relative costs direct investigation toward source
traversal and callbacks rather than Lua compilation.

The default source-form handler list is empty, so source macro walking delegates
to `shen.walk`. Its selected kernel body performs a postorder map and applies
the macro callback. The existing native map allocates a reversed result and
then reverses it. Native readers already exist; no missing-reader claim is made.

## Experiments and complete measurements

Each row below uses seven alternating pairs of fresh processes against bad0eba,
with source hashes/diffs stable across the entire cohort. All 20 complete
judgments, expected rejections, inference counts and native routes pass in every
process. Kernel/FASL caches are off, GC remains enabled, and every native query
runs in require mode. Ratios are median paired baseline/candidate CPU; greater
than one means faster. All individual samples and outliers remain in the archive.

| Candidate / cohort | Requests per case | Typed fixture loads | Persistent corpus | First-query corpus |
| --- | ---: | ---: | ---: | ---: |
| Single-spine map, source | 3 | 0.993x | 0.864x | see raw samples |
| Direct exact-unary map callback, source | 3 | 1.041x | 0.993x | see raw samples |
| Native postorder walk, source pilot | 3 | 1.100x | 0.952x | 0.579x |
| Native postorder walk, source repeat | 51 | 1.107x | 1.505x | 1.738x |
| Native postorder walk, bundle | 51 | 1.028x | 0.941x | 0.651x |
| Native postorder walk, bundle repeat | 51 | 1.067x | 0.992x | 0.650x |
| Native walk with tracing disabled for that function, bundle | 51 | 1.049x | 0.495x | 0.400x |

The source walker load gain reproduced in 6/7 pairs in each source cohort, but
the packaged query behavior failed the adoption gate. Across 14 bundle pairs,
the persistent ratio is 0.952x and the first-query ratio is 0.651x. The tracing
disable experiment also fails. This establishes packaging sensitivity, not a
proven cause: trace/exit attribution and a causal isolation experiment remain
open. No cross-port gain or additional allocation reduction is claimed. Source
cohorts with different persistent request counts are kept separate.

The walker prototype is source-qualified against reviewed canonical fingerprint
`f436f44edc3d32d4`. It preserves dynamic child-walker lookup, custom map behavior,
postorder callback effects, proper/improper list errors without prefix replay,
segment counting and fresh spines. Focused kernel-body comparisons passed,
including nested inputs, callback errors, replacement during traversal, source
handlers, 3,000 nested cars and 20,000 cdr cells. Changed source retains its KL
body through off/cold/hit boots. An initial changed-body control attempted full
stdlib initialization, which legitimately failed because that intentionally
changed walker no longer expands nested macros; the corrected kernel-only
control and the original failure output are both preserved. These semantic
results did not override the performance rejection.

## Adopted measurement changes and qualification

A load receipt now includes inference counts and every observed dispatcher
transition, with reasons and native-attempt flags. The normal runtime does not
retain a history unless routing and a log are explicitly enabled. Query logging
is disabled after each load; existing complete per-query receipts remain.

Cold/off native typed loads record 222,231 / 2,221 / 12,029 inferences and
28 / 4 / 14 dispatch transitions. FASL hits record 10,900 / 1,242 / 8,694
inferences with no dispatcher transitions: declarations replay directly.
The first validator incorrectly required transitions for those hits; its
failure receipt is retained and the corrected validator distinguishes replay.
Diagnostic-only reports additionally attribute macro expansion, source walking,
typechecking and record/evaluate work. Those inclusive counters cover the
whole process, including queries, and are not disjoint load phases.

Final measurement-only runtime qualification:

- `make test-all`: 1,858 port checks, zero failures across 33 specs; kernel 154/0.
- Separate strict-native kernel and pure-KL Prolog control: each 154/0.
- Source and bundle native/legacy corpus: private off/cold/hit states, retained
  primes, full golden verdicts, inference maps and actual routing all pass.
- Genuine PUC Lua 5.4.7: 20 complete legacy golden verdicts pass.
- Standalone bundle: accepted/rejected native judgments pass outside the checkout
  with an intentionally nonexistent external kernel directory.
- Expanded diagnostic report completes successfully outside timing cohorts.

The qualification matrix ran concurrently with other validation processes and
is used for correctness/cache/routing evidence only. Its timings are not an
accepted performance cohort. Experimental performance cohorts ran sequentially;
the host itself remained uncontrolled throughout.

Shared native/legacy primitives remain shared. Their agreement is supplemented
by selected-body comparisons and the pure-KL control, and does not establish
universal semantic equivalence. Issue #72 retains the broader routing boundary;
#73 retains allocation work. No release, general numerical claim or projection
of Chez results onto Lua is justified by this slice. The next performance gate
is to explain the packaged first-query regression before adopting a walker or
another source-expansion shortcut.

## Evidence

`front-end-statistics.json` contains every cohort summary, all paired ratios,
qualification results and source-load counter maps. The checked-in
`front-end-evidence.tar.gz` retains portable complete outputs, source identities,
profiling scripts/results, rejected implementation diffs and focused tests.
`front-end-evidence.sha256` binds the archive. Raw artifacts and generated bundles
also remain under `.work/front-end/`; sibling worktrees and earlier negative
experiments remain intact. Paths are sanitized only in the portable archive;
its index records hashes of both original and portable bytes.
