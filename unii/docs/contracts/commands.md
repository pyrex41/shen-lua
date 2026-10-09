# Commands, client events and decisions (format 1)

A transition returns:

* **Commands**: effects requested from the host. The core never performs an
  effect itself.
* **Decisions**: a record of what the core decided. Replay must reproduce
  every decision exactly.

Both are journaled with the event before any command is dispatched.

## Identifiers

| Identifier | Form | Allocation |
|---|---|---|
| message id | nat, 0, 1, 2, … | `message-appended.id`, gap-free |
| journal seq | nat, 1, 2, … | storage frames, independent of message ids |
| command id | `c<N>` | monotonic counter in core state |
| job id | `j<Epoch>-<Level>-<Index>-a<Attempt>-<Token>` | derived from the inputs |
| view revision | nat | incremented when coverage or the number of view lines changes |

The job token for a leaf is the first 16 hex digits of the message's
SHA-256. For a merge, it is `d` followed by `unii.digest32` (a 32-bit
djb2-style digest, computed in Shen) of the joined child texts. Identical
inputs give identical job ids, and a retry changes only the attempt.

## Commands

### submit-summary

```
[submit-summary CmdId JobId [key Level Index] [attempt N Retry] Input]
Retry = [first-attempt] | [retry-too-long Bytes] | [retry-after-failure Class]
Input = [leaf-input MessageId Kind Sha256]
      | [merge-input [key L 2I] LeftText [key L 2I+1] RightText]
```

The host loads the source and starts the request. For a leaf, the source is
the stored message text with the matching SHA-256. For a merge, the input
contains the exact texts of the two children. Neither input contains any
message after the node's interval.

The supervisor reports the result as a `summary-completed` or
`summary-failed` event. Summaries are read-only, so after a restart any
command without a journaled outcome is dispatched again. A duplicate
request costs spend but cannot publish twice, because a stale completion is
ignored.

Dispatch order:

1. Leaf jobs come first, ordered by message id. After them come merge jobs,
   ordered by first message and then by level.
2. A leaf job may be dispatched only while fewer than `lead_window` (8)
   unresolved leaf jobs come before it.
3. At most `max_inflight` (8) jobs are dispatched at the same time.
4. A merge job exists only after both of its children are built. Waiting
   jobs take queue slots, not network slots.

### emit-client-event

```
[emit-client-event CmdId Event]
Event = [view-changed Rev Bytes Lines]
      | [memory-blocked JobId Reason]
      | [input-rejected Reason]
```

During live operation, the supervisor passes client events to
`on_client_event`. They are not re-emitted during replay.

## Decisions

| Decision | Meaning |
|---|---|
| `[node-committed Key Origin Bytes]` | `Origin` is `[exact-leaf]`, `[joined]` (left LF right, which fits the cap) or `[summarized Job Attempt]` |
| `[view-extended Key]` | a committed leaf was appended to the view |
| `[view-merged ParentKey]` | two adjacent sibling lines were replaced by their parent |
| `[batch-mode Bool]` | emitted only when the batch state changes |
| `[view-revision Rev]` | the view revision was incremented |
| `[job-created Job]`, `[job-retried New Previous]`, `[job-blocked Job Reason]` | job lifecycle |
| `[event-rejected Reason]`, `[completion-ignored Job Reason]` | input that was refused or ignored |

Commands that the plan defines but this build does not implement:
`cancel-request`, `fetch-node`, `execute-tool` and `schedule-timer`. Retries
are queued immediately. Backoff is a host timer policy that does not exist
yet.
