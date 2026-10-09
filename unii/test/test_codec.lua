-- Codec round trips: every tagged value kind through Shen and through the
-- canonical storage encoding; distinctions that automatic table conversion
-- would lose; UTF-8 validation; schema records with optional fields.
local T = require("unii.test.lib")
local codec = require("unii.host.codec")
local schema = require("unii.host.schema")
local sha256 = require("unii.host.sha256")

local function shen()
  T.core()
  return require("unii.host.core").shen()
end

local function samples()
  local c = codec
  return {
    c.sym("user"), c.sym("tool-call"), c.sym("unii.x?"), c.sym("none"), c.sym("nil"),
    c.text(""), c.text("plain"), c.text("café naïve 日本語 🙂"), c.text("e\204\129 combining"),
    c.text("line\nbreak\r\n|pipe"), c.text("nul\0byte"), c.text("(error \"not code\")"),
    c.text("user"),
    c.int("0"), c.int("1"), c.int("-1"), c.int("2147483647"), c.int("9007199254740991"),
    c.int("-9007199254740991"),
    c.bool(true), c.bool(false),
    c.list({}), c.list({ c.list({}) }), c.list({ c.sym("key"), c.int("3"), c.int("5") }),
    c.vec({}), c.vec({ c.int("1"), c.text("two"), c.sym("three") }), c.vec({ c.vec({}), c.list({}) }),
    c.list({ c.vec({ c.bool(false) }), c.text(""), c.list({ c.sym("a"), c.list({}) }) }),
  }
end

