# unii handoff: Phase 0 and Phase 1

unii is a provisional name. It is the memory engine for an endless
conversation agent, built from the plan in this repository's task, *Shen and
LuaJIT Conversation Agent Implementation Plan*, and from the UniiChat gist
pinned in `MANIFEST.md`.

The work is split between two languages:

* **Shen decides.** A typechecked, pure rule bundle covers tree addressing,
  exact leaves, lossless joins, summary jobs, view coverage, merge order,
  batch hysteresis and invariants.
* **Lua does the mechanics.** LuaJIT hosts the codec, journal, locking,
  supervisor, a mock network, a mock summarizer and the CLI.

No model, provider or real network is involved anywhere in this branch.
Every summary is a deterministic fake produced by
`host/mock/summarizer.lua`.

## Quick start

```sh
nix develop ./unii                    # optional: pinned LuaJIT, git, curl, make
luajit unii/test/run.lua              # build (typecheck) + every test; one entrypoint
luajit unii/test/run.lua --only view  # one test file
luajit unii/test/run.lua --with-upstream   # also the pinned port specs and kernel suite
unii/bin/unii milestone --dir /tmp/chat    # the restart demonstration
```

Other CLI commands, all of which take `--dir D`:

* `unii init [--low --high --cap --lead --inflight --attempts]`
* `unii append --count N [--seed S] [--no-pump] [--quiet]`
* `unii view`, `unii hash`, `unii status`
* `unii replay`: prints, for each transaction, the event, decisions, view
  revision and hashes.

## Layout

```
unii/
  manifest.lua          pinned revisions, toolchain, license, bundle files, format versions
  build.lua             typechecked build: pin check, (tc +) load with fasl off, ill-typed fixture, stamp
  flake.nix, flake.lock dev shell pinned to the root flake's nixpkgs revision
  bin/unii              CLI launcher
  core/                 the pure Shen rules (no clock, files, network, randomness, eval or `/`)
    arith.shen          bounds, exact divmod by 2^L, digest32
    types.shen          datatypes, accessors, config validation
    tree.shen           keys, parent/child/sibling, zoom addresses, line rendering, joins
    view.shen           due score, merge selection, line-count policy, byte hysteresis, rendering
    jobs.shen           job ids, priority order, lead window, inflight cap, dispatch
    transition.shen     unii.init / unii.transition, settle, host projections
    invariants.shen     executable structural checks
  host/
    codec.lua           tagged values, Shen conversion, canonical storage bytes
    schema.lua          record shapes mirroring types.shen; boundary validation
    core.lua            boots shen-lua, checks the build stamp, calls the typed core
    supervisor.lua      single writer: validate, transition, journal and fsync, adopt; replay
    storage.lua         framed journal adapter (interface in docs/contracts/storage.md)
    posix.lua           FFI open/write-all/fsync/flock/ftruncate/rename/atomic write
    sha256.lua          pure-Lua SHA-256
    models.lua          provider interface, failure classification
    mock/network.lua    MOCK transport (contract in docs/contracts/network.md)
    mock/summarizer.lua MOCK provider: fake "[mock L/I aN] ..." summaries
    synthetic.lua       deterministic synthetic messages (multi-byte text included)
    cli.lua             milestone CLI
  test/                 run.lua (entrypoint), lib.lua, test_*.lua, fixtures/
  docs/                 HANDOFF.md, MANIFEST.md, contracts/*.md
  eval/                 empty here; eval/oracle/ belongs to the oracle workstream
```

The runtime and compiler outside `unii/` are untouched. `build.lua` and a
test both enforce this against the pinned commit.

## Contracts

| Document | Covers |
|---|---|
| `contracts/events.md` | `message-appended`, `summary-completed`, `summary-failed`, rejection, the settle order |
| `contracts/commands.md` | identifiers, `submit-summary`, client events, decisions, dispatch order |
| `contracts/numeric.md` | bounds, exact due-score comparison, line-count policy and byte-hysteresis policy |
| `contracts/codec.md` | tagged values, records, storage encoding, state hash |
| `contracts/storage.md` | journal frame, recovery, transaction payloads, commit order, replay |
| `contracts/network.md` | the interface the real HTTP adapter in `unii/host/network/` must implement |
| `contracts/oracle.md` | the fixture format for `unii/eval/oracle/` |

## Integration points for the parallel workstreams

**HTTP adapter (`unii/host/network/`).** Implement `contracts/network.md`.
The mock transport has the same shape, except that it counts deadlines in
steps rather than wall-clock time. A real summarizer provider would go in
`host/providers/` with `is_mock = false` and would be passed to
`supervisor.open(dir, {provider = ...})`. The CLI is hard-wired to the mock
provider and says so in its output.

