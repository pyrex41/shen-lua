-- unii/host/models.lua -- provider-neutral summarizer interface.
--
-- A provider turns one submit-summary command (plus the source text the
-- host loaded for it) into one request on a network client (the real
-- adapter in unii/host/network/ or the mock in unii/host/mock/network.lua),
-- and reports exactly one outcome:
--   on_outcome{ ok = true,  text = "..." }
--   on_outcome{ ok = false, class = "retryable" | "permanent" | "uncertain", error = "..." }
-- The supervisor converts outcomes into summary-completed / summary-failed
-- events; providers never touch core state, and nothing below retries.
--
-- Provider shape:
--   provider.name, provider.is_mock
--   provider:start(job, on_outcome)   -- job = { cmd, job, key, attempt, input, source }
--   provider:step(wait_ms)            -- drive the network client once
--   provider:pending()                -- requests started and not yet reported
local M = {}

local RETRYABLE_REASONS = { connect = true, dns = true, timeout = true, curl = true }

-- Map one adapter result (handle.result) to nil (success) or a failure
-- class. `stream_done` is true when the SSE stream delivered [DONE].
function M.classify(result, stream_done)
  local o = result.outcome
  if o == "succeeded" then
    local h = result.status or 0
    if h >= 200 and h < 300 then
      if stream_done == false then return "retryable", "stream ended without [DONE]" end
      return nil
    end
    if h == 429 or h >= 500 then return "retryable", "http " .. h end
    return "permanent", "http " .. h
  elseif o == "failed" then
    if RETRYABLE_REASONS[result.reason] then return "retryable", result.reason end
    return "permanent", result.reason
  elseif o == "uncertain" then
    return "uncertain", result.reason
  elseif o == "cancelled" then
    if result.sent then return "uncertain", "cancelled after the request was sent" end
    return "retryable", "cancelled before send"
  end
  return "permanent", "unknown outcome " .. tostring(o)
end

return M
