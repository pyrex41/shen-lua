rockspec_format = "3.0"
package = "shen"
version = "0.13.0-1"

source = {
   url = "git+https://github.com/pyrex41/shen-lua.git",
   tag = "v0.13.0",
}

description = {
   summary = "A speed-focused LuaJIT port of the Shen language (kernel 43.4)",
   detailed = [[
shen-lua runs the Shen language on LuaJIT 2.1 by compiling KLambda to Lua
source. Embed with `local shen = require("shen")` (boot/eval/call/fn plus
list/symbol marshaling), or use the `shen` launcher for a REPL, running
.shen files, and -e one-liners. Requires LuaJIT (Lua 5.1 semantics + FFI);
the ShenOSKernel 43.4 KLambda sources (kernel, extensions and precompiled
standard library) are bundled and compiled on first boot, then served from a
bytecode cache.

0.13.0 moves to the community ShenOSKernel 43.4 (shen-sources tag shen-43.4,
commit f34b307).
]],
   homepage = "https://github.com/pyrex41/shen-lua",
   license = "BSD-3-Clause (Shen kernel: BSD)",
   labels = { "shen", "language", "compiler", "luajit" },
}

dependencies = {
   -- LuaJIT only: the runtime uses the FFI (prolog engine, test driver) and
   -- Lua 5.1 semantics (loadstring/setfenv).
   "lua == 5.1",
}

build = {
   type = "builtin",
   modules = {
      shen             = "shen.lua",
      boot             = "boot.lua",
      prims            = "prims.lua",
      runtime          = "runtime.lua",
      compiler         = "compiler.lua",
      prolog_engine    = "prolog_engine.lua",
      prolog_compile   = "prolog_compile.lua",
      typecheck_native = "typecheck_native.lua",
      lua_interop      = "lua_interop.lua",
      checked_integer  = "checked_integer.lua",
      repl             = "repl.lua",
   },
   install = {
      bin = { shen = "bin/shen" },
   },
   -- The vendored ShenOSKernel 43.4 KLambda sources, compiled on boot.
   -- They land in the rock directory
   -- (<tree>/lib/luarocks/rocks-5.1/shen/0.13.0-1/klambda); boot.lua's
   -- find_kldir() derives that path from its own install location.
   copy_directories = { "klambda" },
}
