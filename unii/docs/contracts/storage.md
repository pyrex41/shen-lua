# Storage (storage_format 2)

A chat is stored in one directory, which one process owns at a time. Existing
callers keep the same storage interface, while Phase 2 adds content-addressed
blobs, daily journal shards, checkpoints and rebuildable indexes. POSIX
durability operations remain isolated in `host/posix.lua`.

## Interface

```
local store, info = storage.open(dir)   -- take the lock, parse, isolate any crash tail
store:records()  -> { {seq = n, payload = bytes}, ... }   committed, in order
store:append(bytes) -> seq              -- write all bytes, then fsync, before returning
store:close()                           -- release the lock
```

`records()` remains compatible, but its payload fields are lazy: one framed
record is read and hydrated at a time. `iter_records(after_seq)` is the
streaming replay path. `append` does not return until blob, journal and
directory durability boundaries have succeeded.

## Directory layout

| File | Purpose |
|---|---|
| `LOCK` | holds the `flock(LOCK_EX \| LOCK_NB)` lock, open for the lifetime of the store. A second owner, in this process or another, gets `chat <dir> is owned by another process` |
| `journals/MANIFEST` | ordered `USM1` list of daily shards |
| `journals/YYYY-MM-DD.uj` | framed records; sequence numbers remain global across shards |
| `blobs/<sha256>` | immutable message and accepted-summary UTF-8 bytes |
| `checkpoints/checkpoint-<seq>-<digest>.uc` | exact serialized core state and recovery metadata |
| `checkpoints/MANIFEST` | newest four checkpoint candidates |
| `indexes/{journal,messages,blobs,nodes,jobs}.idx` | rebuildable projections, never authority |
| `journal.tail-<offset>-<n>.bin` | uncommitted crash tail kept for diagnostics: the `n` bytes that followed committed data at `offset` |

The init record uses the `0000-00-00` shard. A `message-appended` host event
selects its recorded UTC day; records without a date remain on the active
shard. Creating a shard syncs the empty file, journal directory and manifest
before a frame can be appended.

## Frame

```
"UJ1 " <seq> " " <len> "\n" <payload: len bytes> "\n" <sha256 hex of header..payload> "\n"
```

* Sequence numbers start at 1 and must be contiguous.
* `len` may be at most 16 MiB.
* The checksum covers the header line and the payload.

## Recovery

When the journal is opened:

* **Complete frames:** stream in manifest order. Only one bounded frame is
  resident. Global sequence continuity and every frame checksum are checked.
* **Blob references:** message and summary event text is absent from physical
  frames. The existing byte count and SHA-256 fields name the blob. Every
  committed reference is size- and hash-verified before replay. Missing or
  corrupted blobs refuse open with `repair required`; journal and blob bytes
  are not changed.
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
* **Checkpoints:** newest to oldest, verify framing, journal sequence and
  physical-record anchor, bundle/configuration, serialized state hash,
  rendered view hash/revision and pending commands. A bad or stale checkpoint
  is renamed `.invalid-*`; recovery tries an older one, then record one.

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

## Commit order (supervisor)

1. The boundary validates the event and the pure transition runs.
2. Each new message or summary blob is written to a temporary file, checked,
   file-synced, atomically renamed and its directory synced.
3. The view is rendered and its bytes are checked against the core's
   accounting. The view and the state are hashed.
4. The hash-only transaction is appended with a write-all loop, the shard is
   synced, then the journal directory is synced.
5. Only after that does the supervisor adopt the new state and dispatch
   commands. If step 4 fails, the previous state is kept.
6. Checkpoints and indexes are written by temp/write/sync/rename/directory
   sync. Their failure cannot undo or compete with an authoritative journal
   commit.

## Replay

When the store is opened:

* The supervisor refuses a journal written by a different rule bundle, an
  unsupported format version, or a configuration different from the one
  passed in. Changing the policy epoch needs an epoch event that does not
  exist yet.
* The latest valid checkpoint restores exact core state, view, pending
  commands and journal position. Only later transactions are replayed.
* Every replayed transaction runs through the same transition, and the
  commands, decisions, view hash and state hash must match exactly.
  Otherwise the open fails with `replay divergence at seq N: <what>`.
* The view is never re-fitted from the current policy. It comes only from
  replaying the recorded events.
* Summary commands without a journaled outcome are dispatched again.

## Durability and limits

* Linux uses `fsync`. macOS regular files use `fcntl(F_FULLFSYNC)` because
  macOS `fsync` may not flush volatile drive caches; directories still use
  `fsync`. Actual guarantees remain subject to filesystem, device firmware
  and mount settings. Linux x86_64 is the verified platform; macOS behavior
  is implemented but not exercised in CI.
* Recovery stores bounded frame metadata and rebuildable indexes in memory,
  not journal payloads. Core state still contains its bounded active view and
  queues. Message source text is loaded from blobs on demand.
* Checkpoints are taken every 32 records by default and explicitly on demand.
  At most four are named by the checkpoint manifest.
* `test_storage_faults.lua` injects process death at every observed write,
  sync and rename boundary, plus torn writes and ENOSPC. Complete durable
  frames recover; incomplete final frames are set aside; committed
  corruption/missing blobs refuse without rewriting authority.
* Backup/restore is not implemented.
