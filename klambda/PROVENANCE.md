# Provenance of the vendored KLambda kernel

## Current: ShenOSKernel 42.2 (community `shen-sources` line)

The whole `klambda/` tree (23 `.kl` files) and the kernel test suite under
`../tests/` are vendored **byte-identical** from the ShenOSKernel 42.2 release —
the kernel that upstream [shen-scheme 0.50](https://github.com/tizoc/shen-scheme/tree/v0.50)
(2026-10-01) ships:

- **Repository**: [`Shen-Language/shen-sources`](https://github.com/Shen-Language/shen-sources)
  - Tag: `shen-42.2`
  - Commit: `73507e069fe147aefb728d632c4ce40bc6a7b314`
    ("Prepare Shen kernel 42.2 release", 2026-10-01)
- **Release asset**: `ShenOSKernel-42.2.tar.gz`
  - SHA-256: `1d02273003654d34ec020ae67cb214ecec410dee3350419ff807d82b652678d8`
    (the checksum pinned in shen-scheme 0.50's Makefile)
  - `klambda/*.kl` and `tests/` verified against the extracted archive with
    `cmp` / `diff -r`.
- `(version)` reports `"42.2"` (set by `shen.initialise-environment` in
  `init.kl`).

Files:

    core declarations dict init load macros prolog reader sequent sys
    t-star toplevel track types writer yacc          -- kernel
    stlib                                            -- precompiled standard library
    extension-features extension-expand-dynamic extension-launcher
    extension-programmable-pattern-matching          -- extensions (booted)
    extension-namespaces extension-type-annotations  -- extensions (vendored, opt-in)

### Lineage choice (pyrex41/shen-lua#79, option a)

This is a **lineage switch**. Releases up to 0.11.x vendored Mark Tarver's
**S42.0** kernel (`S42.zip` from shenlanguage.org, 2026-08-25, mirrored as
`pyrex41/shen-upstream` tag `s42-pristine-20260825`, zip SHA-256
`30abdc7e5a1e27b7a20109c1ed141e4712885e31f24d9710d16415fbbd4dfb23`) plus the
community 42 extensions and the S-lineage `Lib/StLib` Shen sources. 42.1 and
42.2 are releases of the **community** line only, which differs structurally,
so per the cross-port decision (pyrex41/bifrost#26, pyrex41/yggdrasil#32) the
42.2 kernel is adopted **wholesale** rather than porting its changes onto the
S42.0 base. Every port that Bifrost and Yggdrasil drive therefore runs the
same kernel as shen-scheme 0.50, byte for byte.

What that means structurally, relative to the S42.0 tree it replaces:

- **`init.kl` and `shen.initialise` are back.** Every 42.2 file is pure
  defuns; nothing initialises at load time. `boot.lua` loads all modules and
  then calls `(shen.initialise)` (environment, `*property-vector*`, arity
  table, lambda forms, kernel signatures), the extension initialisers, and
  `(stlib.initialise)`. The S42 load-order constraints (`… macros declarations
  t-star types`) and the hoisted `types.kl` declares are gone.
- **`dict.kl` is back.** `*property-vector*` is a `shen.dict` (an absvector:
  `shen.dictionary`, capacity, count, then hash buckets of `(Key . Props)`),
  and `get`/`put`/`unput` go through `shen.<-dict` / `shen.dict->` /
  `shen.assoc-set` / `shen.assoc-rm`. `prims.lua`'s native property store was
  rewritten for this layout.
- **Lambda forms are a property again.** `fn` reads the `shen.lambda-form`
  property; there is no `shen.*lambdatable*`. 42.0's requirement that a cached
  callable form be invalidated when a function is redefined with zero or
  unknown arity is met by the native `fn` fast path keying its cache on a
  generation counter that every `shen.lambda-form` write bumps.
- **`stlib.kl` is back** as the standard library: the precompiled output of
  42.2's `lib/stlib` sources (upstream `make-stlib.shen`). The S-lineage
  `lib/StLib` sources that 0.11.x loaded at boot were removed; see
  "Standard library" below.
- **`backend.kl`** (S42's `cl.*` Common Lisp backend) is not part of 42.2 and
  was removed.
- **42.1 source-form handlers**: `shen.macroexpand-h` takes a 4th argument and
  `shen.try-parse` returns parsed forms that the read loop expands afterwards.
  shen-lua overrides none of `read`, `lineread`, `shen.read-loop`,
  `shen.try-parse`, `macroexpand` or `shen.macroexpand-h`, so the kernel's
  own order applies; `read`/`lineread` at EOF without a trailing newline
  behave like shen-scheme 0.50.
- **42.2 namespaces**: `extension-namespaces.kl` is vendored from the release
  as generated (it already carries the 42.2 `externals`/`with-externals`
  change). It is not booted; a program loads the extension's Shen source
  (`extensions/namespaces.shen` in shen-sources) and calls
  `(shen.x.namespaces.initialise)`, as the 42.2 extension tests do.

### Boot list

`boot.lua` (`FILES`) boots the 16 kernel modules, `extension-features`,
`extension-expand-dynamic`, `extension-launcher`,
`extension-programmable-pattern-matching` and `stlib` — the same set
shen-scheme 0.50 boots. After `(shen.initialise)` it calls
`(shen.x.features.initialise …)` and
`(shen.x.programmable-pattern-matching.initialise)` in that order (as
shen-scheme does), registers the `lua.*` interop entries, then runs
`(stlib.initialise)`. The resulting `shen.*sigf*` matches shen-scheme 0.50's
458 signatures plus the four `lua.checked-*` signatures.

### Standard library

`klambda/stlib.kl` loads with the kernel and `(stlib.initialise)` registers
it (port-upgrades.md, 41.1). Its 290 `declare`s are cached next to the kernel
bytecode cache (`<kernel cache>.stlib`, keyed on the kernel cache key); see
`boot.lua` `stlib_types`. `SHEN_NO_STDLIB=1` skips `(stlib.initialise)`.

## Overriding

Set `SHEN_KL_DIR=/path/to/some/other/klambda` to boot a different KLambda tree
with the same file set (e.g. a development build of shen-sources). `boot.lua`
loads the `FILES` list from it and calls `shen.initialise` /
`stlib.initialise` when the tree defines them.

## History

- 0.11.x: Tarver S42.0 (2026-08-25 refresh) + community 42 extensions +
  S-lineage `lib/StLib` sources loaded at boot.
- Earlier: Tarver S41.2 (2026-07-11 refresh); before that the community
  ShenOSKernel 41.2 / 41.1 releases.

`git log -- klambda/PROVENANCE.md` has the full earlier text of each entry.
