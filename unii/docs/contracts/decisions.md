# Reconciled decisions: engine and oracle

The Shen engine (`unii/core/`) and the independent oracle
(`unii/eval/oracle/`, plain Lua) were written separately from the same plan
and gist. `unii/test/test_oracle.lua` diffs them on every run against:

* the oracle's golden traces (`unii/eval/fixtures/`);
* the oracle module run side by side on random configurations.

This page records each place where the sources were ambiguous, which
interpretation both sides now implement, and whether Reuben still needs to
confirm it. Items that were open for Reuben have now been decided by him;
his decisions are recorded under "Reuben's decisions" below and are
implemented and tested.

| # | Question | Decision | Before reconciliation | Reuben? |
|---|---|---|---|---|
| 1 | KB or KiB | 1 KB = 1,000 bytes. Thresholds are exactly 64,000 (low) and 128,000 (high) UTF-8 bytes. | Both sides already agreed. | No. The plan states the numbers. |
| 2 | Threshold equality | Batch mode is entered only when view bytes > high. It ends as soon as view bytes ≤ low. | Both agreed. | No |
| 3 | Line budget for the rollback comparison | After message t (T = t + 1 messages), the budget is the length of the gist's rollback push list. The gist's steps t = 0..20,000 are the fixture's T = 1..20,001. This policy exists only for comparison; the live view uses byte hysteresis (rows 1 and 2). | Both agreed. Same views and merges at all 20,001 steps. | No |
| 4 | Ties between pairs | Greatest due score wins, where `due = (T − last) / 2^level`, compared exactly. On equal scores, the pair with the smaller final message id wins, which is the leftmost pair in the view. The oracle's further `(level, index)` tie-break can never apply, because two different adjacent pairs of a partition cannot end at the same message. | Equivalent formulations: the engine scans left to right with strict `>`, the oracle compares final ids. | No |
| 5 | Delimiter escaping and line breaks | See "Canonical text" below. | **Disagreed.** The oracle percent-encoded `%`, `\|`, C0 controls and DEL, and turned CRLF into one space. The engine escaped nothing and turned CR and LF into one space each, so CRLF gave two spaces. Both sides changed. | Decided by Reuben (R3): no escaping. |
| 6 | Message ceiling | At most 2^31 − 1 messages, so message ids run from 0 to 2^31 − 2. A node or zoom interval must end at or below 2^31 − 1, which means the highest node level is 30. | **Disagreed.** The engine accepted keys whose interval ended at 2^31, for example `(31, 0)` and `(0, 2^31 − 1)`. The engine was wrong and is fixed (`unii.valid-key?`). | No |
| 7 | What view bytes include | Only the rendered lines. The gist's `<chat>` and `</chat>` tags are prompt framing: prompt construction adds them, and the provider prompt budget counts them, but the hysteresis does not. | **Disagreed.** The engine counted 15 wrapper bytes. The engine changed. | Decided by Reuben (R6): wrapper bytes stay excluded. |
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

Reuben confirmed this (R3): `|` and `%` are not escaped, and a tab
becomes one space like every other control character.

## Reuben's decisions

These settle the questions this page used to leave open. Each one is
implemented on the engine side and, where the oracle models it, on the
oracle side too; `unii/test/test_oracle.lua` checks that the two agree.

| # | Decision | Where it is implemented | Pinned by |
|---|---|---|---|
| R1 | Summaries keep the strict 512-byte cap, but every job runs a round of up to 5 tries (`max_attempts`) and keeps the shortest result that fits. A result over the cap is never accepted. Ties go to the earliest try. | `unii.better-candidate`, `unii.completed-job`, `unii.end-round` (core); `oracle.summary_rounds` | `test_transition` (shortest of 5 with a tie), `test_traces`, `test_oracle` (2,000 random outcome sequences) |
| R2 | Uncertain jobs do not stall memory. The uncertain leaf shows a provisional line: its last good summary (the best candidate of the round so far) if there is one, otherwise its raw message. Merge scheduling proceeds around it. The job still waits for an operator retry and is never sent again automatically. | `unii.mark-uncertain`, `unii.provisional-node` (core); `summary-uncertain` from the supervisor | `test_transition`, `test_network_mock`, `test_oracle` |
| R3 | No escaping of `\|` or `%`. A tab becomes one space, like other control characters. | `unii.canonical-text`, `oracle.canonical_text` (unchanged since decision 5) | `test_oracle` (3,000 hostile texts), `byte-hysteresis.trace` |
| R4 | An operator retry grants one fresh round of 5 tries. If the round ends with no result that fits, the job blocks again. | `unii.fresh-round`, `unii.operator-retry-job` | `test_transition`, `test_network_mock`, `test_oracle` |
| R5 | A stream that ends without `[DONE]` is classified uncertain, not retryable. This replaces N3. | `models.classify` | `test_network_mock` |
| R6 | The `<chat>` wrapper bytes stay excluded from the view budget (decision 7). | `unii.apply-byte-policy` (unchanged) | `test_oracle`, `test_hysteresis` |

