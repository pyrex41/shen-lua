-- unii/host/supervisor.lua -- the single serialized writer for one chat.
--
-- Every change goes through submit(event):
--   1. validate the event at the boundary (schema + codec);
--   2. run the pure transition;
--   3. render the view and hash view and state;
--   4. append one journal transaction (event, commands, decisions, view
--      revision and hash, state hash) and fsync it;
--   5. only then adopt the new state and hand commands to adapters.
-- Adapter callbacks never touch state: they push events into an inbox that
-- pump() feeds back through submit() in arrival order.
--
-- open() replays the journal through the same transition and refuses to
-- continue on any divergence from what was recorded (commands, decisions,
-- view hash, state hash), on a different rule bundle, or on a different
-- configuration. The view is never refit from current policy.
--
-- Before a provider starts a summary command, a dispatch record (kind
-- "dispatch", cmd, job) is journaled. A command with a dispatch record and
-- no journaled outcome was in flight when a previous process stopped: the
-- provider may have received it, so it is never sent again automatically.
-- dispatch_pending() submits summary-failed with class "uncertain" for it
-- and the core parks the job until an operator retries it.
local codec = require("unii.host.codec")
local schema = require("unii.host.schema")
local sha256 = require("unii.host.sha256")
local storage = require("unii.host.storage")
local manifest = require("unii.manifest")

local M = {}
local Sup = {}
Sup.__index = Sup

local function txn_bytes(fields) return codec.encode(codec.map(fields)) end

local function text_field(txn, k)
  local v = txn.v[k]
  if not v or v.t ~= "text" then error("journal record lacks text field " .. k, 0) end
  return v.v
end

function M.open(dir, opts)
  opts = opts or {}
  local core = opts.core or require("unii.host.core").boot()
  local store, info = storage.open(dir)
  local self = setmetatable({
    dir = dir, core = core, store = store, info = info, provider = opts.provider,
    on_client_event = opts.on_client_event or function() end,
    outstanding = {}, started = {}, intent = {}, inbox = {}, messages = {}, view_cache = nil,
    checkpoint_interval = opts.checkpoint_interval == nil and 32 or opts.checkpoint_interval,
  }, Sup)
  local ok, err = pcall(self._load, self, opts)
  if not ok then store:close(); error(err, 0) end
  return self
end

function Sup:_load(opts)
  local core, recs = self.core, self.store:records()
  if #recs == 0 then
    local cfg = opts.config or schema.config {}
    self.config = cfg
    self.state = core:init(cfg)
    self.store:append(txn_bytes {
      kind = codec.sym("init"),
      bundle = codec.text(core.bundle_hash),
      bundle_format = codec.int_of(manifest.bundle_format),
      storage_format = codec.int_of(manifest.storage_format),
      codec_version = codec.int_of(manifest.codec_version),
      shen_lua = codec.text(manifest.shen_lua.commit),
      config = schema.encode("config", cfg),
      state_hash = codec.text(core:state_hash(self.state)),
    })
    self:_refresh_view()
    return
  end

  local init = codec.decode(recs[1].payload)
  if init.v.kind.v ~= "init" then error("journal record 1 is not an init record", 0) end
  local recorded = text_field(init, "bundle")
  if recorded ~= core.bundle_hash then
    error(("journal was written by rule bundle %s; this build is %s. Refusing to replay under different rules.")
      :format(recorded:sub(1, 16), core.bundle_hash:sub(1, 16)), 0)
  end
  for _, k in ipairs { "bundle_format", "storage_format", "codec_version" } do
    if codec.to_number(init.v[k]) ~= manifest[k] then
      error(("journal %s %s is not supported by this build (%d)"):format(k, init.v[k].v, manifest[k]), 0)
    end
  end
  local cfg = schema.decode("config", init.v.config)
  if opts.config and codec.encode(schema.encode("config", opts.config)) ~= codec.encode(init.v.config) then
    error("configuration differs from the journal's policy epoch; a new epoch event is required (not implemented)", 0)
  end
  self.config = cfg
  self.state = core:init(cfg)
  if core:state_hash(self.state) ~= text_field(init, "state_hash") then
    error("replay divergence at seq 1: initial state hash", 0)
  end
  self:_refresh_view()
  -- Message text remains in blobs. The in-memory table contains only small
  -- metadata records with a lazy text accessor.
  for id, m in pairs(self.store:message_index()) do
    local meta = m
    self.messages[tonumber(id)] = setmetatable({ kind = meta.kind, date = meta.date }, {
      __index = function(_, k)
        if k == "text" then return self.store:get_blob(meta.hash, meta.bytes) end
      end,
    })
  end
  local start = self:_restore_checkpoint() or 1
  self.info.replay_start_seq = start + 1
  self.info.replayed_records = 0
  for rec in self.store:iter_records(start) do
    self:_replay(rec)
    self.info.replayed_records = self.info.replayed_records + 1
  end
