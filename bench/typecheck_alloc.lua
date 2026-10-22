-- GC-stopped Lua heap growth is a diagnostic, separate from accepted timings.
-- It does not include FFI arena/native allocator bytes.
require('bench.typecheck_harness').run('alloc')
