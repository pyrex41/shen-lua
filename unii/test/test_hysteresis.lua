-- Byte-budget hysteresis, tested separately from the line-count merge gate.
-- An independent Lua model predicts every transition's policy outcome:
--   pre  = previous view bytes + line bytes of the lines extended this step
--   if previously in batch mode or pre > high:
--       merges happen until bytes <= low; batch mode persists iff the view
--       is still above low (no eligible built sibling pair was left)
--   else:
--       no merges, batch mode stays off, bytes == pre (and so <= high)
local T = require("unii.test.lib")

local function rng(seed)
  local x = seed % 2147483646 + 1
  return function(n) x = (16807 * x) % 2147483647; return x % n end
end

local function line_bytes(key, text_bytes)
  local count = 2 ^ key.level
  local first = key.index * count
  return #("%d+%d|"):format(first, count) + text_bytes + 1
end

local function run(cfg, steps, seed, opts)
  local r = rng(seed)
  local e = T.engine(cfg)
  local low, high = cfg.low, cfg.high
  local node_bytes = {}
  local prev = e:status()
  local stats = { entered = 0, exited = 0, merges = 0, stalled = 0, max_bytes = 0, events = 0 }

  local function check(out)
    local pre = prev.view_bytes
    local merges = 0
    for _, d in ipairs(out.decisions) do
      if d._ == "node-committed" then
        node_bytes[d.key.level .. "/" .. d.key.index] = line_bytes(d.key, d.bytes)
      elseif d._ == "view-extended" then
        pre = pre + node_bytes[d.key.level .. "/" .. d.key.index]
      elseif d._ == "view-merged" then
        merges = merges + 1
      end
    end
    local now = e:status()
    local view_text = e.C:render(e.state)
    if pre > stats.max_bytes then stats.max_bytes = pre end
    if prev.batch or pre > high then
      if now.batch then
        T.ok(now.view_bytes > low, "batch mode persisted although bytes <= low")
        stats.stalled = stats.stalled + 1
      else
        T.ok(now.view_bytes <= low, ("left batch mode at %d > low %d"):format(now.view_bytes, low))
      end
      if not prev.batch then stats.entered = stats.entered + 1 end
      if not now.batch then stats.exited = stats.exited + 1 end
    else
      T.eq(merges, 0, "merged while below high and not in batch mode")
      T.eq(now.batch, false, "entered batch mode without crossing high")
      T.eq(now.view_bytes, pre, "bytes without a policy step")
    end
    if not now.batch then T.ok(now.view_bytes <= high, "out of batch mode above high") end
    T.eq(#view_text, now.view_bytes)
    stats.merges = stats.merges + merges
    local errs = e:invariants()
    if #errs > 0 then error("core invariants: " .. table.concat(errs, "; ")) end
    prev = now
  end

  local function apply(ev) stats.events = stats.events + 1; check(e:apply(ev)) end

  for i = 0, steps - 1 do
    apply(T.msg(i, (i % 2 == 0) and "user" or "assistant", ("m"):rep(opts.msg_min + r(opts.msg_span))))
    -- Complete pending summaries, but sometimes hold them back so batch mode
    -- has to wait for parents to be built.
    if r(opts.hold_one_in) ~= 0 then
      while #e.pending > 0 do
        apply(T.done(e:take(), ("s"):rep(opts.sum_min + r(opts.sum_span))))
      end
    end
  end
  while #e.pending > 0 do apply(T.done(e:take(), ("s"):rep(opts.sum_min))) end
  return stats, e
end

return {
  { "small thresholds: sawtooth between high and low, exact model agreement", function()
    local cfg = { low = 1500, high = 3000 }
    local total = { entered = 0, exited = 0, merges = 0, stalled = 0 }
    for seed = 1, 4 do
      local s = run(cfg, 300, seed,
        { msg_min = 10, msg_span = 400, sum_min = 20, sum_span = 200, hold_one_in = 4 })
      for k in pairs(total) do total[k] = total[k] + s[k] end
      T.ok(s.max_bytes > cfg.high, "the trace crossed high")
    end
    T.ok(total.entered >= 8, "batch mode entered repeatedly: " .. total.entered)
    T.ok(total.exited >= 8, "batch mode exited repeatedly: " .. total.exited)
    T.ok(total.stalled > 0, "some batch modes stalled waiting for parents: " .. total.stalled)
    T.ok(total.merges > 0)
  end },

  { "no merge happens below high: a view may sit between low and high", function()
    local cfg = { low = 1000, high = 4000 }
    local e = T.engine(cfg)
    for i = 0, 9 do e:apply(T.msg(i, "user", ("q"):rep(300))) end -- each exact leaf is alone
    while #e.pending > 0 do e:apply(T.done(e:take(), "short")) end
    local st = e:status()
    T.ok(st.view_bytes > cfg.low and st.view_bytes <= cfg.high, tostring(st.view_bytes))
    T.eq(st.view_lines, 10)
    T.eq(st.batch, false)
  end },

  { "default 64,000/128,000 budget: crossing 128,000 merges down to <= 64,000", function()
    local cfg = { low = 64000, high = 128000 }
    local s, e = run(cfg, 300, 7,
      { msg_min = 480, msg_span = 26, sum_min = 100, sum_span = 200, hold_one_in = 1000000 })
    T.ok(s.max_bytes > 128000, "crossed 128,000: " .. s.max_bytes)
    T.ok(s.entered >= 1 and s.exited >= 1)
    local st = e:status()
    T.eq(st.batch, false)
    T.ok(st.view_bytes <= 128000)
  end },
}
