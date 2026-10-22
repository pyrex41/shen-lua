-- Explicit capture/compare of the complete, checked repository corpus.
-- Capture writes to the requested path, never overwrites the checked-in oracle.
local mode, path = arg[1] or 'compare', arg[2] or 'bench/golden_typecheck.golden'
assert(mode == 'compare' or mode == 'capture', 'usage: golden_typecheck.lua compare|capture [path]')
assert(mode ~= 'capture' or arg[2], 'capture requires an explicit output path')
local report = require('bench.typecheck_harness').run('time')
local rows = {}
for _, q in ipairs(report.queries) do
  if q.request == 1 then rows[#rows+1] = q.name .. '\t' .. q.result end
end
local actual = table.concat(rows, '\n') .. '\n'
if mode == 'capture' then
  local f = assert(io.open(path, 'wb')); f:write(actual); f:close()
else
  local f = assert(io.open(path, 'rb'), 'missing golden file: ' .. path)
  local expected = f:read('*a'); f:close()
  assert(actual == expected, 'complete golden corpus differs; inspect full SHEN_BENCH_JSON output')
end
print('golden ' .. mode .. ': ' .. #rows .. ' complete verdicts')
