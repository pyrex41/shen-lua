# Vendored KLambda for ShenOSKernel 42.2

These are the KLambda sources of **ShenOSKernel 42.2** (community
[`shen-sources`](https://github.com/Shen-Language/shen-sources) release
`shen-42.2`), vendored byte-identical so that `shen-lua` is self-contained:
you can `git clone` and run without a separate kernel checkout. See
[PROVENANCE.md](PROVENANCE.md) for the exact source, checksum and the lineage
note (this replaced Tarver's S42.0 kernel).

## Files

There are 23 `.kl` files.

**Kernel (16):** core, declarations, dict, init, load, macros, prolog, reader,
sequent, sys, t-star, toplevel, track, types, writer, yacc

**Standard library (1):** stlib — precompiled from 42.2's `lib/stlib`, registered
at boot by `(stlib.initialise)`.

**Extensions (6):**
- extension-features, extension-expand-dynamic, extension-launcher,
  extension-programmable-pattern-matching (booted; the same set shen-scheme
  0.50 boots)
- extension-namespaces, extension-type-annotations (vendored, opt-in; NOT on
  the boot list)

The actual boot order is defined in `boot.lua` (`FILES`), not by this list.

## License
See the LICENSE in the root of this repository and the license headers at the
top of each `.kl` file.

## Overriding
To use a different set of KLambda files (e.g. a development build of the same
kernel), set:

    SHEN_KL_DIR=/path/to/some/other/klambda
