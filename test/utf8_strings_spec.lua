-- test/utf8_strings_spec.lua — PORT-AUTHORED coverage for issue #80: Shen
-- strings are sequences of Unicode code points, represented as UTF-8.
--
--   * n->string encodes any code point 0..0x10FFFF except surrogates, and
--     errors otherwise (the old primitive was string.char: 0..255 only, and
--     128..255 came back as a lone invalid byte);
--   * string->n / pos / tlstr / hdstr / explode / hash / string.length count
--     characters, not bytes;
--   * the reader decodes UTF-8 source (files, read-from-string, streams), so a
--     non-ASCII literal reads as its characters and prints back unchanged;
--   * pr writes strings as UTF-8; read-byte / write-byte / read-file-as-bytelist
--     stay raw byte primitives;
--   * invalid UTF-8 is lenient and lossless: each ill-formed byte is one
--     character whose code is the byte value (see prims.lua).
--
-- Not the canonical kernel certification suite (run-kernel-tests.lua).
--
--   luajit test/utf8_strings_spec.lua
local shen = require("shen")
shen.boot{ quiet = true }
local R = require("runtime")

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end
local function evs(src) return R.to_str(shen.eval(src)) end
local function checkeq(src, want)
  local ok, got = pcall(evs, src)
  if not ok then
    nfail = nfail + 1
    io.write("FAIL: ", src, "  (raised: ", tostring(got), ")\n")
  elseif got == want then
    npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", src, "\n  want: ", want, "\n  got:  ", got, "\n")
  end
end
-- raw Lua value of an expression
local function ev(src) return shen.eval(src) end
local function trap(src)
  return ev("(trap-error " .. src .. " (lambda E (error-to-string E)))")
end
local function bytes(s)
  local t = {}
  for i = 1, #s do t[#t + 1] = string.format("%02X", s:byte(i)) end
  return table.concat(t, " ")
end

-- ---------------------------------------------------------------------------
-- issue #80 reproduction cases
-- ---------------------------------------------------------------------------
check(bytes(ev("(n->string 8364)")) == "E2 82 AC", "(n->string 8364) is the UTF-8 for U+20AC")
check(bytes(ev("(n->string 252)")) == "C3 BC", "(n->string 252) is the UTF-8 for U+00FC")
checkeq('(string->n "ü")', "252")
checkeq('(pos "Zürich" 1)', '"ü"')
checkeq('(length (explode "Zürich"))', "6")
checkeq('(tlstr "üx")', '"x"')
checkeq('(explode "Zürich")', '("Z" "ü" "r" "i" "c" "h")')
checkeq('(string.length "Zürich")', "6")            -- stdlib, via explode
checkeq('(hash "ü" 1000)', "252")                   -- code point, not 195*188
checkeq('(= "ü" (n->string 252))', "true")
checkeq('(= (hash "Zürich" 1000) (hash (cn "Z" (cn (n->string 252) "rich")) 1000))', "true")

-- ---------------------------------------------------------------------------
-- n->string range: every scalar value, nothing else
-- ---------------------------------------------------------------------------
checkeq("(n->string 0)", '"' .. "\0" .. '"')
checkeq("(n->string 127)", '"\127"')
check(bytes(ev("(n->string 128)")) == "C2 80", "(n->string 128) two bytes")
check(bytes(ev("(n->string 2047)")) == "DF BF", "(n->string 2047) two bytes")
check(bytes(ev("(n->string 2048)")) == "E0 A0 80", "(n->string 2048) three bytes")
check(bytes(ev("(n->string 55295)")) == "ED 9F BF", "(n->string #xD7FF)")
check(bytes(ev("(n->string 57344)")) == "EE 80 80", "(n->string #xE000)")
check(bytes(ev("(n->string 65535)")) == "EF BF BF", "(n->string #xFFFF)")
check(bytes(ev("(n->string 65536)")) == "F0 90 80 80", "(n->string #x10000)")
check(bytes(ev("(n->string 1114111)")) == "F4 8F BF BF", "(n->string #x10FFFF)")
for _, bad in ipairs({ "55296", "57343", "1114112", "-1", "65.5" }) do
  local msg = trap("(n->string " .. bad .. ")")
  check(type(msg) == "string" and msg:find("not a Unicode code point", 1, true),
        "(n->string " .. bad .. ") raises: " .. tostring(msg))
end
check(trap('(n->string "a")') == "n->string: not a number", "(n->string \"a\") raises")

