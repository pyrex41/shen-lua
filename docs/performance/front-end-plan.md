# Typed source-loading follow-up

Baseline: bad0eba, including the accepted literal-colon native guard.
Isolated branch perf/typed-front-end. Preserve sibling worktrees and all earlier
accepted and rejected evidence.

1. Profile complete typed loads of the same authenticated interpreter,
   calculator and parser fixtures; separate reading/expansion, lowering,
   typechecking and host code generation. Diagnostics are separate cohorts.
2. Choose one measured hot path and review the selected upstream implementation
   and existing overrides. Keep macro/redefinition ordering and errors intact.
3. Compare complete typed-load CPU in alternating fresh-process pairs against
   bad0eba, including source and bundle paths, all verdicts and inference counts.
4. Keep only reproduced improvements without material query regressions;
   preserve rejected experiments and exact source/host/sample identities.
5. Qualify adoption with focused regressions, native/legacy differentials,
   make test-all, require-mode corpus, PUC behavior, private off/cold/hit caches
   and standalone bundles. Record remaining Scheme gap without projecting
   cross-cohort ratios or historical timings.

Outcome: the single-spine map, direct mapper callback, native postorder walker
and untraced walker all fail the complete adoption gate. Preserve their diffs,
focused controls and every process sample; retain the accepted bad0eba runtime.
Adopt only measurement receipts for per-load inferences/dispatch history and
expanded diagnostic attribution. Full source/bundle cache, host and kernel
qualification results are in front-end-results.md. Packaging/trace causality
remains OPEN; no additional runtime speedup or release claim is made.
