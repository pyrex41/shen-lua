# Source-bound typechecker measurements (#98, #72, #73)

Run from the repository root with Python 3 and the chosen Lua interpreter.
No external Shen installation or directory change is used. The default checker
is soa32; every native sample uses `SHEN_TYPECHECK_NATIVE=require`.

```
python3 bench/run_typecheck.py --pairs 5 --repeats 3 --out .work/typecheck-release
SHEN_KL_DIR="$PWD/test/fixtures/kernel-ec16a9f" \
  python3 bench/run_typecheck.py --pairs 5 --repeats 3 --out .work/typecheck-ec16a9f
```

`--out` must be new. Each measured process gets a private temporary kernel/FASL
cache. Off disables both; cold starts empty; hit first runs an unmeasured prime
with identical settings. The process report verifies actual kernel and fixture
cache routing, rather than inferring a hit from the requested environment.
Prime outputs and failure/timeout outputs are retained too. Native/legacy order
alternates within each state; the fresh process is the statistical unit.
`--timeout` bounds each child (180 seconds by default); no retries hide failures.

The default kernel remains community release commit
`715824a52b55e9c81a9501df8548ff3edd8411f5`, archive SHA-256
`900eedef44f440af78f9395ed06e689ce1604546fc309f5bc7c8bc84cc651920`.
The exact ec16a9f fixture has its own provenance and all 23 files. Both kernels
report 43.1, so version strings alone are never the identity check.
`bench/verify_inputs.py` authenticates all selected KL bytes and repository
fixtures before execution, failing on missing or changed inputs. The paired
runner binds source SHA, working diff, all runtime/harness sources, complete
kernel hashes, fixture hashes, golden verdicts and (if selected) bundle hash
before and after the cohort. The worktree may be dirty; its exact diff and hashes
are retained. Runtime version, effective JIT status/flags, compiler TRMC setting,
all SHEN environment switches and private-cache paths are retained per process.

The corpus uses authentic community `tests/interpreter.shen` and
`tests/calculator.shen`, plus the complete typed grammar prefix of
`tests/yacc.shen` before `<des>`. The parser subset is byte-for-byte that prefix,
checked by a port regression and SHA-256; the rest of yacc.shen includes untyped
grammars and is not a valid `(tc +)` load. The interpreter and calculator are
loaded with typechecking enabled, so their actual definitions are checked too.
Twenty judgments (including the original inferred Y-combinator request) include nested hypotheses, failed datatype
alternatives and successful/rejected application requests. Every result is
checked against its complete requested type (alpha-normalized type variables),
then against the independently captured legacy golden. A runtime error never
counts as an expected rejection. Inference counters reset before each query;
counts must be stable across persistent requests, processes and cache states
within an engine. Counts may differ between engines; both complete maps remain
in `summary.json`. Agreement is evidence for this corpus, not all Prolog behavior.

CPU phases are `require`, `kernel_load`, `initialise`, `driver_compile`, aggregate
query reading, fixture load, each first judgment, and each persistent judgment.
The first judgment for each case is distinct from the first native query in the
process: the latter follows the explicitly timed lazy-driver compilation.
Fixture-load timing includes source reading, parsing, macro expansion,
typechecking, lowering, compilation and installation (or FASL replay). It is not
mislabelled as pure compiler time. Fresh-process wall time includes all work,
including authentication, validation and serialization. GC remains enabled in
accepted time samples, with boot.lua's configured policy recorded by source and
switch identity. Reports contain every sample, medians, every paired ratio,
paired ranges and native wins. Host load is recorded before/after and per child;
uncontrolled host contention makes timing exploratory. No best/minimum-only
performance claim is accepted.

Source/compilation attribution and allocation are separate processes:

```
python3 bench/run_typecheck.py --mode diagnostic --pairs 1 --out .work/typecheck-attribution
python3 bench/run_typecheck.py --mode alloc --pairs 1 --out .work/typecheck-allocation
```

Diagnostic hooks measure inclusive read/parse/expand, source lowering, KL-to-Lua
and Lua compilation CPU/call counts. They overlap and must not be summed or mixed
into accepted timing cohorts. GC-stopped query heap growth in allocation mode
covers the Lua heap only; FFI arenas and native allocator capacity are excluded.
GC restarts after each query, including a caught error. GC-on occupancy is never
reported as cumulative allocation. Neither diagnostic cohort qualifies speed.

Golden commands use the same checked corpus. Capture requires an explicit
output destination; comparison requires every entry, in order, with no extras:

```
SHEN_PROLOG_ENGINE=legacy SHEN_TYPECHECK_NATIVE=off SHEN_KERNEL_CACHE=off SHEN_FASL=off \
  luajit bench/golden_typecheck.lua capture .work/reviewed.golden
SHEN_TYPECHECK_NATIVE=require SHEN_KERNEL_CACHE=off SHEN_FASL=off \
  luajit bench/golden_typecheck.lua compare
```

For an independent shared-primitive control, select
`SHEN_PROLOG_ENGINE=legacy SHEN_PROLOG_PRIMITIVES=kl` (and native mode off).
The default legacy path retains Lua overrides, so its agreement with soa32 is
not an independent oracle for those operations. Unrecognized source shapes now
preserve the entire KL primitive group, report why, and make strict native
qualification fail. General stdlib overrides remain shared and are not claimed
independently qualified by this switch.

Standalone bundle qualification uses the same corpus and checks embedded KL
source bytes against the authenticated selected disk fixture:

```
SHEN_KL_DIR="$PWD/test/fixtures/kernel-ec16a9f" \
  luajit build/make-bundle.lua .work/ec16a9f-bundle.lua
SHEN_KL_DIR="$PWD/test/fixtures/kernel-ec16a9f" SHEN_BENCH_BUNDLE="$PWD/.work/ec16a9f-bundle.lua" \
  python3 bench/run_typecheck.py --states off --pairs 3 --out .work/typecheck-bundle
```

The bundle embeds its kernel, so kernel bytecode routing is embedded rather
than disk off/cold/hit. FASL off/cold/hit still applies to loaded applications.
Use `--lua lua` for PUC Lua: native FFI operation is explicitly unsupported by
this qualification harness, and strict native samples must fail rather than be
reported as native successes. Legacy golden checks work on PUC Lua; its caches
may self-disable without a bit library and are not labelled hit.

Validation: `make test-all` runs port tests and authenticated community tests;
`LUA` selects the host. Conformance regressions include the release, original
5596445 fixture and exact ec16a9f fixture, pure-KL primitive controls, observable
failed-alternative effects, runtime errors, missing helpers and strict fallback.
The certification driver counts callbacks before the suite's final reset and
fails on errors, zero executed tests or any failed judgment.

Cache mutation controls (`test/cache_mutation_spec.lua`) compare complete state
across off/cold/hit for same-name macro/datatype replacement *inside loaded
files*, destroyed signatures, typed Lua bridge registration, repeated failed
loads with partial effects, and changed nested dependencies. Nested effects run
once on replay; failed loads execute their prior effects on each attempt and
retain their error. Interactive same-name mutation/destroy between loads is
excluded from the FASL contract: run with `SHEN_FASL=off` for such sessions.
Names alone do not establish definition identity. This slice does not broaden
replay or introduce a new compiler-state fingerprint; the existing format and
source/flag invalidation are preserved.

The optional numerical-owner lane remains an experiment to consider after these
gates. These typechecker results supply no numerical-storage evidence and no
projection of Chez's historical SOR gain onto Lua. No numerical representation
or automatic dispatcher is adopted here.
