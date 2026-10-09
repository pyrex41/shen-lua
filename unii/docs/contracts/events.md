# Event contract (format 1)

Events are the only inputs to the pure core:

```
unii.transition : unii.state --> unii.event --> unii.result
result = [result State Commands Decisions]
```

The host builds events as Lua records (`{_ = "name", field = ...}`), checks
them against `host/schema.lua`, encodes them as tagged values
(`host/codec.lua`) and converts them to Shen lists headed by the
constructor symbol. Field order below is the positional order in Shen. The
Shen types are in `core/types.shen`; the two files must agree.

Phase 1 implements four events. The plan's other events (turns, tools,
timers, recovery, epoch changes) are not implemented.

## message-appended

```
[message-appended Id Kind Date [content Bytes Sha256 Text]]
```

| Field | Type | Rule |
|---|---|---|
| `id` | nat | must equal the current message count (zero-based, gap-free) and stay below 2^31 − 1 |
| `kind` | symbol | one of `user assistant tool-call tool-result report imported-note` |
| `date` | text | non-empty; the host supplies it (UTC text, for example `2026-10-09T00:00:37Z`). The core never reads a clock and never orders by date |
| `content.bytes` | nat | UTF-8 byte length of `text`, at most `chunk_max` (16,384 by default) |
| `content.sha256` | hex64 | SHA-256 of `text`, 64 lowercase hex digits |
| `content.text` | text | valid UTF-8 |

The boundary (`schema.encode`) refuses an event whose `bytes` differs from
`#text` or whose `sha256` does not match `text`. The core cannot hash, so it
trusts the declared length once the boundary has checked it.

The leaf text is `kind ": " text`. If its byte count is at most `leaf_cap`
(512 by default), the leaf is committed exactly, with no model call.
Otherwise the core creates a leaf summary job. While `max_frontier` (4,096)
leaf jobs are unresolved, any message that would need a job is rejected
with the reason `unresolved message backlog is full`.

Messages that would be larger than `chunk_max` must be split by the host
before they reach the core. The splitter is not built yet.

## summary-completed

```
[summary-completed JobId Attempt Bytes Sha256 Text]
```

This event carries the output of a summary attempt. The boundary binds
`bytes` and `sha256` to `text` in the same way as for messages.

The core handles it as follows:

* An unknown job, a job that is not dispatched, or an attempt that does not
  match produces a `completion-ignored` decision and nothing else. This
  covers duplicate, stale and replayed deliveries.
* `bytes` must be a positive natural and `sha256` must be hex64. Otherwise
  the event is rejected.
* If `bytes <= leaf_cap` and the result is strictly shorter than the
  job's current candidate (or there is none), it becomes the candidate
  (`candidate-kept`).
* A result with `bytes > leaf_cap` is never accepted. The core never
  truncates a summary.
* If the round has more tries, the next one is queued with its hint
  (`commands.md`, "Rounds of tries"). After the last try, the candidate is
  committed with origin `[summarized JobId Attempt]` of the winning try and
  the parent is built if its sibling is already built. With no candidate,
  the job is blocked and a `memory-blocked` client event is emitted.

## summary-failed

```
[summary-failed JobId Attempt Class]
```

`class` is `retryable` or `permanent`. The same ignore rules apply as for
completions. A `retryable` failure moves on to the next try of the round,
hinted `[retry-after-failure retryable]`. A
`permanent` failure ends the round at once: the candidate is committed if
there is one, otherwise the job blocks. `host/models.lua` maps adapter
results to these classes (`network.md`). An uncertain outcome is not a
failure class; it has its own event.

## summary-uncertain

```
[summary-uncertain JobId Attempt Raw]
Raw = [] | [[content Bytes Sha256 Text]]
```

The host sends this when it cannot know whether the provider received the
request (`commands.md`, "Effect states"). The same ignore rules apply as
for completions. For a leaf job, `Raw` must be exactly the leaf's message,
matched by bytes and SHA-256 and at most `chunk_max` bytes; for a merge job
it must be empty. Otherwise the event is rejected with
`raw content does not match the job's source`. The job is parked as
`[uncertain CmdId]`, a leaf gets a provisional line, and the job is never
retried automatically.

## operator-retry

```
[operator-retry JobId]
```

An operator grants one fresh round of `max_attempts` tries to a job that
is blocked or uncertain (decision R4). The job is requeued as attempt + 1
with `[retry-by-operator]`, and its round ends at attempt + `max_attempts`.
If that round ends with no result within the cap, the job blocks again. The
event is rejected when the job is unknown or already completed, when it is
neither blocked nor uncertain, and when the new round would pass attempt
2^31 − 1.

## Rejection

When an event fails validation, the result is the unchanged state, one
`event-rejected` decision with its reason, and an `input-rejected` client
event. Rejected events are still journaled, so replay reproduces the
rejection.

## After every accepted event (settle)

1. **Extend.** Committed leaves that directly follow the covered prefix are
   appended to the view (`view-extended`).
2. **Byte policy.** See `numeric.md`. This step can produce `view-merged`
   and `batch-mode` decisions.
3. **Dispatch.** Queued jobs are started in priority order, subject to the
   inflight cap and the lead window (`commands.md`).
4. **Revision.** If coverage or the number of view lines changed, the view
   revision is incremented (`view-revision`) and a `view-changed` client
   event is emitted.

A turn may start only when `covered == count` (`unii.view-ready?`).
Unresolved messages stay outside the view and are never shown in place of
a summary.
