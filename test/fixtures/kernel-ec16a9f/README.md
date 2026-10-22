# Exact upstream ec16a9f kernel

All 23 official KL files are byte-identical to the unmodified upstream
`ec16a9fa4fc2e87e2aa336fb1ae30e8ac2266394` build published at:

https://github.com/pyrex41/shen-sources/releases/download/upstream-ec16a9f/ShenOSKernel-43.1-ec16a9f.tar.gz

Archive SHA-256:
`060066a8f84d9a2f7d41cb3b37b986a8d4653279752b739b5063cd648d9baacd`.
Per-file SHA-256: `sha256.json`. License copied from the authenticated archive.
`tests/` in that archive is byte-identical to this repository's release tests.
The default vendored kernel now matches this exact qualification fixture.
The earlier release 715824a and this upstream build both report version 43.1.

The earlier `kernel-43.1-deref-hoist` fixture is preserved with its original
5596445 provenance. Unlike it, these final wrappers return false for empty
hypotheses/datatypes *before* full dereferencing. Their helpers are unchanged
up to generated-name normalization. Other KL byte changes are generated names,
including Select/GoTo/Freeze/Result and signature closure parameter names.

Handport review: native datatype dispatch first lazily dereferences the
alternatives and rejects a non-cons (including NIL), before touching goal or
assumptions. It passes arena handles to predicates; unification and guard reads
resolve current bindings rather than copying the term. The ec16a9f empty-list
guard preserves this valid-term behavior. Alternative order, failed alternatives,
lock/cut checks and binding rollback remain the same. The by-hypothesis wrapper
and helper are translated dynamically from the selected source. All other
REIMPLEMENTED fingerprints match the previously reviewed release or hoist.
This review does not establish equivalence for malformed cyclic engine state.

Native/legacy agreement is not an independent oracle for shared primitive
overrides in prims.lua. Qualification must retain that boundary, and reject
unsupported shared-primitive source shapes rather than silently trusting fallback.
