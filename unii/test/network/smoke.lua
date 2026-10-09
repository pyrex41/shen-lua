-- Real-provider smoke test. Skips with status "skip" when no API key is set.
-- A skip is a successful run of this spike: it is not a provider integration.
--
--   luajit unii/test/network/smoke.lua

local dir = (arg and arg[0] or ""):match("^(.*)/[^/]+$") or "."
local root = dir:gsub("/unii/test/network$", "")
if root == dir then
  root = dir:gsub("unii/test/network$", "")
end
if root == "" then root = "." end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local network = require("unii.host.network")
local json = require("unii.host.network.json")

local function run()
  local key = os.getenv("OPENAI_API_KEY")
  if key == nil or key == "" then
    key = os.getenv("UNII_OPENAI_API_KEY")
  end
  if key == nil or key == "" then
    return "skip", "no API key (set OPENAI_API_KEY or UNII_OPENAI_API_KEY)"
  end

  local url = os.getenv("UNII_OPENAI_BASE_URL")
  if url == nil or url == "" then
    url = "https://api.openai.com/v1/chat/completions"
  end
  local model = os.getenv("UNII_OPENAI_MODEL")
  if model == nil or model == "" then
    model = "gpt-4o-mini"
  end

  local logs = {}
  local client = network.client({
    log = function(_level, msg)
      logs[#logs + 1] = msg
    end,
  })
  local parts = {}
  local handle, err = client:chat_stream({
    url = url,
    api_key = key,
    timeout_ms = 20000,
    payload = {
      model = model,
      messages = json.array({
        { role = "user", content = "Reply with the single word pong." },
      }),
    },
    on_delta = function(text)
      parts[#parts + 1] = text
    end,
  })
  if not handle then
    client:close()
    return "fail", "chat_stream rejected: " .. network.redact.text(tostring(err))
  end

  local spins = 0
  while not handle:done() do
    client:tick(50)
    spins = spins + 1
    if spins > 2000 then
      handle:cancel()
      client:tick(0)
      break
    end
  end
  local result = handle.result
  client:close()

  local blob = table.concat(logs, "\n")
  if blob:find(key, 1, true) then
    return "fail", "smoke log contained the API key"
  end
  if not result then
    return "fail", "smoke produced no result"
  end
  if result.outcome ~= "succeeded" then
    return "fail", "smoke outcome " .. tostring(result.outcome)
        .. " reason " .. tostring(result.reason)
        .. " curl " .. tostring(result.curl_code)
  end
  if #parts == 0 then
    return "fail", "smoke stream produced no deltas"
  end
  return "ok", "deltas=" .. tostring(#parts)
end

local invoked_as = ...
if invoked_as ~= "unii.test.network.smoke" then
  local status, detail = run()
  if status == "skip" then
    print("SKIP smoke: " .. tostring(detail))
    os.exit(0)
  elseif status == "ok" then
    print("ok smoke " .. tostring(detail))
    os.exit(0)
  end
  print("FAIL smoke: " .. tostring(detail))
  os.exit(1)
end

return { run = run }
