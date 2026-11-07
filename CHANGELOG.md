# Changelog

Notable changes to shen-lua. Release notes for earlier versions are under
[`doc/`](doc/) (`RELEASE-*.md`).

## [Unreleased]

### Changed

- **Kernel: ShenOSKernel 43.4** (community `Shen-Language/shen-sources`, tag
  `shen-43.4`, commit `f34b307b490880eedcfe1f5e5d3cc24ca3d2602e`, release
  tarball SHA-256 `15e7972e...a2756`). Vendored byte-identical; `(version)` is
  `"43.4"`. `tests/` is the 43.4 suite. The native typechecker's fingerprints
  are unchanged (verified with `scripts/kernel-fingerprints.lua`).
- stlib.kl now declares its 290 signatures with
  `shen.declare-with-signature` and a precompiled abstraction, so the
  `<kernel cache>.stlib` signature sidecar is gone. `typecheck_native.lua`
  wraps `shen.declare-with-signature`; without that its native signature
  table silently lacked the stdlib signatures (171 instead of 465 entries).
  The two stdlib datatypes still run the rule compiler; their fasl records
  stay in `<kernel cache>.stlibdt`.
- **Startup and compile cost.** `variable?` no longer throws on a non-symbol; the
  fasl records a global push as a delta (SHENFASL9), the reader has native paths for
  plain tokens, macroexpansion keeps unchanged cells, the stdlib datatypes replay from
  `<kernel cache>.stlibdt`, and a replayed `declare` skips the variancy query
  when the compile run found no old type. The GC pause adapts past a small live heap
  and stops adapting once the host sets its own; the default stepmul is 1000, which
  trades work for memory (a string-building loop: +7% instructions, 78 to 47 MB).
- **Calls and closures.** Fixed-arity `APPn`/`CURn` helpers, uncurried lambda groups,
  closed lambdas built once, hot helpers bound as locals, count sinking. `(= F G)` can
  now be true for two evaluations of the same closed lambda.
- **Lists, vectors, strings, Prolog.** `hd`/`tl` read directly where `(cons? E)`
  proves a cons, and a `let` bound to a cons keeps that fact. `+`/`-`/`*` and
  the comparisons are Lua operators once both sides are numbers; `/` stays
  checked, because Lua division by zero does not raise. `address->` stores with
  `rawset`; a self-tail accumulator is a double
  from the start; native `shen.mod` below 2^53; the Prolog engine reuses stack
  segments and has loop-free deref and unify.
- **Kernel cache key** covers every codegen switch: `SHEN_UNCURRY`,
  `SHEN_HOIST_LAMBDA`, `SHEN_SINK_COUNT` and `SHEN_FREEZE_CONT` as well as `SHEN_TRMC`.
- **Calling a function value from Lua.** A compiled lambda called with fewer arguments
  than it takes returns the partial application over the ones it got, wherever the host
  got it (`shen.eval`, `shen.value`, a callback argument, an element of a list): `f(1)(2)`
  and `f(1, 2)` are the same. It tests its last parameter for nil on entry, since nil is
  never a Shen value. **Edge:** a host function that returns nothing (nil) into Shen,
  whose result is then passed as a lambda's last argument, gets that lambda's partial
  application rather than a call. Through the Lua bridge (`lua.call` and the
  marshalers) this cannot happen, since a nil result becomes `()`; only a function
  installed directly in `shen.prims.F` could do it. `shen.prims.F[name]`, a defun's own
  function, still takes exactly its arity when called raw, as before.
  Also deliberate, from the host only: a raw call with too many arguments,
  `add(1, 2, 3)` for a two-parameter lambda, ignores the extra and gives 3, where 0.12.0
  returned a function.
- **CI and gates.** `make certify` fails when a test fails, the suite stops early or
  fewer tests run than the kernel release has (154 for 43.2); it used to exit 0 whatever
  happened. CI runs it with `SHEN_TYPECHECK_NATIVE=require`, and runs the new
  `make golden` (typechecker and Prolog results, y-combinator inference count). A spec
  file missing from `scripts/run-tests.lua` fails the run.
- **Lua 5.5** boots: its collector options changed.

### Fixed (behaviour changes)

