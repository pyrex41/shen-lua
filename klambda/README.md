# Vendored KLambda for Shen 41.1

These are the KLambda kernel sources for **Shen 41.1** (from `ShenOSKernel-41.1`).

They are included directly in this repository so that `shen-lua` is self-contained:
you can `git clone` and run without needing a separate ShenOSKernel checkout.

## Source
- Original: https://github.com/Shen-Language/ShenOSKernel (or equivalent release tarball for 41.1)
- Directory in original: `klambda/`
- Version: 41.1 (as of the March 2026 release)

## Files
There are 21 `.kl` files:
- core, toplevel, sys, dict, sequent, yacc, reader, prolog, track, load, writer, macros, declarations, types, t-star, init
- compiler
- stlib
- extension-features, extension-expand-dynamic, extension-launcher

## License
See the LICENSE in the root of this repository and the original ShenOSKernel distribution.

## Overriding
If you want to use a different set of KLambda files (e.g. a development tree or a different Shen version), set the environment variable:

    SHEN_KL_DIR=/path/to/some/other/klambda

The `boot.lua` loader will use that location instead of the vendored `klambda/` directory.