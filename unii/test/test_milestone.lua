-- The milestone CLI end to end: seven separate processes append synthetic
-- messages with MOCK summaries, terminate, restart and compare hashes.
local T = require("unii.test.lib")

return {
  { "unii milestone: view and state hashes survive every restart", function()
    local dir = T.tmpdir("milestone")
    local out, ok = T.sh(("%q milestone --dir %q/chat"):format(T.root() .. "/unii/bin/unii", dir))
    T.ok(ok and out:find("MILESTONE PASS", 1, true), out)
    T.ok(not out:find("DIFFERENT", 1, true), out)
    local same = select(2, out:gsub("%s+same\n", ""))
    T.eq(same, 6, "six hash comparisons")
    T.rm(dir)
  end },

  { "the CLI refuses a second writer while one holds the chat", function()
    local dir = T.tmpdir("cli")
    local bin = T.root() .. "/unii/bin/unii"
    local _, ok = T.sh(("%q init --dir %q/chat"):format(bin, dir))
    T.ok(ok, "init")
    local s = require("unii.host.storage").open(dir .. "/chat")
    local out, ok2 = T.sh(("%q append --dir %q/chat --count 1"):format(bin, dir))
    s:close()
    T.ok(not ok2 and out:find("owned by another process", 1, true), out)
    T.rm(dir)
  end },
}
