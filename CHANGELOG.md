# Changelog

Notable changes to shen-lua. Release notes for earlier versions are under
[`doc/`](doc/) (`RELEASE-*.md`).

## [Unreleased]

### Changed

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

### Fixed

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
- `<-address` past the end of an absvector raises instead of returning `nil`,
  so the kernel's vector printer stops at the end: `(vector 3)` prints
  `<... ... ...>` (it printed stray `funex…` entries).
