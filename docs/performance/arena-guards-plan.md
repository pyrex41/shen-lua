# Arena guard follow-up plan

Baseline: 908b25d, upstream ec16a9f. Isolated branch perf/arena-guards.
Preserve the foundation worktree, sibling worktrees, all paired receipts and
rejected experiments. The acceptance gates apply to complete typechecks.

1. Attribute remaining materialization call sites and select a narrow guard.
2. Implement only with explicit semantic-equivalence tests, preserving the
   compiler's existing primitive/arity contract and variable/binding behavior.
3. Compare in alternating fresh processes, keeping first/persistent judgments
   and typed source loads separate. Keep diagnostics outside timing cohorts.
4. Adopt only with repeated complete-query evidence and full qualification:
   focused tests, make test-all, require-mode native and legacy differentials,
   private cache off/cold/hit, PUC legacy golden and standalone bundle.
5. Record exact source/kernel identities, settings, verdicts/inferences and all
   samples; preserve unsupported, negative and inconclusive outcomes honestly.

Completed outcome: literal-colon root equality is the only adopted runtime
change (prolog_compile.lua). Source cohorts show 1.46x and 1.54x median full
persistent speedups; bundles show 1.40x. Smaller-case results are mixed and Lua
heap growth is essentially unchanged. All qualification checks pass. Full
methods, source bindings and limitations: arena-guards-results.md.

Not adopted: direct cons-shape guard, root-only cons witness, and protected-call
consolidation. Patches, tests and measurements are retained. The protected-call
prototype also remains on local experiment/protected-boundary at 38e04cc.

Remaining work: front-end reading/expansion/lowering and the smaller-query gap
against Scheme. This slice does not establish parity or a uniform speedup.
