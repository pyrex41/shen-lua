# Network client contract (for `unii/host/network/`)

The real HTTP adapter (libcurl multi interface, TLS, streaming,
cancellation) is being built separately in `unii/host/network/`. This
branch does not contain it. This branch contains:

* a MOCK transport, `host/mock/network.lua`, which implements the contract
  below with a scripted in-process server and no sockets;
* a MOCK summarizer provider, `host/mock/summarizer.lua`, which streams
  fake summaries through the mock transport.

`test_network_mock.lua` pins the semantics. Nothing in this branch has
talked to a real endpoint.

## Module shape

`require("unii.host.network")` (that is, `unii/host/network/init.lua`)
should return:

```lua
M.IS_MOCK = false
M.new(opts) -> client
  opts.max_buffer_bytes   default per-request response bound (default 1 MiB)
  opts.ca_file / ca_path  TLS trust; verification on by default and never silently disabled
  opts.user_agent         optional

client:request(spec) -> handle
client:step(timeout_ms) -> number of callbacks fired   -- drive I/O (curl_multi_poll + perform)
client:pending()        -> number of unfinished requests
client:close()          -- cancels everything still running; later request() raises

handle:cancel()         -- idempotent
```

The request spec:

| Field | Meaning |
|---|---|
| `id` | string, the core's command id (`c<N>`). A second active request with the same id raises `duplicate active request id`. |
| `method`, `url`, `headers` (array of `"Name: value"`), `body` | the request |
| `deadline_ms` | wall-clock deadline for the whole request. The mock uses `deadline_steps` instead and counts `step()` calls. |
| `max_response_bytes` | response bound for this request; overrides `opts.max_buffer_bytes` |
| `on_headers(http_status, headers)` | at most once, before any chunk |
| `on_chunk(bytes)` | body bytes in arrival order; never after `on_done` |
| `on_done(result)` | exactly once per request |

`result` has these fields:

* `status`: one of `"ok"`, `"cancelled"`, `"timeout"`, `"error"` (transport
  or TLS failure) or `"overflow"` (the next chunk would exceed the bound;
  that chunk is not delivered).
* `http_status`: when `status` is `"ok"`.
* `bytes`: body bytes delivered so far.
* `error`: a message, when there is one.

## Required semantics

The mock tests check these, and the real adapter should be held to the same
scenarios against a local HTTP server:

1. Chunks are delivered in order, followed by exactly one `on_done`.
2. `cancel()` during streaming stops further chunks. `on_done` then fires
   once with `"cancelled"`, and calling `cancel()` again, or after
   completion, does nothing.
3. Deadlines, transport errors and the response bound each produce exactly
   one `on_done` with the matching status. No chunk past the bound is
   delivered.
4. Callbacks run only inside `step()` (or inside `cancel()` / `close()` for
   their own `on_done`), on the caller's thread. The supervisor depends on
   this: callbacks only push events into its inbox and never touch core
   state.
5. HTTP status is not a transport outcome. A 4xx or 5xx response with a body
   completes as `"ok"` with `http_status` set, and the provider decides what
   it means.

## Failure classification (`host/models.lua`)

| Transport result | Class |
|---|---|
| ok with 2xx | success |
| ok with 429 or 5xx | `retryable` |
| ok with another status | `permanent` |
| timeout, error or cancelled | `retryable` |
| overflow or anything unknown | `permanent` |

## Providers

A provider turns a `submit-summary` command into one request and reports
exactly one outcome:

```lua
provider:start(job, on_outcome) -> handle
-- job = { cmd, job, key, attempt, input, source }
on_outcome{ ok = true, text = "..." }
on_outcome{ ok = false, class = "retryable" | "permanent", error = "..." }
provider:step()
provider:pending()
provider.is_mock  -- must be false for a real provider
```

The supervisor turns outcomes into `summary-completed` and `summary-failed`
events, measures UTF-8 bytes and SHA-256 itself, and journals them. Prompt
construction for real summaries (plan §6, §8) is not specified yet.
