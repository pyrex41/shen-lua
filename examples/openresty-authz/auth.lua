-- examples/openresty-authz/auth.lua — resolve a bearer token to a user at the
-- HEAD of the proof chain, WITHOUT blocking the nginx worker.
--
-- In a real deployment the end-user's token is not a local table lookup: it
-- lives in a networked session/identity store (Redis, an OIDC introspection
-- endpoint, ...). Reaching it with a blocking socket would stall the whole
-- single-threaded nginx worker for the round-trip. OpenResty's answer is the
-- COSOCKET API — ngx.socket.tcp() — whose connect/send/receive/setkeepalive
-- yield to the event loop instead of blocking, and pool connections across
-- requests. This module uses it directly (lua-resty-redis / lua-resty-http are
-- the production-grade wrappers over exactly these calls).
--
-- token_user(token) is the ONE leaf fact the Prolog policy reads for identity;
-- everything downstream (membership, ownership) stays in the local durable
-- store. Two stores, two I/O models: a networked session store over a cosocket,
-- the local policy store over in-process FFI.

local M = {}

-- ---- minimal Redis RESP GET over a raw cosocket -----------------------------
-- `GET auth:<token>` -> the username, or "" if the key is absent. This is what
-- lua-resty-redis does under the hood; spelled out so the cosocket calls that
-- keep the worker non-blocking are visible: connect, send, receive, and
-- setkeepalive (which returns the socket to nginx's per-worker pool).
local function redis_get(cfg, key)
  local sock = ngx.socket.tcp()
  sock:settimeout(cfg.timeout_ms or 200)          -- bound the round-trip
  local ok, err = sock:connect(cfg.host, cfg.port)  -- reuses a pooled conn if any
  if not ok then return nil, "connect: " .. tostring(err) end

  local req = ("*2\r\n$3\r\nGET\r\n$%d\r\n%s\r\n"):format(#key, key)
  local _, serr = sock:send(req)
  if serr then sock:close(); return nil, "send: " .. serr end

  local line, rerr = sock:receive("*l")           -- bulk header: "$<len>" or "$-1"
  if not line then sock:close(); return nil, "receive: " .. tostring(rerr) end

  local val = ""
  if line ~= "$-1" then                            -- "$-1" == key missing
    local n = tonumber(line:sub(2)) or 0
    val = sock:receive(n) or ""                    -- exactly n bytes of payload
    sock:receive(2)                                -- swallow the trailing CRLF
  end

  sock:setkeepalive(cfg.keepalive_ms or 60000, cfg.pool_size or 20)  -- pool, don't close
  return val
end

-- ---- resolvers --------------------------------------------------------------
-- A resolver is just { token_user = function(token) -> user }.

-- Local resolver: identity from the in-process store. The off-nginx default and
-- the fallback when the network path errors.
function M.local_resolver(token_user_fn)
  return { token_user = token_user_fn }
end

-- Cosocket resolver: a short-TTL shared-dict cache in front of a Redis lookup
-- over ngx.socket.tcp. The cache means the common case never touches the socket
-- at all; a miss does one non-blocking round-trip; any error degrades to the
-- fallback rather than failing the request open.
--
-- opts = { redis = {host,port,timeout_ms,keepalive_ms,pool_size},
--          cache = <ngx.shared dict or nil>, ttl = <seconds>,
--          fallback = function(token) -> user }
function M.cosocket_resolver(opts)
  local cfg, cache = opts.redis, opts.cache
  local ttl, fallback = opts.ttl or 5, opts.fallback
  local R = {}
  function R.token_user(token)
    if cache then
      local hit = cache:get(token)
      if hit ~= nil then return hit end
    end
    local user, err = redis_get(cfg, "auth:" .. token)
    if err then
      if ngx and ngx.log then ngx.log(ngx.ERR, "auth cosocket: ", err) end
      return fallback and fallback(token) or ""    -- fail closed-ish via fallback
    end
    if cache then cache:set(token, user, ttl) end
    return user
  end
  return R
end

return M
