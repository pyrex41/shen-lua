# Guarded callback specialization experiment

The first spike is preserved as commit `7df8ac8`. This second experiment stays
on `spike/closure-analysis` and remains opt-in.

## Questions and decision criteria

1. Does an existing Shen workload spend meaningful work crossing a closure
   boundary that we can remove safely?
2. Can a modest program built from escaping, stateful closures approach a
   manually specialized implementation?
3. What changes in callback construction, tracing, compile cost, code size,
   and retained memory explain or constrain the result?

There is no universal 10% whole-application gate. Compare the measured gain
with the opportunity and the manual reference, and retain negative findings.
Custom closure objects, a new collector, and virtual-object reconstruction on
JIT exits are separate hypotheses and are not implemented here.

## Target selection

`bench/callback_profile.lua` instruments native map calls while loading the
vendored `tests/interpreter.shen`, then typechecks its y-combinator expression.
The baseline load makes 140,708 map calls over 450,870 elements and constructs
149,074 generated MKFUN closures. The dominant callback source locations map
to `shen.beta` (94,251 calls), `shen.walk` (37,560), and `shen.alpha-convert`
(4,536). The following typecheck makes only 30 map calls over 60 elements.

This selects compiler tree traversal as the real workload. The instrumented
inclusive map times are NOT an estimate of uninstrumented CPU share: wrapper,
clock, list-walking, and debug-info overhead substantially distort those times.
`bench/results/callback-profile.txt` retains the raw observations.

## Implementation and semantic boundary

`SHEN_MAP_CLOSURES=on` enables one transformation, independent of
`SHEN_CLOSURES`: a literal unary lambda passed to a known-arity global `map`
inside a defun becomes a chunk-scope worker. Captures are explicit worker
parameters; the worker contains the callback body and list traversal. No
callback or environment object is allocated on the native-consumer path.

The worker guards the selected consumer against the exact native map identity.
A replacement consumer gets a freshly materialized ordinary closure and the
original input. It can retain, compare, or invoke that closure arbitrarily.
The selected callee follows the existing compiler's lookup timing, including
when evaluating the list expression changes the global function table.

The loop follows native map's left-to-right callback evaluation, reversed
accumulator, and final reversal. It deliberately keeps the same two output-list
allocation passes. An improper tail delegates to the native map's original
error/fallback function with the current tail and accumulator, never replaying
the processed prefix. Returned closures capture fresh per-iteration item
locals. Shared vectors remain shared references; they are never copied.

Eligibility is bounded to a literal callback body of at most 80 syntax-tree
nodes and at most eight captures. Unknown callbacks, partial applications,
lexically shadowed consumers, and oversized cases keep existing codegen.
The cache key includes the flag. This remains a source-checkout experiment,
not a published release or a new general closure IR.

## Workloads and measurement protocol

`bench/closure_application.lua` boots a fresh process with kernel and FASL
caching disabled, measures interpreter loading, then warms and measures three
typechecks. Each typecheck resets the inference counter to respect the kernel's
per-query inference budget. All runs must infer the same type.

`bench/closure_objects.lua` creates 1,024 surviving objects, each represented
by three escaping closures sharing a vector: process a batch, read accumulated
state, and update configuration. Processing maps over 32 elements; the callback
updates accumulated state and reads current configuration. The host retains the
objects, changes configuration, invokes their methods, and checks the accumulated
history. Ordinary, optimized, and manually specialized KL implementations run
the same workload. The manual reference includes its worker in code-size and
compilation-cost totals. This is a proposed programming-style workload, not an
existing customer application.

`bench/closure_experiments.py` runs six independent processes per mode, alternating
application order and using all six permutations of the three object modes.
Object timing is the median of five warmed 20,000-method batches per process.
Timing runs have no profiling wrappers and execute sequentially after tests.
GC-stopped heap growth is probed separately over 1,000 calls; it includes any
remaining trace/compiler allocations and is not an allocator-event count.
Retained heap is measured after full collection with the objects still rooted.

`bench/closure_diagnostics.py` runs separate callback-count and `-jv` probes.
Trace markers exclude object construction and boot from workload trace counts.
The diagnostic runs' timings are not used for performance conclusions.

## First-spike control follow-up

Four alternating fresh-process rounds do not reproduce the original 4–6%
control slowdown. Median on/off ratios are 0.976 for escaping callbacks and
0.987 for deferred callbacks. The controls' generated Lua is byte-for-byte
identical in fresh compilers (SHA256
`dd97c5fe93b23c62e08cc125e24af7c676c3a1c2ccc5d45ccaba0d5733beab80`).
These small differences are not evidence of a control-case improvement either.

The original interpreter controls already showed gains without JIT execution
(about 7.5x immediate and 3.3x local). Thus allocation/call simplification matters
independently of tracing. Comparing these with JIT ratios is not a controlled
numeric decomposition of allocation versus tracing benefits.

## Diagnostics

Interpreter loading constructs 149,074 generated callbacks in ordinary mode
versus 8,366 in optimized mode: 140,708 fewer (94.4%). Both infer `(list l-formula)`.
The object allocation probe constructs 1,000 callbacks in ordinary mode versus
zero in optimized and manual modes. Ordinary workload tracing reports 26 FNEW
aborts; optimized/manual report zero. FNEW is confirmed against this LuaJIT's
opcode table. Optimized execution still reports inner-loop trace limitations;
this is not a claim that the entire caller becomes one ideal trace.

