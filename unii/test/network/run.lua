-- Phase 0 network adapter tests.
--
--   luajit unii/test/network/run.lua
--
-- Drives a local mock (streaming, slow, dropped connection, bad TLS) and
-- skips the real-provider smoke test when no API key is set.

local ffi = require("ffi")
ffi.cdef[[
  struct timespec { long tv_sec; long tv_nsec; };
  int clock_gettime(int clk_id, struct timespec *tp);
]]

local function now()
  local ts = ffi.new("struct timespec")
  if ffi.C.clock_gettime(1, ts) ~= 0 then error("clock_gettime failed") end
  return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
end

local function repo_root()
  local dir = (arg[0] or ""):match("^(.*)/[^/]+$") or "."
  local root = dir:gsub("/unii/test/network$", "")
  if root == dir then
    root = dir:gsub("unii/test/network$", "")
  end
  if root == "" then root = "." end
  return root
end

local root = repo_root()
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local network = require("unii.host.network")
local json = require("unii.host.network.json")
local sse = require("unii.host.network.sse")
local redact = require("unii.host.network.redact")

local passed, failed, skipped = 0, 0, 0
local failures = {}

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("ok  " .. name)
  else
    failed = failed + 1
    failures[#failures + 1] = name
    print("FAIL " .. name)
    print("    " .. tostring(err))
  end
end

local function eq(got, want, msg)
  if got ~= want then
    error((msg or "mismatch") .. "\n    got:  " .. tostring(got) .. "\n    want: " .. tostring(want), 2)
  end
end

local function contains(hay, needle, msg)
  if type(hay) ~= "string" or not hay:find(needle, 1, true) then
    error((msg or "missing text") .. " (needle length " .. tostring(type(needle) == "string" and #needle or 0) .. ")", 2)
  end
end

local function absent(hay, needle, msg)
  if type(hay) == "string" and hay:find(needle, 1, true) then
    error(msg or "unexpected secret in text", 2)
  end
end

local function drive(client, handle, limit_s)
  local t0 = now()
  limit_s = limit_s or 8
  while not handle:done() do
    if now() - t0 > limit_s then
      error("timed out waiting for " .. tostring(handle.id))
    end
    client:tick(20)
  end
  return handle.result
end

local function sh(cmd)
  local rc = os.execute(cmd)
  if rc ~= 0 and rc ~= true then
    error("command failed (" .. tostring(rc) .. "): " .. cmd)
  end
end

local function gen_certs(dir)
  os.execute("rm -rf " .. dir)
  sh("mkdir -p " .. dir)
  sh(string.format(
    "openssl req -x509 -newkey rsa:2048 -keyout %s/bad.key -out %s/bad.crt -days 1 -nodes -subj /CN=127.0.0.1 >/dev/null 2>&1",
    dir, dir))
  sh(string.format(
    "openssl req -x509 -newkey rsa:2048 -keyout %s/ca.key -out %s/ca.crt -days 1 -nodes -subj /CN=unii-test-ca >/dev/null 2>&1",
    dir, dir))
  local san = assert(io.open(dir .. "/san.cnf", "w"))
  san:write("[v3]\nsubjectAltName=IP:127.0.0.1,DNS:localhost\nbasicConstraints=CA:FALSE\n")
  san:close()
  sh(string.format(
    "openssl req -newkey rsa:2048 -keyout %s/srv.key -out %s/srv.csr -nodes -subj /CN=127.0.0.1 >/dev/null 2>&1",
    dir, dir))
  sh(string.format(
    "openssl x509 -req -in %s/srv.csr -CA %s/ca.crt -CAkey %s/ca.key -CAcreateserial -out %s/srv.crt -days 1 -extfile %s/san.cnf -extensions v3 >/dev/null 2>&1",
    dir, dir, dir, dir, dir))
end

local function start_server(certdir)
  local script = root .. "/unii/test/network/mock_server.py"
  local cmd = string.format(
    "exec python3 %q --bad-cert %q --bad-key %q --good-cert %q --good-key %q",
    script,
    certdir .. "/bad.crt", certdir .. "/bad.key",
    certdir .. "/srv.crt", certdir .. "/srv.key")
  local pipe = assert(io.popen(cmd, "r"))
  local info = { pipe = pipe }
  local deadline = now() + 8
  while now() < deadline do
    local line = pipe:read("*l")
    if not line then error("mock server exited before READY") end
    if line == "READY" then break end
    local k, v = line:match("^(%S+)%s+(%S+)$")
    if k then info[k] = v end
    if now() >= deadline then error("mock server startup timed out") end
  end
  if not info.HTTP or not info.HTTPS_BAD or not info.HTTPS_GOOD or not info.PID then
    error("mock server did not report ports")
  end
  function info:close()
    os.execute("kill " .. self.PID .. " >/dev/null 2>&1")
    pcall(function() pipe:close() end)
  end
  return info
end

local function client(opts)
  opts = opts or {}
  return network.client(opts)
end

print("curl " .. network.curl_version())
print("max inflight default " .. tostring(network.DEFAULT_MAX_INFLIGHT)
  .. " (summaries " .. tostring(network.MAX_SUMMARY_INFLIGHT)
  .. " + turn " .. tostring(network.MAX_TURN_INFLIGHT) .. ")")

test("json object, array, and escapes", function()
  local encoded = json.encode({
    model = "m",
    stream = true,
    n = 1,
    messages = json.array({ { role = "user", content = "a\"b\\c" } }),
  })
  local decoded, err = json.decode(encoded)
  eq(err, nil)
  eq(decoded.model, "m")
  eq(decoded.stream, true)
  eq(decoded.messages[1].content, "a\"b\\c")
  local snow, serr = json.decode([["\u2603"]])
  eq(serr, nil)
  eq(snow, "\226\152\131")
  local empty_obj = json.encode({})
  eq(empty_obj, "{}")
  eq(json.encode(json.array({})), "[]")
  eq(json.encode(json.null), "null")
end)

test("sse parser reassembles split events and ignores comments", function()
  local p = sse.new()
  local ev, err = p:push(": keep-alive\n\n")
  eq(err, nil)
  eq(#ev, 0)
  ev = p:push("data: {\"a\":1}\n\nda")
  eq(#ev, 1)
  eq(ev[1].data, "{\"a\":1}")
  eq(ev[1].done, false)
  ev = p:push("ta: [DONE]\n\n")
  eq(#ev, 1)
  eq(ev[1].done, true)
  local crlf = sse.new()
  ev = crlf:push("event: delta\r\ndata: hi\r\ndata: there\r\n\r\n")
  eq(#ev, 1)
  eq(ev[1].event, "delta")
  eq(ev[1].data, "hi\nthere")
end)

test("redact strips bearer tokens, sk- keys, and query secrets", function()
  local secret = "super-secret-token-xyz"
  local url = redact.url("https://user:" .. secret .. "@api.example/v1/chat?api_key=" .. secret .. "&x=1")
  absent(url, secret)
  contains(url, "<redacted>")
  contains(url, "x=1")
  local text = redact.text("Authorization failed Bearer " .. secret .. " sk-testsecretvalue123")
  absent(text, secret)
  absent(text, "sk-testsecretvalue123")
  eq(redact.header_is_secret("Authorization"), true)
  eq(redact.header_is_secret("Content-Type"), false)
end)

local tmp = os.tmpname()
os.remove(tmp)
local certdir = tmp .. "-certs"
gen_certs(certdir)
local server = start_server(certdir)
local base = "http://127.0.0.1:" .. server.HTTP
print("mock http " .. base)

local function finish_server()
  server:close()
  os.execute("rm -rf " .. certdir)
end

local ok_suite, suite_err = pcall(function()

test("echo succeeds and keeps a complete 500 as transport success", function()
  local c = client()
  local handle = assert(c:request({
    id = "echo-1",
    method = "POST",
    url = base .. "/echo",
    headers = { ["Content-Type"] = "application/json" },
    body = "{}",
  }))
  local result = drive(c, handle)
  eq(result.outcome, network.outcome.succeeded)
  eq(result.reason, network.reason.complete)
  eq(result.status, 200)
  eq(result.sent, true)
  eq(result.attempts, 1)
  eq(result.body, '{"ok":true}')
  eq(result.curl_code, 0)
  local errh = assert(c:request({ url = base .. "/error" }))
  local bad = drive(c, errh)
  eq(bad.outcome, network.outcome.succeeded)
  eq(bad.status, 500)
  eq(bad.body, '{"error":"nope"}')
  c:close()
end)

test("openai-compatible stream delivers deltas and stops at DONE", function()
  local c = client()
  local deltas = {}
  local saw_done = false
  local events = 0
  local handle, err = c:chat_stream({
    id = "turn-1",
    url = base .. "/v1/chat/completions",
    payload = { chunks = json.array({ "Hello", " ", "world" }), delay_ms = 0 },
    on_delta = function(text)
      deltas[#deltas + 1] = text
    end,
    on_event = function(ev)
      events = events + 1
      if ev.done then saw_done = true end
    end,
    on_done = function()
      saw_done = true
    end,
  })
  eq(err, nil)
  local result = drive(c, handle)
  eq(result.outcome, "succeeded")
  eq(table.concat(deltas), "Hello world")
  eq(saw_done, true)
  eq(events, 4)
  c:close()
end)

test("tick(0) stays non-blocking during a slow stream", function()
  local c = client()
  local n = 0
  local handle = assert(c:request({
    url = base .. "/slow",
    parse_sse = true,
    on_delta = function()
      n = n + 1
    end,
    timeout_ms = 5000,
  }))
  local max_dt = 0
  local t0 = now()
  while not handle:done() do
    if now() - t0 > 4 then error("slow stream did not finish") end
    local a = now()
    c:tick(0)
    local dt = now() - a
    if dt > max_dt then max_dt = dt end
  end
  eq(handle.result.outcome, "succeeded")
  eq(n, 4)
  if max_dt >= 0.05 then
    error("tick(0) blocked for " .. tostring(max_dt) .. "s")
  end
  c:close()
end)

test("caller can cancel mid-stream", function()
  local c = client()
  local deltas = {}
  local handle = assert(c:chat_stream({
    url = base .. "/v1/chat/completions",
    payload = { chunks = json.array({ "a", "b", "c", "d", "e", "f" }), delay_ms = 150 },
    timeout_ms = 5000,
    on_delta = function(text)
      deltas[#deltas + 1] = text
    end,
  }))
  local t0 = now()
  while not handle:done() do
    if now() - t0 > 5 then error("cancel test hung") end
    c:tick(20)
    if #deltas >= 1 and not handle:done() then
      handle:cancel()
    end
  end
  eq(handle.result.outcome, "cancelled")
  eq(handle.result.reason, "cancelled")
  eq(handle.result.attempts, 1)
  if #deltas < 1 then error("expected a delta before cancel") end
  if #deltas >= 6 then error("cancel did not stop the stream, got " .. tostring(#deltas)) end
  c:close()
end)

test("cancel before the first tick does not transmit", function()
  local c = client()
  local handle = assert(c:request({
    url = base .. "/hold",
    timeout_ms = 5000,
  }))
  eq(c:inflight(), 1)
  handle:cancel()
  eq(handle:done(), false)
  c:tick(0)
  eq(handle:done(), true)
  eq(handle.result.outcome, "cancelled")
  eq(handle.result.sent, false)
  eq(c:inflight(), 0)
  c:close()
end)

test("non-http URLs are rejected before a transfer", function()
  local c = client()
  local handle = assert(c:request({
    url = "file:///etc/passwd",
    timeout_ms = 1000,
  }))
  local result = drive(c, handle, 3)
  eq(result.outcome, "failed")
  eq(result.reason, "protocol")
  eq(result.sent, false)
  absent(result.body or "", "root:")
  local bad, err = c:request({
    url = base .. "/echo",
    headers = { ["X-Test"] = "a\r\nX-Injected: yes" },
  })
  eq(bad, nil)
  contains(err, "CR")
  c:close()
end)

test("connect failure is failed and is not retried", function()
  local c = client()
  local handle = assert(c:request({
    url = "http://127.0.0.1:1/",
    timeout_ms = 1000,
    connect_timeout_ms = 500,
  }))
  local result = drive(c, handle, 3)
  eq(result.outcome, "failed")
  eq(result.sent, false)
  eq(result.attempts, 1)
  eq(result.status, nil)
  c:close()
end)

test("drop after send is uncertain and is not retried", function()
  local c = client()
  local handle = assert(c:request({
    method = "POST",
    url = base .. "/drop",
    headers = { ["Content-Type"] = "application/json" },
    body = "{}",
    timeout_ms = 2000,
  }))
  local result = drive(c, handle, 4)
  eq(result.outcome, "uncertain")
  eq(result.reason, "dropped")
  eq(result.sent, true)
  eq(result.attempts, 1)
  eq(result.status, nil)
  local stats_h = assert(c:request({ url = base .. "/stats" }))
  local stats = drive(c, stats_h)
  local snap = assert(json.decode(stats.body))
  eq(snap.hits["/drop"], 1)
  c:close()
end)

test("partial body after send is uncertain and keeps the chunk", function()
  local c = client()
  local deltas = {}
  local handle = assert(c:request({
    url = base .. "/partial",
    timeout_ms = 2000,
    on_delta = function(text)
      deltas[#deltas + 1] = text
    end,
  }))
  local result = drive(c, handle, 4)
  eq(result.outcome, "uncertain")
  eq(result.sent, true)
  eq(table.concat(deltas), "partial")
  eq(result.attempts, 1)
  c:close()
end)

test("timeout after send is uncertain", function()
  local c = client()
  local handle = assert(c:request({
    url = base .. "/hold",
    timeout_ms = 400,
    connect_timeout_ms = 200,
  }))
  local t0 = now()
  local result = drive(c, handle, 4)
  local dt = now() - t0
  eq(result.outcome, "uncertain")
  eq(result.reason, "timeout")
  eq(result.sent, true)
  if dt < 0.3 then error("timeout returned too fast: " .. tostring(dt)) end
  if dt > 3 then error("timeout returned too slow: " .. tostring(dt)) end
  c:close()
end)

test("default TLS verification rejects a bad certificate", function()
  local c = client()
  local url = "https://127.0.0.1:" .. server.HTTPS_BAD .. "/echo"
  local handle = assert(c:request({
    url = url,
    method = "POST",
    body = "{}",
    headers = { ["Content-Type"] = "application/json" },
    timeout_ms = 3000,
  }))
  local result = drive(c, handle, 4)
  eq(result.outcome, "failed")
  eq(result.reason, "tls")
  eq(result.sent, false)
  eq(result.curl_code, 60)
  c:close()

  local off = client({ })
  local allowed = assert(off:request({
    url = url,
    method = "POST",
    body = "{}",
    headers = { ["Content-Type"] = "application/json" },
    verify_tls = false,
    timeout_ms = 3000,
  }))
  local ok = drive(off, allowed, 4)
  eq(ok.outcome, "succeeded")
  eq(ok.status, 200)
  off:close()
end)

test("TLS verification succeeds for a certificate signed by ca_info", function()
  local c = client()
  local handle = assert(c:request({
    url = "https://127.0.0.1:" .. server.HTTPS_GOOD .. "/echo",
    method = "POST",
    body = "{}",
    headers = { ["Content-Type"] = "application/json" },
    ca_info = certdir .. "/ca.crt",
    timeout_ms = 3000,
  }))
  local result = drive(c, handle, 4)
  eq(result.outcome, "succeeded")
  eq(result.status, 200)
  eq(result.body, '{"ok":true}')
  c:close()
end)

test("one loop runs 8 summary slots plus one turn together", function()
  local c = client()
  eq(c.max_inflight, 9)
  local handles = {}
  for i = 1, 9 do
    handles[i] = assert(c:request({
      id = "job-" .. tostring(i),
      method = "POST",
      url = base .. "/echo",
      headers = { ["Content-Type"] = "application/json" },
      body = json.encode({ delay_ms = 300, n = i }),
      timeout_ms = 5000,
    }))
  end
  eq(c:inflight(), 9)
  local extra, err = c:request({ url = base .. "/echo" })
  eq(extra, nil)
  contains(err, "inflight")
  local saw = 0
  local t0 = now()
  while c:inflight() > 0 do
    if now() - t0 > 5 then error("concurrent requests hung") end
    local n = c:inflight()
    if n > saw then saw = n end
    c:tick(20)
  end
  eq(saw, 9)
  for i = 1, 9 do
    eq(handles[i].result.outcome, "succeeded")
    eq(handles[i].result.status, 200)
  end
  local stats_h = assert(c:request({ url = base .. "/stats" }))
  local stats = drive(c, stats_h)
  local snap = assert(json.decode(stats.body))
  if snap.peak < 9 then
    error("server did not observe concurrent requests, peak " .. tostring(snap.peak))
  end
  c:close()
end)

test("body cap aborts a sent request locally", function()
  local c = client()
  local handle = assert(c:request({
    url = base .. "/echo",
    method = "POST",
    body = "{}",
    headers = { ["Content-Type"] = "application/json" },
    max_body_bytes = 4,
    store_body = true,
    timeout_ms = 2000,
  }))
  local result = drive(c, handle, 4)
  eq(result.outcome, "failed")
  eq(result.reason, "body_limit")
  eq(result.sent, true)
  eq(result.attempts, 1)
  c:close()
end)

test("logs omit secrets from the request and the response", function()
  local secret = "super-secret-token-xyz"
  local logs = {}
  local c = client({
    log = function(_level, msg)
      logs[#logs + 1] = msg
    end,
  })
  local handle = assert(c:request({
    method = "POST",
    url = base .. "/echo?api_key=" .. secret .. "&x=1",
    headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. secret,
    },
    body = '{"api_key":"' .. secret .. '"}',
    timeout_ms = 2000,
  }))
  local result = drive(c, handle, 4)
  eq(result.outcome, "succeeded")
  -- The caller still receives raw response headers. Only logs are redacted.
  if not (result.headers["set-cookie"] or ""):find(secret, 1, true) then
    error("response header was not preserved for the caller")
  end
  local blob = table.concat(logs, "\n")
  absent(blob, secret, "log contained a secret")
  absent(blob, "sk-testsecretvalue123")
  absent(result.curl_error or "", secret, "curl_error contained a secret")
  absent(result.body or "", secret, "stored body echoed a secret")
  contains(blob, "outcome=succeeded")
  c:close()
end)

end)

local smoke_status, smoke_detail
do
  local smoke = require("unii.test.network.smoke")
  smoke_status, smoke_detail = smoke.run()
end

finish_server()

if not ok_suite then
  failed = failed + 1
  print("FAIL suite harness")
  print("    " .. tostring(suite_err))
end

if smoke_status == "skip" then
  skipped = skipped + 1
  print("SKIP smoke: " .. tostring(smoke_detail))
elseif smoke_status == "ok" then
  passed = passed + 1
  print("ok  smoke " .. tostring(smoke_detail))
else
  failed = failed + 1
  print("FAIL smoke")
  print("    " .. tostring(smoke_detail))
end

print(string.format("%d passed, %d failed, %d skipped", passed, failed, skipped))
if failed > 0 then
  os.exit(1)
end
os.exit(0)
