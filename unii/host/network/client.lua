-- Non-blocking HTTP client for the unii supervisor.
--
-- One libcurl multi handle is driven by client:tick(wait_ms). wait_ms == 0
-- does not sleep. Completions are classified and never retried:
--   succeeded  a complete HTTP response (any status code)
--   failed     the HTTP request was not transmitted, or this process aborted
--              it locally (body cap, caller callback error)
--   uncertain  request bytes were transmitted and the transfer did not finish
--              (drop, reset, timeout after send). Do not automatically retry.
--   cancelled  the caller cancelled. sent=true means the provider may already
--              have seen the request; cancellation does not undo that.
--
-- Callbacks run outside curl_multi_perform, so they may cancel a handle.
-- They must not call client:tick (the event loop is not re-entrant).

local ffi = require("ffi")
local curl = require("unii.host.network.curl_ffi")
local sse = require("unii.host.network.sse")
local json = require("unii.host.network.json")
local redact = require("unii.host.network.redact")

local MAX_SUMMARY_INFLIGHT = 8
local MAX_TURN_INFLIGHT = 1
local DEFAULT_MAX_INFLIGHT = MAX_SUMMARY_INFLIGHT + MAX_TURN_INFLIGHT
local DEFAULT_TIMEOUT_MS = 60000
local DEFAULT_CONNECT_TIMEOUT_MS = 10000
local DEFAULT_MAX_BODY = 4 * 1024 * 1024

local OUTCOME = {
  succeeded = "succeeded",
  failed = "failed",
  uncertain = "uncertain",
  cancelled = "cancelled",
}

local REASON = {
  complete = "complete",
  cancelled = "cancelled",
  timeout = "timeout",
  tls = "tls",
  connect = "connect",
  dns = "dns",
  dropped = "dropped",
  body_limit = "body_limit",
  sse_limit = "sse_limit",
  callback = "callback",
  bad_url = "bad_url",
  protocol = "protocol",
  curl = "curl",
}

local Handle = {}
Handle.__index = Handle

function Handle:cancel()
  local req = self._req
  if req.finished or req.cancel_requested then return end
  req.cancel_requested = true
end

function Handle:done()
  return self._req.finished == true
end

local Client = {}
Client.__index = Client
-- LuaJIT finalizes tables. A client that drops out of scope still releases
-- the multi handle; explicit close() remains the normal path.

local next_token = 0

local function ptr_key(p)
  return tostring(ffi.cast("uintptr_t", p))
end

local function sanitize_id(id)
  id = tostring(id)
  id = id:gsub("[%c]", "")
  if #id > 128 then id = id:sub(1, 128) end
  if id == "" then id = "request" end
  return id
end

local function classify(req, code, status, from_curl_done)
  if req.overflow then
    return OUTCOME.failed, REASON.body_limit
  end
  if req.sse_overflow then
    return OUTCOME.failed, REASON.sse_limit
  end
  -- A completed HTTP response stays succeeded even if the caller's callback
  -- threw while consuming the last chunk. callback_error is still recorded.
  local completed_ok = from_curl_done and code == curl.CURLE_OK and status and status > 0
  if req.callback_abort and not completed_ok then
    return OUTCOME.failed, REASON.callback
  end
  if req.cancel_requested and not from_curl_done then
    return OUTCOME.cancelled, REASON.cancelled
  end
  if from_curl_done and req.cancel_requested and not req.overflow
      and (code == curl.CURLE_WRITE_ERROR or code == curl.CURLE_ABORTED_BY_CALLBACK) then
    return OUTCOME.cancelled, REASON.cancelled
  end
  if code == curl.CURLE_OK and status and status > 0 then
    return OUTCOME.succeeded, REASON.complete
  end
  if code == curl.CURLE_OK then
    if req.sent then return OUTCOME.uncertain, REASON.dropped end
    return OUTCOME.failed, REASON.protocol
  end
  if code == curl.CURLE_OPERATION_TIMEDOUT then
    if req.sent then return OUTCOME.uncertain, REASON.timeout end
    return OUTCOME.failed, REASON.timeout
  end
  if curl.PRE_SEND[code] then
    local reason = REASON.connect
    if curl.tls_code(code) then
      reason = REASON.tls
    elseif code == curl.CURLE_URL_MALFORMAT then
      reason = REASON.bad_url
    elseif code == curl.CURLE_UNSUPPORTED_PROTOCOL then
      reason = REASON.protocol
    elseif code == curl.CURLE_COULDNT_RESOLVE_HOST
        or code == curl.CURLE_COULDNT_RESOLVE_PROXY then
      reason = REASON.dns
    end
    return OUTCOME.failed, reason
  end
  if req.sent then
    return OUTCOME.uncertain, REASON.dropped
  end
  return OUTCOME.failed, REASON.curl
