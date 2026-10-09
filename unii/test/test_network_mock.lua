-- The MOCK network transport and MOCK summarizer. These tests pin the
-- network contract semantics (docs/contracts/network.md) that the real
-- libcurl adapter must also satisfy; they do not exercise any real network.
local T = require("unii.test.lib")
local mocknet = require("unii.host.mock.network")
local models = require("unii.host.models")
local mock = require("unii.host.mock.summarizer")
local supervisor = require("unii.host.supervisor")
local schema = require("unii.host.schema")

local function server_of(map)
  return function(req) return map[req.id] end
end

local function recorder(log, id)
  return {
    id = id,
    on_headers = function(status) log[#log + 1] = id .. ":H" .. status end,
    on_chunk = function(c) log[#log + 1] = id .. ":" .. c end,
    on_done = function(r) log[#log + 1] = id .. ":done:" .. r.status .. ":" .. tostring(r.bytes) end,
  }
end

local function drain(c) local n = 0; while c:pending() > 0 do c:step(); n = n + 1 end; return n end

return {
  { "streams chunks in order, then exactly one on_done", function()
    local c = mocknet.new { server = server_of { a = { chunks = { "he", "llo" } } } }
    local log = {}
    c:request(recorder(log, "a"))
    drain(c)
    T.eq(table.concat(log, " "), "a:H200 a:he a:llo a:done:ok:5")
  end },

  { "cancel mid-stream stops chunks and reports cancelled once (idempotent)", function()
    local c = mocknet.new { server = server_of { a = { chunks = { "1", "2", "3" } } } }
    local log = {}
    local r = c:request(recorder(log, "a"))
    c:step()
    r:cancel(); r:cancel()
    drain(c)
    r:cancel()
    T.eq(table.concat(log, " "), "a:H200 a:1 a:done:cancelled:1")
    T.eq(c:pending(), 0)
  end },

  { "deadline, transport error and response bound each finish once", function()
    local c = mocknet.new { server = server_of {
      slow = { chunks = { "a", "b", "c", "d", "e" } },
      err = { error = "connection reset" },
      big = { chunks = { ("x"):rep(6), ("y"):rep(6) } },
    }, max_buffer_bytes = 8 }
    local log = {}
    local s = recorder(log, "slow"); s.deadline_steps = 2
    c:request(s); c:request(recorder(log, "err")); c:request(recorder(log, "big"))
    drain(c)
    local text = table.concat(log, " ")
    T.ok(text:find("slow:done:timeout:2", 1, true), text)
    T.ok(text:find("err:done:error:0", 1, true), text)
    T.ok(text:find("big:done:overflow:6", 1, true), text)
    T.ok(not text:find("big:yyyyyy", 1, true), "no chunk past the bound")
    local dones = select(2, text:gsub(":done:", ""))
    T.eq(dones, 3)
  end },

  { "duplicate active request ids are refused; close cancels everything", function()
    local c = mocknet.new { server = server_of { a = { chunks = { "1", "2" } } } }
    local log = {}
    c:request(recorder(log, "a"))
    T.raises(function() c:request(recorder(log, "a")) end, "duplicate active request id")
    c:close()
    T.eq(table.concat(log, " "), "a:done:cancelled:0")
    T.raises(function() c:request(recorder(log, "b")) end, "client closed")
  end },

  { "transport results classify as success, retryable or permanent", function()
    T.eq(models.classify { status = "ok", http_status = 200 }, nil)
    T.eq(models.classify { status = "ok", http_status = 429 }, "retryable")
    T.eq(models.classify { status = "ok", http_status = 503 }, "retryable")
    T.eq(models.classify { status = "ok", http_status = 400 }, "permanent")
    T.eq(models.classify { status = "timeout" }, "retryable")
    T.eq(models.classify { status = "error" }, "retryable")
    T.eq(models.classify { status = "cancelled" }, "retryable")
    T.eq(models.classify { status = "overflow" }, "permanent")
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
  end },

  { "through the supervisor: oversize retries, failures block, all journaled", function()
    local dir = T.tmpdir("net")
    local events = {}
    local provider = mock.new { cap = 512, fixture = {
      ["0/0"] = { [1] = { oversize = 700 } },               -- retry-too-long, then fine
      ["0/1"] = { [1] = { fail = "retryable" }, [2] = { fail = "permanent" } },
    } }
    local sup = supervisor.open(dir, { core = T.core(), provider = provider,
      config = schema.config {}, on_client_event = function(ev) events[#events + 1] = ev end })
    sup:submit(T.msg(0, "user", ("a"):rep(800)))
    sup:submit(T.msg(1, "user", ("b"):rep(800)))
    sup:pump()
    local st = sup:status()
    T.eq(st.covered, 1, "leaf 0 summarized on attempt 2; leaf 1 blocked")
    T.eq(st.blocked, 1)
    T.eq(sup:outstanding_count(), 0)
    local blocked
    for _, ev in ipairs(events) do if ev._ == "memory-blocked" then blocked = ev end end
    T.ok(blocked, "memory-blocked client event emitted")
    T.eq(provider.calls, 4)
    local h = sup:state_hash()
    sup:close()
    local again = supervisor.open(dir, { core = T.core(), provider = mock.new {} })
    T.eq(again:state_hash(), h)
    T.eq(again:outstanding_count(), 0, "nothing is re-dispatched for a blocked job")
    again:close()
    T.rm(dir)
  end },
}
