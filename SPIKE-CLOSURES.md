# Closure analysis spike (LuaJIT)

Branch: spike/closure-analysis. Opt-in; baseline remains unchanged.

Plan:
1. Add a lexical closure analysis pass with explicit capture/use records.
2. Eliminate immediate and non-escaping local unary lambdas by hygienic
   let insertion. Preserve evaluation order, object identity, deferred bodies,
   shadowing, and runtime fallback for unknown/escaping applications.
3. Compare enabled/disabled semantics, generated allocation sites, warmed time,
   and GC-stopped heap growth on bounded workloads; run port/kernel checks.
4. Record evidence and limits here. Explicit heap environments, interprocedural
   map specialization, partial application elimination, and speculative exit
   reconstruction are deferred until this experiment warrants them.

## Implementation

`SHEN_CLOSURES=on` enables `closure_ir.optimize` before defun code generation.
`C.CLOSURES` allows direct in-process codegen comparisons (set the environment
before boot when using persistent caches). Top-level expression compilation is
unchanged. The default is off.

The pass alpha-renames lexical binders, then records local closure candidates:
code body in the syntax tree, lexical capture names, direct-call count, escape
status, and elimination decision. `C.CLOSURE_REPORT` exposes the last defun's
records. This is an analysis prototype, not a backend-independent closure IR.

An immediate unary lambda becomes a let. A let-bound lambda becomes lets at
its call sites only when every reference is an exact unary call outside deferred
bodies. A maximum of four uses and an 80-node body cap bound duplication. No
argument expression is duplicated; arguments execute once before the body.
Unused lambda bodies remain unevaluated. Unique lexical names preserve capture
binding across call-site shadowing. References to mutable vectors remain the
same references, including when two closures share a vector.

Value uses (including equality), storage, unknown consumers, non-unary calls,
and references inside lambdas/freezes cause fallback. Special-form shadowing
causes the entire analysis to bail out. If no elimination occurs, the original
syntax tree is returned. Existing freeze lowering and LuaJIT GC remain in charge.
The cache fingerprint includes both the flag and the enabled pass's source.

This is a source-checkout spike: release rockspecs and standalone bundles have
not been extended to package the optional module.

## Reproduce

```sh
make test-all
SHEN_CLOSURES=on SHEN_KERNEL_CACHE=off make test-all
luajit bench/closures.lua 1000000
luajit -joff bench/closures.lua 1000000
luajit bench/closure_inventory.lua klambda/*.kl
```

The benchmark compiles the same four definitions in both modes, flushes the
JIT, warms for 20,000 calls, and reports the median of five timed samples.
Timed calls run with GC enabled. Separate 10,000-call probes stop GC to measure
heap growth, then collect to measure retained heap delta. These are heap proxies,
not allocator event counts; retained deltas can be slightly negative as older
objects are collected. Trace stop/abort counts cover warm-up; exit events are
sampled separately over 1,000 calls, outside the timing window. Zero exit events
can also reflect execution in the interpreter and do not prove exit-free native
execution. All benchmark sums are checked.

## Scope finding

Kernel inventory: 737 defuns, 31 candidates, **2 eliminated**, 29 escaping or
used in deferred bodies. These are candidates recognized by this pass, not a
census of every lambda. Raw output: `bench/results/closure-inventory.txt`.

This experiment demonstrates local closure elimination, not general map/callback
specialization or partial-application elimination. Those operations retain their
existing runtime behavior. Explicit heap environments, mutable-cell scalar
replacement, native GC metadata, and JIT exit reconstruction remain DEFERRED.
A useful next spike is a guarded, bounded specialization of a known higher-order
consumer, with dynamic redefinition and escaping callback tests. Whole-program
performance improvement remains UNKNOWN.

## Results (2026-09-27, local arm64 LuaJIT 2.1.1774638290)

Final JIT-enabled samples, one million calls, median CPU seconds:

| Case | Off | On | GC-stopped growth per 10,000 calls, off / on |
| --- | ---: | ---: | ---: |
| Immediate lambda | 0.430640 | 0.020572 | 937.5 / 0 KiB |
| Local callback, two calls | 0.540989 | 0.027926 | 937.5 / 0 KiB |
| Escaping callback | 0.502972 | 0.523506 | 937.5 / 937.5 KiB |
| Deferred callback | 0.477620 | 0.506964 | 1796.875 / 1796.875 KiB |

The eligible synthetic cases improve about 19–21x and lose their generated
MKFUN sites. Surviving closures retain their allocation behavior. Controls were
4–6% slower in this run; no control-case speedup is claimed. This is a local
microbenchmark with fixed ordering, not a statistically controlled application
benchmark. Retained deltas were zero here, so this does not demonstrate retained
memory improvement. Raw timing, heap, and trace observations are in
`bench/results/closures.txt`; the interpreter control is in
`bench/results/closures-interpreter.txt`.

Validation:
- Final port suite: 1,092 passed, zero failed, across 22 specs in each mode.
- Canonical kernel suite: 134 passed, zero failed in both modes (baseline full
  run plus final enabled full run).
- New spec: 41 checks spanning both modes, including captures, sharing,
  shadowing, nested invocation, overapplication, identity, delayed errors,
  argument evaluation once, and recursive escaping closures.
- Existing freeze, Prolog, evaluation-order, tail-call, and boot-cache specs pass.
- `git diff --check` passes. Base checkout is unchanged.

Local full-run logs: `/tmp/shen-closures-baseline.log`,
`/tmp/shen-closures-baseline-port.log`, `/tmp/shen-closures-on.log`.

