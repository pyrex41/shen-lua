# unii handoff: Phase 0 through Phase 2

unii is a provisional name. It is the memory engine for an endless
conversation agent, built from the plan in this repository's task, *Shen and
LuaJIT Conversation Agent Implementation Plan*, and from the UniiChat gist
pinned in `MANIFEST.md`.

The work is split between two languages:

* **Shen decides.** A typechecked, pure rule bundle covers tree addressing,
  exact leaves, lossless joins, summary jobs, view coverage, merge order,
  batch hysteresis and invariants.
* **Lua does the mechanics.** LuaJIT hosts the codec, journal, locking,
  supervisor, the network adapter, a chat-completions provider, mocks and
  the CLI.

This branch merges two parallel workstreams:

* **PR #74:** the independent oracle and golden fixtures, in `eval/`.
* **PR #75:** the libcurl HTTP adapter, in `host/network/`.

The engine's tests diff against the oracle on every run
(`contracts/decisions.md`).

The real adapter is wired behind `contracts/network.md`, but the MOCK
transport and MOCK summarizer stay the default for tests and the CLI. The
real adapter has been exercised only against its local test server. No real
model provider has been called.

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
* `unii view`, `unii hash`
* `unii status`: counts, stuck (blocked or uncertain) jobs, and commands
  orphaned by a previous process.
* `unii retry --job J`: operator retry of a blocked or uncertain job.
* `unii replay`: prints, for each transaction, the event, decisions, view
  revision and hashes, plus dispatch records.
