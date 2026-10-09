-- The MOCK network transport, the outcome classification, and the
-- chat-completions provider over it (the MOCK summarizer). The mock has the
-- real adapter's interface (docs/contracts/network.md); these tests do not
-- touch a socket. test_network_real.lua drives the real adapter locally.
local T = require("unii.test.lib")
local mocknet = require("unii.host.mock.network")
local models = require("unii.host.models")
local mock = require("unii.host.mock.summarizer")
local supervisor = require("unii.host.supervisor")
local schema = require("unii.host.schema")
local json = require("unii.host.network.json")

local function server_of(map)
  return function(req) return map[req.id] end
end

local function delta(s) return json.encode { choices = { { delta = { content = s } } } } end

local function drain(c, max)
  local n = 0
  while c:inflight() > 0 do c:tick(0); n = n + 1; if n > (max or 1000) then error("no progress") end end
  return n
end

local function count(t, x) local n = 0; for _, v in ipairs(t) do if v == x then n = n + 1 end end; return n end

local function find_event(events, name)
  for _, ev in ipairs(events) do if ev._ == name then return ev end end
end

return {
  { "SSE deltas arrive in order, [DONE] fires on_done, result is succeeded", function()
    local c = mocknet.client { server = server_of {
      a = { sse = { delta("he"), "not json", delta("llo"), "[DONE]" } } } }
    local got, done = {}, 0
    local h = c:chat_stream { id = "a", url = "mock://x", payload = { model = "m" },
      on_delta = function(t) got[#got + 1] = t end, on_done = function() done = done + 1 end }
    drain(c)
    T.eq(table.concat(got), "hello")
    T.eq(done, 1)
    T.ok(h:done())
    T.eq(h.result.outcome, "succeeded"); T.eq(h.result.reason, "complete")
    T.eq(h.result.status, 200); T.eq(h.result.sent, true); T.eq(h.result.attempts, 1)
  end },

  { "cancel before send is not sent; cancel mid-stream is sent; cancel is idempotent", function()
    local c = mocknet.client { server = server_of {
      a = { chunks = { "1", "2", "3" } }, b = { chunks = { "1", "2", "3" } } } }
    local seen = {}
    local a = c:request { id = "a", url = "mock://x", on_chunk = function(x) seen[#seen + 1] = "a" .. x end }
    local b = c:request { id = "b", url = "mock://x", on_chunk = function(x) seen[#seen + 1] = "b" .. x end }
    a:cancel(); a:cancel()
    c:tick(0)
    b:cancel()
    drain(c)
    b:cancel()
    T.eq(a.result.outcome, "cancelled"); T.eq(a.result.sent, false)
    T.eq(b.result.outcome, "cancelled"); T.eq(b.result.sent, true)
    T.eq(table.concat(seen, ","), "b1")
    T.eq(#c.hits, 1, "only b reached the server")
  end },

  { "pre-send failure, drop, stall and body cap map to the adapter's outcomes", function()
    local c = mocknet.client { tick_ms = 10, timeout_ms = 50, max_body_bytes = 8, server = server_of {
      conn = { fail = "connect" },
      drop = { chunks = { "x", "y", "z" }, drop_after = 1 },
      stall = { stall = true },
      big = { chunks = { ("x"):rep(6), ("y"):rep(6) } },
    } }
    local h = {}
    for _, id in ipairs { "conn", "drop", "stall", "big" } do
      h[id] = c:request { id = id, url = "mock://x", on_chunk = function() end }
    end
    drain(c)
    local function o(id) local r = h[id].result; return r.outcome .. "/" .. r.reason .. "/" .. tostring(r.sent) end
    T.eq(o("conn"), "failed/connect/false")
    T.eq(o("drop"), "uncertain/dropped/true")
    T.eq(o("stall"), "uncertain/timeout/true")
    T.eq(o("big"), "failed/body_limit/true")
    T.eq(count(c.hits, "conn"), 0); T.eq(count(c.hits, "drop"), 1)
  end },

  { "inflight cap refuses without queueing; close cancels everything", function()
    local c = mocknet.client { max_inflight = 2, server = function() return { chunks = { "1", "2" } } end }
    local a = c:request { id = "a", url = "mock://x" }
    c:request { id = "b", url = "mock://x" }
    local none, err = c:request { id = "c", url = "mock://x" }
    T.eq(none, nil); T.eq(err, "inflight cap reached (2)")
    c:close()
    T.eq(a.result.outcome, "cancelled")
    T.eq(c:inflight(), 0)
    local _, err2 = c:request { id = "d", url = "mock://x" }
    T.eq(err2, "client is closed")
  end },

  { "adapter results classify as success, retryable, permanent or uncertain", function()
    local function cl(r, done) return (models.classify(r, done)) end
    T.eq(cl({ outcome = "succeeded", status = 200 }, true), nil)
    T.eq(cl({ outcome = "succeeded", status = 200 }, false), "retryable", "stream cut before [DONE]")
    T.eq(cl { outcome = "succeeded", status = 429 }, "retryable")
    T.eq(cl { outcome = "succeeded", status = 503 }, "retryable")
    T.eq(cl { outcome = "succeeded", status = 400 }, "permanent")
    for _, r in ipairs { "connect", "dns", "timeout", "curl" } do
      T.eq(cl { outcome = "failed", reason = r }, "retryable", r)
    end
    for _, r in ipairs { "tls", "bad_url", "protocol", "body_limit", "sse_limit", "callback" } do
      T.eq(cl { outcome = "failed", reason = r }, "permanent", r)
    end
    T.eq(cl { outcome = "uncertain", reason = "dropped", sent = true }, "uncertain")
    T.eq(cl { outcome = "uncertain", reason = "timeout", sent = true }, "uncertain")
    T.eq(cl { outcome = "cancelled", sent = true }, "uncertain")
    T.eq(cl { outcome = "cancelled", sent = false }, "retryable")
  end },

  { "mock provider is labelled mock and fakes summaries deterministically", function()
    local p = mock.new { cap = 512 }
    T.eq(p.is_mock, true); T.eq(mocknet.IS_MOCK, true)
    local job = { cmd = "c1", job = "j", key = { level = 1, index = 0 }, attempt = { n = 1 },
                  input = { _ = "merge-input", left_text = ("日本"):rep(200), right_text = "b" } }
    local a = mock.fake_text(job, 512)
    T.eq(a, mock.fake_text(job, 512))
    T.ok(#a <= 512 and a:find("^%[mock 1/0 a1%]"))
    T.ok(require("unii.host.codec").valid_utf8(a), "truncation respects UTF-8")
    local got
    p:start(job, function(o) got = o end)
    while p:pending() > 0 do p:step() end
    T.eq(got.ok, true); T.eq(got.text, a, "streamed through SSE and reassembled")
  end },

  { "through the supervisor: oversize and transport failures retry, others block, all journaled", function()
    local dir = T.tmpdir("net")
    local events = {}
    local provider = mock.new { cap = 512, fixture = {
      ["0/0"] = { [1] = { oversize = 700 }, [2] = { transport = "connect" } },
      ["0/1"] = { [1] = { fail = "retryable" }, [2] = { fail = "permanent" } },
    } }
    local sup = supervisor.open(dir, { core = T.core(), provider = provider,
      config = schema.config {}, on_client_event = function(ev) events[#events + 1] = ev end })
    sup:submit(T.msg(0, "user", ("a"):rep(800)))
    sup:submit(T.msg(1, "user", ("b"):rep(800)))
    sup:pump()
    local st = sup:status()
    T.eq(st.covered, 1, "leaf 0 summarized on attempt 3; leaf 1 blocked")
    T.eq(st.blocked, 1)
    T.eq(sup:outstanding_count(), 0)
    T.ok(find_event(events, "memory-blocked"), "memory-blocked client event emitted")
    T.eq(provider.calls, 5)
    local h = sup:state_hash()
    sup:close()
    local again = supervisor.open(dir, { core = T.core(), provider = mock.new {} })
    T.eq(again:state_hash(), h)
    T.eq(again:outstanding_count(), 0, "nothing is re-dispatched for a blocked job")
    again:close()
    T.rm(dir)
  end },

  { "a dropped stream is uncertain: parked, never resent, until an operator retries", function()
    local dir = T.tmpdir("unc")
    local events = {}
    local provider = mock.new { cap = 512, fixture = { ["0/0"] = { [1] = { uncertain = true } } } }
    local sup = supervisor.open(dir, { core = T.core(), provider = provider, config = schema.config {},
      on_client_event = function(ev) events[#events + 1] = ev end })
    sup:submit(T.msg(0, "user", ("a"):rep(800)))
    sup:pump()
    T.eq(provider.calls, 1)
    T.eq(#provider.network.hits, 1)
    local st = sup:status()
    T.eq(st.uncertain, 1); T.eq(st.covered, 0); T.eq(sup:outstanding_count(), 0)
    local ev = find_event(events, "effect-uncertain")
    T.ok(ev, "effect-uncertain client event emitted")
    for _ = 1, 5 do sup:pump() end
    T.eq(provider.calls, 1, "pumping again sends nothing")
    sup:close()
    sup = supervisor.open(dir, { core = T.core(), provider = provider, config = schema.config {} })
    sup:pump()
    T.eq(provider.calls, 1, "a restart sends nothing")
    local stuck = sup:stuck_jobs()
    T.eq(#stuck, 1); T.eq(stuck[1].state, "uncertain"); T.eq(stuck[1].job, ev.job)
    sup:operator_retry(ev.job)
    sup:pump()
    T.eq(provider.calls, 2)
    T.eq(sup:status().covered, 1); T.eq(sup:status().uncertain, 0)
    T.eq(#sup:invariant_errors(), 0)
    sup:close()
    T.rm(dir)
  end },

  { "restart with a command in flight: recovered as uncertain, not resent; undispatched work still runs", function()
    local dir = T.tmpdir("crash")
    local p1 = mock.new { cap = 512 }
    local sup = supervisor.open(dir, { core = T.core(), provider = p1,
      config = schema.config { max_inflight = 1 } })
    sup:submit(T.msg(0, "user", ("a"):rep(800)))
    sup:submit(T.msg(1, "user", ("b"):rep(800)))
    T.eq(sup:dispatch_pending(), 1, "one slot: c for leaf 0 starts, leaf 1 stays queued in the core")
    p1:step()                                      -- bytes reach the fake server; then the process "dies"
    T.eq(#p1.network.hits, 1)
    sup:close()

    local p2 = mock.new { cap = 512 }
    local events = {}
    sup = supervisor.open(dir, { core = T.core(), provider = p2,
      on_client_event = function(ev) events[#events + 1] = ev end })
    T.eq(#sup:orphans(), 1)
    T.eq(sup:status().uncertain, 0, "opening alone writes nothing")
    sup:pump()
    T.eq(#p2.network.hits, 1, "only leaf 1 was sent by the new process")
    T.ok(find_event(events, "effect-uncertain"))
    local st = sup:status()
    T.eq(st.uncertain, 1); T.eq(st.covered, 0); T.eq(sup:outstanding_count(), 0)
    local h = sup:state_hash()
    sup:close()
    sup = supervisor.open(dir, { core = T.core(), provider = mock.new {} })
    T.eq(sup:state_hash(), h, "recovery replays identically")
    T.eq(#sup:orphans(), 0)
    sup:close()
    T.rm(dir)
  end },
}
