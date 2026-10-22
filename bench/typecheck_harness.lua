-- Run from the repository root. No cwd mutation and no FFI dependency.
local M = {}
function M.json(x)
  local t = type(x)
  if t == 'string' then
    return '"' .. x:gsub('[%z\1-\31\\"]', function(c)
      local escapes = {['"']='\\"', ['\\']='\\\\', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t'}
      return escapes[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
  elseif t == 'boolean' or t == 'number' then return tostring(x)
  elseif t == 'nil' then return 'null'
  elseif t == 'table' then
    local out = {}
    if #x > 0 then
      for _, v in ipairs(x) do out[#out+1] = M.json(v) end
      return '[' .. table.concat(out, ',') .. ']'
    end
    local keys = {}; for k in pairs(x) do keys[#keys+1] = k end; table.sort(keys)
    for _, k in ipairs(keys) do out[#out+1] = M.json(k) .. ':' .. M.json(x[k]) end
    return '{' .. table.concat(out, ',') .. '}'
  end
  error('cannot encode ' .. t)
end
function M.run(mode)
  assert(mode == 'time' or mode == 'alloc' or mode == 'diagnostic', 'unknown measurement mode')
  local verifier = assert(io.popen('python3 bench/verify_inputs.py 2>&1'))
  local authenticated = verifier:read('*a'); verifier:close()
  assert(authenticated:match('^%{"fixtures_sha256"'), 'input authentication failed: ' .. authenticated)
  local report = {input_identity_json=authenticated, schema=1, mode=mode, phases={}, queries={}, loads={}}
  local function phase(name, fn)
    local t = os.clock(); local v = fn()
    report.phases[name] = os.clock() - t
    return v
  end
  local P = phase('require', function()
    if os.getenv('SHEN_BENCH_BUNDLE') then dofile(os.getenv('SHEN_BENCH_BUNDLE')) end
    return require('boot')
  end)
  local R = require('runtime')
  if P.KL_SOURCES then
    local dir = os.getenv('SHEN_KL_DIR') or 'klambda'
    for name, content in pairs(P.KL_SOURCES) do
      local f = assert(io.open(dir .. '/' .. name .. '.kl', 'rb'))
      local expected = f:read('*a'); f:close()
      assert(content == expected, 'bundle kernel differs from authenticated disk source: ' .. name)
    end
  end
  local serialize = require('bench.typecheck_serialize')
  local corpus = require('bench.typecheck_corpus')
  -- Missing fixtures must fail before any query, including in golden capture.
  for _, stage in ipairs(corpus) do
    if stage.fixture then
      local f = assert(io.open(stage.fixture, 'rb'), 'missing fixture: ' .. stage.fixture)
      f:close()
    end
  end
  phase('kernel_load', function() P.load_kernel(false) end)
  phase('initialise', P.initialise)
  report.kernel_cache = P.KERNEL_CACHE_STATUS
  report.shared_prolog_primitives = P.PROLOG_PRIMITIVES
  P.TRACK_FASL = true
  P.HUSH_LOAD_ECHO = true
  local TN = package.loaded.typecheck_native
  if TN then TN.track_routes = true end
  report.runtime = {lua=_VERSION, jit=jit and jit.version or 'none',
    jit_enabled=jit and jit.status() or false, jit_flags=jit and {jit.status()} or {},
    os=jit and jit.os or 'unknown', arch=jit and jit.arch or 'unknown'}
  report.compiler = {TRMC=require('compiler').TRMC, MAX_CALLN=require('compiler').MAX_CALLN}
  report.kernel_version = P.F.version()
  report.engine = TN and TN.native_typecheck and os.getenv('SHEN_TYPECHECK_NATIVE') ~= 'off' and 'native-dispatch' or 'legacy'
  assert(os.getenv('SHEN_TYPECHECK_NATIVE') ~= 'require' or report.engine == 'native-dispatch',
    'require mode needs the native dispatcher')
  -- Optional attribution is a separate process, never an accepted time sample.
  -- Inclusive hook CPU times overlap (read-file contains read-from-string).
  if mode == 'diagnostic' then
    report.diagnostics = {}
    local function wrap(tbl, key, label)
      local orig = assert(tbl[key]); local d = {calls=0, cpu=0}; report.diagnostics[label] = d
      tbl[key] = function(...)
        local t = os.clock(); local v = orig(...)
        d.cpu = d.cpu + os.clock()-t; d.calls = d.calls+1
        return v
      end
      if tbl == P.F then P.FA[tbl[key]] = P.FA[orig] end
    end
    wrap(P.F, 'read-file', 'source_read_parse_expand')
    wrap(P.F, 'shen.shen->kl', 'source_lower')
    wrap(P.F, 'read-from-string', 'parse_expand_inclusive')
    wrap(P.F, 'macroexpand', 'macroexpand_inclusive')
    wrap(P.F, 'shen.source-macro-walk', 'source_macro_walk_inclusive')
    wrap(P.F, 'shen.typecheck', 'source_typecheck_inclusive')
    wrap(P.F, 'shen.record-and-evaluate', 'record_evaluate_inclusive')
    wrap(require('compiler'), 'compile_top', 'kl_to_lua_defun')
    wrap(require('compiler'), 'compile_expr_chunk', 'kl_to_lua_expr')
    wrap(P, 'load_chunk', 'lua_compile')
    -- eval-kl captures the LOCAL loader inside compile_and_load; changing
    -- only the exported P.load_chunk misses source compilation entirely.
    -- This reflective hook is confined to diagnostic processes.
    local hooked = false
    for i=1,100 do
      local name = debug.getupvalue(P.compile_and_load, i)
      if not name then break end
      if name == 'load_chunk' then
        debug.setupvalue(P.compile_and_load, i, P.load_chunk)
        hooked = true
        break
      end
    end
    assert(hooked, 'cannot instrument actual local Lua compiler; refusing diagnostic report')
  end
  if TN and report.engine == 'native-dispatch' then
    phase('driver_compile', TN.ensure_drivers)
  end
  local repeats = tonumber(os.getenv('SHEN_BENCH_REPEATS') or '3')
  assert(repeats and repeats >= 1 and repeats <= 100 and repeats % 1 == 0, 'invalid repeats')
  local parse_cpu = 0
  for _, stage in ipairs(corpus) do
    if stage.fixture then
      local t = os.clock()
      P.GLOBALS["shen.*tc*"] = true
      P.GLOBALS["shen.*infs*"] = 0
      assert(P.home_path(stage.fixture) == stage.fixture,
        'benchmark fixture redirected by *home-directory*')
      P.LAST_FASL_STATUS = nil
      if TN then TN.last_route = nil; TN.route_log = {} end
      P.F.load(stage.fixture)
      local cpu = os.clock()-t
      report.loads[#report.loads+1] = {path=stage.fixture, cpu=cpu,
        cache=P.LAST_FASL_STATUS or "off", inferences=P.GLOBALS['shen.*infs*'],
        dispatch_transitions=TN and TN.route_log or {},
        dispatcher=report.engine}
      if TN then TN.route_log = nil end
    end
    for _, case in ipairs(stage.cases) do
      local t = os.clock()
      -- Read expression and type together: the kernel reader treats type
      -- position differently from expression position (shen.lua API contract).
      local forms = P.F['read-from-string'](case[2] .. ' : ' .. case[3])
      assert(R.is_cons(forms) and forms[2][1] == R.intern(':') and forms[2][2][2] == R.NIL,
        'invalid benchmark judgment: ' .. case[1])
      local expr, ty = forms[1], forms[2][2][1]
      parse_cpu = parse_cpu + os.clock()-t
      local function normalize_type(x, vars)
        if getmetatable(x) == R.Symbol and x.name:match('^[A-Z]') then
          if not vars[x] then vars.n=vars.n+1; vars[x]='?' .. vars.n end
          return R.intern(vars[x])
        elseif R.is_cons(x) then
          return R.cons(normalize_type(x[1], vars), normalize_type(x[2], vars))
        end
        return x
      end
      local expected = case[5] or serialize(normalize_type(ty, {n=0}))
      for request=1,repeats do
        P.GLOBALS['shen.*infs*'] = 0
        if TN then TN.last_route = nil end
        if mode == 'alloc' then collectgarbage('collect'); collectgarbage('stop') end
        local mem = mode == 'alloc' and collectgarbage('count') or nil
        local q0 = os.clock()
        local ok, result = R.seg.pcall(P.F['shen.typecheck'], expr, ty)
        local cpu = os.clock()-q0
        local allocated = mem and (collectgarbage('count')-mem)*1024 or nil
        if mode == 'alloc' then collectgarbage('restart') end
        local verdict = ok and serialize(result) or tostring(type(result) == 'table' and result.msg or result)
        local route = TN and TN.last_route or {engine='legacy', reason='configured legacy', native_attempted=false}
        local row = {name=case[1], stage=stage.name, request=request,
          phase=request == 1 and 'first' or 'persistent', expr=case[2], type=case[3],
          ok=ok, result=verdict, inferences=P.GLOBALS['shen.*infs*'],
          cpu=cpu, allocated_bytes=allocated, route=route}
        report.queries[#report.queries+1] = row
        -- Errors never count as a rejected judgment. Complete inferred type
        -- must match the requested ground type, with pvars alpha-normalized.
        if not ok or verdict ~= (case[4] == false and 'false' or expected) then
          io.write('SHEN_BENCH_FAILURE ', M.json(row), '\n')
        end
        assert(ok, case[1] .. ': runtime error: ' .. verdict)
        assert(verdict == (case[4] == false and 'false' or expected),
          case[1] .. ': unexpected verdict ' .. verdict .. ' expected ' .. (case[4] == false and 'false' or expected))
        assert(os.getenv('SHEN_TYPECHECK_NATIVE') ~= 'require' or route.engine == 'native',
          'query did not route natively: ' .. case[1])
      end
    end
  end
  report.phases.query_read = parse_cpu
  report.drivers = TN and TN.drivers or {}
  report.native_problems = TN and TN.native_problems or {}
  io.write('\nSHEN_BENCH_JSON ', M.json(report), '\n')
  return report
end
return M
