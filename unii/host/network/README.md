# Unii network adapter

LuaJIT HTTP client for the standalone chat supervisor. Shen decides when to
retry. This module performs one attempt, streams the body, and classifies the
transport result.

It is a libcurl multi-interface binding loaded with LuaJIT FFI from
`libcurl.so.4` (the OpenSSL build, not `libcurl-gnutls`). The spike was
exercised with libcurl 8.5.0 and LuaJIT 2.1. `curl_multi_poll` requires
libcurl >= 7.66. No extra Lua rock is required. The system libcurl is the TLS
and HTTP stack; this file only drives it.

```lua
package.path = "./?.lua;" .. package.path
local network = require("unii.host.network")

local client = network.client({
  max_inflight = network.DEFAULT_MAX_INFLIGHT, -- 8 summaries + 1 turn
  log = function(level, message) end,          -- message is already redacted
})

local handle, err = client:chat_stream({
  id = command_id,
  url = "https://api.openai.com/v1/chat/completions",
  api_key = key, -- never written to the log
  timeout_ms = 60000,
  payload = {
    model = "gpt-4o-mini",
    messages = network.json.array({
      { role = "user", content = "hello" },
    }),
  },
  on_delta = function(text, decoded, handle) end,
  on_event = function(event, handle) end, -- SSE event, including [DONE]
})

while handle and not handle:done() do
  if stop_requested then handle:cancel() end
  client:tick(50) -- milliseconds; 0 returns without sleeping
end

local result = handle.result
client:close()
```

`client:tick` is the only place the transfer makes progress. It is not
re-entrant: a chunk callback must not call `tick`. Callbacks may call
`handle:cancel()` or `client:request`. A handle added from a callback starts
on a later `perform` inside `tick`. Call `tick` with a short slice (about
50 ms) so cancellation is noticed quickly. `tick` cannot be interrupted while
it is inside `curl_multi_poll`.

## Requests

```lua
handle, err = client:request({
  id = "optional-command-id",
  method = "POST",             -- default POST if body is set, otherwise GET
  url = "https://host/path",
  headers = { ["Content-Type"] = "application/json" }, -- or a list of "Name: value"
  body = "{\"k\":1}",          -- string, or a table encoded as JSON
  timeout_ms = 60000,          -- whole transfer; default 60000
  connect_timeout_ms = 10000,  -- default 10000
  verify_tls = true,           -- default true; false turns verification off
  ca_info = "/path/ca.pem",    -- optional extra trust anchor
  ca_path = nil,
  follow_redirects = false,    -- default false; Authorization is not forwarded
  max_body_bytes = 4 * 1024 * 1024,
  store_body = nil,            -- default false when a stream callback is set
  http_version = "1.1",        -- or "2"
  forbid_reuse = true,         -- default true: one command, one connection
  on_chunk = function(bytes, handle) end,
  on_event = function(event, handle) end,
  on_delta = function(text, decoded, handle) end,
  on_done = function(handle) end, -- SSE data was [DONE], not transport completion
  parse_sse = false,           -- implied by on_event / on_delta
})
```

`client:chat_stream` is `request` with `POST`, `Content-Type: application/json`,
`Accept: text/event-stream`, optional `Authorization: Bearer`, and
`payload.stream = true` copied onto a shallow copy of `payload`.

While a handle is unfinished it occupies one inflight slot. The default cap is
`network.DEFAULT_MAX_INFLIGHT` (9): `MAX_SUMMARY_INFLIGHT` (8) plus
`MAX_TURN_INFLIGHT` (1). A further `request` returns `nil` and
`"inflight cap reached (N)"`. This adapter does not queue. Slots free when
`tick` finishes the handle, including cancellation. `client:inflight()` is the
live count.

`handle:cancel()` only sets a flag. `tick` aborts the transfer. `handle:done()`
is true after that, and `handle.result` is set. `on_done` fires when the SSE
stream emits `data: [DONE]`. It runs before `handle.result` is published.
`handle.result` is the transport outcome, available once `:done()` is true.

An SSE `event` is `{ event = string|nil, data = string, id = string|nil, done = bool, json = table|nil, json_error = string|nil }`.
`json` is filled when an `on_delta` callback is set. Malformed JSON does not
fail the transfer. OpenAI keep-alive comments (`: ping`) are ignored.
`on_delta` receives `choices[1].delta.content` when that field is a non-empty
string.

## Outcomes

Every result is one attempt (`result.attempts == 1`). Nothing in this module
retries.

