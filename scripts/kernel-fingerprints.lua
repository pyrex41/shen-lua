-- scripts/kernel-fingerprints.lua — regenerate typecheck_native.lua's KNOWN
-- table: the fingerprints of the kernel defuns the native typechecker
-- reimplements (typecheck_native.lua REIMPLEMENTED).
--
--   luajit scripts/kernel-fingerprints.lua LABEL KLDIR [LABEL KLDIR ...]
--
-- Prints the table body for every kernel given. Add a kernel ONLY after
-- checking that the native code implements each of its listed defuns: a
-- fingerprint in KNOWN is a claim that the port runs that defun's semantics.
local root = (arg[0]:gsub("scripts/[^/]*$", ""))
package.path = (root ~= "" and root or "./") .. "?.lua;" .. package.path
local TN = require("typecheck_native")

if #arg < 2 or #arg % 2 ~= 0 then
  io.stderr:write("usage: kernel-fingerprints.lua LABEL KLDIR [LABEL KLDIR ...]\n")
  os.exit(2)
end

local function slurp(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a"); f:close()
  return s
end

local seen = {}   -- name -> { fp -> {labels} }, fp order
for i = 1, #arg, 2 do
  local label, dir = arg[i], arg[i + 1]
  local defsets = {}
  for _, e in ipairs(TN.REIMPLEMENTED) do
    local file = e[1]
    defsets[file] = defsets[file] or TN.defuns_of(slurp(dir .. "/" .. file .. ".kl"))
    local fp = TN.fingerprint_in(defsets[file], e[2])
    local byname = seen[e[2]]
    if not byname then byname = { order = {} }; seen[e[2]] = byname end
    if not byname[fp] then byname[fp] = {}; byname.order[#byname.order + 1] = fp end
    table.insert(byname[fp], label)
  end
end

for _, e in ipairs(TN.REIMPLEMENTED) do
  local byname = seen[e[2]]
  local parts = {}
  for _, fp in ipairs(byname.order) do
    parts[#parts + 1] = string.format('["%s"] = "%s"', fp, table.concat(byname[fp], ", "))
  end
  io.write(string.format('  [%q] = { %s },\n', e[2], table.concat(parts, ", ")))
end