return {
  { "sha256 matches FIPS 180-4 vectors", function()
    T.eq(sha256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    T.eq(sha256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    T.eq(sha256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    T.eq(sha256.hex(("a"):rep(1000000)), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
  end },

  { "every tagged value round-trips through Shen", function()
    shen()
    for _, v in ipairs(samples()) do
      local back = codec.from_shen(codec.to_shen(v))
      T.ok(codec.equal(v, back), "Shen round trip changed " .. codec.show(v) .. " -> " .. codec.show(back))
    end
  end },

  { "every tagged value round-trips through storage bytes", function()
    local all = samples()
    all[#all + 1] = codec.list({ codec.ABSENT, codec.int("2") })
    all[#all + 1] = codec.map({ a = codec.int("1"), b = codec.ABSENT, ["z k"] = codec.list({}) })
    for _, v in ipairs(all) do
      local bytes = codec.encode(v)
      local back = codec.decode(bytes)
      T.ok(codec.equal(v, back), "storage round trip changed " .. codec.show(v))
      T.eq(codec.encode(back), bytes, "re-encoding is not canonical")
    end
  end },

  { "Shen keeps symbol/text/empty list/vector/boolean distinct", function()
    local S = shen()
    local R = S.runtime
    local nil_list = codec.to_shen(codec.list({}))
    local empty_vec = codec.to_shen(codec.vec({}))
    T.ok(nil_list == R.NIL, "empty list must be ()")
    T.ok(empty_vec ~= R.NIL and getmetatable(empty_vec) == R.Vmt, "empty vector must stay a vector")
    T.ok(R.is_symbol(codec.to_shen(codec.sym("user"))), "symbol")
    T.eq(type(codec.to_shen(codec.text("user"))), "string")
    T.eq(codec.to_shen(codec.bool(false)), false)
    T.eq(codec.from_shen(R.intern("user")).t, "sym")
    T.eq(codec.from_shen("user").t, "text")
    T.eq(codec.from_shen(R.NIL).t, "list")
    T.eq(codec.from_shen(empty_vec).t, "vec")
    T.eq(codec.from_shen(false).t, "bool")
    -- the distinctions survive storage too
    local seen = {}
    for _, v in ipairs { codec.list({}), codec.vec({}), codec.bool(false), codec.text(""),
                         codec.sym("nil"), codec.ABSENT, codec.text("nil") } do
      local b = codec.encode(v)
      T.ok(not seen[b], "two distinct values share an encoding: " .. b)
      seen[b] = true
    end
  end },

  { "absent has no bare Shen value; true/false are not symbols", function()
    shen()
    T.raises(function() codec.to_shen(codec.ABSENT) end, "absent has no Shen value")
    T.raises(function() codec.to_shen({ t = "sym", v = "true" }) end, "booleans, not symbols")
    T.raises(function() codec.from_shen(function() end) end, "unsupported Shen value")
  end },

  { "Shen tuples and improper lists are refused, not guessed", function()
    local S = shen()
    T.raises(function() codec.from_shen(S.eval("(@p 1 2)")) end, "not a standard vector")
    T.raises(function() codec.from_shen(S.runtime.cons(1, 2)) end, "improper list")
  end },

  { "UTF-8 validation rejects malformed text at the boundary", function()
    for _, bad in ipairs { "\192\128", "\224\128\128", "\237\160\128", "\244\144\128\128",
                           "\128", "abc\226\130", "\255" } do
      T.raises(function() codec.text(bad) end, "invalid UTF-8")
    end
    T.ok(codec.valid_utf8("\244\143\191\191"), "U+10FFFF is valid")
    T.ok(codec.valid_utf8("e\204\129"), "combining mark is valid")
  end },

  { "utf8_prefix never splits a code point", function()
    local s = "a日本語🙂e\204\129z"
    for n = 0, #s do
      local p = codec.utf8_prefix(s, n)
      T.ok(#p <= n and codec.valid_utf8(p), "bad prefix at " .. n)
    end
  end },

  { "storage decoding rejects non-canonical or ambiguous bytes", function()
    T.raises(function() codec.decode("i007;") end, "non-canonical")
    T.raises(function() codec.decode("i-0;") end, "non-canonical")
    T.raises(function() codec.decode("i1;i2;") end, "trailing bytes")
    T.raises(function() codec.decode("ms1:bi1;s1:ai2;e") end, "ascending")
    T.raises(function() codec.decode("ms1:aAe") end, "omitted")
    T.raises(function() codec.decode("s5:abc") end, "truncated")
    T.raises(function() codec.decode("s2:\255\255") end, "invalid UTF-8")
    T.raises(function() codec.decode("l") end, "unterminated")
  end },

  { "map encoding is independent of insertion order", function()
    local a, b = {}, {}
    for i = 1, 50 do a["k" .. i] = codec.int(tostring(i)) end
    for i = 50, 1, -1 do b["k" .. i] = codec.int(tostring(i)) end
    T.eq(codec.encode(codec.map(a)), codec.encode(codec.map(b)))
  end },

  { "schema records round-trip Lua -> tagged -> Shen -> tagged -> Lua", function()
    shen()
    local key = { _ = "key", level = 3, index = 5 }
    local cases = {
      { "event", T.msg(7, "tool-result", "out\nput 🙂") },
      { "event", { _ = "summary-completed", job = "j1-0-3-a2-abc", attempt = 2, bytes = 3,
                   sha256 = sha256.hex("abc"), text = "abc" } },
      { "event", { _ = "summary-failed", job = "j1-1-0-a1-d9", attempt = 1, class = "retryable" } },
      { "command", { _ = "submit-summary", cmd = "c4", job = "j", key = key,
                     attempt = { _ = "attempt", n = 2, retry = { _ = "retry-too-long", bytes = 700 } },
                     input = { _ = "merge-input", left = { _ = "key", level = 2, index = 10 }, left_text = "a",
                               right = { _ = "key", level = 2, index = 11 }, right_text = "b" } } },
      { "command", { _ = "emit-client-event", cmd = "c5",
                     event = { _ = "view-changed", rev = 3, bytes = 100, lines = 2 } } },
      { "decision", { _ = "node-committed", key = key, origin = { _ = "summarized", job = "j", attempt = 1 }, bytes = 400 } },
      { "decision", { _ = "batch-mode", on = false } },
      { "config", schema.config {} },
    }
    for _, c in ipairs(cases) do
      local tagged = schema.encode(c[1], c[2])
      local back = schema.decode(c[1], codec.from_shen(codec.to_shen(tagged)))
      T.eq(codec.encode(schema.encode(c[1], back)), codec.encode(tagged), c[1] .. " " .. c[2]._)
    end
  end },

  { "optional fields: absent, [some []] and [some false] stay distinct", function()
    shen()
    schema.define("test-opt", { { "note", schema.T.opt(schema.T.list(schema.T.text())) },
                                { "flag", schema.T.opt(schema.T.bool()) } })
    local variants = {
      { _ = "test-opt" },
      { _ = "test-opt", note = {} },
      { _ = "test-opt", note = { "x" }, flag = false },
      { _ = "test-opt", flag = true },
    }
    local enc = {}
    for i, v in ipairs(variants) do
      local tagged = schema.encode("test-opt", v)
      local back = schema.decode("test-opt", codec.from_shen(codec.to_shen(tagged)))
      T.eq(back.note == nil, v.note == nil, "note presence " .. i)
      T.eq(back.flag, v.flag, "flag " .. i)
      if v.note then T.eq(#back.note, #v.note, "note length " .. i) end
      enc[i] = codec.encode(tagged)
      for j = 1, i - 1 do T.ok(enc[i] ~= enc[j], "variants " .. i .. " and " .. j .. " collide") end
    end
  end },

  { "schema refuses unknown fields, records and enum values", function()
    T.raises(function() schema.encode("event", { _ = "message-appended", id = "1", kind = "user", date = "d",
      content = { _ = "content", bytes = 1, sha256 = sha256.hex("x"), text = "x" }, extra = 1 }) end, "unexpected field")
    T.raises(function() schema.encode("event", { _ = "launch-missiles" }) end, "not allowed")
    T.raises(function() schema.encode("event", T.msg(1, "system", "x")) end, "unexpected symbol")
    T.raises(function()
      local e = T.msg(1, "user", "x"); e.content.sha256 = ("A"):rep(64); schema.encode("event", e)
    end, "hex")
  end },
}
