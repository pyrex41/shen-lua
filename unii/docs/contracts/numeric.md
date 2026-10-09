# Numeric rules (format 1)

shen-lua represents Shen numbers as LuaJIT doubles. The rules below keep
every quantity in the core exactly representable and keep `/` out of the
core.

## Domains and bounds

| Quantity | Domain | Enforced by |
|---|---|---|
| message ids, counts, node indexes | 0 .. 2^31 − 1 (`unii.max-id`) | `schema` `nat` (host), `unii.nat?` and sequence and ceiling checks (core) |
| node levels | 0 .. 31 | `unii.valid-key?` |
| byte counts | nat; a leaf is at most `leaf_cap` ≤ 65,536; a source chunk is at most `chunk_max` ≤ 2^20 | `config-errors`, `message-errors` |
| view bytes | sum of line bytes; with a frontier of 2^31 leaves, each line under 600 bytes, this is far below 2^53 | — |
| `unii.divmod-pow2 N L` | N < 2^40, 0 ≤ L < 40; anything else raises | its guard |
| `unii.digest32` state | below 2^32 · 33 + 2^21, which is under 2^40 | `divmod-pow2` reduction mod 2^32 at each step |

At the boundary, integers travel as canonical decimal text (`codec.int`).
That text is parsed by shen-lua's `checked_integer`, which rejects values
outside ±(2^53 − 1) before any rounding happens. A Lua number that may
already have been rounded is refused (`codec.int(9007199254740993)`). Values
coming out of Shen pass through `checked.check` in `codec.from_shen`. The
schema layer narrows `nat` to the v1 ceiling 2^31 − 1, so `"2147483648"`,
`"-1"`, `"01"` and `"1e3"` are all rejected (`test_boundary.lua`).

## Merge priority (due score)

Following the plan (§7) and the gist, for the adjacent sibling pair whose
left key is `[key L I]` (I even) and a message count of T:

```
last = (I + 2) * 2^L - 1          zero-based index of the pair's final message
due  = (T - last) / 2^L  =  (T + 1) / 2^L - (I + 2)
```

The core stores this as `[due W F L]`, where `(Q, F) = divmod(T + 1, 2^L)`
and `W = Q − (I + 2)`. The exact value is `W + F / 2^L` with
`0 ≤ F < 2^L`. To compare `(W1, F1, L1)` with `(W2, F2, L2)`:

* If `W1 ≠ W2`, the larger W is more due.
* Otherwise, compare `F1 · 2^(L2 − L1)` with `F2` when `L1 ≤ L2` (or the
  symmetric form). Both sides are below 2^31.

No floating-point division is used, and `/` does not appear in any core
file (a test scans for it). `test_tree.lua` compares this ordering with
exact int64 cross-multiplication over random pairs.

Eligible pairs are adjacent, aligned siblings in the current view whose
parent is built. The pair with the strictly greatest due score wins, and on
a tie the oldest (leftmost) pair wins. No further tie-break is needed,
because two different eligible pairs cannot share the same left key.

## Line-count policy (oracle comparison only)

`unii.merge-keys-to-count Keys T Budget` merges the most due eligible pair
(with every parent treated as built) until the view has at most `Budget`
lines. With `Budget` equal to the length of the gist's rollback push list
at step T, the resulting view equals the push list at all 20,001 steps,
T = 0..20,000 (`test_view.lua`). The first-message variant of the due score
matches at only 481 of those steps, which is why the endpoint form is used.
This policy is not used live.

## Byte-budget hysteresis (live policy)

This is a separate policy from the line-count policy above.

```
line bytes  = #"<first>+<count>|" + text bytes + 1     (text with CR and LF each replaced by one space)
view bytes  = 15 + sum of line bytes                     ("<chat>\n" + "</chat>\n")
```

After the view has been extended, the core applies the policy:

* If not in batch mode and `bytes <= high`, nothing happens. The view may
  remain anywhere between `low` and `high`.
* If in batch mode, or if `bytes > high`, the core repeatedly merges the
  most due eligible pair while `bytes > low`.
  * If the view reaches `bytes <= low`, batch mode ends.
  * If no eligible pair remains, batch mode persists (and is recorded) and
    resumes after the next accepted event.

The defaults are low = 64,000 and high = 128,000. `test_hysteresis.lua`
checks every transition against an independent model of these rules, both
with small thresholds (1,500/3,000) and with the defaults (crossing
128,000).
