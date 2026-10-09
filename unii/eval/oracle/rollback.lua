-- Literal plain-Lua port of Victor Taelin's rollback push.
--
-- Source gist revision:
--   3c190e06f34aba0c69f49042c526093269604935
-- Source file:
--   optchat.md
-- SHA-256:
--   12f300f760af82bc07bc5201051d1267824ded09c9def8186e4f8144368038d8
--
-- The source's JavaScript object list is represented as linked Lua tables.
-- Field names and branch structure intentionally stay close to the source so
-- this can serve as a reference independent of the due-score implementation.

local oracle = require("unii.eval.oracle.oracle")

local M = {}

function M.push(new_state, states)
  if states == nil then
    return { keep = 0, life = 0, state = new_state, older = nil }
  end

  local keep = states.keep
  local life = states.life
  local state = states.state
  local older = states.older

  if keep == 0 then
    return { keep = 1, life = life, state = state, older = older }
  end

  if life > 0 then
    return {
      keep = 0,
      life = 0,
      state = new_state,
      older = {
        keep = 0,
        life = life - 1,
        state = state,
        older = older,
      },
    }
  end

  return {
    keep = 0,
    life = life,
    state = new_state,
    older = M.push(state, older),
  }
end

function M.length(states)
  local count = 0
  while states do
    count = count + 1
    states = states.older
  end
  return count
end

-- Convert newest-first rollback checkpoints into the corresponding
-- oldest-first exact tree partition at message count T.
function M.to_view(states, message_count)
  local newest_first = {}
  local cursor = states
  while cursor do
    newest_first[#newest_first + 1] = cursor.state
    cursor = cursor.older
  end

  local view = {}
  local after = message_count
  for position = 1, #newest_first do
    local first = newest_first[position]
    local count = after - first
    local node = oracle.zoom(first, count)
    table.insert(view, 1, { level = node.level, index = node.index })
    after = first
  end
  oracle.assert_partition(view, message_count)
  return view
end

return M
