-- luajit probe.lua <file.shen> <expr>
-- Loads a Shen file under (tc +) with the fasl cache off in a fresh
-- environment, evaluates <expr> (fixed test source, never data) and prints
-- "LOAD ok|<error>" and "USE <value>|<error>".
local ffi = require("ffi")
ffi.cdef("int setenv(const char *, const char *, int);")
ffi.C.setenv("SHEN_FASL", "off", 1)
local root = debug.getinfo(1, "S").source:sub(2):match("^(.*)/unii/test/fixtures/upstream/probe%.lua$")
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local S = require("unii.host.core").shen()
local msg = require("lua_interop").error_message
S.eval("(tc +)")
local ok, e = pcall(S.eval, ('(load "%s")'):format(arg[1]))
print("LOAD " .. (ok and "ok" or tostring(msg(e))))
ok, e = pcall(S.eval, arg[2])
print("USE " .. (ok and tostring(e) or tostring(msg(e))))
