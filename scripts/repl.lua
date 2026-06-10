-- scripts/repl.lua : dev entry for the Shen REPL.
--   luajit scripts/repl.lua
-- (bin/shen, built by a sibling task, is the user-facing launcher; this
-- wrapper just fixes package.path relative to the repo root and runs.)
local root = (arg and arg[0]) and arg[0]:gsub("scripts/[^/]*$", "") or ""
if root ~= "" then package.path = root .. "?.lua;" .. package.path end
package.path = "./?.lua;" .. package.path
require("repl").run()
