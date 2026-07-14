# Provenance of the vendored KLambda kernel

The vendored `klambda/` tree has **two lineages**. Read both sections — they
come from different upstreams and are updated independently.

## 1. Kernel proper — S41.2 (2026-07-11 refresh)

- **Canonical source**: `pyrex41/shen-s41.1` — the designated mirror of Mark
  Tarver's shenlanguage.org uploads (private repo).
  - Tag: `s41.2-pristine-20260711`
  - Commit: `11fc51bdf53a4dcb505adeec6ec8352754cbe50f`
    ("Pristine import of the 2026-07-11 S41.2 refresh from shenlanguage.org")
- **Upstream origin** (what the mirror imported): Mark Tarver's `S41.2.zip`,
  the reference SBCL/Windows distribution.
  - URL: https://www.shenlanguage.org/Download/S41.2.zip
  - Last-Modified: 2026-07-11
  - Zip SHA-256: `51becbfd60fa8c93c3f8ae5b20b948eaa84c4b1d14ad2f5d2a056002a53ee836`

These 15 files are vendored **byte-identical** to `KLambda/` in the mirror at
that tag — equivalently, to the zip's `KLambda/` directory (both verified with
`cmp`):

    yacc core load prolog reader sequent sys t-star toplevel
    track types writer backend declarations macros

> **Caveat — the "41.2" version number was reused.** Upstream re-uploaded a
> *restructured* kernel under the same `41.2` version. This is a **different
> lineage** from the community `ShenOSKernel-41.2`
> (github.com/Shen-Language/shen-sources, tag `shen-41.2`,
> zip SHA-256 `49f1b85d02348d9b3ebc461570c5c56cc066270ab81e35d5257625fb9d17fe82`)
> that this file previously described. We call the current one
> **"S41.2 (2026-07-11 refresh)"** to disambiguate. `(version)` still reports
> `"41.2"` (it is set in `declarations.kl`).

### What changed vs the community ShenOSKernel-41.2 we used to vendor

- **New: `backend.kl`** — a `cl.*` KLambda→Common-Lisp backend. Irrelevant to
  the Lua runtime, but on the upstream boot list, so vendored and booted (it is
  pure defuns; it defines functions that are never called under Lua).
- **Removed: `compiler.kl`** — was shen-cl's generated KL→Lisp compiler (a
  shen-cl build artifact, never part of any ShenOSKernel release). shen-lua has
  its own Lua compiler (`compiler.lua`) and never used it at runtime. Dropped.
- **Removed: `dict.kl`** — the dictionary layer is gone. Property vectors are
  now plain vectors: `*property-vector*` is `(vector 20000)` and `get`/`put`
  index it via `hash` + `shen.change-pointer-value` / `shen.remove-pointer`,
  rather than the old `shen.dict` / `shen.<-dict` / `shen.dict->`. Internal to
  `get`/`put`; callers are unaffected.
- **Removed: `init.kl`** — its work moved into `declarations.kl` and
  `toplevel.kl`. There is **no `shen.initialise` function** any more: the
  kernel initialises itself at LOAD time via top-level forms in
  `declarations.kl` — `(set *property-vector* (vector 20000))`, the environment
  `set`s, `(shen.initialise-arity-table …)`, `(put shen shen.external-symbols …)`
  and `(shen.build-lambda-table …)`. `shen.initialise-lambda-forms` /
  `-signedfuncs` / `-environment` are gone; `shen.initialise-lambda-tables`
  (~renamed) and the arity table remain.
- **Removed: `stlib.kl`** — the standard library is no longer shipped as a
  precompiled KLambda blob; upstream now ships it as **lazy Shen sources** under
  `Lib/StLib/` to be loaded on demand. See section 2 for how shen-lua bridges
  this gap.
- Other renames observed: `hush` → `shen.hush`, `input+` → `shen.input-h+` /
  `shen.process-input+`, plus new `shen.rdecons`, `shen.shen`, pointer helpers.

## 2. Standard library + extensions — community ShenOSKernel-41.2 (retained)

Because Tarver's refresh no longer ships a precompiled `stlib.kl` and shen-lua
does not yet have a lazy `Lib/StLib` loader, these five files are **retained
byte-identical from the community `ShenOSKernel-41.2`** release
(zip SHA-256 `49f1b85d02348d9b3ebc461570c5c56cc066270ab81e35d5257625fb9d17fe82`)
so the standard library and the CLI launcher stay available and the kernel test
suite still certifies 134/134:

- `stlib.kl` — the precompiled standard library (`filter`, `take`, `drop`,
  `reduce`, string/list/vector helpers, …).
- `extension-features.kl`, `extension-expand-dynamic.kl` — booted.
- `extension-launcher.kl` — booted; provides the launcher the CLI can use.
- `extension-programmable-pattern-matching.kl` — vendored, opt-in, **not** booted.

These are all pure `defun`/`defmacro` and reference only public kernel functions
(`get`/`put`/`arity`/…) — never the removed `dict.*`, `shen.<-dict`, or
`shen.initialise-*` functions — so they load unchanged against the refreshed
kernel. They are library/Shen-level code, effectively version-stable.

> **Known limitation (pre-existing, not introduced by the refresh).** stlib
> functions get an `F` entry from their `defun` and a compiler arity from the
> boot prescan, so they compile as direct calls and work in loaded programs and
> the test suite. But `stlib.initialise` is never called, so their runtime
> `arity` *property* stays `-1`; a bare `(fn filter)` / top-level `(filter …)`
> reference that resolves through the lambda table fails with "fn: filter is
> undefined". This behaves identically on the pre-refresh kernel. The clean fix
> is a lazy `Lib/StLib` loader (see the PR's "remaining work").

## Boot order

The boot order lives in `boot.lua` (`FILES`) with a full rationale. It is **not**
upstream `Sources/make.shen` order: make.shen relies on the factorise pass and a
macros bootstrap that runs last, whereas shen-lua compiles KLambda directly, so
what matters is that each module's LOAD-TIME side effects (the `declare` forms in
`types.kl`, the init forms in `declarations.kl`) see their dependencies already
defined. The resulting tail is `… macros declarations t-star types`.

## Overriding

Set `SHEN_KL_DIR=/path/to/some/other/klambda` to boot a different KLambda tree
(e.g. a full ShenOSKernel checkout during development). `boot.lua` uses it
instead of this vendored directory.
