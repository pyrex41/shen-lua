-- Phase 0 boundary gates: pinned runtime and gist, rule-bundle and
-- configuration checks at boot, typed transition called from Lua, rounded
-- identifier rejection, purity of the core, and no eval of data.
local T = require("unii.test.lib")
local codec = require("unii.host.codec")
local schema = require("unii.host.schema")
local core = require("unii.host.core")
local manifest = require("unii.manifest")

local root = T.root()
local unii = root .. "/unii"

local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s end

return {
  { "runtime outside unii/ is byte-identical to the pinned shen-lua commit", function()
    local out, ok = T.sh(("git -C %q cat-file -t %s"):format(root, manifest.shen_lua.commit))
    if not ok then return "skip" end
    T.eq(out:gsub("%s", ""), "commit")
    local _, same = T.sh(("git -C %q diff --quiet %s -- . ':(exclude)unii'"):format(root, manifest.shen_lua.commit))
    T.ok(same, "files outside unii/ differ from " .. manifest.shen_lua.commit)
    local _, anc = T.sh(("git -C %q merge-base --is-ancestor %s HEAD"):format(root, manifest.shen_lua.commit))
    T.ok(anc, "pinned commit is not an ancestor of HEAD")
  end },

  { "pinned runtime boots and reports Shen 42 / release 0.11.1", function()
    local S = core.shen()
    T.eq(S.value("*version*"), "42")
    local rockspec = read(root .. "/shen-" .. manifest.shen_lua.release .. "-1.rockspec")
    T.ok(rockspec:find('version = "' .. manifest.shen_lua.release .. '-1"', 1, true), "rockspec version")
  end },

  { "gist revision checksum (network; set UNII_OFFLINE=1 to skip)", function()
    if os.getenv("UNII_OFFLINE") == "1" then return "skip" end
    local g = manifest.gist
    local tmp = os.tmpname()
    local _, ok = T.sh(("curl -sSfL --max-time 20 -o %q %q"):format(tmp, g.raw_url))
    if not ok then os.remove(tmp); return "skip" end
    local body = read(tmp)
    T.eq(#body, g.bytes, "gist byte length")
    T.eq(require("unii.host.sha256").hex(body), g.sha256, "gist sha256")
    local id, gok = T.sh(("git hash-object %q"):format(tmp))
    os.remove(tmp)
    if gok then T.eq((id:gsub("%s", "")), g.git_blob, "gist git blob id") end
  end },

  { "build stamp matches the bundle; boot rejects an untypechecked bundle", function()
    T.eq(core.read_stamp(unii), core.bundle_hash(unii))
    local tmp = T.tmpdir("bundle")
    os.execute(("mkdir -p %q/host %q/build && cp -R %q/core %q/ && cp %q/build/bundle.stamp %q/build/")
      :format(tmp, tmp, unii, tmp, unii, tmp))
    local f = assert(io.open(tmp .. "/core/view.shen", "ab"))
    f:write("\n\\\\ an edit after the build\n")
    f:close()
    T.ok(core.bundle_hash(tmp) ~= core.read_stamp(tmp), "edited bundle must change its hash")
    -- boot() checks the hash of its own unii/ dir; emulate with the edited copy
    local saved = core.unii_dir
    core.unii_dir = function() return tmp end
    local err = T.raises(function() core.boot() end, "has not passed the typechecked build")
    core.unii_dir = saved
    T.rm(tmp)
    T.ok(err:find("unii build", 1, true), "error should say how to fix it")
  end },

  { "ill-typed rules are rejected by the kernel typechecker", function()
    local S = core.shen()
    S.eval("(tc +)")
    local ok, err = pcall(S.prims.F["load"], unii .. "/test/fixtures/ill_typed_rules.shen")
    S.eval("(tc -)")
    T.ok(not ok, "ill-typed module loaded")
    T.ok(core.error_message(err):find("type error", 1, true), core.error_message(err))
  end },

  { "a typed transition is callable from Lua with tagged data", function()
    local C = T.core()
    local S = core.shen()
    local sig = S.typecheck("(fn unii.transition)", "A")
    T.eq(S.tostring(sig), "(unii.state --> (unii.event --> unii.result))")
    local st = C:init(schema.config {})
    local st2, out = C:transition(st, T.tag(T.msg(0, "user", "hello")))
    T.eq(T.decision_names(out), "node-committed,view-extended,view-revision")
    T.eq(out.commands[1]._, "emit-client-event")
    T.eq(C:status(st2).count, 1)
    T.eq(C:status(st).count, 0, "transition must not mutate its input state")
  end },

  { "boundary rejects rounded or out-of-range identifiers", function()
    -- 2^53 + 1 written as text: rejected before tonumber could round it
    T.raises(function() codec.int("9007199254740993") end, "outside exact range")
    -- a Lua number that already rounded (2^53 + 1 -> 2^53) is refused outright
    T.raises(function() codec.int(9007199254740993) end, "decimal text")
    T.raises(function() codec.int_of(9007199254740993) end, "not an exact safe integer")
    T.raises(function() codec.int_of(1.5) end, "not an exact safe integer")
    -- domain ceiling for v1 identifiers: 2^31 - 1
    T.raises(function() schema.encode("event", T.msg("2147483648", "user", "x")) end, "outside [0, 2147483647]")
    T.raises(function() schema.encode("event", T.msg(2147483648, "user", "x")) end, "outside [0, 2147483647]")
    T.raises(function() schema.encode("event", T.msg("-1", "user", "x")) end, "outside [0, 2147483647]")
    T.raises(function() schema.encode("event", T.msg("01", "user", "x")) end, "non-canonical")
    T.raises(function() schema.encode("event", T.msg("1e3", "user", "x")) end, "non-canonical")
    -- values leaving Shen are checked too
    local S = core.shen()
    T.raises(function() codec.from_shen(9007199254740992) end, "not an exact safe integer")
    T.raises(function() codec.from_shen(0.5) end, "not an exact safe integer")
    -- the port's checked path inside Shen raises on rounded text
    T.raises(function() S.eval('(lua.checked-integer "9007199254740993")') end, "outside exact range")
    -- the core's own validation of naturals
    T.eq(S.call("unii.nat?", 2147483647), true)
    T.eq(S.call("unii.nat?", 2147483648), false)
    T.eq(S.call("unii.nat?", 1.5), false)
  end },

  { "core rejects an out-of-sequence id even when the codec is bypassed", function()
    local C = T.core()
    local st = C:init(schema.config {})
    local ev = T.tag(T.msg(0, "user", "x"))
    ev.v[2] = codec.int("5")
    local st2, out = C:transition(st, ev)
    T.eq(out.decisions[1]._, "event-rejected")
    T.eq(out.decisions[1].reason, "message id out of sequence")
    T.eq(C:status(st2).count, 0)
  end },

  { "invalid configurations are refused by the core", function()
    local C = T.core()
    T.raises(function() C:init(schema.config { low = 5000, high = 4000 }) end, "high threshold must exceed")
    T.raises(function() C:init(schema.config { leaf_cap = 8 }) end, "leaf cap")
    T.raises(function() C:init(schema.config { max_inflight = 0 }) end, "max inflight")
  end },

  { "core sources are pure: no clock, files, network, randomness, eval or `/`", function()
    local forbidden = {
      "%(lua%.", "%(get%-time", "%(open ", "%(read%-byte", "%(write%-byte", "%(eval",
      "%(eval%-kl", "%(random", "%(stinput", "%(stoutput", "%(pr ", "%(print ", "%(output ",
      "%(load ", "%(close ", "%(read%-file", "%(write%-to%-file", "%(set ", "%(value ",
      "%(/ ", "%(shen%.", "%(intern ",
    }
    for _, name in ipairs(manifest.core_files) do
      local src = read(unii .. "/core/" .. name)
      local code = src:gsub("\\%*.-%*\\", ""):gsub("\\\\[^\n]*", "")
      for _, pat in ipairs(forbidden) do
        T.ok(not code:find(pat), name .. " uses forbidden form " .. pat)
      end
    end
  end },

  { "host never evaluates data as Shen source", function()
    local allowed = { ['"(tc +)"'] = true, ['"(tc -)"'] = true }
    local p = io.popen(("grep -rn 'eval' %q/host"):format(unii))
    for line in p:lines() do
      for arg in line:gmatch("eval(%b())") do
        T.ok(allowed[arg:sub(2, -2)], "host eval with non-constant argument: " .. line)
      end
    end
    p:close()
  end },

  { "message text that looks like Shen code stays inert data", function()
    local e = T.engine()
    local text = '(set *pwned* true) (error "boom")'
    local out = e:apply(T.msg(0, "user", text))
    T.eq(T.decision_names(out), "node-committed,view-extended,view-revision")
    T.ok(e.C:render(e.state):find(text, 1, true), "text rendered verbatim")
    local S = core.shen()
    T.ok(not pcall(S.value, "*pwned*"), "message text was evaluated")
  end },
}