| `result.outcome` | Meaning | Retry |
|---|---|---|
| `succeeded` | A complete HTTP response arrived. `result.status` is set. 4xx and 5xx are still `succeeded`. | Not by this adapter. Shen may treat a definite HTTP error as a new command. |
| `failed` | The HTTP request was not transmitted, or this process aborted locally (`reason` `body_limit`, `sse_limit`, `callback`). | Not by this adapter. A pre-send `failed` (`connect`, `dns`, `tls`, `timeout` with `sent == false`, `protocol`) did not reach the server. |
| `uncertain` | Request bytes were transmitted and the transfer did not finish (`dropped`, or `timeout` with `sent == true`). | Do not automatically retry. The server may have accepted the call. |
| `cancelled` | The caller cancelled. `sent == true` means the provider may already have the request. Cancellation does not undo that. | Do not automatically retry. |

`result.reason` is one of `complete`, `cancelled`, `timeout`, `tls`, `connect`,
`dns`, `dropped`, `body_limit`, `sse_limit`, `callback`, `bad_url`, `protocol`,
`curl`. `result.sent` is true once HTTP request bytes were handed to the
socket. TLS handshake bytes do not count. `result.curl_code` and
`result.curl_error` are the libcurl status. `curl_error` is passed through the
redactor.

`result.headers` is the response header map with lower-case names. Values are
not redacted. The supervisor must not log them raw. `result.body` is present
only when the body was stored.

Suggested mapping onto the effect contract (this module does not emit Shen
events):

| Adapter result | Host event the supervisor can enqueue |
|---|---|
| `succeeded`, stream callbacks already ran | `ModelStreamObserved` per visible chunk, then `ModelStepCompleted` or `SummaryAttemptCompleted` |
| `succeeded` with HTTP status >= 400 | a definite model-failure event; the status is known |
| `failed` | `SummaryAttemptFailed` (or the turn equivalent) with class `failed` |
| `uncertain` | class `uncertain`. Leave it for `RecoveryObserved` or an operator. Do not dispatch the same command again automatically. |
| `cancelled` | `TurnCancelled` or a cancelled job. If `sent`, do not claim the provider call was undone. |

Dispatch intent is still the supervisor's job: record it before `request`, and
record this result after `tick` reports the handle done. A crash after the
bytes went out and before that record is written is `uncertain` even if this
process never got to classify it.

## TLS

Verification is on unless `verify_tls` is explicitly `false`.

- `CURLOPT_SSL_VERIFYPEER = 1`
- `CURLOPT_SSL_VERIFYHOST = 2` (hostname check)
- `ca_info` / `ca_path` select the trust anchor. Without them, curl uses the
  default OpenSSL CA bundle (`SSL_CERT_FILE` / `CURL_CA_BUNDLE` when set).

A bad certificate fails the attempt with `outcome = "failed"`, `reason = "tls"`,
`sent = false`, and curl code 60 (`CURLE_PEER_FAILED_VERIFICATION`). The mock
suite also completes the same request with `verify_tls = false`, and completes
a CA-signed certificate with `verify_tls` left on and `ca_info` set, so the
rejection is the verifier and not a broken client.

Protocols are limited to `http` and `https`. `file://` and other schemes fail
with `reason = "protocol"`.

## Logging

`opts.log(level, message)` receives strings that have already been redacted.
The adapter does not enable curl's stderr trace. The debug callback counts
outbound HTTP bytes and does not copy them into Lua, because those bytes
include `Authorization`.

Redacted before a log line is emitted:

- `Authorization`, `Proxy-Authorization`, `Cookie`, `Set-Cookie`, `X-Api-Key`,
  `Api-Key`, `X-Auth-Token`, `X-OpenAI-API-Key` values (these names are not
  logged as values)
- `user:password@` in URLs
- query keys `api_key`, `apikey`, `key`, `token`, `access_token`,
  `refresh_token`, `secret`, `password`, `client_secret`, `sig`
- `Bearer <token>` and `sk-...` key material if they appear in an error string

Request and response bodies are not logged. Passing `api_key` to `chat_stream`
only places it in the curl header list for the life of that transfer.

## Driving the loop

`tick(wait_ms)` runs one non-blocking iteration: apply cancellations, let
libcurl read and write whatever is ready, deliver queued chunks to Lua, then
publish completions. If handles remain, it calls `curl_multi_poll` for at most
`wait_ms` milliseconds (`0` does not sleep) and pumps curl again.

