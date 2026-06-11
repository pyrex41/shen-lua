# Vendored KLambda for Shen 41.2

These are the KLambda kernel sources for **Shen 41.2** (from `ShenOSKernel-41.2`).

They are included directly in this repository so that `shen-lua` is self-contained:
you can `git clone` and run without needing a separate ShenOSKernel checkout.

See [PROVENANCE.md](PROVENANCE.md) for the exact release tag, checksum, and the
`compiler.kl` caveat (it is a shen-cl build artifact, not part of the release).

## Files
There are 22 `.kl` files:
- core, toplevel, sys, dict, sequent, yacc, reader, prolog, track, load, writer, macros, declarations, types, t-star, init
- compiler (shen-cl build artifact — see PROVENANCE.md)
- stlib
- extension-features, extension-expand-dynamic, extension-launcher
- extension-programmable-pattern-matching (vendored, opt-in; NOT on the boot list)

## License
See the LICENSE in the root of this repository and the original ShenOSKernel distribution.

## Overriding
If you want to use a different set of KLambda files (e.g. a development tree or a different Shen version), set the environment variable:

    SHEN_KL_DIR=/path/to/some/other/klambda

The `boot.lua` loader will use that location instead of the vendored `klambda/` directory.