* `--network real --url URL --model NAME` on any command that pumps
  summaries. This uses the libcurl adapter and an OpenAI-compatible
  endpoint. The key comes from `UNII_API_KEY` or `OPENAI_API_KEY` and is
  never journaled. The default is `--network mock`.

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
    posix.lua           FFI durability operations and fault boundaries
    storage_blobs.lua   content-addressed message/summary bodies
    storage_checkpoint.lua durable checkpoint framing and fallback
    storage_index.lua   rebuildable journal/message/blob/node/job indexes
    sha256.lua          pure-Lua SHA-256
    models.lua          provider interface, adapter-result classification
    network/            REAL libcurl adapter (PR #75; its README covers TLS, logging, limits)
    providers/chat_completions.lua  OpenAI-compatible summarizer over an injected client
    mock/network.lua    MOCK transport with the adapter's interface (docs/contracts/network.md)
    mock/summarizer.lua MOCK provider: chat_completions over the mock transport, fake summaries
    synthetic.lua       deterministic synthetic messages (multi-byte text included)
    cli.lua             milestone CLI
  test/                 run.lua (entrypoint), lib.lua, test_*.lua, fixtures/
    network/            the adapter's own suite and local test server (PR #75)
  docs/                 HANDOFF.md, MANIFEST.md, contracts/*.md
  eval/oracle/          independent Lua oracle (PR #74); eval/fixtures/ golden traces
```

The runtime and compiler outside `unii/` are untouched. `build.lua` and a
test both enforce this against the pinned commit.

## Contracts

| Document | Covers |
|---|---|
| `contracts/events.md` | `message-appended`, `summary-completed`, `summary-failed`, `operator-retry`, rejection, the settle order |
| `contracts/commands.md` | identifiers, `submit-summary`, effect states (including uncertain), client events, decisions, dispatch order |
| `contracts/numeric.md` | bounds, exact due-score comparison, line-count policy and byte-hysteresis policy |
| `contracts/codec.md` | tagged values, records, storage encoding, state hash |
| `contracts/storage.md` | journal frame, recovery, transaction payloads, dispatch records, commit order, replay |
| `contracts/network.md` | client interface shared by the real adapter and the mock, outcome classification, provider interface |
| `contracts/oracle.md` | the oracle's layout and how `test_oracle` diffs against it |
| `contracts/decisions.md` | engine/oracle reconciliation, network integration decisions, open questions for Reuben |

## Integration status

**HTTP adapter (`host/network/`, PR #75).** The adapter is merged and
unchanged, except that it now exports `IS_MOCK = false`.

* `host/providers/chat_completions.lua` drives it.
* `host/models.lua` maps its outcomes to failure classes.
* The adapter's `uncertain` outcome becomes the core's `[uncertain CmdId]`
  job state, which is never re-sent automatically (`commands.md`, "Effect
  states").
* The supervisor journals a dispatch record before each send, so a restart
  turns in-flight commands into `uncertain` instead of resending them.
* The mock transport implements the same interface over a simulated clock.

**Oracle (`eval/`, PR #74).** `test_oracle` diffs the engine against:

* the 20,001-step rollback trace;
* the byte-hysteresis trace;
* the oracle module, side by side.

Three disagreements were found and resolved; see `contracts/decisions.md`.
The oracle's canonical-text function and the byte-hysteresis fixture were
changed to the reconciled policy. The oracle remains a separate
implementation.

**Phase 2 storage.** Content-addressed blobs, daily shards, checkpoints,
indexes and streaming replay are integrated behind the unchanged
`host/storage.lua` interface. Checkpoints preserve outstanding commands and
their dispatch intents, so an in-flight command restored from a checkpoint
becomes uncertain and is not resent.

## Acceptance gates and how each was verified

Every row is an automated test in `luajit unii/test/run.lua`. The last run
passed 98 tests, with 0 failed and 0 skipped. `--with-upstream` adds the
pinned port specs (1,088 checks across 22 specs) and the kernel suite
(134 of 134).

Separately:

* `luajit unii/test/network/run.lua` (the adapter suite) passes 18 and
  skips 1, its real-provider smoke test, because no API key is set.
* `luajit unii/eval/oracle/spec.lua` passes 13 of 13.

### Phase 0

| Gate | Evidence |
|---|---|
| Boot the pinned runtime | `test_boundary`: the runtime outside `unii/` is byte-identical to `fc97577`; the runtime boots and reports Shen 42 / 0.11.1 |
| Typecheck a rules module at build time | `build.lua` loads all 7 core files under `(tc +)` with `SHEN_FASL=off` (about 3.2 s), and refuses `test/fixtures/ill_typed_rules.shen`. `test_boundary` checks that boot rejects a bundle whose hash does not match the stamp. |
| Call a typed transition from Lua | `test_boundary`: the signature is `(unii.state --> (unii.event --> unii.result))`, and a tagged event goes in while decoded commands and decisions come out |
| Round-trip every domain value | `test_codec`: 13 cases, including symbol, text, `()`, vector, boolean and absent all staying distinct, both through Shen and through the storage bytes |
| Reject rounded identifiers at the boundary | `test_boundary`: 2^53 + 1 is refused both as text and as a pre-rounded Lua number; values outside 2^31 − 1, negative values and non-canonical decimals are refused; the core rejects an out-of-sequence id even when the codec is bypassed |
| Stream and cancel an HTTP response | `test_network_mock`: SSE deltas arrive in order; cancel is idempotent and records whether the request was sent; drop, stall, pre-send failure and body cap match the adapter's outcomes. `test_network_real` and the adapter suite do the same over real sockets against a local server. |
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
| Merge order equals rollback push over 20,001 steps, with a defined line-count budget | `test_view`: with budget = length of the push list, equal at all 20,001 steps (the first-message due score matches only 481 of them). `test_oracle`: equal to the oracle's golden `rollback-20001.trace` at every row. |
| Byte-budget hysteresis, tested separately | `test_hysteresis`: an independent model is checked on every transition, at 1,500/3,000 and at the default 64,000/128,000 (the trace crosses 128,000 and comes back down to at most 64,000); batch mode stalls while parents are missing. `test_oracle`: equal to the oracle's `byte-hysteresis.trace` at all 700 steps, and to the oracle module on 40 random configurations. |
| Job dependencies, retries, deterministic ids | `test_transition`: lead window and inflight cap; parents only after both children; retry on over-cap output up to 5 attempts, then blocked with `memory-blocked`; permanent failure blocks; uncertain parks the job until an operator retry; duplicate, stale and unknown completions publish nothing |
| Canonical LF rendering with byte accounting | `test_tree` and `test_oracle` (3,000 random lines equal the oracle's rendering; line bytes equal rendered bytes); `Core:render` checks rendered bytes against the core's count on every render |

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

### Phase 2

`test_storage_phase2` proves that journals hold blob hashes rather than
message/summary bodies, sequence order crosses daily shards, indexes rebuild,
valid checkpoints skip earlier records with identical state/view hashes,
stale checkpoints fall back, bad blobs refuse without journal mutation, and
recovery does not read whole journal files into RAM.

`test_storage_faults` injects process death at every observed write, sync and
rename boundary, and separately covers commit ordering, torn writes and
ENOSPC. See `docs/STORAGE_PHASE2.md` for the outcome matrix.

## Decisions worth knowing

* **Leaf cap.** The 512-byte cap applies to `kind ": " text`. A user
  message of 506 bytes is stored exactly; one of 507 bytes needs a summary.
  Address, `|` and LF bytes count toward the view budget, not toward the
  cap.
* **Rendering.** The view is lines of the form `first+count|text` LF.
  View bytes count only these lines; the `<chat>` wrapper is prompt
  framing. In text:
  * every line break (CRLF counted once, CR, LF, NEL, LS, PS) becomes one
    space;
  * every other C0 control and DEL becomes one space;
  * nothing is escaped.

  This is reconciled with the oracle (`contracts/decisions.md`, items 5
  and 7) and still open for Reuben.
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
* **Uncertain effects.** A request that may have reached the provider is
  never re-sent automatically. Only `operator-retry` requeues it, and each
  operator retry grants one attempt past `max_attempts`.
* **Merge input.** A merge job receives the two children's exact texts. A
  leaf job receives the message. The plan's "bounded preceding context" is
  not supplied yet, so a job can never see a later message.
* **No custom typechecker or VM.** The bundle is ordinary Shen loaded by
  the pinned kernel under `(tc +)`.

## Upstream issue (shen-lua at `fc97577`)

Under the native Prolog engine, a file that defines a double-line datatype
rule with six or more premises over other user datatypes fails at load
with `shen.consume<N> is undefined`. Five premises work.

Reproducer: `unii/test/fixtures/upstream/{six,five}_premises.shen`. Run it
with `luajit unii/test/fixtures/upstream/probe.lua <file> <expr>`.
`test_boundary` asserts the current behavior, and it fails with a clear
message once upstream fixes the bug, so the workaround can then be removed.

Workaround: no rule in `core/types.shen` has more than five premises.
Config is split into `view-budget` and `queue-limits`, state is split into
`tree` and `counters`, and code uses the accessor functions. This has not
been reported upstream from this branch.

## Not done, and known limits

* **Real integrations.** The libcurl adapter is real and wired in, but it
  has been run only against its local test server. No real model provider
  has been called. The summarization prompt is provisional
  (`PROMPT_VERSION = "provisional-0"`). The mock network and mock
  summarizer are labeled as mocks in code, CLI output and docs.
* **Unimplemented plan items:**
  * turns, prompts, zoom and date tools, `core/prompts.shen`,
    `core/tools.shen`, and tool execution;
  * `RecoveryObserved`, timers and backoff, and raw-context recovery mode;
  * policy epoch change;
  * message chunking (events longer than `chunk_max` are rejected);
  * compaction context and a search fallback.
* **Storage limits.** Backup/restore and blob garbage collection do not
  exist. Index metadata is proportional to history. Linux x86_64 is tested;
  macOS uses `F_FULLFSYNC` for regular files but is not exercised in CI.
* **Complexity.** View, live-node and job collections are Shen lists, so
  each transition is O(view + live + jobs). That is a few hundred lines at
  the default thresholds. The one-million-message gate in Phase 7 has not
  been attempted, and nothing has been measured beyond the test runtimes:
  2,400 trace events in about 3.4 s, and about 3.2 s for the cold
  typechecked build.
* **Independence of checks.** `test_view`, `test_hysteresis` and the
  due-ordering check use reference models written alongside the engine.
  `test_oracle` is the independent cross-check.

## Suggested next steps

1. Run the chat-completions provider against a real endpoint with a key,
   and replace the provisional prompt with the plan's (Phase 3).
2. Add timers as host events (`TimerObserved`) for retry backoff.
3. Add message chunking on UTF-8 boundaries, upstream of `message-appended`.
4. Turns and prompts (Phase 4) on top of `unii.view-ready?` and the
   rendered view.
