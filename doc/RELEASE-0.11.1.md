# shen-lua 0.11.1

This patch release adds an explicit checked-integer path for Shen programs
embedded in LuaJIT. Ordinary Shen numbers remain IEEE-754 doubles: for example,
`9007199254740993` and `9007199254740992` can compare equal after parsing.

Pass the **original decimal text** to `shen.checked_integer("42")` from Lua
or `(lua.checked-integer "42")` from Shen. The parser rejects malformed input
and values outside ±(2^53−1) *before* conversion can round them. Use
`checked_add/sub/mul` from Lua or `lua.checked-add/sub/mul` from Shen to check
integer operands and results. The Shen functions have type signatures so
typechecked call sites can use them; runtime checks enforce the narrower
safe-integer range.

This is opt-in. An already-rounded Lua number cannot recover its original
digits, ordinary arithmetic does not stay checked, and values outside the
safe range require a separate exact representation. Details and examples are
in the [README](https://github.com/pyrex41/shen-lua/blob/v0.11.1/README.md#checked-integers-at-external-boundaries).

## Install

```sh
luarocks --lua-version=5.1 install shen 0.11.1-1
shen -e '(lua.checked-add (lua.checked-integer "41") 1)'
```

The attached `shen-0.11.1-1.rockspec` and standalone `shen-bundle.lua` are
alternatives. With Nix: `nix run github:pyrex41/shen-lua/v0.11.1 -- -e '(+ 1 2)'`.

Validation: 1,088 port assertions across 22 specs, the 134/134 official
Shen 42 kernel suite, and a standalone-bundle checked-integer smoke test.
