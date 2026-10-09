-- unii/host/mock/network.lua -- MOCK transport with the same Lua interface
-- as the real libcurl adapter (unii/host/network/, docs/contracts/network.md).
-- No sockets, no TLS, no wall clock: a scripted in-process "server" answers
-- each request, and every client:tick() advances a simulated clock by
-- opts.tick_ms and delivers at most one body chunk per live request.
--
-- A server returns a script per request:
--   { status = 200, headers = {...}, chunks = { "raw body bytes", ... } }
--   { status = 200, sse = { "data payload", ..., "[DONE]" } }   -- framed as SSE
--   { fail = "connect" | "dns" | "tls" | "bad_url" | "protocol" }  -- before send
--   { ..., drop_after = N }   -- request sent, N chunks delivered, then the
--                             -- connection drops: outcome "uncertain"
--   { stall = true }          -- request sent, nothing comes back until the
--                             -- timeout: outcome "uncertain", reason "timeout"
-- Outcomes, reasons and the `sent` flag follow the real adapter's rules.
local sse = require("unii.host.network.sse")
local json = require("unii.host.network.json")

local M = {}
M.IS_MOCK = true
M.DEFAULT_MAX_INFLIGHT = 9

local Client = {}
Client.__index = Client
local Handle = {}
Handle.__index = Handle

-- opts.server(spec) -> script; opts.max_inflight (default 9);
-- opts.max_body_bytes (default 4 MiB); opts.tick_ms (default 10);
-- opts.timeout_ms (default 60000).
function M.client(opts)
  assert(type(opts) == "table" and type(opts.server) == "function", "mock network: server required")
  return setmetatable({
    server = opts.server, max_inflight = opts.max_inflight or M.DEFAULT_MAX_INFLIGHT,
    max_body_bytes = opts.max_body_bytes or 4 * 1024 * 1024, tick_ms = opts.tick_ms or 10,
    timeout_ms = opts.timeout_ms or 60000, now = 0, live = {}, closed = false, hits = {},
  }, Client)
end

function Handle:cancel()
  local r = self._req
  if r.finished then return end
  r.cancel_requested = true
end

function Handle:done() return self._req.finished end

local function finish(r, outcome, reason)
  if r.finished then return end
  r.finished = true
  r.handle.result = {
    outcome = outcome, reason = reason, status = r.status_seen, headers = r.headers_seen,
    body = r.store_body and table.concat(r.stored) or nil, sent = r.sent,
    bytes_received = r.received, attempts = 1, id = r.id, curl_code = 0, curl_error = "",
  }
end

local function frame_sse(events)
  local out = {}
  for i, data in ipairs(events) do out[i] = "data: " .. data .. "\n\n" end
  return out
end

