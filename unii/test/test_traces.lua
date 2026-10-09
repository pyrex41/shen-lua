-- Generated event traces (seeded). After every transition the rendered view
-- is checked against an independent Lua model:
--   * lines form an aligned, gap-free partition of [0, covered);
--   * covered equals the first message whose leaf is not yet built, so no
--     unresolved content reaches a turn;
--   * every line's text is exactly the committed node's text (exact leaves
--     verbatim, joins as left LF right, summaries as delivered);
--   * every merge replaced two adjacent siblings by their parent;
--   * the core's own invariant checks report nothing.
-- Re-running a seed reproduces every state hash.
local T = require("unii.test.lib")

local function rng(seed)
  local x = seed % 2147483646 + 1
  return function(n) x = (16807 * x) % 2147483647; return x % n end
end

local function collapse(s) return (s:gsub("[\r\n]", " ")) end
local function kstr(k) return k.level .. "/" .. k.index end

local function parse_view(text)
  local lines = {}
  for line in text:gmatch("[^\n]*\n") do
    if line ~= "<chat>\n" and line ~= "</chat>\n" then
      local first, count, body = line:match("^(%d+)%+(%d+)|(.*)\n$")
      lines[#lines + 1] = { first = tonumber(first), count = tonumber(count), text = body }
    end
  end
  return lines
end

local WORDS = { "alpha", "beta", "日本", "naïve", "🙂", "x\ny", "id=42", "|", "end" }

local function run_trace(seed, steps, cfg)
  local r = rng(seed)
  local e = T.engine(cfg)
  local cap = cfg.leaf_cap
  local texts, built_leaf, msgs = {}, {}, {}
  local delivered = {}
  local hashes = {}
  local count = 0

  local function body(n)
    local parts, len = {}, 0
    while len < n do local w = WORDS[r(#WORDS) + 1]; parts[#parts + 1] = w; len = len + #w + 1 end
    return table.concat(parts, " ")
  end

  local function check(out, prev_lines)
    local errs = e:invariants()
    if #errs > 0 then error("core invariants: " .. table.concat(errs, "; ")) end
    for _, d in ipairs(out.decisions) do
      if d._ == "node-committed" then
        local k = d.key
        if d.origin._ == "exact-leaf" then
          local m = msgs[k.index]
          texts[kstr(k)] = m.kind .. ": " .. m.text
        elseif d.origin._ == "joined" then
          local l = texts[k.level - 1 .. "/" .. 2 * k.index]
          local rt = texts[k.level - 1 .. "/" .. 2 * k.index + 1]
          T.ok(l and rt, "join without both children")
          texts[kstr(k)] = l .. "\n" .. rt
        else
          texts[kstr(k)] = delivered[d.origin.job]
        end
        T.eq(#texts[kstr(k)], d.bytes, "committed byte count")
        T.ok(d.bytes <= cap, "node over cap")
        if k.level == 0 then built_leaf[k.index] = true end
      end
    end
    local text = e.C:render(e.state)
    local lines = parse_view(text)
    local at = 0
    for _, ln in ipairs(lines) do
      T.eq(ln.first, at, "partition gap/overlap")
      local l = math.log(ln.count) / math.log(2)
      T.eq(2 ^ math.floor(l + 0.5), ln.count, "count is a power of two")
      T.eq(ln.first % ln.count, 0, "aligned")
      local key = math.floor(l + 0.5) .. "/" .. (ln.first / ln.count)
      T.eq(ln.text, collapse(texts[key]), "line text is the committed node text for " .. key)
      at = at + ln.count
    end
    local first_unbuilt = 0
    while built_leaf[first_unbuilt] do first_unbuilt = first_unbuilt + 1 end
    if first_unbuilt > count then first_unbuilt = count end
    T.eq(at, first_unbuilt, "covered must stop at the first unresolved message")
    T.eq(e:status().covered, at)
    -- Replaying the decisions over the previous view must give exactly the
    -- new view: extensions append at the end, each merge replaces two
    -- adjacent siblings by their parent, and nothing else changes.
    local sim = {}
    for i, ln in ipairs(prev_lines) do sim[i] = { first = ln.first, count = ln.count } end
    for _, d in ipairs(out.decisions) do
      local k = d.key
      if d._ == "view-extended" then
        local last = sim[#sim]
        T.eq(k.level, 0, "extensions are leaves")
        T.eq(k.index, last and last.first + last.count or 0, "extension appends at the end")
        sim[#sim + 1] = { first = k.index, count = 1 }
      elseif d._ == "view-merged" then
        local half, cf = 2 ^ (k.level - 1), k.index * 2 ^ k.level
        local at
        for i = 1, #sim - 1 do
          if sim[i].first == cf and sim[i].count == half and sim[i + 1].first == cf + half
            and sim[i + 1].count == half then at = i end
        end
        T.ok(at, "merged pair must be adjacent siblings in the view")
        table.remove(sim, at + 1)
        sim[at] = { first = cf, count = 2 * half }
      end
    end
    T.eq(#sim, #lines, "decision replay line count")
    for i = 1, #sim do
      T.eq(sim[i].first .. "+" .. sim[i].count, lines[i].first .. "+" .. lines[i].count, "decision replay line " .. i)
    end
    hashes[#hashes + 1] = e.C:state_hash(e.state)
    return lines
  end

  local lines, done_cmds = {}, {}
  for _ = 1, steps do
    local roll = r(100)
    local out
    if roll < 45 or #e.pending == 0 then
      local size = ({ 5, 40, 120, 300, 700 })[r(5) + 1]
      local kinds = { "user", "assistant", "tool-call", "tool-result" }
      local m = { kind = kinds[r(4) + 1], text = body(size) }
      msgs[count] = m
      out = e:apply(T.msg(count, m.kind, m.text))
      count = count + 1
    elseif roll < 50 and #done_cmds > 0 then
      local c = done_cmds[r(#done_cmds) + 1]          -- stale / duplicate delivery
      out = e:apply(T.done(c, "late duplicate"))
      T.eq(T.decision_names(out), "completion-ignored")
    else
      local c = e:take(r(#e.pending) + 1)             -- out-of-order completion
      local o = r(100)
      if o < 6 then
        out = e:apply(T.failed(c, "retryable"))
      elseif o < 10 then
        out = e:apply(T.done(c, ("z"):rep(cap + 1 + r(50))))
      else
        local text = ("[s %d/%d] "):format(c.key.level, c.key.index) .. body(r(cap - 20))
        text = require("unii.host.codec").utf8_prefix(text, cap)
        delivered[c.job] = text
        out = e:apply(T.done(c, text))
      end
      done_cmds[#done_cmds + 1] = c
    end
    lines = check(out, lines)
  end
  return hashes, e
end

local CFG = { leaf_cap = 160, low = 900, high = 1800, lead_window = 4, max_inflight = 3, max_attempts = 5 }

return {
  { "6 seeded traces x 400 events keep coverage, alignment and exact merges", function()
    local merges, batches = 0, 0
    for seed = 1, 6 do
      local _, e = run_trace(seed, 400, CFG)
      for _, out in ipairs(e.log) do
        for _, d in ipairs(out.decisions) do
          if d._ == "view-merged" then merges = merges + 1 end
          if d._ == "batch-mode" and d.on then batches = batches + 1 end
        end
      end
    end
    T.ok(merges > 50, "traces should exercise merges (" .. merges .. ")")
    T.ok(batches > 5, "traces should exercise batches (" .. batches .. ")")
  end },

  { "replaying a seed reproduces every state hash", function()
    local a = run_trace(42, 250, CFG)
    local b = run_trace(42, 250, CFG)
    T.eq(#a, #b)
    for i = 1, #a do T.eq(a[i], b[i], "state hash at step " .. i) end
  end },
}
