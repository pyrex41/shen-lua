# Reconciled decisions: engine and oracle

The Shen engine (`unii/core/`) and the independent oracle
(`unii/eval/oracle/`, plain Lua) were written separately from the same plan
and gist. `unii/test/test_oracle.lua` diffs them on every run against:

* the oracle's golden traces (`unii/eval/fixtures/`);
* the oracle module run side by side on random configurations.

This page records each place where the sources were ambiguous, which
interpretation both sides now implement, and whether Reuben still needs to
confirm it. Items marked **Reuben** are implemented as written below, so
that tests can pin them, but are open for his decision.

| # | Question | Decision | Before reconciliation | Reuben? |
|---|---|---|---|---|
| 1 | KB or KiB | 1 KB = 1,000 bytes. Thresholds are exactly 64,000 (low) and 128,000 (high) UTF-8 bytes. | Both sides already agreed. | No. The plan states the numbers. |
| 2 | Threshold equality | Batch mode is entered only when view bytes > high. It ends as soon as view bytes ≤ low. | Both agreed. | No |
| 3 | Line budget for the rollback comparison | After message t (T = t + 1 messages), the budget is the length of the gist's rollback push list. The gist's steps t = 0..20,000 are the fixture's T = 1..20,001. This policy exists only for comparison; the live view uses byte hysteresis (rows 1 and 2). | Both agreed. Same views and merges at all 20,001 steps. | No |
| 4 | Ties between pairs | Greatest due score wins, where `due = (T − last) / 2^level`, compared exactly. On equal scores, the pair with the smaller final message id wins, which is the leftmost pair in the view. The oracle's further `(level, index)` tie-break can never apply, because two different adjacent pairs of a partition cannot end at the same message. | Equivalent formulations: the engine scans left to right with strict `>`, the oracle compares final ids. | No |
| 5 | Delimiter escaping and line breaks | See "Canonical text" below. | **Disagreed.** The oracle percent-encoded `%`, `|`, C0 controls and DEL, and turned CRLF into one space. The engine escaped nothing and turned CR and LF into one space each, so CRLF gave two spaces. Both sides changed. | **Reuben** |
| 6 | Message ceiling | At most 2^31 − 1 messages, so message ids run from 0 to 2^31 − 2. A node or zoom interval must end at or below 2^31 − 1, which means the highest node level is 30. | **Disagreed.** The engine accepted keys whose interval ended at 2^31, for example `(31, 0)` and `(0, 2^31 − 1)`. The engine was wrong and is fixed (`unii.valid-key?`). | No |
| 7 | What view bytes include | Only the rendered lines. The gist's `<chat>` and `</chat>` tags are prompt framing: prompt construction adds them, and the provider prompt budget counts them, but the hysteresis does not. | **Disagreed.** The engine counted 15 wrapper bytes. The engine changed. | **Reuben** (low stakes: 15 bytes of a 128,000-byte threshold) |
| 8 | When the policy runs | After every accepted event, because the engine's view can also grow when a late summary is committed. The oracle grows only on append and calls `hysteresis_resume` when a parent is published. | Equivalent on the oracle's domain. Side-by-side runs with stalled batches and parents published later agree at every step. | No |

## Canonical text (decision 5)

A view line is `first+count|` followed by the canonical text and LF. The
canonical text is the node's text, which the boundary has already checked
is valid UTF-8, with these replacements:

1. Each line break becomes one ASCII space. The line breaks are CRLF
   (counted once), lone CR, lone LF, NEL (U+0085), LS (U+2028) and PS
   (U+2029).
2. Every other C0 control (U+0000 to U+001F, tab included) and DEL
   becomes one ASCII space.
3. All other bytes are kept as they are, including `|`, `%`, `<chat>` and
   combining marks. Spaces are not merged.

The format stays unambiguous without escaping. A line's address is ASCII
digits, `+` and digits, and it ends at the first `|`. The line ends at the
only LF. A rendered line contains no control character other than its
final LF.

The 512-byte cap applies to the raw text, so it is unaffected by rendering.
View bytes are the sum of the rendered line lengths. The engine computes
each rendered line and its length in Shen, and `Core:render` checks the
total on every render.

**Why this and not percent-encoding.** The gist shows the model lines as
`id+n|text`, "with newlines turned into spaces", and its prompt mentions no
escapes. Markdown tables and percentages are common in tool output; with
escaping, the model would see `%7C` and `%25` with no explanation, and the
view would grow by 2 bytes for each such character.

**Open for Reuben:** whether `|` and `%` should be escaped anyway, and
whether tabs should survive. Either change is one function on each side,
`unii.canonical-text` and `oracle.canonical_text`, plus a regenerated
`byte-hysteresis.trace`.

## Other open questions for Reuben (not oracle disagreements)

* **Retries and the shortest line.** The plan says the 512-byte cap is
  strict and to "accept the shortest valid result". The gist says to keep
  the shortest of up to 5 tries and that "a few bytes over is fine". The
  engine is strict and accepts the first result that fits.
* **Uncertain summaries.** Whether a summary whose outcome is uncertain may
  ever be retried automatically, given that summaries are read-only. As
  instructed, it is never retried automatically, and only an operator
  retry re-dispatches it (`commands.md`, "Effect states"). An uncertain
  leaf holds coverage back until someone acts, so a flaky network can stall
  the memory. That is the cost of this rule.

## Network integration decisions

These are implemented and pinned by tests. The ones marked **Reuben** are
policy choices that the instruction did not settle.

| # | Question | Decision | Reuben? |
|---|---|---|---|
| N1 | How a restart tells "maybe sent" from "never sent" | The supervisor journals a `dispatch` record before the provider starts a command. With the record and no outcome, the command becomes `uncertain`. Without the record, it is dispatched normally. | No |
| N2 | Cancelled after send | Classified `uncertain`, like a drop | No |
| N3 | 2xx stream that ends without `[DONE]` | `retryable`. The response was complete at the HTTP level, so the request is known to have been received and answered. | **Reuben** (low stakes) |
| N4 | What an operator retry grants | One attempt past `max_attempts`. A retryable failure after it blocks the job instead of retrying. | **Reuben** |
| N5 | TLS failure | `permanent`. A certificate problem does not fix itself, so it blocks the job for an operator instead of spending attempts. | No |
| N6 | Inflight cap refusal from the client | Held in the provider and not charged as an attempt. The adapter caps at 9 (8 summaries + 1 turn); the core's default `max_inflight` is 8. | No |
