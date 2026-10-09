-- unii/host/mock/summarizer.lua -- MOCK summarization provider.
--
-- The real chat-completions provider (host/providers/chat_completions.lua)
-- driven over the MOCK transport (host/mock/network.lua), with a fake model
-- server behind it that streams deterministic FAKE summaries
-- ("[mock L/I aA] ...") as OpenAI-style SSE. Nothing here calls a model.
-- Scripted fixture outcomes attach per node key and attempt, e.g.
--   fixture = { ["0/3"] = { [1] = { oversize = 700 }, [2] = { fail = "retryable" } } }
-- with entries:
--   oversize = N        a summary of N bytes
--   text = "..."        this exact summary
--   fail = "retryable"  HTTP 503;  fail = "permanent"  HTTP 400
--   transport = REASON  failed before send (e.g. "connect", "tls")
--   uncertain = true    request sent, connection dropped mid-stream
--   no_done = true      HTTP 200 completes but the stream never sends [DONE]
--   stall = true        request sent, no answer until the timeout
local codec = require("unii.host.codec")
local json = require("unii.host.network.json")
local mocknet = require("unii.host.mock.network")
local chat = require("unii.host.providers.chat_completions")

local M = {}
M.URL = "mock://model/v1/chat/completions"

local function collapse(s) return (s:gsub("[\r\n]", " ")) end

-- Deterministic fake summary text of at most cap bytes.
function M.fake_text(job, cap)
  local k = job.key
  local tag = ("[mock %d/%d a%d] "):format(k.level, k.index, job.attempt.n)
  local body
  if job.input._ == "leaf-input" then
    body = job.input.kind .. ": " .. collapse(job.source or "")
  else
    local half = math.floor((cap - #tag - 3) / 2)
    body = codec.utf8_prefix(collapse(job.input.left_text), half) .. " | "
        .. codec.utf8_prefix(collapse(job.input.right_text), half)
  end
  return codec.utf8_prefix(tag .. body, cap)
end

local function pieces(s, n)
  local out, i = {}, 1
  while i <= #s do
    local piece = codec.utf8_prefix(s:sub(i), n)
    if piece == "" then piece = s:sub(i, i + 3) end
    out[#out + 1] = piece
    i = i + #piece
  end
  return out
end

local function sse_events(text, n, done)
  local out = {}
  for _, p in ipairs(pieces(text, n)) do
    out[#out + 1] = json.encode { choices = { { index = 0, delta = { content = p } } } }
  end
  if done then out[#out + 1] = "[DONE]" end
  return out
end

-- opts.cap (default 512), opts.fixture (see above), opts.chunk (bytes per
-- streamed delta, default 64), opts.timeout_ms (simulated, default 60000).
function M.new(opts)
  opts = opts or {}
  local cap, fixture, chunk = opts.cap or 512, opts.fixture or {}, opts.chunk or 64
  local jobs = {}

  local function scripted(job)
    local per = fixture[job.key.level .. "/" .. job.key.index]
    return per and per[job.attempt.n]
  end

  -- The fake model server behind the mock transport. It sees the request
  -- the provider built; the job table is looked up by command id only to
  -- pick a fixture and compose the fake text.
  local function server(req)
    local job = jobs[req.id]
    local s = scripted(job) or {}
    if s.transport then return { fail = s.transport } end
    if s.stall then return { stall = true } end
    if s.fail then
      return { status = s.fail == "retryable" and 503 or 400, chunks = { '{"error":"mock"}' } }
    end
    local text
    if s.oversize then
      text = ("[mock oversize] "):rep(math.ceil(s.oversize / 16)):sub(1, s.oversize)
    else
      text = s.text or M.fake_text(job, cap)
    end
    return { status = 200, sse = sse_events(text, chunk, not s.no_done), drop_after = s.uncertain and 1 or nil }
  end

  local client = mocknet.client { server = server, max_inflight = 64, timeout_ms = opts.timeout_ms }
  local p = chat.new { client = client, url = M.URL, model = "mock-model", cap = cap,
                       name = "mock-summarizer", is_mock = true }
  local start = p.start
  function p:start(job, on_outcome)
    jobs[job.cmd] = job
    return start(self, job, on_outcome)
  end
  p.network = client
  return p
end

return M