end

local function checkpoint_int(cp, name)
  local v = cp.v[name]
  if not v or v.t ~= "int" then error("checkpoint lacks int field " .. name, 0) end
  return codec.to_number(v)
end

-- Try newest to oldest. Invalid/stale checkpoints are accelerators, not
-- authority: set them aside and continue from an older one or record one.
function Sup:_restore_checkpoint()
  for _, candidate in ipairs(self.store:checkpoint_candidates()) do
    local ok, seq_or_error = pcall(function()
      if candidate.error then error(candidate.error, 0) end
      local cp = codec.decode(candidate.payload)
      if cp.t ~= "map" or not cp.v.kind or cp.v.kind.v ~= "checkpoint" then
        error("not a checkpoint record", 0)
      end
      local seq = checkpoint_int(cp, "seq")
      if seq < 1 or seq >= self.store.next_seq then error("stale journal position", 0) end
      if text_field(cp, "anchor") ~= self.store:record_anchor(seq) then error("stale journal anchor", 0) end
      if text_field(cp, "bundle") ~= self.core.bundle_hash then error("different rule bundle", 0) end
      if codec.encode(cp.v.config) ~= codec.encode(schema.encode("config", self.config)) then
        error("different configuration", 0)
      end
      local state = codec.to_shen(cp.v.state)
      if self.core:state_hash(state) ~= text_field(cp, "state_hash") then error("state hash mismatch", 0) end
      local invariant_errors = self.core:invariant_errors(state)
      if #invariant_errors > 0 then
        error("state invariants failed: " .. table.concat(invariant_errors, "; "), 0)
      end
      local rendered = self.core:render(state)
      if sha256.hex(rendered) ~= text_field(cp, "view_hash") then error("view hash mismatch", 0) end
      if self.core:status(state).rev ~= checkpoint_int(cp, "view_rev") then error("view revision mismatch", 0) end
      local outstanding = {}
      if not cp.v.outstanding or cp.v.outstanding.t ~= "list" then error("missing outstanding commands", 0) end
      for _, tagged in ipairs(cp.v.outstanding.v) do
        local command = schema.decode("command", tagged)
        if command._ == "submit-summary" then outstanding[command.cmd] = command end
      end
      if not cp.v.intents or cp.v.intents.t ~= "list" then error("missing dispatch intents", 0) end
      local intent = {}
      for _, tagged in ipairs(cp.v.intents.v) do
        if tagged.t ~= "text" or not outstanding[tagged.v] then
          error("checkpoint has invalid dispatch intent", 0)
        end
        intent[tagged.v] = true
      end
      self.state, self.outstanding, self.started, self.intent = state, outstanding, {}, intent
      self.view_cache = nil
      self:_refresh_view()
      self.info.checkpoint = candidate.name
      self.info.checkpoint_seq = seq
      return seq
    end)
    if ok then return seq_or_error end
    self.store:set_aside_checkpoint(candidate.name, tostring(seq_or_error))
    self.info.checkpoint_rejected = tostring(seq_or_error)
  end
  return nil
end

function Sup:_replay_dispatch(rec, txn)
  local cmd, job = text_field(txn, "cmd"), text_field(txn, "job")
  local c = self.outstanding[cmd]
  if not c or c.job ~= job then
    error(("replay divergence at seq %d: dispatch record for %s is not an outstanding command"):format(rec.seq, cmd), 0)
  end
  self.intent[cmd] = true
end

