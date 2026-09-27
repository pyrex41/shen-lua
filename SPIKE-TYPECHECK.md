# Typechecking and specialization

Status: research only. Runtime remains at the guarded-closure implementation in
PR #68; none of the datatype experiments changes normal compilation or execution.

## Plan and scope

Publish the closure spike, isolate query work from boot history, profile the hot
path, and compare bounded dispatch experiments. Preserve inference counts,
predicate redefinition, cuts, exceptions, and whole-query legacy fallback.
Promote a runtime change only with repeatable evidence.

## Query audit

`bench/typecheck_specialization.lua` loads the canonical interpreter workload and
typechecks its recursive addition term. Every query must return `(list l-formula)`
and exactly 431,741 inferences. One priming query installs lazy native drivers.
Each process then runs 12 queries; reported process times are the median of queries
7–12. GC runs before each timed query. The workload, initialization, and timing
boundary are identical within comparisons; startup and compilation are excluded.

`bench/typecheck_audit.py` alternates ordinary and specialized map across three
fresh-process pairs per JIT-history setting. Local closure elimination is off.
Times below are medians of the three process medians, in seconds.

| JIT history | Ordinary map | Specialized map |
|---|---:|---:|
| Preserve boot traces | 0.138591 | 0.111951 |
| Flush after priming | 0.136424 | 0.103966 |
| Disable after priming | 0.649022 | 0.631897 |

These are **not established speedups**. Flushed ordinary runs range from 0.061373
to 0.145591 seconds, and specialized runs from 0.054520 to 0.128424. Flushing boot
traces does not remove variability. Interpreter results are much tighter. The
previous closure report's slower typechecking median does not establish a stable
map-specialization regression.

## Hot path and bounded experiments

A separate 30-query sampling run recorded 2,050 interpreted and 961 compiled
samples. Native datatype predicate dispatch and its arena operations dominate the
interpreted stacks. Profiling includes between-query GCs, so these counts are not
query-only execution percentages. A separate query trace log contains 150
`trace too long` aborts. These observations motivate investigating trace formation
around datatype dispatch; they do not establish one causal bottleneck.

1. **Unrolled dispatch:** give each datatype entry its own guarded predicate call
   site, up to 32 entries, with generic suffix fallback. The actual workload has
   four entries (2,588 bytes of generated worker source). Four fresh-process pairs
   gave a JIT median of 0.086217 seconds ordinary versus 0.151296 specialized;
   interpreter medians were 0.632305 versus 0.631386. Rejected for runtime adoption.
   The benchmark-only module preserves live predicate lookup and suffix fallback.
2. **Recorder limits:** default, 8,000, and 16,000 recorded instructions gave four-
   process medians of 0.062221, 0.135616, and 0.053224 seconds respectively. Variation
   remained large and a short semantic-check process overlapped part of this
   exploratory run. No global LuaJIT tuning is justified by this evidence.
3. **Loop dispatch:** replace recursive tail dispatch with an explicit loop,
   retaining one dynamic predicate call site. Initial four-process medians were
   0.120075 seconds ordinary, 0.079047 loop, and 0.065525 loop with an 8,000-instruction
   limit. Repeat measurements below isolate the loop with default recorder settings.

The six-pair repeat gave 0.125050 seconds ordinary versus 0.072319 loop; the loop
won five pairs. Ranges still overlap: ordinary 0.039086–0.143462, loop
0.049287–0.111584. The median difference (42.2%) is promising exploratory evidence,
not an established application-wide speedup. Keep the loop benchmark-only until
multiple datatype workloads and trace diagnostics confirm the benefit. Do not
combine it with recorder tuning on this evidence.

The next bounded specialization target is the native datatype predicate path:
inspect where recordings repeatedly expand through dispatch and continuation calls,
then compare any change against this loop reference. Preserve mutable predicate
lookup and the existing native/legacy ABI boundary.

## Validation and reproduction

The unrolled dispatcher passes 57 focused checks; the loop passes 54. These
compare results, inference counts, invocation order, redefinition during dispatch,
malformed entries, cuts, exceptions, reached/unreached missing predicates, long
lists, and positive/negative typechecking against the ordinary dispatcher.
They supplement the closure PR's 1,128 port checks and 134 kernel tests, already
passing in ordinary and combined closure/map configurations.

Run from the repository root with LuaJIT on PATH:

```sh
luajit bench/datatype_dispatch_spec.lua dispatch
luajit bench/datatype_dispatch_spec.lua loop
python3 bench/typecheck_audit.py
python3 bench/typecheck_dispatch_ab.py
python3 bench/typecheck_record_ab.py
python3 bench/typecheck_loop_ab.py
python3 bench/typecheck_loop_repeat.py
```

Each timing subprocess has a 90-second timeout. Processes run sequentially in
alternating/rotated order. Measurements used macOS arm64, LuaJIT 2.1.1774638290. This was a shared
machine with unrelated work running; CPU-time measurements reduce, but do not
eliminate, scheduling and resource-contention effects. No isolated-host claim is made.
Raw per-query data and summaries are in `bench/results/typecheck-*`.

Provenance limitation: the archived dispatch A/B measurements used the temporary
runtime integration in `bench/results/datatype-dispatch.patch` against commit
`1a27f1d`, installed before the priming query and refreshed at native query entry.
That integration was reverted. The committed benchmark module installs after
priming and refreshes explicitly; rerunning the current dispatcher harness measures
that revised protocol, not an exact reproduction of the archived run. The archived
patch is evidence only and is not applied by any test or runtime path.
