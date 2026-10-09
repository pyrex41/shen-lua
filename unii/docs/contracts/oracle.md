# Oracle contract

The independent oracle lives in `unii/eval/oracle/`. It is plain Lua 5.1 /
LuaJIT with no Shen and no imports from the engine. Its golden traces live
in `unii/eval/fixtures/`. The line formats, the generator and the fixture
provenance are documented in `unii/eval/oracle/README.md`.

## How the engine is held to it

`unii/test/test_oracle.lua` runs with the main suite and covers:

| Case | Diff |
|---|---|
| `rollback-20001.trace` | For each T = 1..20,001, append leaf T − 1, call `Core:merge_to_count(view, T, budget)` (the Shen `unii.merge-keys-to-count`), and require exactly the row's merged parents and view. |
| `byte-hysteresis.trace` | For 700 appends with every parent available and the generator's node texts, run the Shen `unii.apply-byte-policy` over nodes built by `unii.make-node`. Compare bytes before and after, batch state, entry, merges and view at every row, and the rendered bytes every 100 rows. |
| Side by side | The oracle's `hysteresis_append` / `hysteresis_resume` against the engine policy at every step: threshold-equality cases, stalled batches resumed when parents are published, and 40 random configurations with hostile text and partial parent availability. |
| Addresses and keys | Zoom and key validity at and around the 2^31 − 1 ceiling |
| Due ordering | 6,000 pairs, including T near 2^31 and levels up to 30, against the oracle's exact cross-products |
| Canonical text | 3,000 texts containing every line-break form, controls, `\|`, `%`, multibyte characters and long ranges (the engine splits long text into halves when rendering), against `oracle.render_line` |

`luajit unii/eval/oracle/spec.lua` runs the oracle's own checks, and
`luajit unii/eval/oracle/generate_fixtures.lua --check` confirms the
committed traces are current. If the oracle changes, regenerate the traces
(`generate_fixtures.lua`) in the same commit.

## Disagreements

Each disagreement is resolved by deciding which side is wrong, fixing that
side and recording the decision in `decisions.md`. Neither side is
special-cased in the tests.
