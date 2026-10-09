-- The REAL libcurl adapter (unii/host/network/) under the chat-completions
-- provider and the supervisor, against the adapter's local test server
-- (unii/test/network/mock_server.py on 127.0.0.1). Real sockets and HTTP;
-- the "model" is that test server, not a provider. Skips when libcurl or
-- python3 is unavailable.
local T = require("unii.test.lib")
local schema = require("unii.host.schema")
local supervisor = require("unii.host.supervisor")
local chat = require("unii.host.providers.chat_completions")

local server

local function journal_bytes(dir)
  local manifest = assert(io.open(dir .. "/journals/MANIFEST", "rb"))
  local names = manifest:read("*a")
  manifest:close()
  local out = {}
  for day in names:gmatch("(%d%d%d%d%-%d%d%-%d%d)\n") do
    local file = assert(io.open(dir .. "/journals/" .. day .. ".uj", "rb"))
    out[#out + 1] = file:read("*a")
    file:close()
  end
  return table.concat(out)
end

local function setup()
  if server then return server end
  local ok, network = pcall(require, "unii.host.network")
  if not ok then return nil end
  local _, has_py = T.sh("command -v python3")
  if not has_py then return nil end
  local pipe = io.popen(("exec python3 %q"):format(T.root() .. "/unii/test/network/mock_server.py"), "r")
  local info = { network = network, pipe = pipe }
  for _ = 1, 10 do
    local line = pipe:read("*l")
    if not line or line == "READY" then break end
    local k, v = line:match("^(%S+)%s+(%S+)$")
    if k then info[k] = v end
  end
  if not (info.HTTP and info.PID) then return nil end
  info.base = "http://127.0.0.1:" .. info.HTTP
  server = info
  return info
end

local function teardown()
  if server then
    os.execute("kill " .. server.PID .. " >/dev/null 2>&1")
    pcall(function() server.pipe:close() end)
    server = nil
  end
end

-- One server per case, always stopped, so a failing assertion leaks nothing.
local function with_server(body)
  return function()
    local s = setup()
    if not s then return "skip" end
    local ok, err = pcall(body, s)
    teardown()
    if not ok then error(err, 0) end
  end
end

local function hits(s, path)
  local c = s.network.client {}
  local h = c:request { url = s.base .. "/stats", method = "GET" }
  c:run_until_idle(20, 500)
  local body = s.network.json.decode(h.result.body)
  c:close()
  return body.hits[path] or 0
end

local function open(s, path, dir)
  local client = s.network.client { timeout_ms = 3000 }
  local p = chat.new { client = client, url = s.base .. path, model = "test-model", cap = 512 }
  local events = {}
  local sup = supervisor.open(dir, { core = T.core(), provider = p, config = schema.config {},
    on_client_event = function(ev) events[#events + 1] = ev end })
  sup.step_ms = 20
  return sup, p, client, events
end

return {
  { "real adapter: a streamed completion becomes the committed summary", with_server(function(s)
    T.eq(s.network.IS_MOCK, false)
    local dir = T.tmpdir("real")
    local sup, p, client = open(s, "/v1/chat/completions", dir)
    T.eq(p.is_mock, false)
    sup:submit(T.msg(0, "user", ("a"):rep(800)))
    sup:pump(2000)
    T.eq(sup:status().covered, 1)
    T.eq(sup:view(), "0+1|Hello world\n")
    T.eq(#sup:invariant_errors(), 0)
    sup:close(); client:close()
    T.rm(dir)
  end) },

  { "real adapter: a connection dropped after send is uncertain and sent once", with_server(function(s)
    local before = hits(s, "/drop")
    local dir = T.tmpdir("realdrop")
    local sup, p, client, events = open(s, "/drop", dir)
    sup:submit(T.msg(0, "user", ("a"):rep(800)))
    sup:pump(2000)
    for _ = 1, 3 do sup:pump(50) end
    local st = sup:status()
    T.eq(st.uncertain, 1); T.eq(st.dispatched, 0); T.eq(st.queued, 0)
    T.eq(p.calls, 1)
    T.eq(hits(s, "/drop") - before, 1, "the server saw exactly one request")
    local ev
    for _, e in ipairs(events) do if e._ == "effect-uncertain" then ev = e end end
    T.ok(ev, "effect-uncertain emitted")
    sup:close(); client:close()
    T.rm(dir)
  end) },

  { "CLI --network real: dropped request is reported stuck, `unii retry` recovers it", with_server(function(s)
    local dir = T.tmpdir("realcli") .. "/chat"
    local bin = T.root() .. "/unii/bin/unii"
    local function run(args) return T.sh(("UNII_API_KEY=test-key-not-secret %q %s"):format(bin, args)) end
    local out, ok = run(("init --dir %q --cap 64"):format(dir))
    T.ok(ok, out)
    out, ok = run(("append --dir %q --count 2 --seed 3 --quiet --network real --url %q --model m")
      :format(dir, s.base .. "/drop"))
    T.ok(ok, out)
    T.ok(out:find("EFFECT UNCERTAIN", 1, true), out)
    T.ok(not out:find("test-key-not-secret", 1, true), "key not printed")
    out = run(("status --dir %q"):format(dir))
    local job = out:match("stuck uncertain%s+(%S+)")
    T.ok(job, out)
    local journal = journal_bytes(dir)
    T.ok(not journal:find("test-key-not-secret", 1, true), "key not journaled")
    out, ok = run(("retry --dir %q --job %s --network real --url %q --model m")
      :format(dir, job, s.base .. "/v1/chat/completions"))
    T.ok(ok, out)
    T.ok(out:find("retrying " .. job, 1, true), out)
    out = run(("status --dir %q"):format(dir))
    T.ok(not out:find("stuck uncertain " .. job, 1, true), out)
    T.rm(dir:match("^(.*)/chat$"))
  end) },
}
