# Unii memory oracle

This directory is an implementation-independent verification oracle for the
memory tree and view policy. It is plain Lua 5.1/LuaJIT code, imports no Shen
module, and does not share an implementation branch with the memory engine.

Run from the repository root:

```sh
luajit unii/eval/oracle/generate_fixtures.lua --check
luajit unii/eval/oracle/spec.lua
```

Regenerate the checked-in traces with:

```sh
luajit unii/eval/oracle/generate_fixtures.lua
```

## Contracts represented

- `node(level,index)` covers
  `[index*2^level,(index+1)*2^level)`.
- `zoom(first,count)` accepts a power-of-two count, an aligned first ID,
  and an interval ending at or below the version-1 ceiling.
- A view is valid only when its ordered intervals exactly partition
  `[0,message_count)`. Gaps, overlaps, invalid nodes, and overruns fail.
- A merge candidate consists of adjacent aligned siblings with an available
  parent. Its score is `(T-last)/2^level`, where `last` is the zero-based ID
  of the pair's final message. Scores are compared as the exact
  cross-products `a.numerator*2^b.level` and
  `b.numerator*2^a.level`.
- Rendering is one `first+count|text` line per node, oldest first, with a
  final LF on every line. `#rendered` is the byte count used by hysteresis.
- The default hysteresis enters batch mode only when rendering is strictly
  greater than 128,000 bytes and remains in it until rendering is at most
  64,000 bytes. If no built parent is eligible, batch mode remains active.
  `hysteresis_resume` continues the same batch when a parent is published.

All accepted numeric values are integral Lua numbers bounded by
`2^31-1`. Although a score cross-product can be as large as roughly `2^61`,
it is an exact binary64 value: its unscaled numerator has at most 31
significant bits and multiplication is only by a power of two. The oracle
checks the inverse scaling before using each product.

## Canonical text policy

The plan requires deterministic line-break collapse and a documented policy
for delimiter-sensitive text. After rejecting invalid UTF-8, this oracle
applies the policy reconciled with the engine (decision 5 in
`unii/docs/contracts/decisions.md`):

1. CRLF (as one break), lone CR, lone LF, NEL (U+0085), LS (U+2028) and PS
   (U+2029) each become one ASCII space.
2. Every other C0 control and DEL becomes one ASCII space.
3. All other bytes are preserved, including `|` and `%`. Spaces are not
   coalesced.

The address ends at the first `|` and the line at its only LF, so no
escaping is needed. Summary text bytes are measured before rendering for
the separate 512-byte summary cap. Address, separator and LF overhead are
included in view bytes. Prompt framing such as `<chat>` tags is not.

## Golden fixture format

Fixtures are UTF-8/LF text under `unii/eval/fixtures/`. Lines beginning with
`#` are metadata. Fields use `|`; lists use commas; `-` is an empty list.
Node addresses are always `first+count`.

`rollback-20001.trace` has:

```text
R|T|line-budget|merged-parent-addresses-or--|oldest-first-view
```

For each `T=1..20001`, the independent rollback port is pushed with message
ID `T-1`. The line budget is exactly the number of checkpoints retained by
that push. A leaf is appended to the due-score view, which is then reduced to
that budget. The expected merged parent is independently derived from the
rollback view delta. Fixture generation aborts unless both the merge sequence
and complete view match.

`byte-hysteresis.trace` has:

```text
B|T|batch-active|entered-batch|bytes-before|bytes-after|merged-parents-or--|oldest-first-view
```

It runs 700 appends with every parent available and deterministic node text of
420 through 499 bytes. The text includes `%`, `|`, CRLF, precomposed UTF-8,
and a combining mark, exercising canonical rendering and byte accounting.
`unii/test/test_oracle.lua` diffs the Shen engine against both traces.
The rollback and hysteresis fixtures are intentionally separate policies.

## Rollback provenance

The port in `rollback.lua` follows the JavaScript branch structure in Victor
Taelin's UniiChat gist:

- gist: `VictorTaelin/91837951a5ce5b38f341ec1ba1df6449`
- Git revision: `3c190e06f34aba0c69f49042c526093269604935`
- `optchat.md` SHA-256:
  `12f300f760af82bc07bc5201051d1267824ded09c9def8186e4f8144368038d8`

## Explicit ambiguity decisions

1. The request says “64 KB high water, 128 KB per the plan,” while the plan
   defines 128,000 bytes as the upper trigger and 64,000 bytes as the lower
   target. The oracle follows the plan. `KB` means 1,000 bytes, not KiB.
2. The gist describes comparison steps as `t=0..20000`; fixture `T` is message
   count, so those steps are represented as `T=1..20001`.
3. “Oldest pair” on equal scores means the smaller final message ID. The final
   stable node-key tie-break is lexicographic `(parent.level,parent.index)`.
4. The plan does not define delimiter escaping. The policy above replaced
   this oracle's original percent-encoding when it was reconciled with the
   engine. That choice is flagged for Reuben in
   `unii/docs/contracts/decisions.md`.
5. The rollback comparison's “matching line-count budget” is the rollback
   list length after each push, not a byte estimate. Byte hysteresis has its
   own trace.
6. A threshold equality does not enter batch mode (“exceeded”), and equality
   with the lower target exits it (“until ... reached”).
7. The version-1 ceiling is interpreted as at most `2^31-1` messages, with
   message IDs `0..2^31-2`. A node or zoom interval may end exactly at that
   message-count ceiling.
