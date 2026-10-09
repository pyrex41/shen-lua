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
| view revision | nat | incremented whenever the view changes: a line added, merged or replaced in place |

The job token for a leaf is the first 16 hex digits of the message's
SHA-256. For a merge, it is `d` followed by `unii.digest32` (a 32-bit
djb2-style digest, computed in Shen) of the joined child texts. Identical
inputs give identical job ids, and a retry changes only the attempt.

## Commands

### submit-summary

```
[submit-summary CmdId JobId [key Level Index] [attempt N Retry] Input]
Retry = [first-attempt] | [retry-too-long Bytes] | [retry-after-failure Class]
      | [retry-seek-shorter BestBytes] | [retry-by-operator]
Input = [leaf-input MessageId Kind Sha256]
      | [merge-input [key L 2I] LeftText [key L 2I+1] RightText]
```

The host loads the source and starts the request. For a leaf, the source is
the stored message text with the matching SHA-256. For a merge, the input
contains the exact texts of the two children. Neither input contains any
message after the node's interval.

The supervisor reports the result as a `summary-completed`,
`summary-failed` or `summary-uncertain` event. A stale or duplicate completion is ignored, so a
summary can never publish twice. See "Effect states" for what happens to a
request that may have reached the provider without a definite answer.

### Rounds of tries

A job runs in rounds (decisions R1 and R4). Its first round is tries 1 to
`max_attempts` (5). Every try in the round runs, and the core keeps the
shortest result that fits `leaf_cap` as the job's candidate. A later try
replaces it only when strictly shorter, so ties go to the earliest try. A
result over the cap is never accepted. The next try's `Retry` hint
describes the try before it:

* `[retry-seek-shorter BestBytes]` after a result that fit, with the length
  of the best candidate so far;
* `[retry-too-long Bytes]` after an over-cap result;
* `[retry-after-failure retryable]` after a retryable failure.

The round ends after its last try, or early on a permanent failure. The
candidate is then committed with origin `[summarized JobId Attempt]`, where
JobId and Attempt are those of the winning try. With no candidate, the job
blocks with the reason `no summary within the leaf cap in a round of tries`
(or `permanent summary failure`).

### Effect states

A summary job is in one of four states (`unii.job-status`):

| State | Meaning | Leaves it by |
|---|---|---|
| `[queued Retry]` | waiting for a slot | dispatch |
| `[dispatched CmdId]` | a `submit-summary` command is out | `summary-completed` or `summary-failed` |
| `[blocked Reason]` | a round ended with no result within the cap | `operator-retry` |
| `[uncertain CmdId]` | the request may have reached the provider and no definite outcome came back | `operator-retry` |

The host reports `summary-uncertain` when:

* the network adapter's outcome is `uncertain` (the request was sent, then
  the connection dropped or the transfer timed out);
* a 2xx stream ended without `[DONE]` (decision R5);
* a request was cancelled after it was sent;
* a previous process journaled the command's dispatch record and stopped
  before journaling an outcome (`storage.md`, "Dispatch records").

The core then marks the job `[uncertain CmdId]`, records
`[job-uncertain Job CmdId]`, and emits `[effect-uncertain Job CmdId]`. The
job is never dispatched again automatically, by the core, the supervisor or
the adapter. Late outcomes for its command are ignored
(`completion-ignored`).

An uncertain job does not stall the memory (decision R2):

* **Leaf job.** The core commits a provisional node with origin
  `[provisional JobId]`. Its text is the round's best candidate if there is
  one, otherwise the leaf's raw message (`kind: text`, which may be longer
  than `leaf_cap`). The provisional node covers the leaf, so the view,
  coverage and readiness move on. It is never joined, merged or used as a
  merge child. When the real summary is committed later, it replaces the
  provisional node: in place if it is in the view (`view-replaced`, a new
  revision), and then the parent is built as usual. If the job blocks
  instead, the provisional node stays.
* **Merge job.** No node is added. Its two children stay in the view, and
  the policy merges other pairs around them, because it only merges a pair
  whose parent is available.

`[operator-retry Job]` moves a blocked or uncertain job back to `queued`
with one fresh round: tries A + 1 to A + `max_attempts`, the first hinted
`[retry-by-operator]`. A candidate from earlier rounds carries over. If the
round ends with no candidate, the job blocks again. The CLI exposes it as
`unii retry --dir D --job J`, and `unii status` lists stuck jobs with their
reason or command id, and counts provisional lines.

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
      | [effect-uncertain JobId CmdId]
```

During live operation, the supervisor passes client events to
`on_client_event`. They are not re-emitted during replay.

## Decisions

| Decision | Meaning |
|---|---|
| `[node-committed Key Origin Bytes]` | `Origin` is `[exact-leaf]`, `[joined]` (left LF right, which fits the cap), `[summarized Job Attempt]` or `[provisional Job]` |
| `[view-replaced Key]` | a line in the view was replaced in place by the real node for the same key |
| `[candidate-kept Job Attempt Bytes]` | this try's result fits the cap and is now the job's shortest candidate |
| `[view-extended Key]` | a committed leaf was appended to the view |
| `[view-merged ParentKey]` | two adjacent sibling lines were replaced by their parent |
| `[batch-mode Bool]` | emitted only when the batch state changes |
| `[view-revision Rev]` | the view revision was incremented |
| `[job-created Job]`, `[job-retried New Previous]`, `[job-blocked Job Reason]`, `[job-uncertain Job CmdId]` | job lifecycle |
| `[event-rejected Reason]`, `[completion-ignored Job Reason]` | input that was refused or ignored |

Commands that the plan defines but this build does not implement:
`cancel-request`, `fetch-node`, `execute-tool` and `schedule-timer`. Retries
are queued immediately. Backoff is a host timer policy that does not exist
yet.
