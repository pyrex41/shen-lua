# Issue 98 implementation plan

Base: origin/main c6c3a2280f6276e8b2b89b231257f50776c583ca.
The issue is the current handoff; the old Chez/Lua review is superseded.

1. Repair the measurement foundation: authenticate repository fixtures, retain
   complete verdicts/inferences/routing, separate phases and allocation diagnostics,
   alternate fresh native/legacy processes with private off/cold/hit caches.
   Coordinate routing with #72 and measurement boundaries with #73.
2. Authenticate all 23 ec16a9f KL files against the pinned archive; review handports
   before adding fingerprints; qualify exact-kernel native/legacy, cache and bundle.
3. Consider an optional checked binary64 owner and complete numerical operation only
   after the foundation and kernel gates pass; preserve negative experiments.
4. Investigate cache mutation semantics with focused controls; adopt changes only
   with reproduced evidence.

Validation: focused regressions, complete golden comparisons, make test-all on
relevant hosts/engine modes, native require corpus, private cache off/cold/hit and
standalone bundle. Keep diagnostics outside accepted timing cohorts. Do not infer
independence of shared primitive overrides from native/legacy agreement.

Execution outcome: measurement foundation and exact-kernel corpus qualification
completed; see issue-98-results.md and its source-bound receipts. File-contained
cache mutation coverage passes. The optional numerical owner is deferred; broader
coverage/boundary attribution stays with #72/#73. No kernel default changes.