`run_until_idle(slice_ms, max_ticks)` is a test helper. The supervisor should
keep its own loop so it can interleave journal writes and timer events.
libcurl services every ready handle on each `perform`, so a slow summary does
not block a turn that already has socket data. There is no priority weight
inside this adapter.

Timeouts are curl's `CURLOPT_TIMEOUT_MS` and `CURLOPT_CONNECTTIMEOUT_MS`.
A timeout before any HTTP request bytes are sent is `failed`. A timeout after
they are sent is `uncertain`.

## OpenResty

This adapter is for the standalone LuaJIT supervisor. It does not belong in
an OpenResty worker.

OpenResty already runs LuaJIT 2.1, and FFI is available there, but
`client:tick` calls `curl_multi_poll`, which sleeps the OS thread. Inside
`content_by_lua` / `rewrite_by_lua` that stalls every other request on the
worker. libcurl's sockets are not registered with nginx's event loop, and
loading `libcurl.so.4` next to nginx's own OpenSSL is not part of this spike.

The plan's front end forwards to the chat owner over a local socket. Workers
do not call the provider and do not append the journal. A later worker-side
HTTP client would be a different module (`ngx.socket` / lua-resty-http), not
this one. Differences that matter if that module is written:

| | This adapter | OpenResty cosocket client |
|---|---|---|
| Event loop | `curl_multi_poll` on the supervisor thread | nginx; yield with `sock:receive` / `ngx.sleep` |
| TLS verify | on by default (`SSL_VERIFYPEER` + `SSL_VERIFYHOST`) | lua-resty-http verifies only when the caller sets `ssl_verify = true` |
| Trust store | OpenSSL default bundle, or `ca_info` | `lua_ssl_trusted_certificate` plus the cosocket options |
| Cancel | `handle:cancel()` then `tick` removes the easy handle | close the cosocket |
| Timeouts | `timeout_ms` / `connect_timeout_ms` | `sock:settimeout` |
| Streaming | write callback, delivered after `curl_multi_perform` returns | read loop in the request coroutine |
| Where it may run | one supervisor thread | worker request or light thread |

Do not mix the two in one worker. Small Shen validations in OpenResty are a
separate question and are not this module.

## Tests

From the repo root:

```sh
luajit unii/test/network/run.lua
luajit unii/test/network/smoke.lua   # exits 0 and prints SKIP without a key
```

`unii/test/network/mock_server.py` is the local HTTP and HTTPS peer. The suite
covers SSE reassembly, a slow stream with `tick(0)`, cancel before send and
mid-stream, connection refused (`failed`), drop after the request is read
(`uncertain`, one hit on the server), a short body with a lying
`Content-Length` (`uncertain`), timeout after send (`uncertain`), the default
verifier rejecting a private certificate (curl code 60) and accepting a
certificate signed by `ca_info`, nine overlapping requests with a tenth
refused, the body cap, secret redaction, and `file://` rejection.

`OPENAI_API_KEY` or `UNII_OPENAI_API_KEY` opts into a real
`/v1/chat/completions` stream. Optional `UNII_OPENAI_BASE_URL` and
`UNII_OPENAI_MODEL` (default model `gpt-4o-mini`). With no key the smoke test
skips and exits 0. A skip is not a provider integration.

## Limits

- HTTP/1.1 by default. `http_version = "2"` asks for TLS HTTP/2 and is not
  what the mock suite covered.
- Connections are not reused (`forbid_reuse` defaults to true), so one
  command cannot observe another command's reset. Keep-alive is off until a
  later change measures it.
- The request body is buffered and handed to curl in one piece. There is no
  request-body stream.
- Response bytes are delivered per `tick`. Stored bodies stop at
  `max_body_bytes` (default 4 MiB). Crossing the cap is a local `failed` /
  `body_limit` after `sent` may already be true.
- Redirects are off. Turning them on can forward `Authorization` to another
  host; curl's default `CURLOPT_UNRESTRICTED_AUTH` stays off, which is not a
  substitute for leaving redirects disabled.
- No proxy support, no OCSP stapling, no client certificates.
- One Lua state, one thread. Do not share a client across threads.
- JSON is a small codec: objects, arrays, strings, numbers, booleans, null.
  Empty tables encode as `{}`. Use `network.json.array` for arrays. Nesting
  is capped at 32. Object keys are sorted when encoding.
- The supervisor still owns journal order, spend limits, and retry policy.
  This module will not turn `uncertain` into a second socket write.
