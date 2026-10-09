-- unii/host/cli.lua -- milestone command line (Phase 1). Summaries come
-- from the MOCK summarizer unless --network real is given, which uses the
-- libcurl adapter and an OpenAI-compatible endpoint (--url, --model; the key
-- comes from UNII_API_KEY or OPENAI_API_KEY and is never journaled).
--
--   unii build                                 typecheck the bundle, write the stamp
--   unii init    --dir D [--low N --high N --cap N --lead N --inflight N]
--   unii append  --dir D --count N [--seed S] [--no-pump] [--quiet]
--   unii view    --dir D                       replay, print the view and hashes
--   unii hash    --dir D                       replay, print VIEW-HASH / STATE-HASH
--   unii status  --dir D                       counts, stuck jobs, orphaned commands
--   unii retry   --dir D --job J               operator retry of a blocked/uncertain job
--   unii replay  --dir D                       per-transaction replay inspector
--   unii milestone --dir D [--count N]         multi-process restart demonstration
local M = {}

local function usage(msg)
  if msg then io.stderr:write("unii: ", msg, "\n") end
  io.stderr:write([[
usage: unii <command> [options]
  build | init | append | view | hash | status | retry | replay | milestone
  common: --dir DIR (chat directory)
          --network mock|real (default mock); real needs --url URL --model NAME
          and UNII_API_KEY or OPENAI_API_KEY in the environment
  retry:  --job JOB_ID
  init:   --low N --high N --cap N --lead N --inflight N --attempts N
  append: --count N --seed S --no-pump --quiet
]])
  os.exit(2)
end

local function parse(argv)
  local cmd, opts = argv[1], {}
  local i = 2
  while i <= #argv do
    local a = argv[i]
    local k = a:match("^%-%-(.+)$")
    if not k then usage("unexpected argument " .. a) end
    if k == "no-pump" or k == "quiet" then
      opts[k] = true
      i = i + 1
    else
      opts[k] = argv[i + 1]
      if opts[k] == nil then usage("missing value for --" .. k) end
      i = i + 2
    end
  end
  return cmd, opts
end

local function num(opts, k, default)
  local v = opts[k]
  if v == nil then return default end
  if not v:match("^%d+$") then usage("--" .. k .. " expects a natural number") end
  return v
end

