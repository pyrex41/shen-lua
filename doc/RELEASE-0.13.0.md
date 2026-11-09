# shen-lua 0.13.0

This release moves shen-lua to the community **ShenOSKernel 43.4** (`Shen-Language/shen-sources`, tag `shen-43.4`, commit `f34b307`). `(version)` prints `43.4`, and the official kernel suite passes 154/154.

The vendored `klambda/` and `tests/` are byte-identical to the 43.4 release archive (SHA-256 `15e7972e6bf0cd65d37c2eba85750b8839d2dbadda41027eae0c88e5017a2756`). The standard library now declares its signatures with `shen.declare-with-signature`, so the stdlib signature sidecar of the kernel cache is gone; the native typechecker wraps that function and its fingerprints are unchanged.

Also in this release, since 0.12.0:

- A test that is not a boolean raises: the test of `if` and `cond`, the operands of `and`/`or`, and the argument of `not`. `(str "a")` is quoted, as on the other ports, and several primitives check their arguments (`absvector`, `address->`, `<-address`, `set`, `value`, `hash`).
- Faster startup, compile and run: delta global pushes in the fasl, native reader paths, fixed-arity call helpers, uncurried lambda groups, direct `hd`/`tl` and raw arithmetic where a value is proved a cons or a number, and a quicker Prolog engine.
- A compiled lambda called from Lua with fewer arguments than it takes returns its partial application; `(thaw F)` of a lambda that takes arguments no longer runs its body with nil.
- A compile that raises leaves no state behind; one such case returned a wrong answer with no error.
- `make certify` fails when the kernel suite fails or stops early, and CI runs it with the native typechecker required, plus `make golden`. Lua 5.5 boots.

Full list in the [CHANGELOG](https://github.com/pyrex41/shen-lua/blob/v0.13.0/CHANGELOG.md).

## Install

From a checkout, or with Nix: `nix run github:pyrex41/shen-lua/v0.13.0 -- -e '(version)'`. The attached `shen-0.13.0-1.rockspec` and standalone `shen-bundle.lua` are alternatives. This release is not published on LuaRocks.org.

Validation: 2,417 port assertions across 38 specs, the official 43.4 kernel suite, 154/154, and 27 golden typechecker and Prolog results, plus a standalone-bundle smoke test.
