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

  { "a round runs every try and commits the shortest fitting summary, earliest on ties", function()
    local e = T.engine()
    local c = commands_of(e:apply(T.msg(0, "user", big(1000))), "submit-summary")[1]
    local texts = { big(300, "a"), big(600, "b"), big(120, "c"), big(120, "d"), big(200, "e") }
    local seen = {}
    local out, n = e:round(c, function(t)
      seen[#seen + 1] = t.attempt.retry._ .. (t.attempt.retry.bytes and ("/" .. t.attempt.retry.bytes) or "")
      return T.done(t, texts[t.attempt.n])
    end)
    T.eq(n, 5, "all five tries run although try 1 already fit")
    T.eq(table.concat(seen, ","),
      "first-attempt,retry-seek-shorter/300,retry-too-long/600,retry-seek-shorter/120,retry-seek-shorter/120")
    local d = T.has_decision(out, "node-committed")
    T.eq(d.origin._, "summarized"); T.eq(d.origin.attempt, 3, "try 3 and try 4 tie at 120 bytes: try 3 wins")
    T.eq(d.bytes, 120)
    T.eq(e.C:render(e.state), "0+1|" .. big(120, "c") .. "\n")
    local kept = 0
    for _, o in ipairs(e.log) do for _, x in ipairs(o.decisions) do
      if x._ == "candidate-kept" then kept = kept + 1 end end end
    T.eq(kept, 2, "candidates kept on try 1 and try 3 only")
    T.eq(#e:invariants(), 0)
  end },

  { "over-cap summaries are never accepted; a round with none that fit blocks", function()
    local e = T.engine { max_attempts = 3 }
    local c = commands_of(e:apply(T.msg(0, "user", big(1000))), "submit-summary")[1]
    local out, n = e:round(c, function(t)
      if t.attempt.n == 2 then return T.failed(t, "retryable") end
      return T.done(t, big(513))
    end)
    T.eq(n, 3)
    T.ok(T.has_decision(out, "job-blocked"), T.decision_names(out))
    T.eq(e.C:stuck_jobs(e.state)[1].detail, "no summary within the leaf cap in a round of tries")
    T.eq(e:status().covered, 0)
  end },

  { "a permanent failure ends the round: best candidate so far commits, else the job blocks", function()
    local e = T.engine()
    local c = commands_of(e:apply(T.msg(0, "user", big(1000))), "submit-summary")[1]
    local out = e:round(c, function(t)
      if t.attempt.n == 2 then return T.failed(t, "permanent") end
      return T.done(t, "fits")
    end)
    T.eq(T.has_decision(out, "node-committed").origin.attempt, 1)
    local c1 = commands_of(e:apply(T.msg(1, "user", big(1000))), "submit-summary")[1]
    out = e:apply(T.failed(c1, "permanent"))
    T.ok(T.has_decision(out, "job-blocked"))
    T.eq(e.C:stuck_jobs(e.state)[1].detail, "permanent summary failure")
  end },

  { "an uncertain leaf renders its raw text provisionally and memory keeps moving", function()
    local e = T.engine { max_inflight = 1 }
    local raw0 = big(1000)
    local c0 = commands_of(e:apply(T.msg(0, "user", raw0)), "submit-summary")[1]
    e:apply(T.msg(1, "user", big(1000)))
    local out = e:apply(T.uncertain(c0, raw0))
    T.eq(T.decision_names(out):match("^job%-uncertain,node%-committed"), "job-uncertain,node-committed")
    T.eq(T.has_decision(out, "node-committed").origin._, "provisional")
    local ev = commands_of(out, "emit-client-event")[1].event
    T.eq(ev._, "effect-uncertain"); T.eq(ev.job, c0.job); T.eq(ev.cmd, c0.cmd)
    local subs = commands_of(out, "submit-summary")
    T.eq(#subs, 1); T.eq(subs[1].key.index, 1, "the freed slot goes to the next leaf")
    local st = e:status()
    T.eq(st.covered, 1, "the uncertain leaf is covered by its provisional line")
    T.eq(st.provisional, 1); T.eq(st.uncertain, 1)
    T.eq(e.C:render(e.state), "0+1|user: " .. raw0 .. "\n")
    e:finish(subs[1], "summary one")
    T.eq(e:status().covered, 2)
    T.eq(e.C:ready(e.state), true, "a turn may start")
    T.eq(e.C:render(e.state), "0+1|user: " .. raw0 .. "\n1+1|summary one\n")
    T.eq(#commands_of(e.log[#e.log], "submit-summary"), 0, "no parent job: its left child is provisional")
    for _, late in ipairs { T.done(c0, "late"), T.failed(c0, "retryable"), T.uncertain(c0, raw0) } do
      out = e:apply(late)
      T.eq(T.decision_names(out), "completion-ignored")
      T.eq(#out.commands, 0)
    end
    local stuck = e.C:stuck_jobs(e.state)
    T.eq(#stuck, 1); T.eq(stuck[1].state, "uncertain"); T.eq(stuck[1].detail, c0.cmd)
    T.eq(#e:invariants(), 0)
  end },

  { "uncertain reports must carry the leaf's own message, and nothing for a merge", function()
    local e = T.engine()
    local c0 = commands_of(e:apply(T.msg(0, "user", big(1000))), "submit-summary")[1]
    T.eq(e:apply(T.uncertain(c0, nil)).decisions[1].reason, "raw content does not match the job's source")
    T.eq(e:apply(T.uncertain(c0, big(999))).decisions[1].reason, "raw content does not match the job's source")
    T.eq(e:status().dispatched, 1)
  end },

  { "an uncertain leaf with a candidate renders that candidate, and the real summary replaces it", function()
    local e = T.engine()
    local raw = big(1000)
    local c = commands_of(e:apply(T.msg(0, "user", raw)), "submit-summary")[1]
    local out = e:apply(T.done(c, "early but fine"))
    local c2 = commands_of(out, "submit-summary")[1]
    out = e:apply(T.uncertain(c2, raw))
    T.eq(e.C:render(e.state), "0+1|early but fine\n")
    local rev = e:status().rev
    out = e:apply({ _ = "operator-retry", job = c2.job })
    local r = commands_of(out, "submit-summary")[1]
    T.eq(r.attempt.n, 3); T.eq(r.attempt.retry._, "retry-by-operator")
    out = e:finish(r, "much shorter")
    T.ok(T.has_decision(out, "view-replaced"), T.decision_names(out))
    T.eq(e.C:render(e.state), "0+1|much shorter\n")
    T.ok(e:status().rev > rev, "replacing a line is a view revision")
    T.eq(e:status().provisional, 0)
    T.eq(#e:invariants(), 0)
  end },

  { "an uncertain merge job: children stay, merges proceed around it", function()
    local e = T.engine { leaf_cap = 32, low = 40, high = 80, max_attempts = 1 }
    for i = 0, 7 do e:apply(T.msg(i, "user", ("m%d-"):format(i) .. big(20))) end
    -- every adjacent pair overflows 32 bytes, so each parent is a merge job
    local parked
    while #e.pending > 0 do
      local c = e:take()
      if not parked and c.key.level == 1 and c.key.index == 0 then
        parked = c
        e:apply(T.uncertain(c, nil))
      else
        e:apply(T.done(c, ("s%d/%d"):format(c.key.level, c.key.index)))
      end
    end
    T.ok(parked, "the (1, 0) merge job ran")
    local view = e.C:render(e.state)
    T.ok(view:find("0+1|user: m0-", 1, true) and view:find("1+1|user: m1-", 1, true), view)
    T.ok(view:find("2+2|s1/1\n4+4|", 1, true), "the rest merged around it:\n" .. view)
    local st = e:status()
    T.eq(st.covered, 8); T.eq(st.uncertain, 1); T.eq(st.provisional, 0)
    T.eq(#e:invariants(), 0)
  end },

  { "operator retry grants one fresh round; if it all fails the job blocks again", function()
    local e = T.engine { max_attempts = 2 }
    local raw = big(1000)
    local c0 = commands_of(e:apply(T.msg(0, "user", raw)), "submit-summary")[1]
    local out = e:apply({ _ = "operator-retry", job = c0.job })
    T.eq(out.decisions[1].reason, "operator retry: job is neither blocked nor uncertain")
    e:apply(T.uncertain(c0, raw))
    out = e:apply({ _ = "operator-retry", job = c0.job })
    local r = commands_of(out, "submit-summary")[1]
    T.eq(r.attempt.n, 2); T.eq(r.job, (c0.job:gsub("%-a1%-", "-a2-")))
    local _, n = e:round(r, function(t) return T.failed(t, "retryable") end)
    T.eq(n, 2, "a fresh round of max_attempts tries (attempts 2 and 3)")
    local stuck = e.C:stuck_jobs(e.state)
    T.eq(stuck[1].state, "blocked")
    T.eq(e:status().provisional, 1, "the provisional line stays while the job is blocked")
    out = e:apply({ _ = "operator-retry", job = stuck[1].job })
    local r4 = commands_of(out, "submit-summary")[1]
    T.eq(r4.attempt.n, 4)
    e:finish(r4, "recovered")
    T.eq(e.C:render(e.state), "0+1|recovered\n")
    T.eq(#e.C:stuck_jobs(e.state), 0)
    T.eq(#e:invariants(), 0)
  end },

  { "duplicate, stale and unknown completions publish nothing", function()
    local e = T.engine { max_attempts = 1 }
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
    local e = T.engine { max_attempts = 1 }
    local c0 = commands_of(e:apply(T.msg(0, "user", big(1000))), "submit-summary")[1]
    local c1 = commands_of(e:apply(T.msg(1, "user", big(1000))), "submit-summary")[1]
    e:apply(T.msg(2, "user", "short"))
    local out = e:apply(T.done(c1, "summary one"))
    T.eq(e:status().covered, 0, "message 0 unresolved: nothing may enter the view")
    T.eq(e.C:render(e.state), "")
    T.ok(not T.has_decision(out, "view-extended"))
    out = e:apply(T.done(c0, "summary zero"))
    T.eq(e:status().covered, 3)
    T.eq(e.C:render(e.state), "0+1|summary zero\n1+1|summary one\n2+1|user: short\n")
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
    local e2 = T.engine { lead_window = 64, max_inflight = 4, max_attempts = 1 }
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
