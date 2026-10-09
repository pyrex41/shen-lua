-- unii/host/models.lua -- provider-neutral summarizer interface.
--
-- A provider turns one submit-summary command (plus the source text the
-- host loaded for it) into a streamed request on a network client, and
-- reports exactly one outcome:
--   on_outcome{ ok = true,  text = "..." }
--   on_outcome{ ok = false, class = "retryable" | "permanent", error = "..." }
-- The supervisor converts outcomes into summary-completed / summary-failed
-- events; providers never touch core state.
--
-- Provider shape:
--   provider.name, provider.is_mock
--   provider:start(client, job, on_outcome) -> request handle (cancel())
-- where job = { cmd, job, key, attempt, retry, input, source }.
local M = {}

-- Map a transport result to a failure classification.
function M.classify(result)
  if result.status == "ok" then
    local h = result.http_status or 200
    if h >= 200 and h < 300 then return nil end
    if h == 429 or h >= 500 then return "retryable" end
    return "permanent"
  end
  if result.status == "cancelled" then return "retryable" end
  if result.status == "timeout" or result.status == "error" then return "retryable" end
  return "permanent" -- overflow and anything unknown
end

-- Accumulate a streamed body and deliver one outcome.
function M.collect(on_outcome)
  local parts = {}
  return {
    on_chunk = function(c) parts[#parts + 1] = c end,
    on_done = function(result)
      local class = M.classify(result)
      if class then
        on_outcome { ok = false, class = class, error = result.error or result.status }
      else
        on_outcome { ok = true, text = table.concat(parts) }
      end
    end,
  }
end

return M
