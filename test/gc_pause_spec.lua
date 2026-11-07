-- gc_pause_spec.lua : boot's adaptive GC pause follows the live heap, and leaves
-- alone a pause the host set. Boot's GC block runs when boot.lua is required.
package.path = (arg[0]:gsub("test/[^/]*$", "")) .. "?.lua;" .. package.path
local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else nfail = nfail + 1; print("FAIL " .. name) end
end
local function pause()
  local p = collectgarbage("setpause", 0)
  collectgarbage("setpause", p)
  return p
end
local function cycles(n) for _ = 1, n do collectgarbage("collect") end end

if os.getenv("SHEN_GC") or not newproxy then
  print("gc_pause_spec: skipped (SHEN_GC set, or no newproxy)")
  os.exit(0)
end
require("boot")

cycles(3)
check(pause() == 400, "a small live heap stays at 400, got " .. pause())

-- 128 MB or so live: the pause falls, and more than once
local hold = {}
for i = 1, 1000000 do hold[i] = { i, i } end
cycles(3)
local big = pause()
check(big < 400 and big >= 150, "a big live heap lowers the pause, got " .. big)
hold = nil
cycles(3)
check(pause() == 400, "the pause comes back when the heap shrinks, got " .. pause())

-- the host sets its own: it stays through cycles of any heap size
collectgarbage("setpause", 275)
cycles(3)
check(pause() == 275, "the host's pause stands, got " .. pause())
hold = {}
for i = 1, 1000000 do hold[i] = { i, i } end
cycles(3)
check(pause() == 275, "the host's pause stands on a big heap, got " .. pause())
hold = nil

print(("gc_pause_spec: %d pass, %d fail"):format(npass, nfail))
os.exit(nfail == 0 and 0 or 1)
