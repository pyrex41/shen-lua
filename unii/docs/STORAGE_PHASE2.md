# Phase 2 storage and recovery

The journal remains the sole authority. Blobs hold message and accepted
summary text; checkpoints and indexes can always be discarded and rebuilt.

## Fault outcomes

| Fault | Defined outcome | Automated evidence |
|---|---|---|
| Crash before/during blob write, sync or rename | No journal record; any temp/orphan is ignored | `test_storage_faults` boundary sweep |
| Crash after blob durability, before journal completion | Blob may be orphaned; incomplete journal bytes are set aside; no record is fabricated | boundary sweep and torn-write case |
| Crash after a complete frame write, before/after sync | On the test filesystem the checksum-valid frame recovers; callers must still treat a failed append as unacknowledged | boundary sweep |
| Incomplete final frame at every byte | Preserve `journal.tail-*`, truncate to the committed prefix, continue | `test_storage` exhaustive cut test |
| Bad header/checksum/separator/sequence in committed data | Refuse with `repair required`; do not rewrite the shard | `test_storage` corruption cases |
| Missing or corrupted committed blob | Refuse; journal remains byte-identical | `test_storage_phase2` |
| Corrupt or stale checkpoint | Rename `.invalid-*`, try an older valid checkpoint, otherwise replay from record one | `test_storage_phase2` |
| Stale/corrupt/missing index | Rebuild from validated journal and blobs | indexes are replaced on open |
| ENOSPC before blob commit | Refuse append; no journal or supervisor state mutation | `test_storage_faults` and `test_storage` |
| ENOSPC/torn journal append | Refuse append; isolate partial final frame on restart | `test_storage_faults` |
| Second owner | Refuse nonblocking OS `flock`; no PID-file inference | `test_storage` same- and cross-process cases |

The boundary sweeps discover every write, file/directory sync and rename
callback exercised by blob, shard-manifest, journal, index and checkpoint
commits, then repeat the operation with a simulated process death at each
callback. Journal recovery must produce either zero records or the one
complete transaction, never a partial or invented transaction; checkpoint
recovery must preserve the journal-derived state.

## Checkpoint proof

A checkpoint binds:

* physical journal sequence and physical-payload hash;
* rule bundle and complete policy configuration;
* canonical serialized Shen state and state hash;
* exact rendered view hash and revision;
* pending summary commands.

Recovery validates all fields, restores the state, and starts transition
replay at `checkpoint.seq + 1`. Tests compare final state and view bytes/hashes
with uninterrupted execution and assert the number of replayed records.

## Remaining limits

* Blob garbage collection and backup/restore are not implemented.
* Indexes are periodically/close-time replaced rather than incrementally
  paged; their in-memory metadata is proportional to record/message count.
* Checkpoint files retain the newest four manifest entries; invalid and
  orphaned diagnostic files require operator cleanup.
* Linux x86_64 is tested. macOS uses `F_FULLFSYNC` for regular files, but
  filesystem/device durability still needs platform testing.
