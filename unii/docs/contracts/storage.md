# Storage (storage_format 1)

A chat is stored in one directory, which one process owns at a time. Phase 1
has one storage adapter: a framed append journal (`host/storage.lua`) with
POSIX helpers in `host/posix.lua`, which use the LuaJIT FFI.

## Interface

```
local store, info = storage.open(dir)   -- take the lock, parse, isolate any crash tail
store:records()  -> { {seq = n, payload = bytes}, ... }   committed, in order
store:append(bytes) -> seq              -- write all bytes, then fsync, before returning
store:close()                           -- release the lock
```

Another backend (with blobs, checkpoints or shards) can replace this one
without changing the supervisor, as long as it keeps the same contract:
records come back in the order they were appended, `append` is durable
when it returns, and the store has a single owner.

## Directory layout

| File | Purpose |
|---|---|
| `LOCK` | holds the `flock(LOCK_EX \| LOCK_NB)` lock, open for the lifetime of the store. A second owner, in this process or another, gets `chat <dir> is owned by another process` |
| `journal.uj` | the journal |
| `journal.tail-<offset>-<n>.bin` | uncommitted crash tail kept for diagnostics: the `n` bytes that followed committed data at `offset` |

## Frame

```
"UJ1 " <seq> " " <len> "\n" <payload: len bytes> "\n" <sha256 hex of header..payload> "\n"
```

* Sequence numbers start at 1 and must be contiguous.
* `len` may be at most 16 MiB.
* The checksum covers the header line and the payload.

## Recovery

When the journal is opened:

* **Complete frames:** read in order.
* **Incomplete final frame:** treated as an uncommitted crash tail. This
  covers a partial header shorter than 64 bytes and a frame that ends before
  its checksum line. The tail bytes are written to a `journal.tail-*` file
  with an atomic temp file, fsync and rename, and the journal is then
  truncated to the committed prefix and fsynced. Tail bytes are never
  turned into records. `test_storage.lua` cuts a journal at every byte
  offset to check this.
* **Damaged committed data:** an error `journal corrupt at byte N ...
  (repair required)`, and the file is left unchanged. This covers a bad
  header, a checksum mismatch, a missing separator or a sequence gap
  anywhere before the end. No history is discarded.

## Transaction payloads

Each payload is a codec map (see `codec.md`).

Record 1 is `init`:

| Field | Content |
|---|---|
| `kind` | `init` |
| `bundle` | SHA-256 of the typechecked rule bundle |
| `bundle_format`, `storage_format`, `codec_version` | format versions |
| `shen_lua` | pinned commit |
| `config` | the policy epoch configuration record |
| `state_hash` | hash of the initial state |

Records 2 and later are `event` transactions:

| Field | Content |
|---|---|
| `kind` | `event` |
| `event` | tagged event |
| `commands` | as returned by the core |
| `decisions` | as returned by the core |
| `view_rev`, `view_hash` | sha256 of the rendered view |
| `state_hash` | hash of the resulting state |

### Dispatch records

Immediately before a provider starts a `submit-summary` command, the
supervisor appends and fsyncs a host-level record:

| Field | Content |
|---|---|
| `kind` | `dispatch` |
| `cmd` | the command id |
| `job` | the job id |

It is not a core event and changes no state. It exists so a restarted
process can tell "never sent" from "maybe sent". Replay checks that the
record names an outstanding command (otherwise `replay divergence`). The
storage interface is unchanged: this is one more payload through `append`.

## Commit order (supervisor)

1. The boundary validates the event.
2. The pure transition runs.
3. The view is rendered and its bytes are checked against the core's
   accounting. The view and the state are hashed.
4. The transaction is appended, using a write-all loop followed by fsync.
5. Only after that does the supervisor adopt the new state and dispatch
   commands. If step 4 fails, the previous state is kept.

## Replay

When the store is opened:

* The supervisor refuses a journal written by a different rule bundle, an
  unsupported format version, or a configuration different from the one
  passed in. Changing the policy epoch needs an epoch event that does not
  exist yet.
* Every transaction is replayed through the same transition, and the
  commands, decisions, view hash and state hash must match exactly.
  Otherwise the open fails with `replay divergence at seq N: <what>`.
* The view is never re-fitted from the current policy. It comes only from
  replaying the recorded events.
* A summary command without a journaled outcome and without a dispatch
  record was never handed to a provider, and is dispatched normally.
* A summary command with a dispatch record and no outcome was in flight
  when the previous process stopped. It is never sent again automatically.
  The next `dispatch_pending` (or `pump`) journals `summary-failed` with
  class `uncertain` for each, in command order, and the job waits for an
  operator. Opening a chat alone writes nothing, so `view`, `hash` and
  `status` stay read-only.

## Durability and limits

* Durability depends on `fsync` of the journal and, when the journal is
  created, of the directory. On macOS, `fsync` does not flush the drive
  cache (`F_FULLFSYNC` is not used), so its guarantee is weaker. Only Linux
  x86_64 has been verified.
* The whole journal is read into memory on open, and replay starts from
  record 1. Checkpoints, indexes, blobs, day shards and backup/restore do
  not exist yet.
* Message text is stored only inside journal transactions, and the
  supervisor keeps a map from message id to text in RAM. The plan requires
  bounded memory and paging, which is still to do.
* Fault injection exists only for a failed append (`test_storage.lua`). It
  does not yet cover every write, sync and rename boundary.