Retained object heap is effectively unchanged between ordinary and optimized
(about 689 KiB in the diagnostic run). The surviving methods and state still
allocate and remain rooted. This experiment does not establish retained-memory
improvement or any need for a different collector.

## Final timing results

Local arm64 LuaJIT 2.1.1774638290, six fresh processes per mode. Values below
are medians of process results; ranges are across those six processes. These
are CPU seconds, not wall-clock latency. Shen caches were disabled for the
application comparison; OS filesystem caches were not flushed.

| Measured phase | Ordinary | Optimized | Manual reference |
| --- | ---: | ---: | ---: |
| Interpreter load/compilation | 0.745090 | 0.540169 | — |
| Warm y-combinator typecheck | 0.099235 | 0.121838 | — |
| Stateful objects, 20,000 batches | 0.122676 | 0.097784 | 0.086749 |

Interpreter loading improves **27.5%**, with non-overlapping observed ranges:
0.627108–0.810611 ordinary, 0.486806–0.591180 optimized. This is a real Shen
compilation/loading workload, not an end-to-end process-startup measurement.

The object workload improves **20.3%** and recovers **69.3%** of the measured
ordinary-to-manual time gap. Optimized remains **12.7% slower** than manual.
Ranges: ordinary 0.102052–0.133343, optimized 0.081064–0.103044, manual
0.075787–0.092902. This supports making this particular closure-heavy style
cheaper; it does not measure every style of stateful-closure programming.

**Typecheck performance is unresolved.** The final optimized median is 22.8%
slower, with very broad overlapping ranges (ordinary 0.058485–0.162242;
optimized 0.036322–0.146308). Three paired rounds favor each mode. An earlier
six-process pilot favored optimized at the median instead. Neither a speedup
nor a stable regression is established. JIT-history sensitivity is a possible
explanation, not a verified cause. Isolate that before considering default-on
behavior for general workloads.

Costs and memory:

| Metric | Ordinary | Optimized | Manual reference |
| --- | ---: | ---: | ---: |
| Generated kernel Lua bytes | 588,900 | 618,740 | — |
| Uncached kernel load, including compilation | 0.423356 s | 0.431287 s | — |
| Object implementation Lua bytes | 576 | 1,029 | 815 |
| Object implementation compile/load median | 3.291 ms | 3.284 ms | 3.423 ms |
| Heap growth, 1,000 object-method calls | 5,554.688 KiB | 5,500 KiB | 5,500 KiB |
| Retained heap with 1,024 objects alive | 655.816 KiB | 655.816 KiB | 647.896 KiB |

Kernel source grows **5.1%**; the narrowly measured object implementation grows
78.6% because it embeds the traversal plus two materialization fallbacks.
The uncached kernel-load metric includes parsing, code generation, loading,
and installation; it does not isolate compiler CPU time. Target compile times
are short and noisy, so no compile-time improvement is claimed.

Object heap growth falls only about **1%**: list cells dominate this workload.
Together with the eliminated FNEW aborts and the interpreter-control findings,
this supports both call/allocation simplification and improved traceability;
it does not assign an exact fraction of the speedup to either mechanism.
Retained heap does not improve.

## Validation and reproduction

- Original local-elimination spike: commit `7df8ac8`.
- Final default and combined-enabled runs: **1,128 port checks**, zero failures,
  across 23 specs; **134 canonical kernel tests**, zero failures in each run.
- New map spec: 36 checks across both map modes, covering redefinition,
  replacement consumers retaining callbacks, absent consumers, lexical
  shadowing, capture-budget fallback, nested maps, escaping result closures,
  shared mutation, evaluation order, and errors after a processed prefix.
- Every application run inferred `(list l-formula)`; every object run validated
  the full accumulated state history. Generated control source matches exactly.
- `git diff --check` passes. Original checkout remains unchanged.

```sh
make test-all
SHEN_CLOSURES=on SHEN_MAP_CLOSURES=on SHEN_KERNEL_CACHE=off make test-all
SHEN_FASL=off luajit bench/callback_profile.lua
python3 bench/closure_controls.py
python3 bench/closure_experiments.py
python3 bench/closure_diagnostics.py
```

The fresh-process experiment runs its children sequentially with per-process
timeouts. Run it without concurrent test/profiling jobs. Raw observations live
in `bench/results/closure-experiments.{json,txt}`, `closure-controls.{json,txt}`,
`closure-diagnostics.txt`, and `closure-traces-*.txt`. Full validation logs are
`/tmp/shen-callbacks-off.log` and `/tmp/shen-callbacks-on.log`.

## Decision

Continue with bounded, guarded compiler specialization. It demonstrably reaches
hot existing code and brings a stateful closure workload closer to its manual
reference without changing shared-state or escape semantics. Keep the flag off
by default while investigating typecheck timing variability and reviewing code
size/fallback costs. This is evidence for this compiler path; long-lived capture
management and a different collector remain open, separate experiments.
