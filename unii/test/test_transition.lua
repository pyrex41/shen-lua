-- Transition behaviour: exact leaves, lossless joins, job identity, lead
-- window, inflight cap, retries, blocking, duplicates, out-of-order
-- completions and event rejection.
local T = require("unii.test.lib")

local function big(n, ch) return (ch or "x"):rep(n) end
local function commands_of(out, name)
  local t = {}
  for _, c in ipairs(out.commands) do if c._ == name then t[#t + 1] = c end end
  return t
end

return {
  { "leaf cap includes the kind attribution: 506 bytes exact, 507 needs a job", function()
    local e = T.engine()
    local out = e:apply(T.msg(0, "user", big(506)))
    T.eq(out.decisions[1]._, "node-committed")
    T.eq(out.decisions[1].bytes, 512)
    T.eq(out.decisions[1].origin._, "exact-leaf")
    out = e:apply(T.msg(1, "user", big(507)))
    T.eq(T.decision_names(out), "job-created")
    T.eq(#commands_of(out, "submit-summary"), 1)
    T.eq(#e:invariants(), 0)
  end },

  { "siblings join losslessly iff left + LF + right fits the cap", function()
    local e = T.engine()
    e:apply(T.msg(0, "user", big(249)))          -- 255 bytes
    local out = e:apply(T.msg(1, "user", big(250))) -- 256 bytes: 255 + 1 + 256 = 512
    T.ok(T.decision_names(out):find("node-committed,node-committed", 1, true), T.decision_names(out))
    T.eq(out.decisions[2].origin._, "joined")
    T.eq(out.decisions[2].bytes, 512)
    T.eq(out.decisions[2].key.level, 1)
    e:apply(T.msg(2, "user", big(249)))
    out = e:apply(T.msg(3, "user", big(251)))      -- 255 + 1 + 257 = 513 > 512
    T.ok(T.has_decision(out, "job-created"), "a merge job instead of a join")
    local c = commands_of(out, "submit-summary")[1]
    T.eq(c.key.level .. "/" .. c.key.index, "1/1")
    T.eq(c.input._, "merge-input")
    T.eq(c.input.left_text, "user: " .. big(249))
    T.eq(#e:invariants(), 0)
  end },

  { "job ids are deterministic and change only with the attempt on retry", function()
    local function run()
      local e = T.engine()
      local out = e:apply(T.msg(0, "assistant", big(900, "y")))
      return e, commands_of(out, "submit-summary")[1]
    end
    local e1, c1 = run()
    local _, c2 = run()
    T.eq(c1.job, c2.job)
    T.ok(c1.job:match("^j1%-0%-0%-a1%-%x+$"), c1.job)
    local out = e1:apply(T.done(c1, big(600)))      -- over the cap -> retry
    local r = commands_of(out, "submit-summary")[1]
    T.eq(r.job, (c1.job:gsub("%-a1%-", "-a2-")))
    T.eq(r.attempt.retry._, "retry-too-long")
    T.eq(r.attempt.retry.bytes, 600)
  end },

  { "oversized summaries retry up to max attempts, then block visibly", function()
    local e = T.engine { max_attempts = 3 }
    local out = e:apply(T.msg(0, "user", big(1000)))
    local c = commands_of(out, "submit-summary")[1]
    for attempt = 1, 3 do
      T.eq(c.attempt.n, attempt)
      out = e:apply(T.done(c, big(513)))
      if attempt < 3 then c = commands_of(out, "submit-summary")[1] end
    end
    T.ok(T.has_decision(out, "job-blocked"), T.decision_names(out))
    local ev = commands_of(out, "emit-client-event")[1].event
    T.eq(ev._, "memory-blocked")
    local st = e:status()
    T.eq(st.blocked, 1); T.eq(st.covered, 0); T.eq(st.count, 1)
    T.eq(e.C:ready(e.state), false, "a blocked leaf keeps the memory not ready")
    T.eq(#e:invariants(), 0)
  end },

  { "retryable failures retry; permanent failures block", function()
    local e = T.engine()
    local c = commands_of(e:apply(T.msg(0, "user", big(1000))), "submit-summary")[1]
    local out = e:apply(T.failed(c, "retryable"))
    local r = commands_of(out, "submit-summary")[1]
    T.eq(r.attempt.retry._, "retry-after-failure")
    out = e:apply(T.failed(r, "permanent"))
    T.ok(T.has_decision(out, "job-blocked"))
    T.eq(e:status().blocked, 1)
  end },

  { "duplicate, stale and unknown completions publish nothing", function()
    local e = T.engine()
    local c = commands_of(e:apply(T.msg(0, "user", big(1000))), "submit-summary")[1]
    local out = e:apply(T.done(c, "first"))
    T.ok(T.has_decision(out, "node-committed"))
    local before = e.C:state_hash(e.state)
    out = e:apply(T.done(c, "second delivery"))
    T.eq(T.decision_names(out), "completion-ignored")
    T.eq(e.C:state_hash(e.state), before, "duplicate delivery changed state")
    out = e:apply({ _ = "summary-completed", job = "j9-0-0-a1-x", attempt = 1, bytes = 1,
                    sha256 = require("unii.host.sha256").hex("x"), text = "x" })
    T.eq(T.decision_names(out), "completion-ignored")
    T.ok(e.C:render(e.state):find("0+1|first", 1, true), "first delivery published once")
  end },

  { "out-of-order completion: later leaf waits outside the view", function()
    local e = T.engine()
    local c0 = commands_of(e:apply(T.msg(0, "user", big(1000))), "submit-summary")[1]
    local c1 = commands_of(e:apply(T.msg(1, "user", big(1000))), "submit-summary")[1]
    e:apply(T.msg(2, "user", "short"))
    local out = e:apply(T.done(c1, "summary one"))
    T.eq(e:status().covered, 0, "message 0 unresolved: nothing may enter the view")
    T.eq(e.C:render(e.state), "<chat>\n</chat>\n")
    T.ok(not T.has_decision(out, "view-extended"))
    out = e:apply(T.done(c0, "summary zero"))
    T.eq(e:status().covered, 3)
    T.eq(e.C:render(e.state), "<chat>\n0+1|summary zero\n1+1|summary one\n2+1|user: short\n</chat>\n")
    T.eq(#e:invariants(), 0)
  end },

  { "lead window and inflight cap bound dispatch; leaves before parents", function()
    local e = T.engine { lead_window = 3, max_inflight = 8 }
    local dispatched = 0
    for i = 0, 9 do
      dispatched = dispatched + #commands_of(e:apply(T.msg(i, "user", big(700))), "submit-summary")
    end
    T.eq(dispatched, 3, "only the first lead-window leaves dispatch")
    T.eq(e:status().dispatched, 3)
    local e2 = T.engine { lead_window = 64, max_inflight = 4 }
    dispatched = 0
    for i = 0, 9 do
      dispatched = dispatched + #commands_of(e2:apply(T.msg(i, "user", big(700))), "submit-summary")
    end
    T.eq(dispatched, 4, "inflight cap")
    -- completing leaf 0 and 1 creates a parent job; remaining leaves go first
    local c0, c1 = e2:take(1), e2:take(1)
    e2:apply(T.done(c0, big(300)))
    local out = e2:apply(T.done(c1, big(300)))
    local next_cmds = commands_of(out, "submit-summary")
    T.ok(T.has_decision(out, "job-created"), "parent job created")
    for _, c in ipairs(next_cmds) do T.eq(c.key.level, 0, "queued leaves dispatch before the parent") end
    T.eq(#e2:invariants(), 0)
  end },

  { "malformed or out-of-policy events are rejected and journaled as such", function()
    local e = T.engine { max_frontier = 2, chunk_max = 1000 }
    local cases = {
      { T.msg(5, "user", "x"), "message id out of sequence" },
      { (function() local m = T.msg(0, "user", "x"); m.date = ""; return m end)(), "missing message date" },
      { T.msg(0, "user", big(1001)), "content bytes outside [0, chunk max]" },
    }
    for _, c in ipairs(cases) do
      local out = e:apply(c[1])
      T.eq(out.decisions[1]._, "event-rejected")
      T.eq(out.decisions[1].reason, c[2])
      T.eq(out.commands[1].event._, "input-rejected")
    end
    e:apply(T.msg(0, "user", big(800)))
    e:apply(T.msg(1, "user", big(800)))
    local out = e:apply(T.msg(2, "user", big(800)))
    T.eq(out.decisions[1].reason, "unresolved message backlog is full")
    out = e:apply(T.msg(2, "user", "small exact leaves are still admitted"))
    T.eq(out.decisions[1]._, "node-committed")
    T.eq(e:status().count, 3)
  end },

  { "exact leaves and joins never call a model until a join overflows", function()
    local e = T.engine()
    local joined_top
    for i = 0, 31 do
      local out = e:apply(T.msg(i, "user", ("m%02d"):format(i)))
      T.eq(#commands_of(out, "submit-summary"), 0)
      for _, d in ipairs(out.decisions) do
        if d._ == "node-committed" and d.key.level == 5 then joined_top = d end
      end
    end
    T.ok(joined_top and joined_top.origin._ == "joined", "0+32 built by lossless joins")
    T.eq(joined_top.bytes, 32 * #"user: m00" + 31)
    local st = e:status()
    T.eq(st.covered, 32); T.eq(st.queued + st.dispatched, 0)
    -- 64 such leaves cannot join into one 512-byte node: that parent needs a job
    for i = 32, 63 do e:apply(T.msg(i, "user", ("m%02d"):format(i))) end
    T.eq(e:status().dispatched, 1)
    T.eq(e.pending[1].key.level, 6)
  end },
}