**Oracle (`unii/eval/oracle/`).** Add `fixtures/manifest.lua` in the format
given in `contracts/oracle.md`. `test_view.lua` picks it up automatically
and stops reporting SKIP.

## Acceptance gates and how each was verified

Every row is an automated test in `luajit unii/test/run.lua`. The last full
run passed 72 tests, failed 0 and skipped 1. The skip is the oracle
fixtures, which do not exist yet. That count includes the upstream port
specs (1,088 checks across 22 specs) and the kernel suite (134 of 134).
The suite passes on both LuaJIT builds listed in `MANIFEST.md`.

### Phase 0

| Gate | Evidence |
|---|---|
| Boot the pinned runtime | `test_boundary`: the runtime outside `unii/` is byte-identical to `fc97577`; the runtime boots and reports Shen 42 / 0.11.1 |
| Typecheck a rules module at build time | `build.lua` loads all 7 core files under `(tc +)` with `SHEN_FASL=off` (about 3.2 s), and refuses `test/fixtures/ill_typed_rules.shen`. `test_boundary` checks that boot rejects a bundle whose hash does not match the stamp. |
| Call a typed transition from Lua | `test_boundary`: the signature is `(unii.state --> (unii.event --> unii.result))`, and a tagged event goes in while decoded commands and decisions come out |
| Round-trip every domain value | `test_codec`: 13 cases, including symbol, text, `()`, vector, boolean and absent all staying distinct, both through Shen and through the storage bytes |
| Reject rounded identifiers at the boundary | `test_boundary`: 2^53 + 1 is refused both as text and as a pre-rounded Lua number; values outside 2^31 − 1, negative values and non-canonical decimals are refused; the core rejects an out-of-sequence id even when the codec is bypassed |
| Stream and cancel a mock HTTP response | `test_network_mock`: chunks arrive in order; cancelling twice yields one `on_done`; deadline, transport error and overflow are covered; requests are classified |
| Record the gist revision and checksum | `manifest.lua`; `test_boundary` downloads the pinned revision and checks its bytes, sha256 and git blob id |
| Contracts written | `docs/contracts/*.md` |

### Phase 1

| Gate | Evidence |
|---|---|
| Generated traces keep coverage and alignment | `test_traces`: 6 seeds of 400 events each, with out-of-order and held completions. After every step, an independent Lua model checks that the view is an aligned, gap-free partition of `[0, covered)`. |
| Sibling merges are exact | `test_traces`: every line's text equals the committed node's text; joins equal `left LF right`; every `view-merged` replaces exactly its two children. `test_transition` covers the 512-byte boundary, where the join is lossless at exactly 512. |
| Score ties are deterministic and stable | `test_view` (equal due selects the oldest pair); `test_tree` (due ordering agrees with exact int64 cross-multiplication); `test_traces` (re-running a seed reproduces every state hash) |
| No unresolved content reaches a turn | `test_traces`: `covered` is always the first message without a built leaf. `test_transition`: a later leaf waits outside the view; a blocked leaf keeps `view-ready?` false. |
| Gist small rollback examples | `test_view`: the t = 0..9 push table and the worked T = 10 example |
| Merge order equals rollback push over 20,001 steps, with a defined line-count budget | `test_view`: with budget = length of the push list, equal at all 20,001 steps (the first-message due score matches only 481 of them) |
| Byte-budget hysteresis, tested separately | `test_hysteresis`: an independent model is checked on every transition, at 1,500/3,000 and at the default 64,000/128,000 (the trace crosses 128,000 and comes back down to at most 64,000); batch mode stalls while parents are missing |
| Job dependencies, retries, deterministic ids | `test_transition`: lead window and inflight cap; parents only after both children; retry on over-cap output up to 5 attempts, then blocked with `memory-blocked`; permanent failure blocks; duplicate, stale and unknown completions publish nothing |
| Canonical LF rendering with byte accounting | `test_tree` (line bytes equal rendered bytes; CR and LF collapse byte-for-byte); `Core:render` checks rendered bytes against the core's count on every render |

### Milestone

`unii milestone --dir D` runs seven separate OS processes:

1. `init`, with low 1,500 and high 3,000 so that merges happen early.
2. `append` 48 synthetic messages with mock summaries, printing the view as
   it changes.
3. `hash`, a fresh process that replays the journal.
4. `append` 8 more without running summaries, then exit with work
   outstanding.
5. `hash` again.
6. `append` 4 more, which resumes the outstanding summaries.
7. `view`.

