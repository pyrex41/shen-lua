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
