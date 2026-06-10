-- repl.lua : interactive Shen REPL with optional line editing, multiline
-- input, persisted history, and Shen-flavoured error reporting.
--
--   require("repl").run()          -- boots the kernel if needed, then loops
--   luajit scripts/repl.lua        -- dev entry (fixes package.path)
--
-- bin/shen (built separately) is the user-facing launcher; it boots and then
-- calls run(opts). opts: { P = booted prims module, quiet = no banner,
-- verbose = verbose kernel load }.
--
-- No hard dependencies: linenoise or readline bindings are used when present
-- (pcall require); otherwise a plain io.read loop with an in-process history
-- buffer (no recall keys). rlwrap is suggested in the fallback banner when
-- found on PATH. History persists to ~/.shen_history when line editing is
-- active.

local M = {}

-- =========================================================================
-- 1. multiline awareness: paren balancing over Shen surface syntax
-- =========================================================================
-- Mirrors the kernel reader (klambda/reader.kl):
--   * strings: "..." with NO escape sequences -- shen.<strc> is any byte
--     except 34, so a double quote ALWAYS closes the string and backslashes
--     inside strings are literal ("\\" is a two-backslash string, not a
--     comment start).
--   * comments: \\ to end of line (shen.<singleline>) and \* ... *\ blocks,
--     which NEST (shen.<longnatter> includes shen.<comment>).
-- Approximation: a single-line comment inside a block comment is not given
-- special treatment (a *\ on such a line still closes the block).
--
-- input_state(s) -> depth, mode
--   depth : net count of unclosed '(' (can go negative on a stray ')')
--   mode  : "code" | "string" | "line" | "block"  (state at end of buffer)
function M.input_state(s)
  local depth = 0
  local mode = "code"
  local blockdepth = 0
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if mode == "code" then
      if c == "(" then depth = depth + 1
      elseif c == ")" then depth = depth - 1
      elseif c == '"' then mode = "string"
      elseif c == "\\" then
        local d = s:sub(i + 1, i + 1)
        if d == "\\" then mode = "line"; i = i + 1
        elseif d == "*" then mode = "block"; blockdepth = 1; i = i + 1
        end
      end
    elseif mode == "string" then
      if c == '"' then mode = "code" end
    elseif mode == "line" then
      if c == "\n" then mode = "code" end
    else -- block comment (nests)
      local d = s:sub(i + 1, i + 1)
      if c == "\\" and d == "*" then
        blockdepth = blockdepth + 1; i = i + 1
      elseif c == "*" and d == "\\" then
        blockdepth = blockdepth - 1; i = i + 1
        if blockdepth == 0 then mode = "code" end
      end
    end
    i = i + 1
  end
  return depth, mode
end

-- Is the buffer ready to hand to the kernel reader? Balanced parens, not
-- inside a string or block comment. NEGATIVE depth counts as complete: the
-- reader reports a stray ')' better than we could by waiting forever. A
-- trailing single-line comment is complete (it ends with its line).
function M.balanced(s)
  local depth, mode = M.input_state(s)
  return depth <= 0 and mode ~= "string" and mode ~= "block"
end

-- =========================================================================
-- 2. error translation (defined in prims.lua next to TOEXCN, re-exported
--    here so REPL users and tests have one import point)
-- =========================================================================
function M.translate_error(msg)
  return require("prims").translate_error(msg)
end

-- =========================================================================
-- 3. "did you mean": nearest names from the function table
-- =========================================================================
local floor, abs, min = math.floor, math.abs, math.min

-- Levenshtein distance with an early exit once every entry of a row
-- exceeds `cap` (returns cap+1 in that case -- "too far, don't care").
local function edit_distance(a, b, cap)
  cap = cap or math.huge
  local la, lb = #a, #b
  if abs(la - lb) > cap then return cap + 1 end
  local prev, cur = {}, {}
  for j = 0, lb do prev[j] = j end
  for i = 1, la do
    cur[0] = i
    local best = i
    local ca = a:byte(i)
    for j = 1, lb do
      local cost = (ca == b:byte(j)) and 0 or 1
      local v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
      cur[j] = v
      if v < best then best = v end
    end
    if best > cap then return cap + 1 end
    prev, cur = cur, prev
  end
  return prev[lb]
