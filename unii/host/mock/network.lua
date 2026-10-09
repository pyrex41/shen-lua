-- unii/host/mock/network.lua -- MOCK transport implementing the network
-- contract (docs/contracts/network.md). No sockets, no TLS: a scripted
-- in-process "server" produces each response as a list of body chunks, and
-- every client:step() delivers at most one chunk per active request. It
-- exists to exercise the streaming, cancellation, deadline and bounded
-- buffering semantics that the real libcurl adapter (unii/host/network/,
-- built separately) must provide.
local M = {}
M.IS_MOCK = true

local Client = {}
Client.__index = Client

-- opts.server(req) -> { http_status=, headers=, chunks={...} }
--                   | { error="message" }   (transport failure)
-- opts.max_buffer_bytes  per-request response bound (default 1 MiB)
function M.new(opts)
  assert(type(opts) == "table" and type(opts.server) == "function", "mock network: server required")
  return setmetatable({
    server = opts.server, max_buffer = opts.max_buffer_bytes or 1048576,
    active = {}, order = {}, tick = 0, closed = false,
  }, Client)
end

local Req = {}
Req.__index = Req

local function finish(r, result)
  if r.done then return end
  r.done = true
  r.client.active[r.id] = nil
  result.bytes = r.received
  r.spec.on_done(result)
end

function Client:request(spec)
  assert(not self.closed, "mock network: client closed")
  assert(type(spec.id) == "string", "request id (command id) required")
  assert(type(spec.on_done) == "function", "on_done required")
  assert(not self.active[spec.id], "duplicate active request id " .. spec.id)
  local r = setmetatable({ client = self, id = spec.id, spec = spec, received = 0, next_chunk = 1,
                           started = self.tick, done = false }, Req)
  r.response = self.server(spec)
  self.active[spec.id] = r
  self.order[#self.order + 1] = r
  return r
end

-- Idempotent. After it returns no further on_chunk fires, and on_done
-- reports "cancelled" exactly once unless the request already finished.
function Req:cancel()
  finish(self, { status = "cancelled" })
end

-- Advance simulated time by one tick. Returns the number of callbacks fired.
function Client:step()
  self.tick = self.tick + 1
  local fired = 0
  local keep = {}
  for _, r in ipairs(self.order) do
    if not r.done then
      local spec, resp = r.spec, r.response
      if spec.deadline_steps and self.tick - r.started > spec.deadline_steps then
        finish(r, { status = "timeout" }); fired = fired + 1
      elseif resp.error then
        finish(r, { status = "error", error = resp.error }); fired = fired + 1
      else
        if r.next_chunk == 1 and spec.on_headers and not r.headers_sent then
          r.headers_sent = true
          spec.on_headers(resp.http_status or 200, resp.headers or {}); fired = fired + 1
        end
        local chunk = resp.chunks[r.next_chunk]
        if chunk == nil then
          finish(r, { status = "ok", http_status = resp.http_status or 200 }); fired = fired + 1
        elseif r.received + #chunk > (spec.max_response_bytes or self.max_buffer) then
          finish(r, { status = "overflow", error = "response exceeds buffer bound" }); fired = fired + 1
        else
          r.next_chunk = r.next_chunk + 1
          r.received = r.received + #chunk
          if spec.on_chunk then spec.on_chunk(chunk); fired = fired + 1 end
        end
      end
      if not r.done then keep[#keep + 1] = r end
    end
  end
  self.order = keep
  return fired
end

function Client:pending() return #self.order end

function Client:close()
  for _, r in ipairs(self.order) do r:cancel() end
  self.order, self.closed = {}, true
end

return M