local function open_chat(opts, extra)
  if not opts.dir then usage("--dir is required") end
  local sup = require("unii.host.supervisor")
  local mock = require("unii.host.mock.summarizer")
  extra = extra or {}
  local events = {}
  local s = sup.open(opts.dir, {
    config = extra.config,
    on_client_event = function(ev) events[#events + 1] = ev end,
  })
  local net = opts.network or "mock"
  if net == "mock" then
    s.provider = mock.new { cap = s.config.leaf_cap }
  elseif net == "real" then
    if not (opts.url and opts.model) then s:close(); usage("--network real needs --url and --model") end
    local key = os.getenv("UNII_API_KEY") or os.getenv("OPENAI_API_KEY")
    local network = require("unii.host.network")
    s.provider = require("unii.host.providers.chat_completions").new {
      client = network.client {}, url = opts.url, model = opts.model, api_key = key,
      cap = s.config.leaf_cap,
    }
    s.step_ms = 50
  else
    s:close(); usage("--network must be mock or real")
  end
  return s, events
end

local function short(h) return h:sub(1, 16) end

local function print_hashes(s)
  local _, vh = s:view()
  print("VIEW-HASH " .. vh)
  print("STATE-HASH " .. s:state_hash())
end

local function status_line(s)
  local st = s:status()
  return ("rev %d | %d lines %d bytes | covered %d/%d | jobs q%d d%d b%d u%d%s"):format(
    st.rev, st.view_lines, st.view_bytes, st.covered, st.count,
    st.queued, st.dispatched, st.blocked, st.uncertain, st.batch and " | BATCH" or "")
end

local commands = {}

function commands.build()
  local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/host/cli%.lua$")
  local ok = os.execute(("luajit %q"):format(here .. "/build.lua"))
  os.exit((ok == 0 or ok == true) and 0 or 1)
end

function commands.init(opts)
  local schema = require("unii.host.schema")
  local cfg = schema.config {
    low = num(opts, "low", "64000"), high = num(opts, "high", "128000"),
    leaf_cap = num(opts, "cap", "512"), lead_window = num(opts, "lead", "8"),
    max_inflight = num(opts, "inflight", "8"), max_attempts = num(opts, "attempts", "5"),
  }
  local s = open_chat(opts, { config = cfg })
  print(("initialised %s  (MOCK summarizer; config epoch %d cap %d low %d high %d)"):format(
    opts.dir, s.config.epoch, s.config.leaf_cap, s.config.budget.low, s.config.budget.high))
  print_hashes(s)
  s:close()
end

function commands.append(opts)
  local synthetic = require("unii.host.synthetic")
  local sha256 = require("unii.host.sha256")
  local s, events = open_chat(opts)
  local count = tonumber(num(opts, "count", "10"))
  local seed = tonumber(num(opts, "seed", "1"))
  if s:outstanding_count() > 0 and not opts["no-pump"] then
    print(("resuming %d outstanding summary command(s) from the journal"):format(s:outstanding_count()))
    s:pump()
  end
  local base = s:status().count
  for i = base, base + count - 1 do
    local m = synthetic.message(seed, i)
    local out = s:submit { _ = "message-appended", id = tostring(i), kind = m.kind, date = m.date,
      content = { _ = "content", bytes = #m.text, sha256 = sha256.hex(m.text), text = m.text } }
    for _, d in ipairs(out.decisions) do
      if d._ == "event-rejected" then print("  rejected: " .. d.reason) end
    end
    if not opts["no-pump"] then s:pump() end
    if not opts.quiet then
      print(("msg %-5d %-11s %5dB -> %s"):format(i, m.kind, #m.text, status_line(s)))
    end
  end
  for _, ev in ipairs(events) do
    if ev._ == "memory-blocked" then print("MEMORY BLOCKED: " .. ev.job .. ": " .. ev.reason) end
    if ev._ == "effect-uncertain" then
      print("EFFECT UNCERTAIN: " .. ev.job .. " (" .. ev.cmd .. "); not resent; `unii retry --job` to retry")
    end
  end
  local text = s:view()
  if not opts.quiet then io.write(text) end
  print(status_line(s))
  print_hashes(s)
  local errs = s:invariant_errors()
  print("invariants: " .. (#errs == 0 and "ok" or table.concat(errs, "; ")))
  s:close()
end

function commands.view(opts)
  local s = open_chat(opts)
  io.write((s:view()))
  print(status_line(s))
  print_hashes(s)
  s:close()
end

function commands.hash(opts)
  local s = open_chat(opts)
  print_hashes(s)
  print("OUTSTANDING " .. s:outstanding_count())
  s:close()
end

function commands.status(opts)
  local s = open_chat(opts)
  print(status_line(s))
  print("journal records " .. #s.store:records())
  if s.info.tail_isolated then print("isolated crash tail: " .. s.info.tail_isolated) end
  print("outstanding summary commands " .. s:outstanding_count())
  local orphans = s:orphans()
  if #orphans > 0 then
    print(#orphans .. " command(s) were in flight when the last process stopped; "
      .. "the next append records them as uncertain")
  end
  for _, j in ipairs(s:stuck_jobs()) do print(("stuck %-9s %s  %s"):format(j.state, j.job, j.detail)) end
  print("ready for a turn: " .. tostring(s.core:ready(s.state)))
  s:close()
end

function commands.retry(opts)
  if not opts.job then usage("--job is required") end
  local s, events = open_chat(opts)
  local out = s:operator_retry(opts.job)
  for _, d in ipairs(out.decisions) do
    if d._ == "event-rejected" then s:close(); error(d.reason, 0) end
    if d._ == "job-retried" then print("retrying " .. d.previous .. " as " .. d.job) end
  end
  s:pump()
  for _, ev in ipairs(events) do
    if ev._ == "memory-blocked" then print("MEMORY BLOCKED: " .. ev.job .. ": " .. ev.reason) end
    if ev._ == "effect-uncertain" then print("EFFECT UNCERTAIN: " .. ev.job .. " (" .. ev.cmd .. ")") end
  end
  print(status_line(s))
  s:close()
end

function commands.replay(opts)
  if not opts.dir then usage("--dir is required") end
  local codec = require("unii.host.codec")
  local schema = require("unii.host.schema")
  local storage = require("unii.host.storage")
  local store = storage.open(opts.dir)
  for _, r in ipairs(store:records()) do
    local t = codec.decode(r.payload)
    if t.v.kind.v == "init" then
      print(("%5d init bundle %s config %s"):format(r.seq, short(t.v.bundle.v), codec.show(t.v.config)))
    elseif t.v.kind.v == "dispatch" then
      print(("%5d dispatch %s %s"):format(r.seq, t.v.cmd.v, t.v.job.v))
    else
      local ev = schema.decode("event", t.v.event)
      local what = ev._ == "message-appended" and ("message %d %s %dB"):format(ev.id, ev.kind, ev.content.bytes)
        or ev._ == "summary-completed" and ("completed %s %dB"):format(ev.job, ev.bytes)
        or ev._ == "summary-failed" and ("failed %s %s"):format(ev.job, ev.class)
        or ("operator retry %s"):format(ev.job)
      local ds = {}
      for _, d in ipairs(t.v.decisions.v) do ds[#ds + 1] = d.v[1].v end
      print(("%5d %-44s rev %-4s view %s | %s"):format(r.seq, what, t.v.view_rev.v,
        short(t.v.view_hash.v), table.concat(ds, ",")))
    end
  end
  store:close()
  -- Full verification replay (bundle, commands, decisions, hashes).
  local s = open_chat(opts)
  print("replay verified: " .. #s.store:records() .. " records, " .. status_line(s))
  s:close()
end

-- Multi-process restart demonstration: each step is a separate luajit
-- process, so state survives only through the journal.
function commands.milestone(opts)
  if not opts.dir then usage("--dir is required") end
  local count = num(opts, "count", "48")
  local self = arg and arg[0] or "unii/bin/unii"
  local function run(args)
    local cmd = ("luajit %q %s 2>&1"):format(self, args)
    local p = io.popen(cmd)
    local out = p:read("*a")
    local ok = p:close()
    return out, ok
  end
  local function grab(out, tag) return out:match(tag .. " (%x+)") end
  local dir = opts.dir
  os.execute(("rm -rf %q"):format(dir))
  local failures = 0
  local function check(label, a, b)
    local ok = a ~= nil and a == b
    if not ok then failures = failures + 1 end
    print(("  %-58s %s"):format(label, ok and "same" or ("DIFFERENT " .. tostring(a) .. " vs " .. tostring(b))))
  end

  print("== process 1: init (MOCK summarizer, low 1500 / high 3000 bytes)")
  local out = run(("init --dir %q --low 1500 --high 3000"):format(dir))
  io.write(out)
  print("== process 2: append " .. count .. " synthetic messages with fake summaries")
  out = run(("append --dir %q --count %s --seed 7"):format(dir, count))
  io.write(out)
  local v1, s1 = grab(out, "VIEW%-HASH"), grab(out, "STATE%-HASH")
  print("== process 3: restart and replay the journal")
  out = run(("hash --dir %q"):format(dir))
  io.write(out)
  check("view hash after restart", grab(out, "VIEW%-HASH"), v1)
  check("state hash after restart", grab(out, "STATE%-HASH"), s1)

  print("== process 4: append 8 more WITHOUT running summaries, then exit")
  out = run(("append --dir %q --count 8 --seed 7 --no-pump --quiet"):format(dir))
  io.write(out)
  local v2, s2 = grab(out, "VIEW%-HASH"), grab(out, "STATE%-HASH")
  print("== process 5: restart with unresolved summaries outstanding")
  out = run(("hash --dir %q"):format(dir))
  io.write(out)
  check("view hash with pending work after restart", grab(out, "VIEW%-HASH"), v2)
  check("state hash with pending work after restart", grab(out, "STATE%-HASH"), s2)
  print("== process 6: resume outstanding summaries, append 4 more")
  out = run(("append --dir %q --count 4 --seed 7 --quiet"):format(dir))
  io.write(out)
  local v3, s3 = grab(out, "VIEW%-HASH"), grab(out, "STATE%-HASH")
  print("== process 7: final restart")
  out = run(("view --dir %q"):format(dir))
  io.write(out)
  check("final view hash after restart", grab(out, "VIEW%-HASH"), v3)
  check("final state hash after restart", grab(out, "STATE%-HASH"), s3)
  print(failures == 0 and "MILESTONE PASS" or ("MILESTONE FAIL (" .. failures .. ")"))
  os.exit(failures == 0 and 0 or 1)
end

function M.main(argv)
  local cmd, opts = parse(argv)
  local f = commands[cmd or ""]
  if not f then usage(cmd and ("unknown command " .. cmd) or nil) end
  local ok, err = pcall(f, opts)
  if not ok then
    io.stderr:write("unii: ", tostring(err), "\n")
    os.exit(1)
  end
end

return M