-- round trips through string->n
for _, n in ipairs({ 65, 127, 128, 233, 252, 255, 256, 2047, 2048, 8364, 65533, 65535, 65536, 128512, 1114111 }) do
  checkeq(string.format("(string->n (n->string %d))", n), tostring(n))
  checkeq(string.format("(length (explode (n->string %d)))", n), "1")
end

-- ---------------------------------------------------------------------------
-- character-indexed primitives
-- ---------------------------------------------------------------------------
checkeq('(pos "Zürich" 0)', '"Z"')
checkeq('(pos "Zürich" 2)', '"r"')
checkeq('(pos "Zürich" 5)', '"h"')
check(trap('(pos "Zürich" 6)') == "pos: index out of range", "(pos \"Zürich\" 6) out of range")
check(trap('(pos "ü" 1)') == "pos: index out of range", "(pos \"ü\" 1) out of range (2 bytes, 1 char)")
checkeq('(pos "a€b😀c" 3)', '"😀"')
checkeq('(pos "a€b😀c" 4)', '"c"')
checkeq('(hdstr "€uro")', '"€"')
checkeq('(tlstr "€uro")', '"uro"')
checkeq('(tlstr "😀")', '""')
checkeq('(string->n "€uro")', "8364")
-- compiler.lua fuses (string->n (pos S I)) / (string->n (hdstr S)) to STRNPOS
checkeq('(string->n (pos "Zürich" 1))', "252")
checkeq('(string->n (pos "Zürich" 2))', "114")
checkeq('(string->n (pos "Zürich" 0))', "90")
checkeq('(string->n (hdstr "€x"))', "8364")
checkeq('(string->n (hdstr "x€"))', "120")
checkeq('(string->n (pos "abc" 2))', "99")
check(trap('(string->n (pos "ü" 1))') == "pos: index out of range", "fused (string->n (pos ...)) keeps pos errors")
shen.eval([[(define u-codes "" -> [] S -> [(string->n (hdstr S)) | (u-codes (tlstr S))])]])
checkeq('(u-codes "aü€😀")', "(97 252 8364 128512)")
shen.eval([[(define u-codes-at S I N -> [] where (= I N) S I N -> [(string->n (pos S I)) | (u-codes-at S (+ I 1) N)])]])
checkeq('(u-codes-at "aü€😀b" 0 5)', "(97 252 8364 128512 98)")
checkeq('(u-codes-at "plain" 0 5)', "(112 108 97 105 110)")
checkeq('(string->n "😀")', "128512")
checkeq('(explode "a€b😀c")', '("a" "€" "b" "😀" "c")')
checkeq('(cn (hdstr "Grüße") (tlstr "Grüße"))', '"Grüße"')
checkeq('(shen.string->bytes "aü€")', "(97 252 8364)")
checkeq('(shen.str->bytes "aü€")', "(97 252 8364)")
checkeq('(@s "Gr" "ü" "ße")', '"Grüße"')
checkeq('(str "Grüße")', '"Grüße"')
-- @s pattern matching in a define walks characters (hdstr / tlstr)
shen.eval([[(define u-count "" -> 0 (@s _ S) -> (+ 1 (u-count S)))]])
checkeq('(u-count "Zürich😀")', "7")
shen.eval([[(define u-first (@s C _) -> C)]])
checkeq('(u-first "über")', '"ü"')

-- ASCII is unchanged
checkeq('(string->n "A")', "65")
checkeq("(n->string 65)", '"A"')
checkeq('(pos "hello" 4)', '"o"')
checkeq('(tlstr "hello")', '"ello"')
checkeq('(explode "ab")', '("a" "b")')
checkeq('(hash "hello" 1000)', tostring((104*101*108*108*111) % 1000))

-- ---------------------------------------------------------------------------
-- = and hash agree on non-ASCII text, however it was built
-- ---------------------------------------------------------------------------
checkeq('(= "Zürich" (cn "Zü" "rich"))', "true")
checkeq('(= "Zürich" "Zurich")', "false")
checkeq('(= (hash "€" 997) (hash (n->string 8364) 997))', "true")
checkeq('(hash (intern "ü") 1000)', "252")
checkeq([[(do (put "Zürich" city yes) (get (cn "Zü" "rich") city))]], "yes")