After each restart, the view hash and state hash must equal the ones the
previous process printed. The command prints `MILESTONE PASS`, and
`test_milestone` asserts all six comparisons. `test_storage` covers the
same property at the API level, plus crash tails at every byte offset,
corruption refusal, lock contention across processes, tampered
transactions, foreign bundles and configuration changes.

## Decisions worth knowing

* **Leaf cap.** The 512-byte cap applies to `kind ": " text`. A user
  message of 506 bytes is stored exactly; one of 507 bytes needs a summary.
  Address, `|` and LF bytes count toward the view budget, not toward the
  cap.
* **Rendering.** The view is `<chat>` LF, then lines of the form
  `first+count|text` LF, then `</chat>` LF. CR and LF in text each become
  one space, so byte counts are unchanged. Nothing else is escaped: `|`
  and `<chat>` inside text cannot be confused with structure, because every
  line starts with the address and ends at the only LF.
* **Two policies.** The line-count policy (`merge-keys-to-count`) exists
  only for comparison with the gist and oracle. The live view uses byte
  hysteresis.
* **Batch mode can persist.** Batch mode stays on (and is recorded) when
  the view is above low but no adjacent pair has a built parent. For
  example, at the end of the milestone the view is 4 lines (`0+32`,
  `32+16`, `48+8`, `56+4`) and no two of them are siblings. This matches
  plan §7.
* **Retries.** Retries are requeued immediately with the reason in
  `attempt.retry`. The first summary that fits the cap is accepted. The
  plan's "accept the shortest valid result" and timer backoff are not
  implemented.
* **Merge input.** A merge job receives the two children's exact texts. A
  leaf job receives the message. The plan's "bounded preceding context" is
  not supplied yet, so a job can never see a later message.
* **No custom typechecker or VM.** The bundle is ordinary Shen loaded by
  the pinned kernel under `(tc +)`.

## Upstream issue (shen-lua at `fc97577`)

Under the native Prolog engine, a file that defines a double-line datatype
rule with six or more premises over other user datatypes fails at load
with `shen.consume<N> is undefined`. Five premises work. In this repository
the failure surfaced as a type error when such a record was used, which is
how it was first found.

Reproducer: `unii/test/fixtures/upstream/{six,five}_premises.shen`. Run it
with `luajit unii/test/fixtures/upstream/probe.lua <file> <expr>`.
`test_boundary` asserts the current behavior, and it fails with a clear
message once upstream fixes the bug, so the workaround can then be removed.

Workaround: no rule in `core/types.shen` has more than five premises.
Config is split into `view-budget` and `queue-limits`, state is split into
`tree` and `counters`, and code uses the accessor functions. This has not
been reported upstream from this branch.

## Not done, and known limits

* **Real integrations.** There is no real provider, HTTP or TLS. The mock
  network and mock summarizer are labeled as mocks in code, CLI output and
  docs.
* **Unimplemented plan items:** turns, prompts, zoom and date tools,
  `core/prompts.shen`, `core/tools.shen`, tool execution, uncertain
  effects, `RecoveryObserved`, timers and backoff, operator retry and
  raw-context recovery mode, policy epoch change, message chunking (events
  longer than `chunk_max` are rejected), compaction context, and a search
  fallback.
* **Storage.** One journal file holds everything. It is read entirely into
  RAM, replay starts from record 1, and message text is held in RAM. There
  are no blobs, checkpoints, indexes, day shards or backup/restore. Fault
  injection covers only a failed append. On macOS, `fsync` has weaker
  guarantees, and macOS has not been tested.
* **Complexity.** View, live-node and job collections are Shen lists, so
  each transition is O(view + live + jobs). That is a few hundred lines at
  the default thresholds. The one-million-message gate in Phase 7 has not
  been attempted, and nothing has been measured beyond the test runtimes:
  2,400 trace events in about 3.4 s, and about 3.2 s for the cold
  typechecked build.
* **Independence of checks.** The rollback comparison and the due-ordering
  check are reference models written in this repository. They are not the
  independent oracle, which is the separate workstream.

## Suggested next steps

1. Phase 2 storage: content-addressed blobs for message text, checkpoints
   (view, state, journal position) so replay does not start at record 1,
   rebuildable indexes, and fault injection around every write, fsync and
   rename.
2. Plug in the real network adapter and one real summarizer provider
   (Phase 3), keeping the same tests running against the mock.
3. Add timers as host events (`TimerObserved`) for retry backoff, and an
   operator retry for blocked jobs.
4. Add message chunking on UTF-8 boundaries, upstream of `message-appended`.
5. Turns and prompts (Phase 4) on top of `unii.view-ready?` and the
   rendered view.
