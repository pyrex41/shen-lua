# shen-lua 0.11.0

Shen 42 on LuaJIT, with faster compilation and execution, structural maps,
and stack-safe recursive list builders.

## Highlights

- Shen 42 kernel and standard library, including the standard library in
  LuaRocks installs.
- New `lua.map-*` structural maps for lists, vectors, tuples, and other Shen
  keys, plus `lua.table-new` for an empty Lua table that stays boxed.
- Tail recursion modulo cons: recursive `[X | (f ...)]` list builders use a
  loop and can build million-element lists without overflowing the Lua stack.
  Set `SHEN_TRMC=off` to compare with ordinary recursion.
- Faster curried calls, forward references, `do` forms, list equality, and
  native kernel operations. Curried calls preserve evaluation order after
  redefinition; list builders release their temporary references after use.
- Cached standard-library boot images and quieter loading via `--hush-load`
  or `shen.boot{hush_load=true}`.
- Fixes for large numeric literals and rendering, deep pattern compilation,
  large comments, evaluation order, and Prolog semantics.
- Nix packaging, native-extension feature discovery, and host SHA-256 support
  when a compatible OpenSSL library is available.

See [the benchmark results](https://github.com/pyrex41/shen-lua/blob/v0.11.0/doc/BENCH-2026-09-27.md) for measured performance and
methodology. Improvements depend on the workload and LuaJIT host.

## Install

LuaJIT 2.1 is the primary supported runtime. Download the attached rockspec
and install directly from the release tag:

```sh
luarocks --lua-version=5.1 install shen-0.11.0-1.rockspec
shen -e '(+ 1 2)'
```

Or download `shen-bundle.lua` into your Lua module path:

```lua
local shen = require("shen-bundle")
shen.boot{quiet=true}
print(shen.eval("(+ 1 2)"))
```

The bundle includes the kernel and standard-library sources. Its precompiled
kernel falls back to source compilation on other LuaJIT bytecode formats.

Nix users can run the tagged source:

```sh
nix run github:pyrex41/shen-lua/v0.11.0 -- -e '(+ 1 2)'
```