-- ---------------------------------------------------------------------------
-- reader: files, read-from-string and streams decode UTF-8
-- ---------------------------------------------------------------------------
do
  local p = os.tmpname()
  local fh = assert(io.open(p, "wb"))
  fh:write('(define u-greet {string --> string} N -> (@s "Grüß " N "!"))\n')
  fh:write('(set u-lit "Zürich")\n')
  fh:write('(set u-code (string->n "€"))\n')
  fh:close()
  shen.eval(string.format('(let H (value *hush*) (do (set *hush* true) (load "%s") (set *hush* H)))', p))
  checkeq('(u-greet "Zoë")', '"Grüß Zoë!"')
  checkeq("(value u-lit)", '"Zürich"')
  checkeq("(length (explode (value u-lit)))", "6")
  checkeq("(value u-code)", "8364")
  checkeq(string.format('(length (read-file "%s"))', p), "3")
  -- read-file-as-bytelist stays raw bytes; read-file-as-string is the text
  checkeq(string.format('(length (read-file-as-bytelist "%s"))', p),
          tostring(#('(define u-greet {string --> string} N -> (@s "Grüß " N "!"))\n'
                    .. '(set u-lit "Zürich")\n(set u-code (string->n "€"))\n')))
  local first = '(define u-greet {string --> string} N -> (@s "Grüß " N "!"))\n'
  local ci = first:find("ü", 1, true) - 1          -- ASCII before it: chars == bytes
  checkeq(string.format('(string->n (pos (read-file-as-string "%s") %d))', p, ci), "252")
  checkeq(string.format('(string->n (pos (read-file-as-string "%s") %d))', p, ci + 1), "223")  -- ß
  os.remove(p)
end
check(ev([[(hd (read-from-string (cn (n->string 34) (cn "ü€" (n->string 34)))))]]) == "ü€",
      "read-from-string of a non-ASCII string literal")
check(ev([[(hd (read-from-string (cn (n->string 34) (cn "c#252;" (n->string 34)))))]]) == "ü",
      "c#252; escape inside a string literal is U+00FC")
do
  -- (read Stream) on a file stream goes through shen.my-read-byte
  local p = os.tmpname()
  local fh = assert(io.open(p, "wb")); fh:write('"Grüße" [€]\n'); fh:close()
  check(ev(string.format('(let S (open "%s" in) R (read S) (do (close S) R))', p)) == "Grüße",
        "(read S) decodes a UTF-8 string literal")
  -- read-byte on the same kind of stream still returns raw bytes
  checkeq(string.format('(let S (open "%s" in) A (read-byte S) B (read-byte S) C (read-byte S) D (read-byte S) (do (close S) [A B C D]))', p),
          "(34 71 114 195)")
  os.remove(p)
end

-- ---------------------------------------------------------------------------
-- output: pr writes UTF-8; write-byte writes one raw byte
-- ---------------------------------------------------------------------------
do
  local p = os.tmpname()
  shen.eval(string.format('(let S (open "%s" out) (do (pr "Zürich €" S) (pr (n->string 128512) S) (write-byte 255 S) (close S)))', p))
  local fh = assert(io.open(p, "rb")); local data = fh:read("*a"); fh:close()
  check(data == "Zürich €😀\255", "pr writes UTF-8, write-byte a raw byte: " .. bytes(data))
  os.remove(p)
end

-- ---------------------------------------------------------------------------
-- invalid UTF-8: lenient, lossless, one character per ill-formed byte
-- ---------------------------------------------------------------------------
do
  -- strings with invalid bytes, built in Lua and bound as globals
  local G = require("boot").GLOBALS
  G["u-lone"] = "a\252b"          -- 0xFC: invalid lead byte
  G["u-cont"] = "\188x"           -- stray continuation byte
  G["u-trunc"] = "\226\130"       -- truncated 3-byte sequence (E2 82)
  G["u-over"] = "\192\128"        -- overlong NUL
  G["u-surr"] = "\237\160\128"    -- encoded surrogate U+D800
  checkeq("(length (explode (value u-lone)))", "3")
  checkeq("(string->n (pos (value u-lone) 1))", "252")
  check(ev("(pos (value u-lone) 1)") == "\252", "invalid byte comes back raw from pos")
  check(ev("(tlstr (value u-cont))") == "x", "tlstr drops one stray continuation byte")
  checkeq("(string->n (value u-cont))", "188")
  checkeq("(length (explode (value u-trunc)))", "2")
  checkeq("(shen.string->bytes (value u-trunc))", "(226 130)")
  checkeq("(length (explode (value u-over)))", "2")
  checkeq("(length (explode (value u-surr)))", "3")
  check(ev("(cn (hdstr (value u-lone)) (tlstr (value u-lone)))") == "a\252b",
        "hdstr/tlstr split of invalid text is lossless")
  -- hash still agrees with =
  checkeq("(= (hash (value u-lone) 1000) (hash (cn \"a\" (cn (pos (value u-lone) 1) \"b\")) 1000))", "true")
end

print(string.format("utf8_strings_spec: %d pass, %d fail", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
