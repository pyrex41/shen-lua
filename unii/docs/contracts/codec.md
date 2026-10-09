# Boundary codec (codec_version 1)

`host/codec.lua` handles every value that crosses between Lua and Shen. It
does not use shen-lua's automatic table conversion. `host/schema.lua` adds
record shapes on top of the codec.

## Tagged values

| Tag | Lua form | Shen value | Notes |
|---|---|---|---|
| `sym` | `{t="sym", v="name"}` | interned symbol | |
| `text` | `{t="text", v=s}` | string | strict UTF-8: no overlong forms, no surrogates, nothing above U+10FFFF |
| `int` | `{t="int", v="-42"}` | number | canonical decimal text, within ±(2^53 − 1) through `checked_integer` |
| `bool` | `{t="bool", v=true}` | `true` / `false` | different from the symbols `true` and `false` |
| `list` | `{t="list", v={...}}` | cons list; `v={}` is `()` | |
| `vec` | `{t="vec", v={...}}` | standard vector (size in slot 0) | other absvectors (tuples, for example) are refused |
| `absent` | `codec.ABSENT` | none | used only in record fields and maps |
| `map` | `{t="map", v={k=...}}` | none | storage only, for journal transactions |

`to_shen` and `from_shen` are inverses on this domain. In particular, the
symbol `a`, the text `"a"`, `()`, an empty vector, `false`, the text
`"false"` and absent all stay distinct (`test_codec.lua`).

## Records

A record is a Shen list headed by its constructor symbol, followed by the
fields in schema order (see `events.md` and `commands.md`). On the Lua side
it is `{_ = "name", field = value}`. The schema rules are:

* Unknown or missing fields are errors.
* `nat` accepts decimal text, which is preferred for anything from outside
  the process, or a Lua number the host computed itself, in
  [0, 2^31 − 1].
* `opt(T)` encodes as `[none]` or `[some X]`, so an absent field is never
  confused with `()`, `false` or `""`.
* `content` and `summary-completed` must declare the true byte length and
  SHA-256 of their text.

## Storage encoding

`encode` and `decode` produce exactly one byte string for each tagged
value. The encoding is binary-safe and deterministic, and is used for
journal payloads and state hashes.

```
sym   y<len>:<bytes>         text  s<len>:<bytes>        int  i<decimal>;
bool  T | F                  absent A
list  l<item>*e              vec   v<item>*e
map   m(<text key><value>)*e   keys sorted ascending by bytes; absent values omitted
```

`decode` rejects:

* trailing bytes;
* non-canonical integers;
* invalid UTF-8 in text;
* length prefixes that run past the end of the input;
* map keys that are not strictly ascending;
* explicit absent values in a map.

## State hash

`state_hash = sha256(encode(from_shen(state)))`. This encodes the whole
core state: config, tree, view, live nodes, jobs and counters.

## Never evaluated

User and model text is carried only as `text` values. The host never passes
data to `eval`: a test scans `host/` for `eval` calls with non-constant
arguments. A message whose text is Shen code is stored and rendered
unchanged and is never run.
