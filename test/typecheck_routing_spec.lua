-- Observable dispatch receipts and strict-mode fallback gates (#72/#98).
local shen = require('shen')
shen.boot{quiet=true}
local P, R = shen.prims, require('runtime')
local TN = require('typecheck_native')
if not TN.native_typecheck or os.getenv('SHEN_TYPECHECK_NATIVE') == 'off' then
  print('typecheck_routing_spec: skipped (native dispatcher disabled)')
  return
end
TN.track_routes = true
local function raw()
  P.GLOBALS['shen.*infs*'] = 0
  return P.F['shen.typecheck'](1, R.intern('number'))
end
assert(raw() == R.intern('number'))
assert(TN.last_route.engine == 'native' and TN.last_route.native_attempted)
-- Rejecting a judgment is still successful native execution.
assert(P.F['shen.typecheck'](1, R.intern('string')) == false)
assert(TN.last_route.engine == 'native')
P.GLOBALS['shen.*spy*'] = true
-- Abort before the interactive legacy spy can read stdin.
if os.getenv('SHEN_TYPECHECK_NATIVE') == 'require' then
  local ok, err = pcall(raw)
  assert(not ok and tostring(type(err) == 'table' and err.msg or err):find('require', 1, true))
  assert(TN.last_route.engine == 'unavailable' and TN.last_route.reason == 'spy enabled')
else
  -- Incomplete signature metadata also forces a safe noninteractive fallback.
  P.GLOBALS['shen.*spy*'] = false
  local complete = TN.sigs_complete
  TN.sigs_complete = false
  assert(raw() == R.intern('number'))
  assert(TN.last_route.engine == 'legacy' and TN.last_route.reason == 'incomplete signatures')
  TN.sigs_complete = complete
end
P.GLOBALS['shen.*spy*'] = false
TN.track_routes = nil
print('typecheck_routing_spec: 1 pass, 0 fail')
