# Provenance of the vendored KLambda kernel

## Release

- **Release**: ShenOSKernel-41.2
- **Tag/URL**: https://github.com/Shen-Language/shen-sources/releases/tag/shen-41.2
- **Zip SHA-256**: `49f1b85d02348d9b3ebc461570c5c56cc066270ab81e35d5257625fb9d17fe82`

All `.kl` files from the release `klambda/` directory are vendored here
**byte-identical** to the release (verified with `cmp` against the extracted
zip). This includes the new opt-in extension
`extension-programmable-pattern-matching.kl`, which is vendored but **not**
on the boot list — shen-lua boots the same 21 modules as shen-cl 41.2.

## compiler.kl caveat

`compiler.kl` is **not** part of the ShenOSKernel release. It is shen-cl's
generated KL->Lisp compiler (a shen-cl build artifact), vendored here from a
freshly generated 41.2 shen-cl build
(`cl-source/ShenOSKernel-41.2/klambda/compiler.kl`,
SHA-256 `ed30a08be4c8916b1e844d437fb9d65a36476e1a99419340b5523fc81a7c3e44`).
