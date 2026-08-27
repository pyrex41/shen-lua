# Provenance of the vendored KLambda kernel

The vendored `klambda/` tree has **two lineages**. Read both sections — they
come from different upstreams and are updated independently.

## 1. Kernel proper — S42 (2026-08-25 refresh)

- **Canonical source**: `pyrex41/shen-upstream` — the designated mirror of Mark
  Tarver's shenlanguage.org uploads (private repo).
  - Tag: `s42-pristine-20260825`
  - Commit: `pending mirror import`
    ("Pristine import of the 2026-08-25 S42 refresh from shenlanguage.org")
- **Upstream origin** (what the mirror imported): Mark Tarver's `S42.zip`,
  the reference SBCL/Windows distribution.
  - URL: https://www.shenlanguage.org/Download/S42.zip
  - Last-Modified: 2026-08-25
  - Zip SHA-256: `30abdc7e5a1e27b7a20109c1ed141e4712885e31f24d9710d16415fbbd4dfb23`

These 15 files are vendored **byte-identical** to `KLambda/` in the mirror at
that tag — equivalently, to the zip's `KLambda/` directory (both verified with
`cmp`):

    yacc core load prolog reader sequent sys t-star toplevel
    track types writer backend declarations macros

> **Caveat — S42 is the upstream 2026-08-25 distribution.** Community
> extensions retained below are not part of the pristine archive.
> `(version)` reports `"42"` (it is set in `declarations.kl`).

### What changed vs the community ShenOSKernel-42 we used to vendor

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
  precompiled KLambda blob; upstream now ships it as **Shen sources** under
  `Lib/StLib/`. shen-lua vendors those sources under `lib/StLib/` and loads them
  at boot (see section 2 and `lib/StLib/PROVENANCE.md`); `stlib.kl` is gone.
- Other renames observed: `hush` → `shen.hush`, `input+` → `shen.input-h+` /
  `shen.process-input+`, plus new `shen.rdecons`, `shen.shen`, pointer helpers.

## 2. Extensions — community ShenOSKernel-42 (retained); stdlib moved out

**Extensions.** Tarver's refresh does not ship these; they are **retained
byte-identical from the community `ShenOSKernel-42`** release (zip SHA-256
`49f1b85d02348d9b3ebc461570c5c56cc066270ab81e35d5257625fb9d17fe82`) so the CLI
launcher etc. stay available:

- `extension-features.kl`, `extension-expand-dynamic.kl` — booted.
- `extension-launcher.kl` — booted; provides the launcher the CLI can use.
- `extension-programmable-pattern-matching.kl` — vendored, opt-in, **not** booted.

They are pure `defun`/`defmacro` referencing only public kernel functions
(`get`/`put`/`arity`/…) — never the removed `dict.*`, `shen.<-dict`, or
`shen.initialise-*` — so they load unchanged against the refreshed kernel.

**Standard library.** No longer a `.kl` file here. It is loaded at boot from the
S-lineage Shen sources vendored under `lib/StLib/` — see
[`lib/StLib/PROVENANCE.md`](../lib/StLib/PROVENANCE.md) and `boot.lua`
`load_stdlib`. Loading through the kernel's own `define` path (rather than as
raw `stlib.kl` defuns) registers each function's `arity` property + lambda-table
entry, which **fixes** the long-standing quirk where a bare `(fn filter)` /
top-level `(filter …)` raised "fn: filter is undefined" (the pre-refresh
`stlib.kl` never called `stlib.initialise`, so those functions had runtime
`arity` = -1). A regression test lives in `test/stdlib_spec.lua`.

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