function Client:request(spec)
  if self.closed then return nil, "client is closed" end
  if #self.live >= self.max_inflight then
    return nil, "inflight cap reached (" .. self.max_inflight .. ")"
  end
  if type(spec.url) ~= "string" or spec.url == "" then return nil, "url is required" end
  local body = spec.body
  if type(body) == "table" then body = json.encode(body) end
  local script = self.server { id = spec.id, url = spec.url, headers = spec.headers or {}, body = body }
  local on_chunk, on_event, on_delta = spec.on_chunk, spec.on_event, spec.on_delta
  local store_body = spec.store_body
  if store_body == nil then store_body = not (on_chunk or on_event or on_delta) end
  local r = {
    id = spec.id or ("net-" .. tostring(#self.hits + 1)), spec = spec, script = script,
    chunks = script.sse and frame_sse(script.sse) or script.chunks or {}, next = 1,
    received = 0, stored = {}, store_body = store_body, sent = false, finished = false,
    started = self.now, timeout_ms = spec.timeout_ms or self.timeout_ms,
    max_body = spec.max_body_bytes or self.max_body_bytes,
    parser = (on_event or on_delta or spec.parse_sse) and sse.new() or nil,
  }
  r.handle = setmetatable({ id = r.id, _req = r }, Handle)
  self.live[#self.live + 1] = r
  return r.handle
end

function Client:chat_stream(opts)
  local payload = {}
  for k, v in pairs(opts.payload or {}) do payload[k] = v end
  payload.stream = true
  local headers = { ["Content-Type"] = "application/json", ["Accept"] = "text/event-stream" }
  if opts.api_key then headers["Authorization"] = "Bearer " .. opts.api_key end
  for k, v in pairs(opts.headers or {}) do headers[k] = v end
  return self:request {
    id = opts.id, method = "POST", url = opts.url, headers = headers, body = json.encode(payload),
    timeout_ms = opts.timeout_ms, max_body_bytes = opts.max_body_bytes,
    on_chunk = opts.on_chunk, on_event = opts.on_event, on_delta = opts.on_delta, on_done = opts.on_done,
  }
end

-- Mirrors the adapter's delivery: raw chunk, then SSE events, decoded JSON,
-- the first choice's delta text, and on_done for the [DONE] sentinel.
local function emit(r, chunk)
  local spec = r.spec
  if spec.on_chunk then spec.on_chunk(chunk, r.handle) end
  if not r.parser then return end
  local events, err = r.parser:push(chunk)
  if not events then r.sse_overflow = err; return end
  for _, ev in ipairs(events) do
    if r.cancel_requested then return end
    if ev.data and not ev.done then ev.json, ev.json_error = json.decode(ev.data) end
    if spec.on_event then spec.on_event(ev, r.handle) end
    local j = ev.json
    local choice = type(j) == "table" and type(j.choices) == "table" and j.choices[1] or nil
    local delta = type(choice) == "table" and choice.delta or nil
    local content = type(delta) == "table" and delta.content or nil
    if spec.on_delta and type(content) == "string" and content ~= "" then
      spec.on_delta(content, j, r.handle)
    end
    if spec.on_done and ev.done then spec.on_done(r.handle) end
  end
end

local function step(self, r)
  local s = r.script
  if r.cancel_requested then return finish(r, "cancelled", "cancelled") end
  if s.fail then return finish(r, "failed", s.fail) end
  if not r.sent then
    r.sent = true
    self.hits[#self.hits + 1] = r.id
  end
  if self.now - r.started > r.timeout_ms then
    return finish(r, "uncertain", "timeout")
  end
  if s.stall then return end
  if r.status_seen == nil then
    r.status_seen, r.headers_seen = s.status or 200, s.headers or {}
  end
  if s.drop_after and r.next > s.drop_after then return finish(r, "uncertain", "dropped") end
  local chunk = r.chunks[r.next]
  if chunk == nil then return finish(r, "succeeded", "complete") end
  if r.received + #chunk > r.max_body then return finish(r, "failed", "body_limit") end
  r.next = r.next + 1
  r.received = r.received + #chunk
  if r.store_body then r.stored[#r.stored + 1] = chunk end
  local ok, err = pcall(emit, r, chunk)
  if not ok then
    r.callback_error = tostring(err)
    return finish(r, "failed", "callback")
  end
  if r.sse_overflow then return finish(r, "failed", "sse_limit") end
end

-- Advance simulated time and make one round of progress on every live
-- request. wait_ms is accepted for interface parity; time moves by tick_ms.
function Client:tick(_wait_ms)
  if self.closed then error("client is closed") end
  if self.in_tick then error("client:tick is not re-entrant") end
  self.in_tick = true
  self.now = self.now + self.tick_ms
  local snapshot = { unpack(self.live) }
  local ok, err = pcall(function()
    for _, r in ipairs(snapshot) do
      if not r.finished then step(self, r) end
    end
  end)
  local keep = {}
  for _, r in ipairs(self.live) do
    if not r.finished then keep[#keep + 1] = r end
  end
  self.live = keep
  self.in_tick = false
  if not ok then error(err) end
  return #self.live
end

function Client:inflight() return #self.live end

function Client:close()
  if self.closed then return end
  for _, r in ipairs(self.live) do r.cancel_requested = true; finish(r, "cancelled", "cancelled") end
  self.live, self.closed = {}, true
end

return M
