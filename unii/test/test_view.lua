-- Merge-order gates (plan section 16, Phase 1):
--   * the gist's small rollback examples (t = 0..9 table, T = 10 example);
--   * merge sequence vs the gist's rollback push over 20,001 steps under
--     the line-count budget "after appending message t, merge the most due
--     pair until the view has as many lines as push's list at t";
--   * deterministic tie-breaks.
-- The push function below is a direct transcription of the gist's
-- rollback_state_list.js push, used as the test-side reference. The
-- independent oracle's golden fixtures are diffed in test_oracle.lua.
local T = require("unii.test.lib")

local function push(new, st)
  if st == nil then return { keep = 0, life = 0, state = new, older = nil } end
  if st.keep == 0 then return { keep = 1, life = st.life, state = st.state, older = st.older } end
  if st.life > 0 then
    return { keep = 0, life = 0, state = new,
             older = { keep = 0, life = st.life - 1, state = st.state, older = st.older } }
  end
  return { keep = 0, life = st.life, state = new, older = push(st.state, st.older) }
end

-- Push list read as view lines, oldest first: {first, count}.
local function push_lines(st, total)
  local starts = {}
  while st do starts[#starts + 1] = st.state; st = st.older end
  local lines = {}
  for k = #starts, 1, -1 do
    local s = starts[k]
    local e = (k > 1) and starts[k - 1] or total
    lines[#lines + 1] = { s, e - s }
  end
  return lines
end

local function as_lines(keys)
  local out = {}
  for i, k in ipairs(keys) do out[i] = { k[2] * 2 ^ k[1], 2 ^ k[1] } end
  return out
end

local function same(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i][1] ~= b[i][1] or a[i][2] ~= b[i][2] then return false end end
  return true
end

local function fmt(lines)
  local t = {}
  for i, l in ipairs(lines) do t[i] = l[1] .. "+" .. l[2] end
  return table.concat(t, ", ")
end

-- Reference merge with an arbitrary due function (for the "first message"
-- counterexample only; the Shen core is what is under test).
local function ref_merge(keys, total, budget, due)
  while #keys > budget do
    local best, bk
    for k = 1, #keys - 1 do
      local a, b = keys[k], keys[k + 1]
      if a[1] == b[1] and a[2] % 2 == 0 and b[2] == a[2] + 1 then
        local d = due(total, a[1], a[2])
        if not best or d > best then best, bk = d, k end
      end
    end
    if not bk then break end
    local a = keys[bk]
    table.remove(keys, bk + 1)
    keys[bk] = { a[1] + 1, a[2] / 2 }
  end
  return keys
end

local function run_against_push(steps, merge)
  local st, keys, matches, first_mismatch = nil, {}, 0, nil
  for t = 0, steps - 1 do
    st = push(t, st)
    local total = t + 1
    keys[#keys + 1] = { 0, t }
    local want = push_lines(st, total)
    keys = merge(keys, total, #want)
    if same(as_lines(keys), want) then matches = matches + 1
    elseif not first_mismatch then first_mismatch = { t = t, got = fmt(as_lines(keys)), want = fmt(want) } end
  end
  return matches, first_mismatch
end

local function shen_merge(keys, total, budget)
  local view = T.core():merge_to_count(keys, total, budget)
  return view
end

return {
  { "gist t=0..9 push table reproduced by push and by the Shen merge order", function()
    -- From the gist: t=0 -0 | t=1 +0 | t=2 -2,-0 | t=3 +2,-0 | t=4 -4,+0 |
    -- t=5 +4,+0 | t=6 -6,-4,-0 | t=7 +6,-4,-0 | t=8 -8,+4,-0 | t=9 +8,+4,-0
    local starts = { { 0 }, { 0 }, { 2, 0 }, { 2, 0 }, { 4, 0 }, { 4, 0 }, { 6, 4, 0 },
                     { 6, 4, 0 }, { 8, 4, 0 }, { 8, 4, 0 } }
    local st, keys = nil, {}
    for t = 0, 9 do
      st = push(t, st)
      local got = {}
      local s = st
      while s do got[#got + 1] = s.state; s = s.older end
      T.eq(table.concat(got, ","), table.concat(starts[t + 1], ","), "push at t=" .. t)
      keys[#keys + 1] = { 0, t }
      local want = push_lines(st, t + 1)
      keys = shen_merge(keys, t + 1, #want)
      T.eq(fmt(as_lines(keys)), fmt(want), "Shen view at t=" .. t)
    end
    T.eq(fmt(as_lines(keys)), "0+4, 4+4, 8+2", "gist: at t=9 the lines are 8+2, 4+4, 0+4")
  end },

  { "gist T=10 example: endpoint due merges 8-9, first-message due merges 0-7", function()
    local view = { { 2, 0 }, { 2, 1 }, { 0, 8 }, { 0, 9 } } -- 0+4, 4+4, 8+1, 9+1
    local _, merged = T.core():merge_to_count(view, 10, 3)
    T.eq(#merged, 1)
    T.eq(merged[1][1] .. "/" .. merged[1][2], "1/4", "endpoint rule merges 8+1, 9+1 into 8+2")
    local wrong = ref_merge({ { 2, 0 }, { 2, 1 }, { 0, 8 }, { 0, 9 } }, 10, 3,
      function(total, l, i) return (total - i * 2 ^ l) / 2 ^ l end)
    T.eq(fmt(as_lines(wrong)), "0+8, 8+1, 9+1", "first-message rule merges 0-7")
  end },

  { "Shen merge order equals rollback push at all 20,001 steps (t = 0..20,000)", function()
    local matches, mismatch = run_against_push(20001, shen_merge)
    if mismatch then
      error(("first mismatch at t=%d: got %s, push %s"):format(mismatch.t, mismatch.got, mismatch.want))
    end
    T.eq(matches, 20001)
  end },

  { "first-message due matches push at only 481 of 20,001 steps (gist)", function()
    local matches = run_against_push(20001, function(keys, total, budget)
      return ref_merge(keys, total, budget, function(tt, l, i) return (tt - i * 2 ^ l) / 2 ^ l end)
    end)
    T.eq(matches, 481)
  end },

  { "equal due scores select the oldest pair, deterministically", function()
    -- T = 7: pairs (0,0) last 1 -> due 6 ; (0,2) last 3 -> due 4 ; (1,0) last 3 -> due 2
    -- Construct equal scores: level-0 pair ending at 3 (due 4) and level-1 pair
    -- (1,2) ending at 7 with T=11: due (11-7)/2 = 2 vs level-0 pair (0,8) ending 9: due 2.
    local view = { { 2, 0 }, { 1, 2 }, { 1, 3 }, { 0, 8 }, { 0, 9 }, { 0, 10 } }
    for _ = 1, 3 do
      local _, merged = T.core():merge_to_count(view, 11, 5)
      T.eq(merged[1][1] .. "/" .. merged[1][2], "2/1", "older of two equal-due pairs wins")
    end
  end },

}
