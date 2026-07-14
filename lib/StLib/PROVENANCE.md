# Provenance of the vendored standard-library sources (lib/StLib)

These are the **Shen sources** of the Shen standard library for the S41.2
(2026-07-11 refresh) kernel. Tarver's refresh no longer ships the standard
library as a precompiled `stlib.kl`; it ships these sources, which the SBCL
reference distribution loads into the image at install time via `install.shen`.
shen-lua does the equivalent at boot — see `boot.lua` `load_stdlib` and
`klambda/PROVENANCE.md`.

## Canonical source

- **Mirror**: `pyrex41/shen-upstream` — the designated mirror of Mark Tarver's
  shenlanguage.org uploads (private repo; formerly `pyrex41/shen-s41.1`, old
  URLs redirect).
  - Tag: `s41.2-pristine-20260711`
  - Commit: `11fc51bdf53a4dcb505adeec6ec8352754cbe50f`
- **Upstream origin** (what the mirror imported): Mark Tarver's `S41.2.zip`.
  - URL: https://www.shenlanguage.org/Download/S41.2.zip
  - Last-Modified: 2026-07-11
  - Zip SHA-256: `51becbfd60fa8c93c3f8ae5b20b948eaa84c4b1d14ad2f5d2a056002a53ee836`

Every file here is vendored **byte-identical** to `Lib/StLib/` in the mirror at
that tag (28 files, verified with `cmp`).

## How shen-lua loads these

`boot.lua` `load_stdlib()` runs upstream's own `install.shen` — its file order,
its `factorise` toggles, its `(package stlib …)` + `(map (fn systemf) …)`
externals block — with two mechanical rewrites:

1. The relative `(load "Sub/file.shen")` paths are made absolute against this
   directory, so no process `chdir` is needed.
2. The `(tc +)` toggles are neutralised to `(tc -)`: the stdlib is loaded
   **without typechecking**. This matches the pre-refresh behaviour (the old
   precompiled `stlib.kl` registered no stdlib type signatures either — its
   `stlib.initialise` was never called), it is much faster, and it keeps the
   native typecheck drivers deferred at boot. Functions are still fully defined
   and **arity-registered** (via the kernel's `define`/`update-lambda-table`
   path), which is what makes `(fn filter)` and a bare top-level `(filter …)`
   resolve — the very thing raw `stlib.kl` defuns did *not* do.

The load runs at every boot (after kernel init), for the CLI, the port spec
suite, and the kernel certification alike. `SHEN_NO_STDLIB=1` skips it (a
kernel-only embed); `SHEN_STDLIB_DIR` overrides this location. In the
single-file bundle these sources are embedded and materialised to a temp dir at
boot (see `build/make-bundle.lua`).

## Not typechecked here

Because the stdlib is loaded with `(tc -)`, stdlib functions carry no
registered type signatures — a `tc +` program that calls, say, `filter` will
not see `filter`'s type. This is unchanged from the pre-refresh port. Loading
the stdlib under `tc +` (upstream's default) would register the signatures but
is markedly slower and eagerly initialises the native typecheck drivers; if a
typed stdlib is wanted, that is a deliberate future option, not the default.