end
M.edit_distance = edit_distance

-- Suggest up to `maxn` (default 3) names near `name` from `names`: either an
-- array of strings or a table whose KEYS are the names (e.g. P.F). Distance
-- cap scales with the name length so short names don't match everything.
function M.did_you_mean(name, names, maxn)
  maxn = maxn or 3
  local cap = (#name > 6) and 3 or (#name > 2) and 2 or 1
  local cands = {}
  local function consider(k)
    if type(k) == "string" and k ~= name then
      local d = edit_distance(name, k, cap)
      if d <= cap then cands[#cands + 1] = { d = d, k = k } end
    end
  end
  if names[1] ~= nil then
    for _, k in ipairs(names) do consider(k) end
  else
    for k in pairs(names) do consider(k) end
  end
  table.sort(cands, function(x, y)
    if x.d ~= y.d then return x.d < y.d end
    return x.k < y.k
  end)
  local out = {}
  for i = 1, min(maxn, #cands) do out[i] = cands[i].k end
  return out
end

-- =========================================================================
-- 4. Shen-level backtrace
-- =========================================================================
-- Compiled user defuns carry chunkname "shen:<name>" (P.eval in prims.lua),
-- so their frames are recognized by source. Kernel functions live in big
-- per-file chunks, so they are recognized by identity through a reverse map
-- of P.F, built on demand (error path only, ~2k entries). Lua plumbing
-- frames (APP, thunks, pcall wrappers, the REPL itself) are suppressed.
local MAX_BT = 12
function M.shen_backtrace(P, start_level)
  local getinfo = debug and debug.getinfo
  if not getinfo then return {}, false end
  local rev = {}
  for k, v in pairs(P.F) do
    if type(v) == "function" and rev[v] == nil then rev[v] = k end
  end
  local out, more = {}, false
  local level = start_level or 2
  while true do
    local info = getinfo(level, "fS")
    if not info then break end
    local nm = info.func and rev[info.func]
    if not nm then
      local src = info.source or ""
      nm = src:match("^shen:(.+)$")
    end
    if nm then
      if #out >= MAX_BT then more = true; break end
      if out[#out] ~= nm then out[#out + 1] = nm end -- collapse direct recursion
    end
    level = level + 1
  end
  return out, more
end

-- =========================================================================
-- 5. error display (translation + did-you-mean + backtrace)
-- =========================================================================
function M.describe_error(P, err, frames, more)
  local R = require("runtime")
  local msg
  if getmetatable(err) == R.Excn then
    msg = err.msg                      -- kernel exception: already Shen-speak
  else
    msg = M.translate_error(tostring(err))
  end
  msg = msg:gsub("%s+$", "")   -- kernel messages often end with "\n"
  local lines = { msg }
  -- undefined-function errors: suggest near matches from the F key set.
  -- Shapes: "<name> is undefined" (our translation), "fn: <name> is
  -- undefined" (kernel fn macro), "not a function: <name>" (APP).
  local missing = msg:match("([^%s]+) is undefined")
                  or msg:match("^not a function: ([^%s]+)")
  if missing then
    local sugg = M.did_you_mean(missing, P.F)
    if #sugg > 0 then
      lines[#lines + 1] = "  did you mean: " .. table.concat(sugg, ", ") .. " ?"
    end
  end
  if frames and #frames > 0 then
    lines[#lines + 1] = "  Shen call stack (most recent first):"
    for _, f in ipairs(frames) do lines[#lines + 1] = "    " .. f end
    if more then lines[#lines + 1] = "    ..." end
  end
  return table.concat(lines, "\n")
end

-- =========================================================================
-- 6. line editing (optional) + history
-- =========================================================================
local HISTORY_FILE = (os.getenv("HOME") or ".") .. "/.shen_history"

local function have_rlwrap()
  local fh = io.popen("command -v rlwrap 2>/dev/null")
  if not fh then return false end
  local out = fh:read("*l")
  fh:close()
  return out ~= nil and out ~= ""
end

local function make_editor()
  -- lua-linenoise: module-level linenoise/historyadd/historyload/historysave
  local ok, L = pcall(require, "linenoise")
  if ok and type(L) == "table" and L.linenoise then
    pcall(L.historyload, HISTORY_FILE)
    return {
      kind = "linenoise",
      read = function(prompt) return L.linenoise(prompt) end,
      remember = function(line)
        pcall(L.historyadd, line)
        pcall(L.historysave, HISTORY_FILE)
      end,
    }
  end
  -- readline bindings (lua-readline and friends)
  local ok2, RL = pcall(require, "readline")
  if ok2 and type(RL) == "table" and RL.readline then
    pcall(function()
      if RL.set_options then RL.set_options({ histfile = HISTORY_FILE, auto_add = false }) end
    end)
    return {
      kind = "readline",
      read = function(prompt) return RL.readline(prompt) end,
      remember = function(line)
        pcall(function() if RL.add_history then RL.add_history(line) end end)
        pcall(function() if RL.save_history then RL.save_history() end end)
      end,
    }
  end
  -- plain fallback: io.read with an in-process history buffer (no recall
  -- keys, no persistence -- per contract history only persists when a line
  -- editor is active).
  local hist = {}
  return {
    kind = "plain",
    history = hist,
    read = function(prompt)
      io.write(prompt)
      io.flush()
      return io.read("*l")
    end,
    remember = function(line) hist[#hist + 1] = line end,
  }
end
M.make_editor = make_editor -- exposed for tests

local function banner(P, ed)
  local v = P.GLOBALS["*version*"] or "Shen"
  io.write(tostring(v), " on shen-lua (", jit and jit.version or _VERSION, ")\n")
  if ed.kind == "plain" then
    local hint = "plain input mode (no linenoise/readline found"
    if have_rlwrap() then
      hint = hint .. "; tip: run under rlwrap for arrow-key history"
    end
    io.write("exit with (exit 0) or Ctrl-D; ", hint, ")\n")
  else
    io.write("exit with (exit 0) or Ctrl-D; line editing: ", ed.kind,
             ", history in ", HISTORY_FILE, "\n")
  end
end

-- =========================================================================
-- 7. the loop
-- =========================================================================
function M.run(opts)
  opts = opts or {}
  local P = opts.P or require("boot")
  if P.F["shen.initialise"] == nil then P.load_kernel(opts.verbose) end
  if P.GLOBALS["*property-vector*"] == nil then P.initialise() end

  local ed = make_editor()
  if not opts.quiet then banner(P, ed) end

  local function eval_input(buf)
    local forms = P.F["read-from-string"](buf)
    if P.GLOBALS["shen.*tc*"] == true then
      return P.F["shen.check-eval-and-print"](forms)
    end
    return P.F["shen.eval-and-print"](forms)
  end
  local function handler(e) -- runs on the erroring stack: capture Shen frames
    local frames, more = M.shen_backtrace(P, 2)
    return { e = e, frames = frames, more = more }
  end

  local n = 0
  while true do
    n = n + 1
    local prompt = "(" .. n .. (P.GLOBALS["shen.*tc*"] == true and "+" or "-") .. ") "
    local line = ed.read(prompt)
    if line == nil then io.write("\n"); break end       -- EOF (Ctrl-D): clean exit
    local buf = line
    while not M.balanced(buf) do                        -- keep reading until closed
      local cont = ed.read("... ")
      if cont == nil then break end                     -- EOF mid-form: hand over as-is
      buf = buf .. "\n" .. cont
    end
    if buf:match("%S") then
      ed.remember(buf)
      local ok, r = xpcall(function() return eval_input(buf) end, handler)
      if not ok then
        -- r is the handler capture, unless something threw inside the
        -- handler itself (then r is whatever Lua gives us).
        if type(r) == "table" and r.frames then
          io.write(M.describe_error(P, r.e, r.frames, r.more), "\n")
        else
          io.write(M.translate_error(tostring(r)), "\n")
        end
      end
      io.write("\n")
    else
      n = n - 1                                         -- blank input: same prompt number
    end
  end
end

return M
