# Changelog

Notable changes to shen-lua. Release notes for earlier versions are under
[`doc/`](doc/) (`RELEASE-*.md`).

## [Unreleased]

### Changed

- **Kernel: ShenOSKernel 43.1** (community `Shen-Language/shen-sources`);
  vendored wholesale from verified upstream commit `ec16a9f`, including the
  merged dereference-hoist changes and final empty-list guards. Kernel version
  remains `43.1`. The public
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

- Native typechecking compares eligible literal-colon guards directly in the
  arena, avoiding a lifted guard and materialization call. Complete-query
  measurements, semantic qualification and rejected prototypes are recorded in
  [`arena-guards-results.md`](docs/performance/arena-guards-results.md).

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