function Sup:_replay(rec)
  local txn = codec.decode(rec.payload)
  if txn.v.kind and txn.v.kind.v == "dispatch" then return self:_replay_dispatch(rec, txn) end
  local event = txn.v.event
  local state, out = self.core:transition(self.state, event)
  local function check(what, a, b)
    if a ~= b then error(("replay divergence at seq %d: %s"):format(rec.seq, what), 0) end
  end
  check("commands", codec.encode(out.commands_tagged), codec.encode(txn.v.commands))
  check("decisions", codec.encode(out.decisions_tagged), codec.encode(txn.v.decisions))
  self.state = state
  self:_refresh_view()
  check("view hash", self.view_hash, text_field(txn, "view_hash"))
  check("state hash", self.core:state_hash(state), text_field(txn, "state_hash"))
  self:_absorb(schema.decode("event", event), out, true)
end

function Sup:_refresh_view()
  local st = self.core:status(self.state)
  if self.view_cache and self.view_cache.rev == st.rev then return end
  local text = self.core:render(self.state)
  self.view_text, self.view_hash = text, sha256.hex(text)
  self.view_cache = { rev = st.rev }
end

-- Book-keeping shared by live submission and replay.
function Sup:_absorb(ev, out, replaying)
  local rejected = false
  for _, d in ipairs(out.decisions) do if d._ == "event-rejected" then rejected = true end end
  if ev._ == "message-appended" and not rejected then
    local hash, bytes = ev.content.sha256, ev.content.bytes
    self.messages[ev.id] = setmetatable({ kind = ev.kind, date = ev.date }, {
      __index = function(_, k)
        if k == "text" then return self.store:get_blob(hash, bytes) end
      end,
    })
  end
  if ev._ == "summary-completed" or ev._ == "summary-failed" then
    for cmd, c in pairs(self.outstanding) do
      if c.job == ev.job then self.outstanding[cmd] = nil; self.started[cmd] = nil; self.intent[cmd] = nil end
    end
  end
  for _, c in ipairs(out.commands) do
    if c._ == "submit-summary" then
      self.outstanding[c.cmd] = c
    elseif not replaying then
      self.on_client_event(c.event, c.cmd)
    end
  end
end

-- Validate, transition, journal (durable), then adopt. Returns the decoded
-- transition output and the journal sequence number.
function Sup:submit(event)
  local tagged = schema.encode("event", event)
  local state, out = self.core:transition(self.state, tagged)
  local prev_state, prev_cache = self.state, self.view_cache
  local prev_text, prev_hash = self.view_text, self.view_hash
  self.state = state
  local ok, err = pcall(self._refresh_view, self)
  if not ok then
    self.state, self.view_cache = prev_state, prev_cache
    self.view_text, self.view_hash = prev_text, prev_hash
    error(err, 0)
  end
  local aok, seq = pcall(self.store.append, self.store, txn_bytes {
    kind = codec.sym("event"),
    event = tagged,
    commands = out.commands_tagged,
    decisions = out.decisions_tagged,
    view_rev = codec.int_of(self.core:status(state).rev),
    view_hash = codec.text(self.view_hash),
    state_hash = codec.text(self.core:state_hash(state)),
  })
  if not aok then
    self.state, self.view_cache = prev_state, prev_cache
    self.view_text, self.view_hash = prev_text, prev_hash
    error(seq, 0)
  end
  self:_absorb(schema.decode("event", tagged), out, false)
  self:_maybe_checkpoint(seq)
  return out, seq
end

