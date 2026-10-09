-- unii/host/synthetic.lua -- deterministic synthetic conversation messages
-- for the milestone CLI and tests. Host-side only: the seed and the date
-- base are inputs, so the same arguments always give the same messages.
local M = {}

local WORDS = {
  "deploy", "rollback", "the", "config", "file", "src/main.lua", "error", "fixed",
  "user", "decided", "to", "keep", "batch", "view", "summary", "café", "naïve",
  "日本語", "テスト", "🙂", "e\204\129", "Zoë", "id=4821", "PR#71", "build", "failed",
  "because", "timeout", "rename", "notes.md", "→", "ok", "later", "retry", "|", "<chat>",
}
local KINDS = { "user", "assistant", "tool-call", "tool-result" }

-- Park-Miller minimal standard generator: exact in doubles (16807 * x < 2^46).
local function rng(seed)
  local x = seed % 2147483646 + 1
  return function(n)
    x = (16807 * x) % 2147483647
    return x % n
  end
end

-- Message i of a stream: { kind, text, date }.
function M.message(seed, i)
  local r = rng(seed * 1000003 + i)
  local kind = KINDS[r(#KINDS) + 1]
  local roll = r(10)
  local target
  if roll < 6 then target = 8 + r(180)
  elseif roll < 9 then target = 300 + r(700)
  else target = 2000 + r(4000) end
  local parts, len = {}, 0
  while len < target do
    local w = WORDS[r(#WORDS) + 1]
    if r(17) == 0 then w = w .. "\n" end
    parts[#parts + 1] = w
    len = len + #w + 1
  end
  local text = ("m%d %s"):format(i, table.concat(parts, " "))
  local date = os.date("!%Y-%m-%dT%H:%M:%SZ", 1791504000 + i * 37) -- from 2026-10-09T00:00:00Z
  return { kind = kind, text = text, date = date }
end

return M
