# Merge-policy oracle fixtures (for `unii/eval/oracle/`)

The independent arithmetic oracle and the gist rollback fixtures are being
built separately in `unii/eval/oracle/`. This branch does not contain them.
`test_view.lua` already contains a case that loads them, and it reports SKIP
until they exist.

## Layout

```
unii/eval/oracle/fixtures/manifest.lua   -> return { { file = "rollback_t0_20000.lua" }, ... }
unii/eval/oracle/fixtures/<file>         -> return { steps = { step, ... } }
```

Each step is checked against the Shen core's line-count policy
(`Core:merge_to_count`, which calls `unii.merge-keys-to-count`):

```lua
{
  view   = { {level, index}, ... },   -- input view, oldest first, aligned, gap-free
  total  = T,                         -- message count used for due scores
  budget = B,                         -- merge until #view <= B
  expect_view   = { {level, index}, ... },
  expect_merged = { {level, index}, ... },   -- optional: parents in merge order
}
```

The line-count policy treats every parent as built. The due score for a
pair whose left key is `{L, I}` is `(T - last) / 2^L`, with
`last = (I + 2) * 2^L - 1`. The greatest score is merged first, and on a
tie the oldest pair is merged first (see `numeric.md`). The oracle should
compute these scores without trusting the core: exact rationals or int64
cross-multiplication.

Byte-budget hysteresis is a separate policy. If the oracle also models it,
add a separate fixture kind and keep it apart from the line-count steps.
Its rules are in `numeric.md`. `test_hysteresis.lua` already contains an
in-tree reference model.

## In-tree reference until the fixtures exist

`test_view.lua` reimplements the gist's rollback `push` in Lua and checks
three things against the Shen policy:

1. The push table for t = 0..9 matches.
2. The worked T = 10 example matches.
3. The merge sequence equals the push list at all 20,001 steps.

`test_tree.lua` checks the due ordering against int64 cross-multiplication.
These checks live inside this repository and are not independent of it.
