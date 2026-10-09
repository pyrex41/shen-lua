-- Engine versus the independent oracle (unii/eval/oracle, plain Lua, no
-- Shen). Every case drives the typed Shen core and diffs it against the
-- oracle's golden fixtures or against the oracle module run side by side.
local T = require("unii.test.lib")
local oracle = require("unii.eval.oracle.oracle")

local function S() T.core(); return require("unii.host.core").shen() end
local FIX = T.root() .. "/unii/eval/fixtures/"

local function log2(n) local l = 0; while 2 ^ l < n do l = l + 1 end; return l end
local function parse_addrs(s)
  local out = {}
  if s == "-" then return out end
  for first, count in s:gmatch("(%d+)%+(%d+)") do
    first, count = tonumber(first), tonumber(count)
    out[#out + 1] = { log2(count), first / count }
  end
  return out
end
local function fmt(keys)
  local t = {}
  for i, k in ipairs(keys) do t[i] = (k[2] * 2 ^ k[1]) .. "+" .. 2 ^ k[1] end
  return #t == 0 and "-" or table.concat(t, ",")
end
local function lines_of(path, prefix)
  local rows = {}
  for line in io.lines(path) do
    if line:sub(1, 2) == prefix .. "|" then
      local f = {}
      for field in (line .. "|"):gmatch("([^|]*)|") do f[#f + 1] = field end
      rows[#rows + 1] = f
    end
  end
  return rows
end

-- The fixture generator's node text (unii/eval/oracle/generate_fixtures.lua).
-- If this copy drifted, the byte columns below would stop matching.
local function synthetic_text(value)
  local node = oracle.node(value.level, value.index)
  local target = 420 + ((node.first * 17 + node.level * 31) % 80)
  local prefix = string.format("kind: synthetic %d+%d | 100%% caf\195\169 e\204\129\r\n", node.first, node.count)
  local fill = string.char(97 + ((node.index + node.level) % 26))
  return prefix .. string.rep(fill, target - #prefix)
end

-- Engine-side byte policy over explicit nodes: the same unii.apply-byte-policy
-- the transition uses, with the oracle's notion of "parent available".
local function policy_engine(opts)
  local s = S()
  local codec = require("unii.host.codec")
  local schema = require("unii.host.schema")
  local cfg = codec.to_shen(schema.encode("config", schema.config { low = opts.low, high = opts.high }))
  local joined = s.list({ s.sym("joined") })
  local cache = {}
  local function node(l, i)
    local id = l .. ":" .. i
    if not cache[id] then
      local text = opts.text_for { level = l, index = i }
      local n = s.call("unii.make-node", s.list({ s.sym("key"), l, i }), text, #text, joined)
      cache[id] = { shen = n, bytes = s.call("unii.node-line-bytes", n), line = s.call("unii.node-line", n) }
    end
    return cache[id]
  end
  local e = { view = {}, count = 0, batch = false }

  local function step(allow_entry)
    local T_ = e.count
    local vb, vlist, inview = 0, {}, {}
    for i, k in ipairs(e.view) do
      local n = node(k[1], k[2]); vb = vb + n.bytes; vlist[i] = n.shen; inview[k[1] .. ":" .. k[2]] = true
    end
    -- Every ancestor wholly inside [0, T) that is not in the view and is available.
    local live, seen = {}, {}
    for _, k in ipairs(e.view) do
      local l, i = k[1], k[2]
      while true do
        l, i = l + 1, math.floor(i / 2)
        if l > 30 or (i + 1) * 2 ^ l > T_ then break end
        local id = l .. ":" .. i
        if not seen[id] and not inview[id] then
          seen[id] = true
          if not opts.available or opts.available { level = l, index = i } then
            live[#live + 1] = node(l, i).shen
          end
        end
      end
    end
    local before = vb
    local entered = allow_entry and not e.batch and before > opts.high
    local r = s.totable(s.call("unii.apply-byte-policy", cfg, T_, s.list(vlist), vb, s.list(live), e.batch))
    local view, merged = {}, {}
    for i, n in ipairs(s.totable(r[2])) do
      local kt = s.totable(s.call("unii.node-key", n)); view[i] = { kt[2], kt[3] }
    end
    for i, k in ipairs(s.totable(r[6])) do local kt = s.totable(k); merged[i] = { kt[2], kt[3] } end
    e.view, e.batch = view, r[5]
    local text = {}
    for i, k in ipairs(view) do text[i] = node(k[1], k[2]).line end
    return { batch = r[5], entered = entered, bytes_before = before, bytes = r[3],
             merges = merged, rendered = table.concat(text) }
  end

  function e:append() self.count = self.count + 1; self.view[#self.view + 1] = { 0, self.count - 1 }; return step(true) end
  function e:resume() return step(false) end
  return e
end

local function okeys2(keys)
  local out = {}
  for i, k in ipairs(keys) do out[i] = { level = k[1], index = k[2] } end
  return out
end

local function okeys(view)
  local out = {}
  for i, v in ipairs(view) do out[i] = { v.level, v.index } end
  return out
end

-- Run oracle and engine side by side and diff every step.
local function side_by_side(opts, steps, label)
  local o = oracle.new_hysteresis { low_bytes = opts.low, high_bytes = opts.high, text_for = opts.text_for,
                                    parent_available = opts.available }
  local e = policy_engine(opts)
  for n = 1, steps do
    local resume = opts.resume_every and n % opts.resume_every == 0
    if resume and opts.flip then opts.flip(n) end
    local a = resume and oracle.hysteresis_resume(o) or oracle.hysteresis_append(o)
    local b = resume and e:resume() or e:append()
    local where = ("%s step %d"):format(label, n)
    T.eq(b.bytes_before, a.bytes_before, where .. " bytes before")
    T.eq(b.bytes, a.bytes, where .. " bytes after")
    T.eq(b.batch, a.batch, where .. " batch")
    T.eq(b.entered, a.entered_batch, where .. " entered")
    T.eq(fmt(b.merges), fmt(okeys(a.merges)), where .. " merges")
    T.eq(fmt(e.view), fmt(okeys(o.view)), where .. " view")
    T.eq(b.rendered, a.rendered, where .. " rendered bytes")
  end
end

return {
  { "rollback-20001.trace: engine merges and views equal the oracle at every step", function()
    local C = T.core()
    local rows = lines_of(FIX .. "rollback-20001.trace", "R")
    T.eq(#rows, 20001)
    local view = {}
    for n, f in ipairs(rows) do
      local T_, budget = tonumber(f[2]), tonumber(f[3])
      T.eq(T_, n)
      view[#view + 1] = { 0, T_ - 1 }
      local merged
      view, merged = C:merge_to_count(view, T_, budget)
      T.eq(fmt(view), fmt(parse_addrs(f[5])), "view at T=" .. T_)
      T.eq(fmt(merged), fmt(parse_addrs(f[4])), "merges at T=" .. T_)
    end
  end },

  { "byte-hysteresis.trace: engine bytes, batch state, merges and views equal the oracle", function()
    local rows = lines_of(FIX .. "byte-hysteresis.trace", "B")
    T.eq(#rows, 700)
    local e = policy_engine { low = 64000, high = 128000, text_for = synthetic_text }
    local entries = 0
    for n, f in ipairs(rows) do
      local r = e:append()
      local where = "T=" .. f[2]
      T.eq(e.count, tonumber(f[2]), where)
      T.eq(r.batch and "1" or "0", f[3], where .. " batch")
      T.eq(r.entered and "1" or "0", f[4], where .. " entered")
      T.eq(r.bytes_before, tonumber(f[5]), where .. " bytes before")
      T.eq(r.bytes, tonumber(f[6]), where .. " bytes after")
      T.eq(fmt(r.merges), fmt(parse_addrs(f[7])), where .. " merges")
      T.eq(fmt(e.view), fmt(parse_addrs(f[8])), where .. " view")
      if r.entered then entries = entries + 1 end
      if n % 100 == 0 then
        local rendered = oracle.render_view(okeys2(e.view), synthetic_text)
        T.eq(r.rendered, rendered, where .. " rendering")
      end
    end
    T.ok(entries >= 2, "the trace crosses 128,000 bytes repeatedly")
  end },

  { "side by side: thresholds at equality, stalled batches, resumption", function()
    local x10 = function() return ("x"):rep(10) end
    side_by_side({ low = 5, high = 15, text_for = x10 }, 6, "exact high")      -- 15 bytes does not enter
    side_by_side({ low = 15, high = 29, text_for = x10 }, 6, "exact low")      -- 30 enters, 15 exits
    local avail = false
    side_by_side({ low = 5, high = 10, text_for = function() return "abcdefghijklmnopqrst" end,
                   available = function() return avail end, resume_every = 3,
                   flip = function(n) avail = n >= 6 end }, 12, "unavailable parents")
  end },

  { "side by side: 40 random configurations with hostile text and partial availability", function()
    local seed = 20261009
    local function rnd(n) seed = (seed * 48271) % 2147483647; return seed % n end
    local TOK = { "a", "é", "e\204\129", "\r\n", "\r", "\n", "\194\133", "\226\128\168", "\226\128\169",
                  "\t", "|", "%", "🙂", "\0", "\127", "<chat>", " " }
    for case = 1, 40 do
      local texts = {}
      local function text_for(v)
        local id = v.level .. ":" .. v.index
        if not texts[id] then
          local parts, len, want = {}, 0, 1 + rnd(case % 3 == 0 and 900 or 120)
          while len < want do local t = TOK[rnd(#TOK) + 1]; parts[#parts + 1] = t; len = len + #t end
          texts[id] = table.concat(parts)
        end
        return texts[id]
      end
      local low = 200 + rnd(2000)
      local high = low + 1 + rnd(3000)
      local hole = rnd(5)
      local avail = function(v) return (v.index + v.level) % 5 ~= hole end
      side_by_side({ low = low, high = high, text_for = text_for, available = avail, resume_every = 7,
                     flip = function() hole = (hole + 1) % 5 end }, 120, "case " .. case)
    end
  end },

  { "addresses and keys agree with the oracle at the v1 ceiling", function()
    local s = S()
    local MAX = oracle.MAX_MESSAGES
    local function engine_zoom(first, count)
      return #s.totable(s.call("unii.address->key", first, count, MAX)) == 1
    end
    local cases = { { MAX - 1, 1 }, { MAX - 1, 2 }, { MAX - 2, 2 }, { 0, 2 ^ 30 }, { 2 ^ 30, 2 ^ 30 },
                    { 0, 3 }, { 2, 4 }, { 40, 8 }, { 0, 1 }, { MAX - 64, 64 }, { 2 ^ 31 - 2 ^ 20, 2 ^ 20 } }
    for _, c in ipairs(cases) do
      local ok = pcall(oracle.zoom, c[1], c[2])
      T.eq(engine_zoom(c[1], c[2]), ok, ("zoom %d+%d"):format(c[1], c[2]))
    end
    for _, k in ipairs { { 0, MAX - 1 }, { 0, MAX }, { 30, 0 }, { 30, 1 }, { 31, 0 }, { 29, 2 }, { 29, 3 }, { 1, (MAX - 1) / 2 } } do
      local ok = pcall(oracle.node, k[1], k[2])
      T.eq(s.call("unii.valid-key?", s.list({ s.sym("key"), k[1], k[2] })), ok, ("key %d/%d"):format(k[1], k[2]))
    end
  end },

  { "due ordering agrees with the oracle's exact cross-products (6,000 pairs)", function()
    local s = S()
    local seed = 77
    local function rnd(n) seed = (seed * 48271) % 2147483647; return seed % n end
    local function cand(T_, l, i)
      local left = oracle.node(l, i)
      local right = oracle.node(l, i + 1)
      return { numerator = T_ - right.last, level = l, last = right.last,
               parent = oracle.node(l + 1, i / 2) }
    end
    local MAX = oracle.MAX_MESSAGES
    for n = 1, 6000 do
      local T_ = n % 3 == 0 and (MAX - rnd(1000)) or (2 + rnd(5000000))
      local function pick()
        while true do
          local l = rnd(n % 5 == 0 and 30 or 12)
          local span = 2 ^ (l + 1)
          if span <= T_ then return l, 2 * rnd(math.floor(T_ / span)) end
        end
      end
      local l1, i1 = pick()
      local l2, i2 = pick()
      local a, b = cand(T_, l1, i1), cand(T_, l2, i2)
      local d1 = s.call("unii.pair-due", T_, s.list({ s.sym("key"), l1, i1 }))
      local d2 = s.call("unii.pair-due", T_, s.list({ s.sym("key"), l2, i2 }))
      local o = oracle.compare_due(a, b)
      local strict = (a.numerator * 2 ^ b.level) > (b.numerator * 2 ^ a.level)
      T.eq(s.call("unii.due>", d1, d2), strict, ("T=%d %d/%d vs %d/%d"):format(T_, l1, i1, l2, i2))
      if strict then T.eq(o, 1) end
    end
  end },

  { "canonical lines equal the oracle's rendering for 3,000 hostile texts", function()
    local s = S()
    local seed = 4242
    local function rnd(n) seed = (seed * 48271) % 2147483647; return seed % n end
    local TOK = { "a", "é", "日本", "\r\n", "\r", "\n", "\n\r", "\194\133", "\226\128\168", "\226\128\169",
                  "\226\128\170", "\194\134", "\t", "\11", "\12", "|", "%", "🙂", "\0", "\31", "\127", "<chat>", "" }
    for n = 1, 3000 do
      local parts, len, want = {}, 0, rnd(n % 10 == 0 and 3000 or 200)
      while len < want do local t = TOK[rnd(#TOK) + 1]; parts[#parts + 1] = t; len = len + #t end
      local text = table.concat(parts)
      local l = rnd(20)
      local i = rnd(1000)
      local line = s.totable(s.call("unii.make-line", s.list({ s.sym("key"), l, i }), text, #text))
      local want_line = oracle.render_line({ level = l, index = i }, text)
      T.eq(line[2], want_line, "text #" .. n)
      T.eq(line[3], #want_line, "bytes #" .. n)
    end
  end },
}
