# ShenOSKernel 43.1 with the typecheck deref hoist

`t-star.kl` is ShenOSKernel 43.1's `klambda/t-star.kl` with one kernel source
change applied: `perf(t-star): deref the checked term once, outside the
datatype and hypothesis loops` (shen-sources branch
`perf/typecheck-deref-hoist`, commit
`55964453e8a687ba2c9d107dbaebb23ef72996a9`, not yet upstream).

- SHA-256: `a0cedbb0334eb7f66fe5e2296056ea66d1e2f42c9efe176f6d1be2f0b28bf2ec`
- `shen.search-user-datatypes` and `shen.by-hypothesis` become plain defuns
  that dereference their term arguments once and call the new Prolog
  predicates `shen.search-user-datatypes-h` and `shen.by-hypothesis-h`.
- Every other defun is unchanged except for gensym renumbering.

`test/kernel_conformance_spec.lua` assembles a kernel directory from the
vendored `klambda/` with this file in place of `t-star.kl` and checks that the
native typechecker runs it (and agrees with the kernel's KL typechecker).
