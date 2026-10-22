# Arena guard experiment

Baseline: 908b25d, upstream ec16a9f. Isolated branch perf/arena-guards.
Preserve the foundation worktree, all paired receipts and rejected experiments.

1. Attribute remaining materialization call sites and select one narrow guard.
2. Implement an arena operation only with an explicit semantic equivalence test;
   preserve user redefinitions, malformed input/errors and variable freshness.
3. Run focused tests and strict-native full golden corpus. Compare old/new in
   alternating fresh processes, first/persistent and typed loads separately.
   Keep diagnostic counters/profiling outside accepted timing cohorts.
4. Adopt only on complete-query evidence without material regression in the
   heavy case. Otherwise retain the rejected patch and try the next bounded
   target. Protected-call consolidation is a separate experiment.
5. On adoption: full make test-all, native require and legacy differentials,
   private cache off/cold/hit and bundle qualification; retain source hashes,
   settings, complete verdicts/inferences and every paired sample.

Experiment status:
- Direct arena cons-test emission rejected: five-pair median speedups were
  0.64x full / 0.54x smaller judgments (slower), with exact verdict/inference
  agreement. Guard implementation and focused test are preserved in evidence.
- Root-only witness guard not adopted: five-pair median 1.04x full / 1.14x
  smaller, but typed loading 0.86x and highly variable timings. No clear gain.
- Next isolated candidate: consolidate dispatch/query protected calls, keeping
  preprocessing inside the protected boundary and cleanup before returning
  status. Pilot: 1.11x full / 1.08x smaller. Repeat before adoption.
