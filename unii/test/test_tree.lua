-- Tree addressing and exact arithmetic, checked against independent Lua
-- computations (int64 cross-multiplication for due scores).
local T = require("unii.test.lib")
local ffi = require("ffi")

local function S() T.core(); return require("unii.host.core").shen() end

local function key(s, l, i) return s.list({ s.sym("key"), l, i }) end
local function unkey(s, k) local t = s.totable(k); return t[2], t[3] end

return {
  { "divmod-pow2 equals floor division for 4,000 values up to 2^40", function()
    local s = S()
    local x = 12345
    for n = 1, 4000 do
      x = (x * 48271) % 2147483647
      local N = (x * 512 + n) % 1099511627776
      local L = n % 40
      local r = s.call("unii.divmod-pow2", N, L)
      local q, m = s.prims.F["fst"](r), s.prims.F["snd"](r)
      T.eq(q, math.floor(N / 2 ^ L), "quotient " .. N .. "/2^" .. L)
      T.eq(m, N - math.floor(N / 2 ^ L) * 2 ^ L, "remainder")
    end
    T.raises(function() s.call("unii.divmod-pow2", 2 ^ 40, 1) end, "outside the exact domain")
  end },

  { "parent, children and sibling are mutually consistent", function()
    local s = S()
    for l = 0, 6 do
      for i = 0, 40 do
        local k = key(s, l, i)
        local pl, pi = unkey(s, s.call("unii.parent", k))
        T.eq(pl, l + 1); T.eq(pi, math.floor(i / 2))
        local kids = s.totable(s.call("unii.children", s.call("unii.parent", k)))
        local a, b = { unkey(s, kids[1]) }, { unkey(s, kids[2]) }
        T.eq(a[2], pi * 2); T.eq(b[2], pi * 2 + 1); T.eq(a[1], l)
        local sl, si = unkey(s, s.call("unii.sibling", k))
        T.eq(sl, l); T.eq(si, i % 2 == 0 and i + 1 or i - 1)
        T.eq(s.call("unii.key-first", k), i * 2 ^ l)
        T.eq(s.call("unii.key-end", k), (i + 1) * 2 ^ l)
      end
    end
  end },

  { "zoom addresses: gist example node(3,5) = 40+8; misaligned rejected", function()
    local s = S()
    local r = s.totable(s.call("unii.address->key", 40, 8, 100))
    T.eq(#r, 1)
    local l, i = unkey(s, r[1])
    T.eq(l, 3); T.eq(i, 5)
    for _, bad in ipairs { { 41, 8, 100 }, { 40, 6, 100 }, { 96, 8, 100 }, { 0, 0, 10 }, { 4, 3, 10 } } do
      T.eq(#s.totable(s.call("unii.address->key", bad[1], bad[2], bad[3])), 0,
        ("address %d+%d of %d"):format(bad[1], bad[2], bad[3]))
    end
    T.eq(#s.totable(s.call("unii.address->key", 0, 1, 1)), 1)
  end },

  { "due ordering matches exact int64 cross-multiplication", function()
    local s = S()
    local i64 = ffi.typeof("int64_t")
    local x = 99
    local function rnd(n) x = (x * 16807) % 2147483647; return x % n end
    for _ = 1, 3000 do
      local T_ = rnd(2147483646) + 1
      local function pair()
        local l = rnd(29)
        local maxi = math.floor((T_ + 1) / 2 ^ (l + 1)) - 1
        if maxi < 0 then return nil end
        return l, 2 * rnd(maxi + 1)
      end
      local l1, i1 = pair()
      local l2, i2 = pair()
      if l1 and l2 then
        local last1 = (i1 + 2) * 2 ^ l1 - 1
        local last2 = (i2 + 2) * 2 ^ l2 - 1
        -- due1 > due2  <=>  (T - last1) * 2^l2 > (T - last2) * 2^l1, exactly in int64
        local lhs = i64(T_ - last1) * i64(2 ^ l2)
        local rhs = i64(T_ - last2) * i64(2 ^ l1)
        local d1 = s.call("unii.pair-due", T_, key(s, l1, i1))
        local d2 = s.call("unii.pair-due", T_, key(s, l2, i2))
        T.eq(s.call("unii.due>", d1, d2), lhs > rhs, ("T=%d (%d,%d) vs (%d,%d)"):format(T_, l1, i1, l2, i2))
      end
    end
  end },

  { "line bytes equal rendered bytes; line breaks collapse byte-for-byte", function()
    local s = S()
    for _, c in ipairs { { 0, 0, "x" }, { 3, 5, "a\nb\r\nc 日本" }, { 0, 123456, "" }, { 10, 2, ("é"):rep(200) } } do
      local k = key(s, c[1], c[2])
      local line = s.call("unii.render-line", k, c[3])
      T.eq(#line, s.call("unii.line-bytes", k, #c[3]))
      T.ok(not line:sub(1, -2):find("[\r\n]"), "only the final LF remains")
      T.eq(line:sub(-1), "\n")
      T.ok(line:find("^" .. (c[2] * 2 ^ c[1]) .. "%+" .. (2 ^ c[1]) .. "|"), "address prefix " .. line)
    end
  end },

  { "decimal width and leaf/join byte accounting", function()
    local s = S()
    for _, n in ipairs { 0, 9, 10, 99, 100, 2147483647 } do
      T.eq(s.call("unii.decimal-width", n), #tostring(n))
    end
    T.eq(s.call("unii.leaf-text-bytes", s.sym("tool-result"), 10), #"tool-result: " + 10)
    T.eq(#s.call("unii.leaf-text", s.sym("imported-note"), "x"), s.call("unii.leaf-text-bytes", s.sym("imported-note"), 1))
    T.eq(#s.call("unii.join-text", "ab", "cde"), s.call("unii.join-bytes", 2, 3))
  end },
}