end

local function header_lines(headers)
  local lines = {}
  local saw_expect = false
  if headers == nil then headers = {} end
  if type(headers) ~= "table" then
    return nil, "headers must be a table"
  end
  local function add(name, value)
    if type(name) ~= "string" or type(value) ~= "string" then
      return "header name and value must be strings"
    end
    if name:find("[\r\n:]") or value:find("[\r\n]") then
      return "header contains CR, LF, or a colon in the name"
    end
    if name:lower() == "expect" then saw_expect = true end
    lines[#lines + 1] = name .. ": " .. value
    return nil
  end
  if headers[1] ~= nil then
    for i = 1, #headers do
      local line = headers[i]
      if type(line) ~= "string" or line:find("[\r\n]") then
        return nil, "header list entries must be single-line strings"
      end
      local name = line:match("^([^:]+):")
      if not name then return nil, "header list entry needs a colon" end
      if name:lower() == "expect" then saw_expect = true end
      lines[#lines + 1] = line
    end
  else
    for name, value in pairs(headers) do
      local err = add(name, value)
      if err then return nil, err end
    end
  end
  if not saw_expect then
    -- Stop curl waiting on 100-continue for larger bodies.
    lines[#lines + 1] = "Expect:"
  end
  return lines
end

function Client:_log(level, msg)
  if not self.log then return end
  local ok, err = pcall(self.log, level, redact.text(msg))
  if not ok then
    -- A broken log sink must not take down the event loop, and the error
    -- itself is redacted before it is dropped on the floor.
    self._log_error = redact.text(tostring(err))
  end
end

function Client:_install_callbacks()
  local live = self.live
  self._write_cb = ffi.cast("unii_curl_write_cb", function(ptr, size, nmemb, userdata)
    local nbytes = tonumber(size) * tonumber(nmemb)
    if nbytes == 0 then return 0 end
    local ok, ret = pcall(function()
      local id = tonumber(ffi.cast("intptr_t*", userdata)[0])
      local req = live[id]
      if not req or req.cancel_requested or req.overflow then
        return curl.WRITEFUNC_ERROR
      end
      local chunk = ffi.string(ptr, nbytes)
      req.bytes_received = req.bytes_received + #chunk
      if req.store_body then
        if req.stored_n + #chunk > req.max_body_bytes then
          req.overflow = true
          return curl.WRITEFUNC_ERROR
        end
        req.stored[#req.stored + 1] = chunk
        req.stored_n = req.stored_n + #chunk
      end
      if req.pending_bytes + #chunk > req.max_body_bytes then
        req.overflow = true
        return curl.WRITEFUNC_ERROR
      end
      req.pending[#req.pending + 1] = chunk
      req.pending_bytes = req.pending_bytes + #chunk
      return nbytes
    end)
    if not ok then
      return curl.WRITEFUNC_ERROR
    end
    return ret
  end)

  self._header_cb = ffi.cast("unii_curl_write_cb", function(ptr, size, nmemb, userdata)
    local nbytes = tonumber(size) * tonumber(nmemb)
    local ok = pcall(function()
      local id = tonumber(ffi.cast("intptr_t*", userdata)[0])
      local req = live[id]
      if not req then return end
      local line = ffi.string(ptr, nbytes)
      line = line:gsub("\r\n$", ""):gsub("\n$", "")
      if line == "" then return end
      local code = line:match("^HTTP/%d%.%d%s+(%d%d%d)")
      if code then
        req.status = tonumber(code)
        req.header_map = {}
        return
      end
      local name, value = line:match("^([^:]+):%s*(.*)$")
      if name then
        name = name:lower()
        local prev = req.header_map[name]
        if prev then
          req.header_map[name] = prev .. ", " .. value
        else
          req.header_map[name] = value
        end
      end
    end)
    if not ok then return curl.WRITEFUNC_ERROR end
    return nbytes
  end)

  -- Counts outbound HTTP bytes. The buffer is never copied into a Lua
  -- string: HEADER_OUT contains Authorization and must not reach logs.
  self._debug_cb = ffi.cast("unii_curl_debug_cb", function(_handle, type_, _data, size, userdata)
    local ok = pcall(function()
      local id = tonumber(ffi.cast("intptr_t*", userdata)[0])
      local req = live[id]
      if not req then return end
      local t = tonumber(type_)
      if t == curl.INFO_HEADER_OUT or t == curl.INFO_DATA_OUT then
        req.saw_request_bytes = true
        req.outgoing_bytes = req.outgoing_bytes + tonumber(size)
      end
    end)
    if not ok then return 0 end
    return 0
  end)
end

function Client:inflight()
  local n = 0
  for _ in pairs(self.live) do n = n + 1 end
  return n
end

function Client:_perform()
  local running = self._running
  for _ = 1, 8 do
    local rc = tonumber(curl.lib.curl_multi_perform(self.multi, running))
    if rc ~= curl.CURLM_CALL_MULTI_PERFORM then
      if rc ~= curl.CURLM_OK then
        self:_log("error", "curl_multi_perform " .. curl.multi_strerror(rc))
      end
      return
    end
  end
end

function Client:_poll(wait_ms)
  local rc = tonumber(curl.lib.curl_multi_poll(
    self.multi, nil, 0, wait_ms, self._poll_ret))
  if rc ~= curl.CURLM_OK then
    self:_log("error", "curl_multi_poll " .. curl.multi_strerror(rc))
  end
end

local function snapshot_sent(req)
  local uploaded = 0
  if req.easy ~= nil then
    uploaded = curl.get_off(req.easy, curl.SIZE_UPLOAD_T) or 0
  end
  req.sent = req.saw_request_bytes or uploaded > 0
  if req.outgoing_bytes > 0 then
    req.bytes_sent = req.outgoing_bytes
  else
    req.bytes_sent = uploaded
  end
end

function Client:_finish(req, code, from_curl_done)
  if req.finished then return end
  snapshot_sent(req)
  local status = req.status
  local outcome, reason = classify(req, code, status, from_curl_done)
  local err_text = ""
  if req.errbuf ~= nil then
    err_text = ffi.string(req.errbuf)
  end
  if err_text == "" and code ~= curl.CURLE_OK then
    err_text = curl.strerror(code)
  end
  err_text = redact.text(err_text or "")
  local body
  if req.store_body then
    body = table.concat(req.stored)
  end
  local result = {
    outcome = outcome,
    reason = reason,
    status = status,
    headers = req.header_map,
    body = body,
    bytes_sent = req.bytes_sent,
    bytes_received = req.bytes_received,
    sent = req.sent,
    curl_code = code,
    curl_error = err_text,
    events = req.sse_events,
    attempts = 1,
    id = req.public_id,
    callback_error = req.callback_error,
  }
  req.result = result
  req.handle.result = result
  req.finished = true
  self:_release(req)
  self:_log("info", string.format(
    "done id=%s outcome=%s reason=%s status=%s sent=%s curl=%s in=%d out=%d",
    req.public_id, outcome, reason, status and tostring(status) or "-",
    tostring(req.sent), tostring(code), req.bytes_received, req.bytes_sent))
end

function Client:_release(req)
  if req.easy ~= nil then
    local key = ptr_key(req.easy)
    if req.added then
      curl.lib.curl_multi_remove_handle(self.multi, req.easy)
      req.added = false
    end
    curl.lib.curl_easy_cleanup(req.easy)
    req.easy = nil
    self.by_easy[key] = nil
  end
  if req.slist ~= nil then
    curl.lib.curl_slist_free_all(req.slist)
    req.slist = nil
  end
  self.live[req.token_id] = nil
end

function Client:_apply_cancels()
  local ids = {}
  for id, req in pairs(self.live) do
    if req.cancel_requested and not req.finished then
      ids[#ids + 1] = id
    end
  end
  for i = 1, #ids do
    local req = self.live[ids[i]]
    if req and not req.finished then
      -- Drop anything already pulled off the socket but not yet delivered
      -- only when the caller cancelled before this delivery pass. Bytes
      -- already handed to on_delta stay delivered.
      self:_finish(req, curl.CURLE_ABORTED_BY_CALLBACK)
    end
  end
end

function Client:_emit(req, chunk)
  if req.on_chunk then
    req.on_chunk(chunk, req.handle)
  end
  if not req.parser then return end
  local events, err = req.parser:push(chunk)
  if not events then
    req.sse_overflow = true
    req.cancel_requested = true
    req.callback_error = err
    return
  end
  for i = 1, #events do
    if req.cancel_requested or req.finished then return end
    local ev = events[i]
    req.sse_events = req.sse_events + 1
    if req.want_delta and ev.data and not ev.done then
      local decoded, dec_err = json.decode(ev.data)
      ev.json = decoded
      ev.json_error = dec_err
    end
    if req.on_event then
      req.on_event(ev, req.handle)
    end
    if req.on_delta and not ev.done and type(ev.json) == "table" then
      local choices = ev.json.choices
      local choice = type(choices) == "table" and choices[1] or nil
      local delta = choice and type(choice) == "table" and choice.delta or nil
      local content = delta and type(delta) == "table" and delta.content or nil
      if type(content) == "string" and content ~= "" then
        req.on_delta(content, ev.json, req.handle)
      end
    end
    if req.on_done and ev.done then
      req.on_done(req.handle)
    end
  end
end

function Client:_deliver()
  local ids = {}
  for id in pairs(self.live) do ids[#ids + 1] = id end
  for i = 1, #ids do
    local req = self.live[ids[i]]
    if req and not req.finished then
      local pending = req.pending
      req.pending = {}
      req.pending_bytes = 0
      for c = 1, #pending do
        if req.cancel_requested or req.finished or req.callback_abort then break end
        local ok, err = pcall(self._emit, self, req, pending[c])
        if not ok then
          req.callback_abort = true
          req.callback_error = redact.text(tostring(err))
          req.cancel_requested = true
          break
        end
      end
    end
  end
end

function Client:_take_completions()
  -- Copy messages out immediately. curl reuses the CURLMsg on the next read.
  local done = {}
  local queue = self._queue
  while true do
    local msg = curl.lib.curl_multi_info_read(self.multi, queue)
    if msg == nil then break end
    if tonumber(msg.msg) == curl.CURLMSG_DONE then
      done[#done + 1] = {
        key = ptr_key(msg.easy_handle),
        code = tonumber(msg.data.result),
      }
    end
  end
  return done
end

function Client:_finish_done(done)
  for i = 1, #done do
    local req = self.by_easy[done[i].key]
    if req and not req.finished then
      self:_finish(req, done[i].code, true)
    end
  end
end

function Client:_cycle(wait_ms)
  self:_apply_cancels()
  self:_perform()
  local done = self:_take_completions()
  self:_deliver()
  self:_finish_done(done)
  -- poll(0) refreshes readiness without sleeping, so a zero wait still
  -- observes sockets that became readable since the first perform.
  self:_apply_cancels()
  if self:inflight() > 0 then
    self:_poll(wait_ms)
    self:_perform()
    done = self:_take_completions()
    self:_deliver()
    self:_finish_done(done)
    self:_apply_cancels()
  end
end

function Client:tick(wait_ms)
  if self.closed then error("client is closed") end
  if self.in_tick then error("client:tick is not re-entrant") end
  wait_ms = tonumber(wait_ms) or 0
  if wait_ms < 0 then wait_ms = 0 end
  self.in_tick = true
  local ok, err = pcall(self._cycle, self, wait_ms)
  self.in_tick = false
  if not ok then error(err) end
  return self:inflight()
end

function Client:run_until_idle(slice_ms, max_ticks)
  slice_ms = slice_ms or 50
  max_ticks = max_ticks or 2000
  local spins = 0
  while self:inflight() > 0 do
    self:tick(slice_ms)
    spins = spins + 1
    if spins > max_ticks then
      error("run_until_idle exceeded " .. tostring(max_ticks) .. " ticks")
    end
  end
end

local function build_slist(lines)
  local slist = nil
  for i = 1, #lines do
    local line = lines[i]
    local tmp = ffi.new("char[?]", #line + 1)
    ffi.copy(tmp, line)
    local next_list = curl.lib.curl_slist_append(slist, tmp)
    if next_list == nil then
      if slist ~= nil then curl.lib.curl_slist_free_all(slist) end
      return nil, "curl_slist_append failed"
    end
    slist = next_list
  end
  return slist
end

function Client:request(opts)
  if self.closed then return nil, "client is closed" end
  opts = opts or {}
  if self:inflight() >= self.max_inflight then
    return nil, "inflight cap reached (" .. tostring(self.max_inflight) .. ")"
  end
  local url = opts.url
  if type(url) ~= "string" or url == "" then
    return nil, "url is required"
  end
  if url:find("[\r\n]") then
    return nil, "url contains CR or LF"
  end
  local body = opts.body
  if body ~= nil and type(body) ~= "string" then
    if type(body) == "table" then
      local ok, encoded = pcall(json.encode, body)
      if not ok then return nil, "body encode failed" end
      body = encoded
    else
      return nil, "body must be a string or a json table"
    end
  end
  local method = opts.method
  if method == nil then
    method = body and "POST" or "GET"
  end
  if type(method) ~= "string" then return nil, "method must be a string" end
  method = method:upper()
  if not method:match("^[A-Z]+$") then return nil, "method has invalid characters" end

  local timeout_ms = tonumber(opts.timeout_ms) or self.timeout_ms
  local connect_timeout_ms = tonumber(opts.connect_timeout_ms) or self.connect_timeout_ms
  if timeout_ms <= 0 or connect_timeout_ms <= 0 then
    return nil, "timeouts must be positive"
  end
  local verify = opts.verify_tls
  if verify == nil then verify = true end
  local max_body = tonumber(opts.max_body_bytes) or self.max_body_bytes
  if max_body <= 0 then return nil, "max_body_bytes must be positive" end

  local on_chunk = opts.on_chunk
  local on_event = opts.on_event
  local on_delta = opts.on_delta
  local on_done = opts.on_done
  local store_body = opts.store_body
  if store_body == nil then
    store_body = not (on_chunk or on_event or on_delta)
  end

  local lines, herr = header_lines(opts.headers)
  if not lines then return nil, herr end

  local easy = curl.lib.curl_easy_init()
  if easy == nil then return nil, "curl_easy_init failed" end

  next_token = next_token + 1
  local token_id = next_token
  local public_id = sanitize_id(opts.id or ("net-" .. tostring(token_id)))

  local req = {
    token_id = token_id,
    token = ffi.new("intptr_t[1]", token_id),
    public_id = public_id,
    easy = easy,
    method = method,
    url_buf = ffi.new("char[?]", #url + 1),
    errbuf = ffi.new("char[?]", curl.ERROR_SIZE),
    header_map = {},
    pending = {},
    pending_bytes = 0,
    stored = {},
    stored_n = 0,
    store_body = store_body == true,
    max_body_bytes = max_body,
    bytes_received = 0,
    bytes_sent = 0,
    outgoing_bytes = 0,
    saw_request_bytes = false,
    sent = false,
    sse_events = 0,
    on_chunk = on_chunk,
    on_event = on_event,
    on_delta = on_delta,
    on_done = on_done,
    want_delta = on_delta ~= nil or on_event ~= nil,
    added = false,
    finished = false,
    cancel_requested = false,
  }
  ffi.copy(req.url_buf, url)
  req.handle = setmetatable({ id = public_id, _req = req }, Handle)

  if on_event or on_delta or opts.parse_sse then
    req.parser = sse.new(max_body)
  end

  local function fail(msg)
    curl.lib.curl_easy_cleanup(easy)
    req.easy = nil
    if req.slist ~= nil then
      curl.lib.curl_slist_free_all(req.slist)
      req.slist = nil
    end
    return nil, msg
  end

  local function setopt_ok(rc, what)
    if rc ~= 0 then
      return fail(what .. " failed (" .. tostring(rc) .. ")")
    end
    return true
  end

  local token_ptr = ffi.cast("void*", req.token)
  if not setopt_ok(curl.set_ptr(easy, curl.URL, req.url_buf), "CURLOPT_URL") then
    return nil, "CURLOPT_URL failed"
  end
  if not setopt_ok(curl.set_ptr(easy, curl.ERRORBUFFER, req.errbuf), "CURLOPT_ERRORBUFFER") then
    return nil, "CURLOPT_ERRORBUFFER failed"
  end
  if not setopt_ok(curl.set_ptr(easy, curl.WRITEFUNCTION, self._write_cb), "CURLOPT_WRITEFUNCTION") then
    return nil, "CURLOPT_WRITEFUNCTION failed"
  end
  if not setopt_ok(curl.set_ptr(easy, curl.WRITEDATA, token_ptr), "CURLOPT_WRITEDATA") then
    return nil, "CURLOPT_WRITEDATA failed"
  end
  if not setopt_ok(curl.set_ptr(easy, curl.HEADERFUNCTION, self._header_cb), "CURLOPT_HEADERFUNCTION") then
    return nil, "CURLOPT_HEADERFUNCTION failed"
  end
  if not setopt_ok(curl.set_ptr(easy, curl.HEADERDATA, token_ptr), "CURLOPT_HEADERDATA") then
    return nil, "CURLOPT_HEADERDATA failed"
  end
  if not setopt_ok(curl.set_ptr(easy, curl.DEBUGFUNCTION, self._debug_cb), "CURLOPT_DEBUGFUNCTION") then
    return nil, "CURLOPT_DEBUGFUNCTION failed"
  end
  if not setopt_ok(curl.set_ptr(easy, curl.DEBUGDATA, token_ptr), "CURLOPT_DEBUGDATA") then
    return nil, "CURLOPT_DEBUGDATA failed"
  end
  -- Verbose routes debug traffic into our callback (which does not copy
  -- header bytes) instead of stderr.
  if not setopt_ok(curl.set_long(easy, curl.VERBOSE, 1), "CURLOPT_VERBOSE") then
    return nil, "CURLOPT_VERBOSE failed"
  end
  if not setopt_ok(curl.set_long(easy, curl.NOSIGNAL, 1), "CURLOPT_NOSIGNAL") then
    return nil, "CURLOPT_NOSIGNAL failed"
  end
  if not setopt_ok(curl.set_long(easy, curl.TCP_NODELAY, 1), "CURLOPT_TCP_NODELAY") then
    return nil, "CURLOPT_TCP_NODELAY failed"
  end
  if not setopt_ok(curl.set_long(easy, curl.TIMEOUT_MS, timeout_ms), "CURLOPT_TIMEOUT_MS") then
    return nil, "CURLOPT_TIMEOUT_MS failed"
  end
  if not setopt_ok(curl.set_long(easy, curl.CONNECTTIMEOUT_MS, connect_timeout_ms), "CURLOPT_CONNECTTIMEOUT_MS") then
    return nil, "CURLOPT_CONNECTTIMEOUT_MS failed"
  end
  if not setopt_ok(curl.set_long(easy, curl.PROTOCOLS, curl.PROTO_HTTP_HTTPS), "CURLOPT_PROTOCOLS") then
    return nil, "CURLOPT_PROTOCOLS failed"
  end
  if not setopt_ok(curl.set_long(easy, curl.REDIR_PROTOCOLS, curl.PROTO_HTTP_HTTPS), "CURLOPT_REDIR_PROTOCOLS") then
    return nil, "CURLOPT_REDIR_PROTOCOLS failed"
  end
  local http_version = opts.http_version or "1.1"
  local version_code = curl.HTTP_VERSION_1_1
  if http_version == "2" then version_code = curl.HTTP_VERSION_2TLS end
  if not setopt_ok(curl.set_long(easy, curl.HTTP_VERSION, version_code), "CURLOPT_HTTP_VERSION") then
    return nil, "CURLOPT_HTTP_VERSION failed"
  end
  local follow = opts.follow_redirects and 1 or 0
  if not setopt_ok(curl.set_long(easy, curl.FOLLOWLOCATION, follow), "CURLOPT_FOLLOWLOCATION") then
    return nil, "CURLOPT_FOLLOWLOCATION failed"
  end
  if not setopt_ok(curl.set_long(easy, curl.MAXREDIRS, opts.max_redirects or 0), "CURLOPT_MAXREDIRS") then
    return nil, "CURLOPT_MAXREDIRS failed"
  end
  local reuse = opts.forbid_reuse
  if reuse == nil then reuse = true end
  if not setopt_ok(curl.set_long(easy, curl.FORBID_REUSE, reuse and 1 or 0), "CURLOPT_FORBID_REUSE") then
    return nil, "CURLOPT_FORBID_REUSE failed"
  end
  if opts.fresh_connect then
    if not setopt_ok(curl.set_long(easy, curl.FRESH_CONNECT, 1), "CURLOPT_FRESH_CONNECT") then
      return nil, "CURLOPT_FRESH_CONNECT failed"
    end
  end

  if verify then
    if not setopt_ok(curl.set_long(easy, curl.SSL_VERIFYPEER, 1), "CURLOPT_SSL_VERIFYPEER") then
      return nil, "CURLOPT_SSL_VERIFYPEER failed"
    end
    if not setopt_ok(curl.set_long(easy, curl.SSL_VERIFYHOST, 2), "CURLOPT_SSL_VERIFYHOST") then
      return nil, "CURLOPT_SSL_VERIFYHOST failed"
    end
  else
    if not setopt_ok(curl.set_long(easy, curl.SSL_VERIFYPEER, 0), "CURLOPT_SSL_VERIFYPEER") then
      return nil, "CURLOPT_SSL_VERIFYPEER failed"
    end
    if not setopt_ok(curl.set_long(easy, curl.SSL_VERIFYHOST, 0), "CURLOPT_SSL_VERIFYHOST") then
      return nil, "CURLOPT_SSL_VERIFYHOST failed"
    end
  end
  if type(opts.ca_info) == "string" and opts.ca_info ~= "" then
    req.ca_buf = ffi.new("char[?]", #opts.ca_info + 1)
    ffi.copy(req.ca_buf, opts.ca_info)
    if not setopt_ok(curl.set_ptr(easy, curl.CAINFO, req.ca_buf), "CURLOPT_CAINFO") then
      return nil, "CURLOPT_CAINFO failed"
    end
  end
  if type(opts.ca_path) == "string" and opts.ca_path ~= "" then
    req.capath_buf = ffi.new("char[?]", #opts.ca_path + 1)
    ffi.copy(req.capath_buf, opts.ca_path)
    if not setopt_ok(curl.set_ptr(easy, curl.CAPATH, req.capath_buf), "CURLOPT_CAPATH") then
      return nil, "CURLOPT_CAPATH failed"
    end
  end

  local ua = opts.user_agent or self.user_agent
  req.ua_buf = ffi.new("char[?]", #ua + 1)
  ffi.copy(req.ua_buf, ua)
  if not setopt_ok(curl.set_ptr(easy, curl.USERAGENT, req.ua_buf), "CURLOPT_USERAGENT") then
    return nil, "CURLOPT_USERAGENT failed"
  end

  -- POST without CURLOPT_POSTFIELDS makes curl read the body from stdin.
  -- Every method other than a body-less GET gets an explicit buffer.
  if method == "GET" and body == nil then
    if not setopt_ok(curl.set_long(easy, curl.HTTPGET, 1), "CURLOPT_HTTPGET") then
      return nil, "CURLOPT_HTTPGET failed"
    end
  else
    if method == "POST" then
      if not setopt_ok(curl.set_long(easy, curl.POST, 1), "CURLOPT_POST") then
        return nil, "CURLOPT_POST failed"
      end
    else
      req.method_buf = ffi.new("char[?]", #method + 1)
      ffi.copy(req.method_buf, method)
      if not setopt_ok(curl.set_ptr(easy, curl.CUSTOMREQUEST, req.method_buf), "CURLOPT_CUSTOMREQUEST") then
        return nil, "CURLOPT_CUSTOMREQUEST failed"
      end
    end
    body = body or ""
    local n = #body
    req.body_buf = ffi.new("char[?]", math.max(n, 1))
    if n > 0 then ffi.copy(req.body_buf, body, n) end
    if not setopt_ok(curl.set_ptr(easy, curl.POSTFIELDS, req.body_buf), "CURLOPT_POSTFIELDS") then
      return nil, "CURLOPT_POSTFIELDS failed"
    end
    if not setopt_ok(curl.set_long(easy, curl.POSTFIELDSIZE, n), "CURLOPT_POSTFIELDSIZE") then
      return nil, "CURLOPT_POSTFIELDSIZE failed"
    end
  end

  local slist, serr = build_slist(lines)
  if not slist and serr then
    curl.lib.curl_easy_cleanup(easy)
    req.easy = nil
    return nil, serr
  end
  req.slist = slist
  if slist ~= nil then
    if not setopt_ok(curl.set_ptr(easy, curl.HTTPHEADER, slist), "CURLOPT_HTTPHEADER") then
      return nil, "CURLOPT_HTTPHEADER failed"
    end
  end

  local mrc = tonumber(curl.lib.curl_multi_add_handle(self.multi, easy))
  if mrc ~= curl.CURLM_OK then
    return fail("curl_multi_add_handle failed (" .. tostring(mrc) .. ")")
  end
  req.added = true
  self.live[token_id] = req
  self.by_easy[ptr_key(easy)] = req

  self:_log("info", string.format("start id=%s %s %s", public_id, method, redact.url(url)))
  return req.handle
end

function Client:chat_stream(opts)
  opts = opts or {}
  if type(opts.url) ~= "string" then
    return nil, "url is required"
  end
  local body = opts.body
  if opts.payload ~= nil then
    if type(opts.payload) ~= "table" then
      return nil, "payload must be a table"
    end
    local payload = {}
    for k, v in pairs(opts.payload) do payload[k] = v end
    payload.stream = true
    local ok, encoded = pcall(json.encode, payload)
    if not ok then return nil, "payload encode failed" end
    body = encoded
  end
  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "text/event-stream",
  }
  if opts.api_key ~= nil then
    if type(opts.api_key) ~= "string" or opts.api_key == "" then
      return nil, "api_key must be a non-empty string"
    end
    headers["Authorization"] = "Bearer " .. opts.api_key
  end
  if opts.headers then
    for k, v in pairs(opts.headers) do headers[k] = v end
  end
  return self:request({
    id = opts.id,
    method = "POST",
    url = opts.url,
    headers = headers,
    body = body,
    timeout_ms = opts.timeout_ms,
    connect_timeout_ms = opts.connect_timeout_ms,
    verify_tls = opts.verify_tls,
    ca_info = opts.ca_info,
    ca_path = opts.ca_path,
    max_body_bytes = opts.max_body_bytes,
    store_body = opts.store_body,
    on_chunk = opts.on_chunk,
    on_event = opts.on_event,
    on_delta = opts.on_delta,
    on_done = opts.on_done,
    http_version = opts.http_version,
    forbid_reuse = opts.forbid_reuse,
  })
end

function Client:close()
  if self.closed then return end
  local ids = {}
  for id, req in pairs(self.live) do
    ids[#ids + 1] = id
    if not req.cancel_requested then req.cancel_requested = true end
  end
  for i = 1, #ids do
    local req = self.live[ids[i]]
    if req and not req.finished then
      self:_finish(req, curl.CURLE_ABORTED_BY_CALLBACK)
    end
  end
  if self.multi ~= nil then
    curl.lib.curl_multi_cleanup(self.multi)
    self.multi = nil
  end
  if self._write_cb ~= nil then self._write_cb:free() end
  if self._header_cb ~= nil then self._header_cb:free() end
  if self._debug_cb ~= nil then self._debug_cb:free() end
  self._write_cb, self._header_cb, self._debug_cb = nil, nil, nil
  self.closed = true
end

Client.__gc = Client.close

local function new(opts)
  opts = opts or {}
  curl.global_init()
  local max_inflight = tonumber(opts.max_inflight) or DEFAULT_MAX_INFLIGHT
  if max_inflight < 1 then error("max_inflight must be >= 1") end
  local multi = curl.lib.curl_multi_init()
  if multi == nil then error("curl_multi_init failed") end
  local rc = curl.lib.curl_multi_setopt(multi, curl.CURLMOPT_MAX_TOTAL_CONNECTIONS,
    ffi.cast(ffi.typeof("long"), max_inflight))
  if tonumber(rc) ~= curl.CURLM_OK then
    curl.lib.curl_multi_cleanup(multi)
    error("curl_multi_setopt MAX_TOTAL_CONNECTIONS failed")
  end
  local self = setmetatable({
    multi = multi,
    live = {},
    by_easy = {},
    max_inflight = max_inflight,
    timeout_ms = tonumber(opts.timeout_ms) or DEFAULT_TIMEOUT_MS,
    connect_timeout_ms = tonumber(opts.connect_timeout_ms) or DEFAULT_CONNECT_TIMEOUT_MS,
    max_body_bytes = tonumber(opts.max_body_bytes) or DEFAULT_MAX_BODY,
    user_agent = opts.user_agent or "unii-network/0",
    log = opts.log,
    closed = false,
    in_tick = false,
    _running = ffi.new("int[1]"),
    _poll_ret = ffi.new("int[1]"),
    _queue = ffi.new("int[1]"),
  }, Client)
  self:_install_callbacks()
  return self
end

return {
  new = new,
  OUTCOME = OUTCOME,
  REASON = REASON,
  MAX_SUMMARY_INFLIGHT = MAX_SUMMARY_INFLIGHT,
  MAX_TURN_INFLIGHT = MAX_TURN_INFLIGHT,
  DEFAULT_MAX_INFLIGHT = DEFAULT_MAX_INFLIGHT,
  DEFAULT_TIMEOUT_MS = DEFAULT_TIMEOUT_MS,
  DEFAULT_CONNECT_TIMEOUT_MS = DEFAULT_CONNECT_TIMEOUT_MS,
  DEFAULT_MAX_BODY = DEFAULT_MAX_BODY,
}
