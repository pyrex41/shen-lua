# Issue 98: measurement foundation and exact-kernel qualification

The benchmark-repair slice is implemented, followed by exact ec16a9f adapter
qualification and file-contained cache mutation coverage. The default vendored
kernel remains release 715824a; no numerical representation change is adopted.

Implementation commits: `4fdacd2` and `b4504cb`; corrected diagnostic hooks:
`05367d6`. Base: fetched origin/main `c6c3a2280f6276e8b2b89b231257f50776c583ca`.
The original e3dec8b checkout and sibling worktrees were preserved.

## Qualification receipts

| Selected kernel | Port suite | Community suite, native require | Community suite, pure KL Prolog primitives | PUC Lua 5.4.7 golden |
| --- | --- | --- | --- | --- |
| Release 715824a | 1,833 / 0, 32 specs | 154 / 0 | 154 / 0 | 20 complete verdicts |
| Exact ec16a9f | 1,833 / 0, 32 specs | 154 / 0 | 154 / 0 | 20 complete verdicts |

Both kernels also passed ordinary default-native certification. Full-suite
runtime module hashes match the final implementation. The later diagnostic-only
harness change was checked against all 20 verdicts and off/cold/hit states in
both source and bundle configurations. Each kernel fixture was authenticated
against its pinned archive; all 23 ec16a9f KL files and all 73 community test files
match. Ten KL files are byte-identical between releases, twelve differ only in
generated names, and t-star contains the reviewed wrapper/helper changes.

The exact wrapper initially failed translation at its inline lazy-dereference
empty-list guard. The translator now supports that specific sentinel test; the
new fingerprint was accepted after reviewing datatype handport behavior. The
older 5596445 fixture remains intact. Derived helper closure, empty hypotheses,
accepted/rejected nested judgments, failed earlier alternatives, binding
rollback, runtime-error effects, missing drivers and strict fallback have focused
controls. Shared Prolog override mismatches preserve the selected KL definitions;
a pure-KL override switch supplies the independent primitive control.

Standalone bundles for both kernels passed accepted/rejected native judgments
from a separate directory with an intentionally missing external kernel path.
Source and bundle corpus matrices verified actual native routing and FASL
off/cold/hit, including retained prime processes.

Negative controls exited nonzero for a failed certification judgment (despite
the suite's final reset), missing input, changed input, and PUC strict-native
qualification. The certification driver now counts actual callbacks and reports
154/0 rather than the reset 0/0; failures and zero executed tests fail the driver.

The host command `lua` is a LuaJIT alias. Earlier reports labelled `puc-golden`
are retained as additional LuaJIT legacy controls and superseded for PUC claims.
Genuine PUC qualification uses the explicit Nix Lua 5.4.7 binary; reports assert
Lua 5.4 with no JIT. The first native-rejection probe under the alias exited zero
and is preserved with this explanation.

## Measurements

Timed source: `b4504cb`; 36 measured fresh processes and 12 private-cache primes,
three pairs per kernel/state and three requests per judgment. Every process
retains complete stdout/stderr, 20 full verdicts, inference counts, actual route,
cache outcome, effective runtime/compiler settings and input/source hashes.
Input identities match before/after every cohort. Allocation and profiling are
separate cohorts. The 431,741-inference inferred Y-combinator judgment is retained
alongside the much cheaper explicit-type judgment.

The table is the process CPU sum of the two persistent requests for every case.
Ratios are paired legacy/native ratios, summarized across three process pairs;
they are not ratios of the two displayed medians. These compare the existing
engines on this runtime. They do not measure a gain introduced by these commits
or a kernel A/B improvement. The host had ten CPUs and load averages around
31–40 at the two cohort starts; all timing remains exploratory.

| Kernel | Cache | Legacy median seconds | Native median seconds | Paired ratio median | Paired ratio range | Native wins |
| --- | --- | --- | --- | --- | --- | --- |
| release | off | 0.970055 | 0.058776 | 17.444 | 15.047–18.012 | 3/3 |
| release | cold | 1.065752 | 0.110087 | 9.837 | 7.087–10.827 | 3/3 |
| release | hit | 0.876003 | 0.123532 | 7.091 | 6.612–14.745 | 3/3 |
| exact | off | 0.884569 | 0.075078 | 13.603 | 11.586–13.946 | 3/3 |
| exact | cold | 0.943492 | 0.109520 | 8.099 | 7.286–10.743 | 3/3 |
| exact | hit | 0.864089 | 0.079683 | 11.374 | 4.359–12.602 | 3/3 |

All paired samples and other phases (require, kernel load, initialise, fixture
loads, query reading, first judgments and persistent judgments) are in
`issue-98-statistics.json` and the raw receipts. Native-only driver compilation
has its own samples/medians there; legacy performs no native-driver translation.
This is an engine-paired matrix for each selected kernel, not an interleaved
release-versus-ec16a9f speed experiment.

Counters are stable within each engine across repetitions, processes and cache
states. Native exceeds legacy by two inferences for `map`, and by one for nine
signature-using cases; all other counts, including the inferred Y-combinator,
match. A separate diagnostic suppressing only the existing successful-signature
increment at typecheck_native.lua:458 exactly matches the legacy map for both
kernels. This explains the difference; production inference accounting and its
budget behavior are unchanged. No exact low-budget threshold parity is claimed.

The original Lua compiler profiling hook observed only the public export and
missed the captured local loader. Those reports are retained and superseded by
`corrected-*-diagnostic` and `corrected-*-bundle`. The corrected cold/off profiles
observe 89 defun compilations plus 55 expression compilations and 144 actual Lua
loads/compilations. Inclusive hooks overlap and must not be summed. GC-stopped
allocation diagnostics measure Lua heap growth, excluding FFI/native capacity;
GC-on heap occupancy is never labelled cumulative allocation.

## Cache boundary and remaining work

Off/cold/hit mutation controls pass for file-contained same-name macro/datatype
replacement, destroy, typed bridges, repeated failed loads with effects, and
changed nested dependencies. Nested loads run once. Interactive mutation between
loads remains excluded from the documented FASL contract; such sessions must use
FASL off. No broader replay or new cache format is adopted.

#72 remains the place for broader native coverage and fallback/effect conformance;
#73 retains detailed guard/materialization/import allocation attribution. This
corpus does not establish whole-port independence of shared general stdlib
overrides. The optional checked numerical owner/application remains unimplemented:
no Lua numerical-storage benefit was measured and no Chez gain is projected.

## Reproduction and evidence

Commands and exact measurement boundaries are in [typecheck-benchmarks.md](typecheck-benchmarks.md).
[Complete portable receipts](issue-98-evidence.tar.gz) include all accepted
samples, primes, complete outputs, commands, source hashes, archive checks,
negative controls and superseded experiments. Absolute checkout/home/temp paths
are normalized; the per-file index contains both original and portable hashes.
Generated bundle/cache binaries and downloaded archives remain in the local
`.work/issue98` directory; bundle hashes and archive identities are recorded.

Evidence archive SHA-256: `e22ae45537f68a61accdef1b5be9c577a3ed3f8cc0e5f8404636ed6eaca88b0c`.
