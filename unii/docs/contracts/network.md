# Network contract

Two transports share one Lua interface:

* **Real:** `require("unii.host.network")` (`unii/host/network/`, from PR
  #75). This is a libcurl multi binding through LuaJIT FFI. It has TLS
  verification on by default, SSE streaming, cancellation, and redacted
  logging. `IS_MOCK = false`. Its README covers TLS, logging, limits and
  OpenResty.
* **Mock:** `require("unii.host.mock.network")`, with `IS_MOCK = true`. It
  has no sockets and no wall clock. A scripted in-process server answers
  each request, and each `tick` advances a simulated clock. This is the
  default for tests and for the CLI.

A summarizer provider (`host/providers/chat_completions.lua`) takes either
client by injection. The MOCK summarizer (`host/mock/summarizer.lua`) is
that same provider over the mock transport, with a fake model server that
streams deterministic fake summaries.

## Client interface

```lua
client = network.client(opts)       -- real: max_inflight (9), timeout_ms, connect_timeout_ms,
                                    --       max_body_bytes, user_agent, log
                                    -- mock: server, max_inflight (9), timeout_ms, max_body_bytes, tick_ms
handle, err = client:request(spec)  -- nil, "inflight cap reached (N)" when full; never queues
handle, err = client:chat_stream{ id, url, api_key, payload, timeout_ms, headers,
                                  on_delta, on_event, on_done }
client:tick(wait_ms)  -> inflight   -- the only place transfers progress; not re-entrant
client:inflight()     -> n
client:close()                      -- cancels everything still running

handle:cancel()   -- idempotent; takes effect on the next tick
handle:done()     -- true once handle.result is set
handle.result     -- see below
```

Request fields: `id` (the core's command id), `method`, `url`, `headers`,
`body` (a string or a JSON table), `timeout_ms`, `max_body_bytes`,
`on_chunk(bytes, handle)`, `on_event(sse_event, handle)`,
`on_delta(text, decoded, handle)`, and `on_done(handle)`. `on_done` fires
for the SSE `[DONE]` sentinel, not for the end of the transport. Callbacks
run only inside `tick`. They may cancel handles, but they must not call
`tick`.

`chat_stream` posts `payload` with `stream = true`,
`Content-Type: application/json` and `Accept: text/event-stream`. When
`api_key` is set it adds `Authorization: Bearer`. The key lives only in the
request's header list. The adapter never logs it, and the supervisor never
journals it.

## Result

| Field | Meaning |
|---|---|
| `outcome` | `succeeded`, `failed`, `uncertain` or `cancelled` |
| `reason` | `complete`, `cancelled`, `timeout`, `tls`, `connect`, `dns`, `dropped`, `body_limit`, `sse_limit`, `callback`, `bad_url`, `protocol` or `curl` |
| `status` | HTTP status, when a response line arrived |
| `sent` | true once HTTP request bytes were handed to the socket. TLS handshake bytes do not count |
| `attempts` | always 1. Nothing in either transport retries |
| `bytes_received`, `headers`, `body`, `id`, `curl_code`, `curl_error` | details. `curl_error` is redacted |

The outcome rules, which the mock follows:

* **`succeeded`:** a complete HTTP response. A 4xx or 5xx response is still
  `succeeded`.
* **`failed`:** the request was never transmitted (`connect`, `dns`,
  `tls`, `bad_url`, `protocol`, or `timeout` with `sent == false`), or this
  process aborted locally (`body_limit`, `sse_limit`, `callback`).
* **`uncertain`:** the request was sent and the transfer did not finish
  (`dropped`, or `timeout` with `sent == true`). The server may have acted
  on it.
* **`cancelled`:** the caller cancelled. `sent` tells whether the provider
  may already have the request.

## Classification (`host/models.lua`)

| Adapter result | Class |
|---|---|
| `succeeded`, 2xx, stream reached `[DONE]` | success |
| `succeeded`, 2xx, stream ended without `[DONE]` | `uncertain` (decision R5) |
| `succeeded`, 429 or 5xx | `retryable` |
| `succeeded`, any other status | `permanent` |
| `failed`: `connect`, `dns`, `timeout` (before send), `curl` | `retryable` |
| `failed`: `tls`, `bad_url`, `protocol`, `body_limit`, `sse_limit`, `callback` | `permanent` |
| `uncertain` | `uncertain` |
| `cancelled` with `sent` | `uncertain` |
| `cancelled` without `sent` | `retryable` |

A successful stream whose text is empty or not valid UTF-8 is reported as
`permanent`.

For an `uncertain` class the supervisor sends `summary-uncertain` instead of
`summary-failed`, with the leaf's message as raw content for a leaf job
(`events.md`). It maps onto the job state `[uncertain CmdId]` and, for a
leaf, a provisional line (`commands.md`, "Effect states"). The job is never
re-sent automatically. Three things hold
that line:

* the adapter makes exactly one attempt;
* the provider reports one outcome per command;
* the core requeues an uncertain job only on `operator-retry`.

A crash between sending and journaling the outcome is covered by the
supervisor's dispatch records (`storage.md`).

## Provider interface

```lua
provider = chat_completions.new{ client, url, model, api_key, cap, timeout_ms, max_body_bytes, name, is_mock }
provider:start(job, on_outcome)  -- job = { cmd, job, key, attempt, input, source }
provider:step(wait_ms)           -- launches waiting requests, ticks the client, reports finished ones
provider:pending()               -- started or waiting, not yet reported
on_outcome{ ok = true, text = "..." }
on_outcome{ ok = false, class = "retryable" | "permanent" | "uncertain", error = "..." }
```

If the client refuses a request because the inflight cap is full, the
provider holds it locally. It costs no attempt, and the provider launches
it on a later `step`. Any other refusal, such as a bad URL, is `permanent`.
The request carries `X-Unii-Job: <job id>`.

The prompt is **provisional** (`PROMPT_VERSION = "provisional-0"`). It has a
system message that states the byte cap, plus a "be shorter" hint after
`retry-too-long` and a "best so far is N bytes" hint after
`retry-seek-shorter`. For a leaf, the user message is `kind: text`. For a merge,
it is the two child texts. `max_tokens` is set to the cap. The plan's
summarization prompt (§6, §8) is not specified yet.

## What has been exercised

* **Mock transport and MOCK summarizer** (`test_network_mock.lua`):
  * outcome rules and classification;
  * rounds of tries, blocking and uncertain parking through the
    supervisor, including a 2xx stream without `[DONE]`;
  * restart recovery.
* **Real adapter through the provider, supervisor and CLI**
  (`test_network_real.lua`):
  * runs against the adapter's local test server
    (`unii/test/network/mock_server.py`, 127.0.0.1, plain HTTP);
  * a streamed completion is committed as the summary;
  * a connection dropped after send becomes `uncertain`, and the server
    sees exactly one request;
  * `unii retry` recovers the job;
  * the API key is never printed or journaled;
  * it skips when libcurl or python3 is missing.
* **The adapter's own suite** (`luajit unii/test/network/run.lua`):
  * TLS verification, cancellation, timeouts, the inflight cap and
    redaction;
  * its real-provider smoke test skips without an API key.

No real model provider has been called from this branch. `--network real`
with a provider URL and key is wired, but it is unverified against a live
provider.
