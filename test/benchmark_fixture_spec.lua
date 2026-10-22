-- Prevent source drift in the authentic parser subset without duplicating it.
local function read(p)
  local f=assert(io.open(p,'rb'), 'missing benchmark fixture: '..p)
  local s=f:read('*a'); f:close(); return s
end
local source=read('tests/yacc.shen')
local stop=assert(source:find('(defcc <des>',1,true))
assert(read('bench/fixtures/parser.shen') == source:sub(1,stop-1), 'parser subset differs from authenticated source')
local names={}
for _,stage in ipairs(require('bench.typecheck_corpus')) do
  if stage.fixture then read(stage.fixture) end
  for _,c in ipairs(stage.cases) do
    assert(not names[c[1]], 'duplicate benchmark case'); names[c[1]]=true
    assert(c[2] and c[3], 'missing expression or explicit type')
  end
end
local h=assert(io.popen('python3 bench/verify_inputs.py 2>&1'))
local identity=h:read('*a'); h:close()
assert(identity:match('^%{"fixtures_sha256"'), identity)
print('benchmark_fixture_spec: 1 pass, 0 fail')
