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
    outstanding = {}, started = {}, inbox = {}, messages = {}, view_cache = nil,
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
  for i = 2, #recs do self:_replay(recs[i]) end
end

function Sup:_replay(rec)
  local txn = codec.decode(rec.payload)
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
    self.messages[ev.id] = { kind = ev.kind, text = ev.content.text, date = ev.date }
  end
  if ev._ == "summary-completed" or ev._ == "summary-failed" then
    for cmd, c in pairs(self.outstanding) do
      if c.job == ev.job then self.outstanding[cmd] = nil; self.started[cmd] = nil end
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
  self.state = state
  local ok, err = pcall(self._refresh_view, self)
  if not ok then self.state, self.view_cache = prev_state, prev_cache; error(err, 0) end
  local seq = self.store:append(txn_bytes {
    kind = codec.sym("event"),
    event = tagged,
    commands = out.commands_tagged,
    decisions = out.decisions_tagged,
    view_rev = codec.int_of(self.core:status(state).rev),
    view_hash = codec.text(self.view_hash),
    state_hash = codec.text(self.core:state_hash(state)),
  })
  self:_absorb(schema.decode("event", tagged), out, false)
  return out, seq
end

-- Start every outstanding summary command not yet started in this process
-- (after a restart this re-dispatches commands whose outcome was never
-- journaled; summaries are read-only, so a duplicate costs only spend).
function Sup:dispatch_pending()
  if not self.provider then return 0 end
  local cmds = {}
  for cmd, c in pairs(self.outstanding) do
    if not self.started[cmd] then cmds[#cmds + 1] = c end
  end
  table.sort(cmds, function(a, b) return tonumber(a.cmd:sub(2)) < tonumber(b.cmd:sub(2)) end)
  for _, c in ipairs(cmds) do
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
    if self.provider then self.provider:step() end
    while #self.inbox > 0 do self:submit(table.remove(self.inbox, 1)) end
    steps = steps + 1
  end
  return steps
end

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