- A test that is not a boolean raises: the test of `if` and `cond`, both operands of
  `and`/`or`, and the argument of `not`. `(if 1 a b)` used to give `a`, and `(not 5)`
  compiled gave `false`. A predicate with too few arguments is not a boolean.
  **Limit:** a call in tail position as the last operand of `and`/`or`, in a defun or a
  lambda, stays a tail call and is not checked itself; a test of the function's result
  is what raises. So `(define f X -> (and true (g X)))` with `g` returning 5 gives
  `(f 5)` = 5 unless the caller tests it. shen-go does the same; Shen/JIT and
  Shen/Scheme raise.
- `(str "a")` gives `"\"a\""`, quoted, as on the other ports.
- `absvector` rejects a length that is not a non-negative integer; `address->` and
  `<-address` reject an index outside the vector; `set`/`value` raise on a non-symbol;
  `hash` raises on a bound that is not a positive integer; `close` is idempotent;
  `(get-time unix)` is the Unix time; `(eval-kl sym)` gives the symbol.
- `(thaw F)` for a compiled lambda that takes arguments gives a partial application, as
  before uncurrying; it no longer runs the body with nil. For a one-parameter lambda that
  is the lambda itself; 0.12.0 ran its body with nil.
- A compile that raises, or a compile attempt the compiler throws away, leaves no state
  behind for later code. One such case read an undeclared local as nil and returned a
  wrong answer with no error (count sinking on a branch compiled twice).
- A host's own Lua function is called as given whatever its chunk is named; a host's
  yield through a stack segment keeps its exact values; on PUC Lua a hook set during a
  job does not leak into the next.
- A fasl replays a macro's `(set ...)` even when the global already held that value
  when the file was compiled.

## [0.12.0] - 2026-11-05

### Changed

- **Kernel: ShenOSKernel 43.2** (community `Shen-Language/shen-sources`, tag
  `shen-43.2`, commit `e6947f507ebc`, release tarball SHA-256
  `23c71508...417f32`). Vendored byte-identical; `(version)` is `"43.2"`. Against
  the previously vendored 43.1 build at `ec16a9f` only `init.kl` (the version
  string) and `extension-type-annotations.kl` (renumbered generated names) change;
  `t-star.kl` is unchanged, so the native typechecker fingerprints and the eqterm
  path in `shen.by-hypothesis-h` are unaffected. `tests/` gains upstream's
  `benchmark-coverage.shen`. `bin/yggdrasil-build.lua` now expects manifest
  `kernel-version=43.2`.

