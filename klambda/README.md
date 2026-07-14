# Vendored KLambda for Shen 41.2

These are the KLambda kernel sources for **Shen 41.2**. They are included
directly in this repository so that `shen-lua` is self-contained: you can
`git clone` and run without needing a separate ShenOSKernel checkout.

The tree has **two lineages** — the refreshed kernel proper from
shenlanguage.org, and the community standard library + extensions retained on
top. See [PROVENANCE.md](PROVENANCE.md) for exact sources, checksums, and the
full list of what the refresh added/removed.

## Files

There are 20 `.kl` files.

**Kernel proper — S41.2 (2026-07-11 refresh), 15 files, byte-identical to
`shenlanguage.org/Download/S41.2.zip`:**
- yacc, core, load, prolog, reader, sequent, sys, t-star, toplevel,
  track, types, writer, backend, declarations, macros

**Standard library + extensions — retained from community ShenOSKernel-41.2:**
- stlib
- extension-features, extension-expand-dynamic, extension-launcher (booted)
- extension-programmable-pattern-matching (vendored, opt-in; NOT on the boot list)

The actual boot order is defined in `boot.lua` (`FILES`), not by this list.

> Removed relative to the pre-refresh vendored set: `compiler.kl` (a shen-cl
> build artifact), `dict.kl`, and `init.kl` — see PROVENANCE.md.

## License
See the LICENSE in the root of this repository and the original Shen distribution.

## Overriding
To use a different set of KLambda files (e.g. a development tree or a different
Shen version), set the environment variable:

    SHEN_KL_DIR=/path/to/some/other/klambda

The `boot.lua` loader will use that location instead of the vendored `klambda/`
directory.
