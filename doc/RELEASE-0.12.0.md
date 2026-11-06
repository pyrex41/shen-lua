# shen-lua 0.12.0

This release moves shen-lua to the community **ShenOSKernel 43.2** (`Shen-Language/shen-sources`, tag `shen-43.2`, commit `e6947f5`), the kernel that Yggdrasil v0.1.0 requires of a stage-1 host. `(version)` prints `43.2`, and the official kernel suite passes 154/154.

It is the first release on the community kernel line; 0.11.1 shipped Tarver's S42 kernel. The vendored `klambda/` and `tests/` are byte-identical to the 43.2 release archive (SHA-256 `23c71508f0de24785e1f127ea4fab440081904d81c463090bc642ee840417f32`). The 43.2 type checker dereferences the checked term once per call and fails at once on an empty hypothesis or datatype list; the native typechecker follows it without falling back.

Also in this release, since 0.11.1:

- Strings count Unicode code points (UTF-8) (#80).
- Deep non-tail recursion, deep Prolog proofs and very long list or string literals no longer overflow LuaJIT's stack (#85, #88, #93).
- Relative file names resolve against `*home-directory*` (#86); the kernel bytecode cache lives under `$XDG_CACHE_HOME/shen-lua` instead of the current directory (#87); a nested `load` no longer runs twice on a warm cache hit (#92).
- Typechecking: `=` guards over engine terms compare in the arena, which cut a typecheck-heavy workload from about 48 s to 11 s CPU, and the native typechecker falls back loudly if the kernel's type-checker definitions differ from the ones it implements.

Full list in the [CHANGELOG](https://github.com/pyrex41/shen-lua/blob/v0.12.0/CHANGELOG.md).

## Install

From a checkout, or with Nix: `nix run github:pyrex41/shen-lua/v0.12.0 -- -e '(version)'`. The attached `shen-0.12.0-1.rockspec` and standalone `shen-bundle.lua` are alternatives. This release is not published on LuaRocks.org.

Validation: 1,798 port assertions across 29 specs and the official 43.2 kernel suite, 154/154, plus a standalone-bundle smoke test.
