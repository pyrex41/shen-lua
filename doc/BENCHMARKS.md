# Benchmarks and reproducibility

For the most recent recorded, host-controlled A/B measurements in this tree,
see [the 2026-09-27 run](BENCH-2026-09-27.md). It names both source commits,
the LuaJIT build, hardware, warm-cache procedure, commands, and per-workload
minima and medians. Those results compare `7fb9744` with `29ba88c`; they are
not measurements of every subsequent commit or of a different host.

On that host, the branch's warm `bin/shen -e "(+ 1 2)"` wall-time minimum was
0.119 s, cold (no caches) 1.383 s, and the warm official suite 4.592 s for
134/134 tests. The `bench.lua` Einstein solve minimum was 0.0682 s. The
earlier typecheck and sub-millisecond Einstein measurements came from other
workloads/hosts; don't compare them as if they used this A/B protocol. Timing
varies with CPU, LuaJIT build, JIT state, cache warmth, and
whether the number is process wall time or in-process CPU time.

The current boot path caches compiled kernel bytecode and the loaded standard
library, and user `(load)` uses a content-keyed fasl-style cache. A warm boot
does not recompile all kernel files. See [kernel provenance](../klambda/PROVENANCE.md)
for the current S42 layout (the standard library is Shen source under
`lib/StLib/`, not `stlib.kl`). To measure a cold boot, disable/remove the
relevant caches; to compare revisions, give each revision its own cache paths
and warm both first. `SHEN_KERNEL_CACHE=off` and `SHEN_FASL=off` disable the
respective caches.

The native Prolog/typechecker engine is the default on LuaJIT with FFI;
`SHEN_PROLOG_ENGINE=legacy` exercises the compiled-KLambda fallback. Changing
engine modes changes the workload. Use `make test` for the port specs,
`make certify` for the vendored 134-report kernel suite, and `luajit bench.lua`
for the local microbenchmarks. For historical development measurements, see
[PERF-HANDOFF.md](PERF-HANDOFF.md) and [PERF-URDR-RESULTS.md](PERF-URDR-RESULTS.md);
their branch-tip figures are snapshots, not current performance claims.
The [earlier Shen 42 benchmark snapshot](https://github.com/pyrex41/shen-lua/blob/5b09a25/doc/BENCHMARKS.md)
preserves the first bring-up's compiler notes and pre-cache numbers.

## Historical 22.4 comparison (different host and kernel)

The earlier port was compared against shen-c 0.2.3 at Shen 22.4. These
figures are preserved only as history and cannot be compared to Shen 42 runs:

| workload | shen-c 22.4 | shen-lua 22.4 |
|---|---:|---:|
| cold startup | 0.235 s | 0.247 s |
| fib(32) | 13.771 s | 0.291 s |
| n-queens board 5, ×100 | 4.09 s | 1.62 s |
| Einstein, ×10 | 12.4 s | 18.2 s |
