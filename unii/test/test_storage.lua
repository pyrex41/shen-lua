-- Framed journal and supervisor durability: round trips, crash tails at
-- every byte offset, corruption refusal, single-owner locking, restart
-- with identical hashes, replay divergence, and bundle/config refusal.
local T = require("unii.test.lib")
local storage = require("unii.host.storage")
local supervisor = require("unii.host.supervisor")
local codec = require("unii.host.codec")
local schema = require("unii.host.schema")
local mock = require("unii.host.mock.summarizer")

local function read(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end
local function write(path, s)
  local f = assert(io.open(path, "wb")); f:write(s); f:close()
end
local PAYLOADS = { "first", "", "bin\0\255\n\nUJ1 9 9\n", ("z"):rep(70) }

local function journal_with(payloads)
  local dir = T.tmpdir("store")
  local s = storage.open(dir)
  for _, p in ipairs(payloads) do s:append(p) end
  s:close()
  return dir, read(dir .. "/" .. storage.JOURNAL)
end

local function open_sup(dir, extra)
  local o = { core = T.core(), provider = mock.new { cap = 512 } }
  for k, v in pairs(extra or {}) do o[k] = v end
  return supervisor.open(dir, o)
end

local function feed(sup, from, n)
  for i = from, from + n - 1 do
    sup:submit(T.msg(i, i % 2 == 0 and "user" or "assistant", ("message %d "):format(i) .. ("w"):rep((i * 97) % 700)))
    sup:pump()
  end
end

-- Rewrite record `seq` of a journal through `edit(decoded_payload)`.
local function tamper(dir, seq, edit)
  local first = seq == 1 and 1 or 2
  local path = seq == 1 and (dir .. "/" .. storage.JOURNAL)
    or (dir .. "/journals/2026-10-09.uj")
  local recs = storage.parse(read(path), first)
  local out = {}
  for _, r in ipairs(recs) do
    local payload = r.payload
    if r.seq == seq then
      local v = codec.decode(payload)
      edit(v)
      payload = codec.encode(v)
    end
    out[#out + 1] = storage.frame(r.seq, payload)
  end
  write(path, table.concat(out))
end

return {
  { "frames round-trip arbitrary bytes and survive reopen", function()
    local dir = journal_with(PAYLOADS)
    local s, info = storage.open(dir)
    T.eq(info.records, #PAYLOADS); T.eq(info.tail_isolated, nil)
    for i, p in ipairs(PAYLOADS) do T.eq(s:records()[i].payload, p); T.eq(s:records()[i].seq, i) end
    T.eq(s:append("next"), #PAYLOADS + 1)
    s:close()
    T.rm(dir)
  end },

  { "a crash tail at every byte offset is isolated and truncated", function()
    local dir, bytes = journal_with(PAYLOADS)
    local ends, off = {}, 0
    for i, p in ipairs(PAYLOADS) do off = off + #storage.frame(i, p); ends[#ends + 1] = off end
    T.eq(off, #bytes)
    local path = dir .. "/" .. storage.JOURNAL
    for cut = 0, #bytes do
      os.execute(("rm -f %q/journal.tail-*"):format(dir))
      write(path, bytes:sub(1, cut))
      local whole = 0
      for _, e in ipairs(ends) do if e <= cut then whole = whole + 1 end end
      local s, info = storage.open(dir)
      T.eq(info.records, whole, "records at cut " .. cut)
      local boundary = cut == 0 or cut == ends[whole]
      if boundary then
        T.eq(info.tail_isolated, nil, "no tail at frame boundary " .. cut)
      else
        T.ok(info.tail_isolated, "tail isolated at cut " .. cut)
        T.eq(read(info.tail_isolated), bytes:sub((whole > 0 and ends[whole] or 0) + 1, cut))
      end
      T.eq(#read(path), whole > 0 and ends[whole] or 0, "truncated to committed data")
      T.eq(s:append("after"), whole + 1)
      s:close()
    end
    T.rm(dir)
  end },

  { "corruption inside committed data refuses to open and changes nothing", function()
    local dir, bytes = journal_with(PAYLOADS)
    local path = dir .. "/" .. storage.JOURNAL
    local hdr = #("UJ1 1 5\n")
    for _, pos in ipairs { 1, hdr + 2, hdr + 6, hdr + 7, hdr + 40 } do
      local bad = bytes:sub(1, pos - 1) .. string.char((bytes:byte(pos) + 1) % 256) .. bytes:sub(pos + 1)
      write(path, bad)
      T.raises(function() storage.open(dir) end, "journal corrupt at byte")
      T.eq(read(path), bad, "a refused journal is left untouched")
    end
    write(path, storage.frame(1, "a") .. storage.frame(3, "c"))
    T.raises(function() storage.open(dir) end, "sequence 3, expected 2")
    T.rm(dir)
  end },

  { "one owner per chat: a second open (same or other process) is refused", function()
    local dir = T.tmpdir("lock")
    local s = storage.open(dir)
    T.raises(function() storage.open(dir) end, "owned by another process")
    local child = ([[luajit -e 'package.path=%q..package.path
      local ok, e = pcall(require("unii.host.storage").open, %q)
      io.write(ok and "OPENED" or tostring(e))']]):format(T.root() .. "/?.lua;", dir)
    local out = T.sh(child)
    T.ok(out:find("owned by another process", 1, true), out)
    s:close()
    out = T.sh(child)
    T.ok(out:find("OPENED", 1, true), "lock released on close: " .. out)
    T.rm(dir)
  end },

  { "supervisor restart reproduces view hash, state hash and status", function()
    local dir = T.tmpdir("sup")
    local sup = open_sup(dir, { config = schema.config { low = 1500, high = 3000 } })
    feed(sup, 0, 40)
    local text, vh = sup:view()
    local sh, st = sup:state_hash(), sup:status()
    T.ok(st.covered == 40 and st.view_lines > 0, "summaries were absorbed")
    sup:close()
    local again = open_sup(dir)
    local text2, vh2 = again:view()
    T.eq(vh2, vh); T.eq(text2, text); T.eq(again:state_hash(), sh)
    T.eq(again:status().rev, st.rev)
    T.eq(#again:invariant_errors(), 0)
    feed(again, 40, 5)
    T.eq(again:status().count, 45)
    again:close()
    T.rm(dir)
  end },

  { "outstanding summaries are re-dispatched after a restart", function()
    local dir = T.tmpdir("sup")
    local sup = open_sup(dir)
    sup:submit(T.msg(0, "user", ("x"):rep(900)))       -- needs a summary
    T.eq(sup:outstanding_count(), 1)
    sup:close()                                          -- "crash" before it completes
    local again = open_sup(dir)
    T.eq(again:outstanding_count(), 1)
    again:pump()
    T.eq(again:outstanding_count(), 0)
    T.eq(again:status().covered, 1)
    again:close()
    T.rm(dir)
  end },

  { "a failed journal append leaves the in-memory state unadopted", function()
    local dir = T.tmpdir("sup")
    local sup = open_sup(dir)
    feed(sup, 0, 3)
    local before = sup:state_hash()
    local before_view, before_view_hash = sup:view()
    local real = sup.store.append
    sup.store.append = function() error("storage append: disk full (injected)", 0) end
    T.raises(function() sup:submit(T.msg(3, "user", "lost")) end, "disk full")
    T.eq(sup:state_hash(), before)
    local after_view, after_view_hash = sup:view()
    T.eq(after_view, before_view)
    T.eq(after_view_hash, before_view_hash)
    sup.store.append = real
    sup:submit(T.msg(3, "user", "kept"))
    local h = sup:state_hash()
    sup:close()
    local again = open_sup(dir)
    T.eq(again:state_hash(), h)
    again:close()
    T.rm(dir)
  end },

  { "tampered records, foreign bundles and changed config are refused", function()
    local dir = T.tmpdir("sup")
    local sup = open_sup(dir)
    feed(sup, 0, 6)
    sup:close()
    local path = dir .. "/" .. storage.JOURNAL
    local day_path = dir .. "/journals/2026-10-09.uj"
    local clean, clean_day = read(path), read(day_path)
    local inspected = storage.open(dir)
    local n = #inspected:records()
    inspected:close()

    tamper(dir, n, function(v) v.v.view_hash = codec.text(("0"):rep(64)) end)
    T.raises(function() open_sup(dir) end, "replay divergence at seq " .. n .. ": view hash")
    write(path, clean); write(day_path, clean_day)

    tamper(dir, 3, function(v) v.v.decisions = codec.list {} end)
    T.raises(function() open_sup(dir) end, "replay divergence at seq 3: decisions")
    write(path, clean); write(day_path, clean_day)

    tamper(dir, 1, function(v) v.v.bundle = codec.text(("f"):rep(64)) end)
    T.raises(function() open_sup(dir) end, "Refusing to replay under different rules")
    write(path, clean); write(day_path, clean_day)

    T.raises(function() open_sup(dir, { config = schema.config { high = 99999 } }) end,
      "configuration differs")
    local ok = open_sup(dir)
    ok:close()
    T.rm(dir)
  end },
}