### How the rounds work (R1, R4)

* A job's first round is tries 1 to `max_attempts`. An operator retry of a
  job at try A grants tries A + 1 to A + `max_attempts`.
* Every try in the round runs, even after a result fits, because a later
  try may be shorter. The next try's hint describes the previous try:
  `retry-seek-shorter` with the best length so far after a fit,
  `retry-too-long` with the over-cap length, or `retry-after-failure` with
  the failure class.
* A permanent failure ends the round early.
* At the end of the round, the best candidate is committed as the node,
  with its own try number as the origin. With no candidate, the job blocks.
* A best candidate carries over into an operator's fresh round, and a later
  try replaces it only if it is strictly shorter.

### Provisional lines (R2)

* An uncertain report for a leaf job carries the leaf's own message
  (`summary-uncertain` with `raw`). The core checks that it matches the
  job's source by length and hash.
* The provisional node is a level-0 node with origin `provisional`. It
  covers the leaf, so coverage, readiness and the view keep moving. It is
  never joined with a neighbour, merged or used as a merge child, so no
  parent is built on top of it until the real summary arrives.
* When the real summary is committed after an operator retry, it replaces
  the provisional line in place (`view-replaced`, a new view revision) and
  the parent is scheduled as usual.
* An uncertain merge job has no provisional node. Its children stay in the
  view, and other pairs merge around it, because the policy only merges a
  pair whose parent is available.

### Interpretations made while implementing (flag if wrong)

* **Cost.** Running every try means up to 5 provider calls per summary
  instead of usually 1.
* **Permanent failures** end the round early. If a result already fits, it
  is committed; otherwise the job blocks.
* **Uncertain wins over a candidate.** An uncertain try parks the job even
  when an earlier try in the round already fits. That candidate is shown
  provisionally and is committed only after an operator retry ends a round.
  Treating it as final would have let an uncertain outcome commit
  automatically.
* **A raw provisional line may exceed 512 bytes**, up to the message
  ceiling `chunk_max`. This is how "keeps rendering its raw leaves" reads;
  it counts towards the byte hysteresis like any other line.
* **The provisional line stays if the job later blocks**, so a failed
  operator round does not take coverage away again.

## Network integration decisions

These are implemented and pinned by tests. N3 and N4 were policy choices
that the instruction did not settle; Reuben has since decided both.

| # | Question | Decision | Reuben? |
|---|---|---|---|
| N1 | How a restart tells "maybe sent" from "never sent" | The supervisor journals a `dispatch` record before the provider starts a command. With the record and no outcome, the command becomes `uncertain`. Without the record, it is dispatched normally. | No |
| N2 | Cancelled after send | Classified `uncertain`, like a drop | No |
| N3 | 2xx stream that ends without `[DONE]` | `uncertain` (Reuben, R5). The summary may have been produced and cut off, so it is parked for an operator and never resent automatically. | Decided |
| N4 | What an operator retry grants | One fresh round of `max_attempts` tries (Reuben, R4). If none fits, the job blocks again. | Decided |
| N5 | TLS failure | `permanent`. A certificate problem does not fix itself, so it blocks the job for an operator instead of spending attempts. | No |
| N6 | Inflight cap refusal from the client | Held in the provider and not charged as an attempt. The adapter caps at 9 (8 summaries + 1 turn); the core's default `max_inflight` is 8. | No |