- **Kernel: ShenOSKernel 43.1 at upstream `ec16a9f`** (the 43.1 release plus
  shen-sources#117): `shen.by-hypothesis` and `shen.search-user-datatypes`
  dereference the checked term once per call through new `-h` predicates, and
  fail at once on an empty list. Vendored byte-identical from
  `ShenOSKernel-43.1-ec16a9f.tar.gz` (SHA-256 `060066a8…9baacd`); `(version)`
  is still `"43.1"`. The native typechecker follows it without falling back:
  `typecheck_native.lua` accepts the new `shen.search-user-datatypes`
  fingerprint (the hand port already fails on an empty list), and the driver
  translator compiles the `(= (shen.lazyderef Hyp B) ())` guard in
  `shen.by-hypothesis` as an arena comparison. eqterm still fires in
  `shen.by-hypothesis-h`.

- **Kernel: ShenOSKernel 43.1** (community `Shen-Language/shen-sources`);
  vendored wholesale from the verified `shen-43.1` release. The public
  `char-stream?`, `read-unit-string`, and `write-string` interfaces are
  provided by the native Lua stream layer.

- **Kernel: ShenOSKernel 42.2** (community `Shen-Language/shen-sources`, tag
  `shen-42.2`, commit `73507e0`, release tarball SHA-256 `1d022730…2678d8`),
  vendored byte-identical, replacing Tarver's S42.0 kernel — the same kernel
  shen-scheme 0.50 ships. `(version)` is `"42.2"`. Lineage choice and full
  delta: [`klambda/PROVENANCE.md`](klambda/PROVENANCE.md) (pyrex41/shen-lua#79).
- Boot: the 42.2 modules are pure defuns; `boot.lua` now calls
  `(shen.initialise)`, `(shen.x.features.initialise …)`,
  `(shen.x.programmable-pattern-matching.initialise)` and `(stlib.initialise)`
  after loading them, matching shen-scheme 0.50's boot set and order.
- Standard library: the precompiled 42.2 `klambda/stlib.kl` replaces the
  S-lineage `lib/StLib` Shen sources (removed, together with the stdlib boot
  image that cached loading them). Its 290 type signatures are cached in a
  sidecar of the kernel bytecode cache (`<kernel cache>.stlib`). Warm boot is
  ~100 ms CPU (was ~135 ms).
- `prims.lua`: the native `get`/`put`/`unput`/`arity` property store now
  operates on the 42.2 `shen.dict` layout; the native `fn` cache is
  invalidated on every `shen.lambda-form` write (42.0 port requirement).
  `shen.lambda-entry` is native from boot.
- The kernel test suite under `tests/` is the 42.2 suite (143 tests, was 134);
  the 42.2 extension suite (`tests/extensions/runme.shen`, 123 checks) passes
  when run from a ShenOSKernel 42.2 tree.
- `shen.*prolog-memory*` defaults to 10000 (42.2 `init.kl`; S42 had 1000).
- `bin/yggdrasil-build.lua` expects `kernel-version=42.2` manifests (older
  slices still build, with a warning).

### Performance

- Typechecking: the native Prolog translator compiles an `(= T1 T2)` guard
  over two engine terms to an in-arena comparison (`E.eqterm`) instead of
  copying both terms out to Shen lists and calling `=`. That guard is
  `shen.by-hypothesis`'s check, run once per hypothesis per goal, and copying
  it was ~75% of a typecheck-heavy run: capcov's `b-typed` workload drops
  from ~48 s to ~11 s CPU (instructions retired 661 G -> 140 G) with
  byte-identical output. Each side may be
  `(shen.deref X B)` or a bare term variable, so the deref-hoisted
  `by-hypothesis-h` of a patched 43.1 kernel takes the same path. Atoms and
  variables that differ still go through the kernel's `=`, so tuples and
  vectors keep structural equality.

### Fixed

- The native typechecker no longer returns wrong verdicts on a kernel whose
  type-checker defuns differ from the ones it was written against. On
  ShenOSKernel 43.1 with the typecheck deref hoist (shen-sources
  `perf/typecheck-deref-hoist`), the translated `shen.by-hypothesis` called
  the new `shen.by-hypothesis-h`, which had no native definition. The call
  raised a plain Lua error. That error reached callers as an ordinary Shen
  exception, which `trap-error` (and the Lua `shen.typecheck` API, which
  fails closed) read as "does not typecheck". Every typecheck failed and
  the process exited 0. Now:
  - The translated drivers are the closure of the t-star roots under
    "calls by name": any `t-star.kl` defun a driver calls is translated too,
    so the hoisted kernel's `shen.by-hypothesis-h` runs natively.
  - Before the first typecheck, every kernel defun the port reimplements
    instead of translating is fingerprinted against the versions it
    implements. That covers the hand-ported `shen.typecheck`,
    `lookupsig`/`sigf`, `search-user-datatypes`(`-h`), `show` and
    `maxinfexceeded?`, plus the `prolog.kl` primitives and builtin goals.
    The fingerprint is gensym-insensitive; regenerate it with
    `scripts/kernel-fingerprints.lua`. The set also checks that every driver
    call resolves.
  - A mismatch makes typechecks use the kernel's own KL typechecker, and
    stderr names the defun once. A predicate that is missing at run time
    raises a distinct sentinel, and the query is rerun on the KL engine.
  - `SHEN_TYPECHECK_NATIVE=require` raises an error instead of falling back.
  - `test/kernel_conformance_spec.lua` runs the native typechecker on the
    vendored 43.1 and the deref-hoisted 43.1 (fixture under
    `test/fixtures/`) against the kernel's KL typechecker. It also runs it
    on deliberately mismatched kernels.

- Deep non-tail recursion no longer overflows the Lua stack, in user code
  or in the kernel's own tree walkers. `(depth 12000)` for a plain
  `(+ 1 (depth (- N 1)))` recursion failed with `stack overflow` (it reached
  ~8000), as did typechecking a 3000-deep `[s N]` term or a 10000-element
  `[list number]` (`shen.curry`) and reading a 4000-element list literal
  (`shen.find-types`, `shen.process-applications`). LuaJIT's stack is a
  fixed ~65500 slots per coroutine (`LJ_STACK_MAX`, a compile-time
  constant), so a compiled function that makes a non-tail call now counts
  itself while it is on the stack, and every 160 of them the next call runs
  on a fresh coroutine stack. Tail calls are not counted, so constant-stack
  loops are unchanged. Depth is bounded by memory (`(depth 100000)` works);
  past 10000 nested segments, shared with the Prolog engine's, a call raises
  the trappable `Lua stack depth limit exceeded` (pyrex41/shen-lua#93).
- A warm fasl hit no longer runs a nested `load` twice. When a loaded file
  loaded another file, from a top-level `(load ...)` form or from a function
  that loads, the nested file's output printed twice on every cached run.
  The fasl format is now `SHENFASL7`, so caches written by older builds are
  recompiled once rather than replayed (pyrex41/shen-lua#92).
- The reader reads list literals of any length: `shen.<s-exprs>` recursed
  once per token, so past ~1550 elements LuaJIT's fixed stack overflowed and
  `read-file` reported it as `reader error near here:` with no context. The
  sequence rule, `shen.cons-form`, and the per-character
  `shen.<strcontents>`/`<alphanums>`/`<whitespaces>` (a 14 KB string literal
  overflowed the same way) are iterative in `prims.lua`; the single-token
  rules are still the kernel's. `test/reader_native_spec.lua` checks them
  against the kernel's own KL on every `.shen` file in `tests/` and
  `examples/` plus edge cases. A Lua stack overflow inside `read-file` is now
  reported as `stack overflow`. A list literal is still a nested `cons`
  expression to the rest of the pipeline, whose tree walkers bound it at
  about 3400 elements (pyrex41/shen-lua#88).
- Generated Lua no longer exceeds LuaJIT's 200-locals limit for a datatype
  rule whose conclusion pattern nests 16 or more levels deep, or for a
  `define` that returns a list literal of 200 or more elements; both failed
  to load with `function at line 1 has more than 200 local variables`. The
  fix is the let-splitting and wide-mode compilation from #78 (sequent rules
  with up to 194 premises); `test/wide_compile_spec.lua` now pins the two
  shapes from the issue (pyrex41/shen-lua#84).
- The native Prolog engine no longer overflows the Lua stack on deep
  proofs: a typecheck died with `stack overflow` at ~375 nested rule
  applications (`(shen.typecheck (mk 400) peano)`, an 800-element
  `[list number]`), well short of the legacy engine's ~1000. The engine runs
  in continuation-passing style on the Lua stack, and LuaJIT's stack is a
  fixed ~65500 slots per coroutine, so a deep proof now continues on a fresh
  coroutine stack every 96 counted non-tail continuation calls. Depth is
  bounded by memory; past 1000 nested segments a query raises the trappable
  `Prolog depth limit exceeded`. Typechecks of 1000-20000-deep terms now stop
  at the kernel's own recursive preprocessing (`shen.curry`, ~2000 nested
  `[s N]` levels or ~4600 list elements) instead (pyrex41/shen-lua#85).
- The kernel bytecode cache and its stdlib-signature sidecar default to
  `${XDG_CACHE_HOME:-$HOME/.cache}/shen-lua/kernel-<build>.bin` (directory
  created on first write; an unwritable location just skips caching). They
  were written into the current directory, one ~1.8 MB copy per directory
  shen ran from. `SHEN_KERNEL_CACHE` still overrides; old
  `.shen-kernel-cache.*` files in project directories can be deleted
  (pyrex41/shen-lua#87).
- `open`, `read-file`, `read-file-as-string`, `read-file-as-bytelist` and
  `load` resolve a relative file name against `*home-directory*`, which `cd`
  sets, as shen-go and shen-scheme do; they used the process cwd. As there,
  the prefix is a plain string join, applied to absolute names too. The native fast paths no longer try the cwd first,
  so a same-named file there cannot shadow the one `open` means
  (pyrex41/shen-lua#86).
- `<-address` past the end of an absvector raises instead of returning `nil`,
  so the kernel's vector printer stops at the end: `(vector 3)` prints
  `<... ... ...>` (it printed stray `funex…` entries).
