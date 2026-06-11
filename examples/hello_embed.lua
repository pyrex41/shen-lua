-- hello_embed.lua — the smallest useful embedding of Shen in a Lua program.
--
--   luajit examples/hello_embed.lua
--
-- Everything the `shen` module offers in ~25 lines: boot, define a typed
-- Shen function from a string, call it from Lua, pass data both ways.

package.path = "./?.lua;" .. package.path   -- run from the repo root
local shen = require("shen")

shen.boot{quiet = true}                     -- warm boot is ~30 ms (bytecode cache)

-- Define a Shen function at runtime, with the typechecker on
-- (sum/length come from the 41.2 stlib).
shen.eval([[
  (tc +)
  (define mean
    {(list number) --> number}
    Xs -> (/ (sum Xs) (length Xs)))
  (tc -)
]])

-- Call Shen from Lua. shen.list marshals a Lua array to a cons list.
print("mean:", shen.call("mean", shen.list({3, 4, 5, 6})))   --> 4.5

-- shen.fn gives a plain Lua callable; partial application works too.
local mean = shen.fn("mean")
print("mean:", mean(shen.list({1, 2})))                      --> 1.5

-- And back: cons lists marshal to Lua arrays.
local arr = shen.totable(shen.eval("(map (* 2) [1 2 3])"))
print("doubled:", table.concat(arr, ", "))                   --> 2, 4, 6