function Sup:checkpoint(seq)
  seq = seq or (self.store.next_seq - 1)
  if seq < 1 then error("cannot checkpoint an empty journal", 0) end
  local commands = {}
  for _, command in pairs(self.outstanding) do
    commands[#commands + 1] = schema.encode("command", command)
  end
  table.sort(commands, function(a, b)
    return codec.encode(a) < codec.encode(b)
  end)
  local intents = {}
  for cmd in pairs(self.intent) do intents[#intents + 1] = codec.text(cmd) end
  table.sort(intents, function(a, b) return a.v < b.v end)
  local payload = txn_bytes {
    kind = codec.sym("checkpoint"),
    seq = codec.int_of(seq),
    anchor = codec.text(assert(self.store:record_anchor(seq))),
    bundle = codec.text(self.core.bundle_hash),
    config = schema.encode("config", self.config),
    state = codec.decode(self.core:state_bytes(self.state)),
    state_hash = codec.text(self:state_hash()),
    view_hash = codec.text(self.view_hash),
    view_rev = codec.int_of(self:status().rev),
    outstanding = codec.list(commands),
    intents = codec.list(intents),
  }
  return self.store:write_checkpoint(seq, payload)
end

function Sup:_maybe_checkpoint(seq)
  if self.checkpoint_interval > 0 and seq % self.checkpoint_interval == 0 then
    local ok, err = pcall(self.checkpoint, self, seq)
    if not ok then self.info.checkpoint_error = tostring(err) end
  end
end

local function by_cmd(a, b) return tonumber(a.cmd:sub(2)) < tonumber(b.cmd:sub(2)) end

-- Outstanding commands a previous process started and never resolved.
function Sup:orphans()
  local out = {}
  for cmd, c in pairs(self.outstanding) do
    if self.intent[cmd] and not self.started[cmd] then out[#out + 1] = c end
  end
  table.sort(out, by_cmd)
  return out
end

-- Settle orphans as uncertain, in command order. Each is an ordinary
-- journaled event, so replay reproduces it.
function Sup:recover()
  local n = 0
  for _, c in ipairs(self:orphans()) do
    if self.outstanding[c.cmd] then
      self:submit { _ = "summary-failed", job = c.job, attempt = c.attempt.n, class = "uncertain" }
      n = n + 1
    end
  end
  return n
end

-- Start every outstanding summary command not yet started, journaling the
-- dispatch intent first. Orphans are recovered as uncertain, never resent.
function Sup:dispatch_pending()
  if not self.provider then return 0 end
  self:recover()
  local cmds = {}
  for cmd, c in pairs(self.outstanding) do
    if not self.started[cmd] then cmds[#cmds + 1] = c end
  end
  table.sort(cmds, by_cmd)
  for _, c in ipairs(cmds) do
    local seq = self.store:append(txn_bytes {
      kind = codec.sym("dispatch"), cmd = codec.text(c.cmd), job = codec.text(c.job),
    })
    self.intent[c.cmd] = true
    self:_maybe_checkpoint(seq)
    self.started[c.cmd] = true
    local source
    if c.input._ == "leaf-input" then
      local m = self.messages[c.input.message]
      if not m then error("no stored source for message " .. c.input.message, 0) end
      source = m.text
    end
    local job = { cmd = c.cmd, job = c.job, key = c.key, attempt = c.attempt, input = c.input, source = source }
    self.provider:start(job, function(outcome)
      if outcome.ok then
        self.inbox[#self.inbox + 1] = { _ = "summary-completed", job = c.job, attempt = c.attempt.n,
          bytes = #outcome.text, sha256 = sha256.hex(outcome.text), text = outcome.text }
      else
        self.inbox[#self.inbox + 1] = { _ = "summary-failed", job = c.job, attempt = c.attempt.n,
          class = outcome.class }
      end
    end)
  end
  return #cmds
end

-- Drive adapters until nothing is outstanding (or max_steps elapse).
function Sup:pump(max_steps)
  max_steps = max_steps or math.huge
  local steps = 0
  while steps < max_steps do
    self:dispatch_pending()
    if #self.inbox == 0 and (not self.provider or self.provider:pending() == 0) then break end
    if self.provider then self.provider:step(self.step_ms or 0) end
    while #self.inbox > 0 do self:submit(table.remove(self.inbox, 1)) end
    steps = steps + 1
  end
  return steps
end

-- Grant one more attempt to a blocked or uncertain job.
function Sup:operator_retry(job)
  return self:submit { _ = "operator-retry", job = job }
end

function Sup:stuck_jobs() return self.core:stuck_jobs(self.state) end

function Sup:status() return self.core:status(self.state) end
function Sup:view() return self.view_text, self.view_hash end
function Sup:state_hash() return self.core:state_hash(self.state) end
function Sup:invariant_errors() return self.core:invariant_errors(self.state) end

function Sup:outstanding_count()
  local n = 0
  for _ in pairs(self.outstanding) do n = n + 1 end
  return n
end

function Sup:close() self.store:close() end

return M
