-- examples/openresty-authz/auth.lua — resolve a bearer token to a user at the
-- HEAD of the proof chain.
--
-- Whether this touches the network is a TOKEN-FORMAT decision, not a given:
--
--   * Signed tokens (JWT/PASETO) — verify LOCALLY: check the signature + exp/
--     aud/iss. That is CPU (crypto), no per-request I/O; the only network is a
--     JWKS key fetch, cached for hours. This is the default and the common case
--     for a stateless authz gate.
--   * Opaque tokens (session ids / OAuth2 introspection) — must be looked up in
--     a REMOTE store, so THEN it is network I/O. On a single-threaded nginx
--     worker a blocking socket would stall the whole worker for the round-trip,
--     so use a COSOCKET (ngx.socket.tcp, whose connect/send/receive/setkeepalive
--     yield to the event loop and pool connections) and cache the result.
--
-- So the DEFAULT resolver is local (`local_resolver`); `cosocket_resolver` is an
-- opt-in for the opaque-token case only. Either way, token_user(token) is the
-- ONE leaf fact the Prolog policy reads for identity — everything downstream
-- (membership, ownership) stays in the local durable store.

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

-- DEFAULT resolver: identity verified/looked up locally, no per-request I/O.
-- In production this is where a JWT signature check lives (lua-resty-jwt);
-- `token_user_fn` returns the subject. It is also the fallback for the cosocket
-- resolver when the remote store errors.
function M.local_resolver(token_user_fn)
  return { token_user = token_user_fn }
end

-- OPT-IN resolver, for OPAQUE tokens only (session ids / introspection) whose
-- store is remote. A short-TTL shared-dict cache sits in front of a Redis lookup
-- over ngx.socket.tcp, so the common case never touches the socket at all; a
-- miss does one non-blocking round-trip; any error degrades to the local
-- fallback rather than failing the request open. Do NOT use this for signed
-- tokens — verify those locally with M.local_resolver instead.
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
