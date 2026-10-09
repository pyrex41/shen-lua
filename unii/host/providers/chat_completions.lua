-- unii/host/providers/chat_completions.lua -- summarizer over an
-- OpenAI-compatible /chat/completions stream.
--
-- The network client is injected: the real libcurl adapter
-- (require("unii.host.network").client{...}) or the MOCK transport
-- (require("unii.host.mock.network").client{...}). One submit-summary
-- command is one request; nothing here retries. Outcomes are classified by
-- models.classify, so a request that may have reached the provider without
-- a definite answer is reported as "uncertain" and the core parks the job.
--
-- The prompt is PROVISIONAL: the plan's summarization prompt (§6, §8) is
-- not specified yet. PROMPT_VERSION names what was sent.
local codec = require("unii.host.codec")
local json = require("unii.host.network.json")
local models = require("unii.host.models")

local M = {}
M.PROMPT_VERSION = "provisional-0"

local function system_prompt(cap, job)
  local s = ("Provisional summarization prompt (%s). Summarize the conversation material for a "
    .. "long-term memory. Keep names, numbers, decisions and open questions. Plain text, one "
    .. "paragraph, at most %d bytes of UTF-8."):format(M.PROMPT_VERSION, cap)
  local rt = job.attempt.retry
  if rt and rt._ == "retry-too-long" then
    s = s .. (" A previous attempt was %d bytes, over the limit: be shorter."):format(rt.bytes)
  elseif rt and rt._ == "retry-seek-shorter" then
    s = s .. (" The best attempt so far is %d bytes: try to be shorter without losing facts."):format(rt.bytes)
  end
  return s
end

local function user_content(job)
  if job.input._ == "leaf-input" then
    return job.input.kind .. ": " .. (job.source or "")
  end
  return "Earlier part:\n" .. job.input.left_text .. "\n\nLater part:\n" .. job.input.right_text
end

function M.messages(job, cap)
  return json.array {
    { role = "system", content = system_prompt(cap, job) },
    { role = "user", content = user_content(job) },
  }
end

-- opts.client (required), opts.url (required), opts.model (required),
-- opts.api_key (never journaled or logged), opts.cap (default 512),
-- opts.timeout_ms, opts.max_body_bytes, opts.name, opts.is_mock.
function M.new(opts)
  assert(opts.client and opts.url and opts.model, "chat_completions: client, url and model are required")
  local cap = opts.cap or 512
  local self = {
    name = opts.name or "chat-completions", is_mock = opts.is_mock == true,
    client = opts.client, calls = 0, live = {}, waiting = {},
  }

  local function report(entry, outcome)
    local ok, err = pcall(entry.on_outcome, outcome)
    if not ok then error(err, 0) end
  end

  local function finish(entry)
    local r = entry.handle.result
    local class, why = models.classify(r, entry.stream_done)
    if class then
      return report(entry, { ok = false, class = class, error = why })
    end
    local text = table.concat(entry.parts)
    if text == "" then
      return report(entry, { ok = false, class = "permanent", error = "empty summary" })
    end
    if not codec.valid_utf8(text) then
      return report(entry, { ok = false, class = "permanent", error = "summary is not valid UTF-8" })
    end
    report(entry, { ok = true, text = text })
  end

  local function launch(entry)
    local job = entry.job
    local handle, err = self.client:chat_stream {
      id = job.cmd, url = opts.url, api_key = opts.api_key, timeout_ms = opts.timeout_ms,
      max_body_bytes = opts.max_body_bytes,
      headers = { ["X-Unii-Job"] = job.job },
      payload = { model = opts.model, messages = M.messages(job, cap), max_tokens = cap },
      on_delta = function(text) entry.parts[#entry.parts + 1] = text end,
      on_done = function() entry.stream_done = true end,
    }
    if handle then
      entry.handle = handle
      self.live[#self.live + 1] = entry
      return true
    end
    if tostring(err):find("inflight cap", 1, true) then return false end
    report(entry, { ok = false, class = "permanent", error = "request refused: " .. tostring(err) })
    return true
  end

  -- A request the client refuses for lack of an inflight slot waits here
  -- and was never sent, so it costs no attempt.
  function self:start(job, on_outcome)
    self.calls = self.calls + 1
    local entry = { job = job, on_outcome = on_outcome, parts = {}, stream_done = false }
    if #self.waiting > 0 or not launch(entry) then self.waiting[#self.waiting + 1] = entry end
  end

  function self:step(wait_ms)
    while #self.waiting > 0 and launch(self.waiting[1]) do table.remove(self.waiting, 1) end
    if #self.live > 0 then self.client:tick(wait_ms or 0) end
    local keep = {}
    for _, entry in ipairs(self.live) do
      if entry.handle:done() then finish(entry) else keep[#keep + 1] = entry end
    end
    self.live = keep
  end

  function self:pending() return #self.live + #self.waiting end

  function self:close() for _, e in ipairs(self.live) do e.handle:cancel() end end

  return self
end

return M
