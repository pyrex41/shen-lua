-- Strip credentials from strings before they reach a log sink.
-- Response data returned to the caller is not passed through here.

local M = {}

local SECRET_PARAMS = {
  api_key = true,
  apikey = true,
  key = true,
  token = true,
  access_token = true,
  refresh_token = true,
  secret = true,
  password = true,
  client_secret = true,
  sig = true,
}

M.SECRET_HEADERS = {
  ["authorization"] = true,
  ["proxy-authorization"] = true,
  ["x-api-key"] = true,
  ["api-key"] = true,
  ["cookie"] = true,
  ["set-cookie"] = true,
  ["x-auth-token"] = true,
  ["x-openai-api-key"] = true,
}

function M.header_is_secret(name)
  if type(name) ~= "string" then return false end
  return M.SECRET_HEADERS[name:lower()] == true
end

function M.url(url)
  if type(url) ~= "string" then return url end
  url = url:gsub("://([^/%s:@]+):([^@%s]+)@", "://%1:<redacted>@")
  url = url:gsub("([%?&])([^%s&=]+)=([^%s&]+)", function(sep, key, _value)
    if SECRET_PARAMS[key:lower()] then
      return sep .. key .. "=<redacted>"
    end
    return sep .. key .. "=" .. _value
  end)
  return url
end

function M.text(s)
  if type(s) ~= "string" or s == "" then return s end
  s = s:gsub("Bearer%s+[%w%._%-%~%+/=]+", "Bearer <redacted>")
  s = s:gsub("sk%-[%w%-_]+", "<redacted-key>")
  s = M.url(s)
  return s
end

return M
