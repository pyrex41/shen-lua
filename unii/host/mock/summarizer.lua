-- unii/host/mock/summarizer.lua -- MOCK summarization provider.
--
-- Produces deterministic FAKE summaries ("[mock L/I] ...") from the source
-- text, streamed through a mock network server so the host exercises the
-- same request/stream/outcome path a real provider will use. Nothing here
-- calls a model. Scripted fixture outcomes (oversize text, failures) can be
-- attached per node key and attempt, e.g.
--   fixture = { ["0/3"] = { [1] = { oversize = 700 }, [2] = { fail = "retryable" } } }
local codec = require("unii.host.codec")
local models = require("unii.host.models")
local mocknet = require("unii.host.mock.network")

local M = {}

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

local function chunks_of(s, n)
  local out, i = {}, 1
  while i <= #s do
    local piece = codec.utf8_prefix(s:sub(i), n)
    if piece == "" then piece = s:sub(i, i + 3) end
    out[#out + 1] = piece
    i = i + #piece
  end
  return out
end

-- opts.cap (default 512), opts.fixture (see above), opts.chunk (bytes per
-- streamed chunk, default 64).
function M.new(opts)
  opts = opts or {}
  local cap, fixture, chunk = opts.cap or 512, opts.fixture or {}, opts.chunk or 64
  local self = { name = "mock-summarizer", is_mock = true, calls = 0 }

  local function scripted(job)
    local per = fixture[job.key.level .. "/" .. job.key.index]
    return per and per[job.attempt.n]
  end

  -- The fake model server behind the mock transport.
  local function server(req)
    local job = req.job
    local s = scripted(job)
    if s and s.fail then
      return { http_status = s.fail == "retryable" and 503 or 400, chunks = {} }
    end
    local text
    if s and s.oversize then
      text = ("[mock oversize] "):rep(math.ceil(s.oversize / 16)):sub(1, s.oversize)
    elseif s and s.text then
      text = s.text
    else
      text = M.fake_text(job, cap)
    end
    return { http_status = 200, chunks = chunks_of(text, chunk) }
  end

  self.client = mocknet.new { server = server }

  function self:start(job, on_outcome)
    self.calls = self.calls + 1
    local sink = models.collect(on_outcome)
    return self.client:request {
      id = job.cmd, method = "POST", url = "mock://summarize", body = job.job,
      job = job, deadline_steps = 1000,
      on_chunk = sink.on_chunk, on_done = sink.on_done,
    }
  end

  function self:step() return self.client:step() end
  function self:pending() return self.client:pending() end
  return self
end

return M
