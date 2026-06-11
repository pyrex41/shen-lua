-- bin/yggdrasil-build.lua : Yggdrasil stage-2 builder for shen-lua.
--
--   luajit bin/yggdrasil-build.lua <shaken-dir> <out.lua> [--linked]
--
-- <shaken-dir> is a Yggdrasil stage-1 output directory: a tree-shaken
-- kernel (kernel.kl, ShenOSKernel-41.1 defuns in load order), the user
-- program as KL (one or more user= files), and yggdrasil.manifest.txt.
-- The builder compiles every KL form ahead of time with the port's own
-- compiler (compiler.lua C.compile_top) and emits ONE runnable Lua
-- program <out.lua>:
--
--   * default: fully self-contained — embeds the runtime/compiler/prims
--     module sources via package.preload (same technique as
--     build/make-bundle.lua), so the output runs on any LuaJIT with no
--     access to a shen-lua checkout;
--   * --linked: small output that requires the shen-lua modules from
--     this checkout (the repo root is baked into package.path) — useful
--     during development.
--
-- Each compiled chunk is embedded twice: as string.dump'd LuaJIT
-- bytecode (fast load path) and as Lua source (fallback for a LuaJIT
-- whose bytecode format differs from the build machine's) — mirroring
-- boot.lua's kernel-cache / make-bundle.lua's embedded-blob strategy.
--
-- The generated program does NOT go through boot.lua's full-kernel path
-- (that would defeat the tree-shaking): it performs only the minimal
-- "lib boot" derived from boot.lua —
--   1. jit.opt mcode-area tuning (perf only, SHEN_JIT_OPT=off to skip),
--   2. *stinput*/*stoutput*/*sterror* stream setup + *home-directory*,
--   3. platform globals (*language* ... *release*) the 41.1 kernel reads,
--   4. run the compiled kernel chunks (the shaken defuns, in load order),
--   5. install the native overrides that REPLACE kernel KL functions
--      (P.install_native_prolog + P.install_native_stdlib, after the
--      kernel chunks exactly as boot.lua's install_native_overrides does;
--      the prolog_engine.lua soa32 engine is deliberately NOT installed —
--      it hooks shen.compile-prolog at macroexpansion time, which has
--      already happened in stage 1, so the shaken program runs the
--      certified pure-KL CPS prolog from kernel.kl),
--   6. call the manifest's init function (shen.initialise),
--   7. run the user chunks in manifest order.
-- Skipped from boot.lua on purpose: kernel bytecode cache, fasl layer,
-- lua_interop, prolog_engine, repl — none are needed by a shaken program.
--
-- needs-eval / eval-kl note: prims.lua requires compiler.lua at module
-- scope (defprim writes C.ARITY; P.ENV.KDATA aliases C.KDATA; P.eval
-- requires "compiler"), so the compiler is ALWAYS part of the embedded
-- runtime — there is no lighter eval-less profile in this port. eval-kl
-- therefore works in the generated program for free: P.eval compiles
-- through the embedded compiler. To make runtime eval-kl emit the same
-- direct exact-arity calls stage-2 compilation saw, the generated
-- program restores the defun arity table (C.ARITY) captured at build
-- time, like boot.lua does when loading its bytecode cache.
--
-- All chunks are compiled with C.NO_KDATA = true: literal cons trees ride
-- inside the chunk via MKTREE blueprints instead of the compile-time
-- KDATA side table, so the emitted chunks are relocatable and the
-- generated program needs no KDATA serialization/rebuild step.

-- ---- locate the repo root from this script's own path ---------------------
local self = arg and arg[0] or "bin/yggdrasil-build.lua"
local root = self:match("^(.*)[/\\]bin[/\\][^/\\]+$") or "."
if not root:match("^[/\\]") and not root:match("^%a:[/\\]") then
  -- absolutize so --linked outputs bake a path that works from any cwd
  local p = io.popen("pwd -P")
  if p then
    local cwd = p:read("*l"); p:close()
    if cwd and cwd ~= "" then
      root = (root == ".") and cwd or (cwd .. "/" .. root)
    end
  end
end
package.path = root .. "/?.lua;" .. package.path

local USAGE = "usage: luajit bin/yggdrasil-build.lua <shaken-dir> <out.lua> [--linked]\n"

local shaken_dir, outpath, linked
for i = 1, #arg do
  local a = arg[i]
  if a == "--linked" then linked = true
  elseif a == "-h" or a == "--help" then io.write(USAGE); os.exit(0)
  elseif not shaken_dir then shaken_dir = a
  elseif not outpath then outpath = a
  else io.stderr:write("yggdrasil-build: unexpected argument " .. a .. "\n" .. USAGE); os.exit(2) end
end
if not (shaken_dir and outpath) then
  io.stderr:write(USAGE); os.exit(2)
end
shaken_dir = shaken_dir:gsub("/+$", "")

local function read_file(path)
  local fh, e = io.open(path, "rb")
  if not fh then error("cannot open " .. path .. " (" .. tostring(e) .. ")", 0) end
  local s = fh:read("*a"); fh:close()
  return s
end

-- ---- 1. parse the manifest -------------------------------------------------
local MANIFEST = shaken_dir .. "/yggdrasil.manifest.txt"
local man = { user = {}, primitive = {} }
for line in read_file(MANIFEST):gmatch("[^\r\n]+") do
  local k, v = line:match("^([%w%-]+)=(.*)$")
  if k == "user" or k == "primitive" then
    table.insert(man[k], v)
  elseif k then
    man[k] = v
  end
end
assert(man.kernel, MANIFEST .. ": missing kernel=")
assert(man.init, MANIFEST .. ": missing init=")
assert(#man.user > 0, MANIFEST .. ": no user= entries")
if man["kernel-version"] ~= "41.1" then
  io.stderr:write(("yggdrasil-build: warning: manifest kernel-version=%s, this port is certified against 41.1\n")
    :format(tostring(man["kernel-version"])))
end

-- ---- 2. load the port's compiler ------------------------------------------
local R = require("runtime")
local C = require("compiler")
local P = require("prims")    -- registers primitive arities into C.ARITY

-- Contract check: every primitive the manifest expects must be provided by
-- this port — a prims.lua F-table entry, a compiler special form, a global
-- the generated lib boot sets, or a name that is guarded-dead here (the
-- kernel only calls it behind a port predicate this port answers false to:
-- shen.char-stoutput?/shen.char-stinput? are hardwired false in prims.lua,
-- so the shen.write-string / shen.read-unit-string branches never run).
local SPECIAL = {
  ["if"]=true, ["cond"]=true, ["let"]=true, ["do"]=true, ["trap-error"]=true,
  ["and"]=true, ["or"]=true, ["lambda"]=true, ["freeze"]=true, ["defun"]=true,
  ["type"]=true,
}
local BOOT_GLOBALS = {
  ["*stinput*"]=true, ["*stoutput*"]=true, ["*sterror*"]=true,
  ["*home-directory*"]=true, ["*language*"]=true, ["*implementation*"]=true,
  ["*port*"]=true, ["*porters*"]=true, ["*os*"]=true, ["*release*"]=true,
}
local GUARDED_DEAD = { ["shen.write-string"]=true, ["shen.read-unit-string"]=true }
for _, name in ipairs(man.primitive) do
  if not (P.F[name] or SPECIAL[name] or BOOT_GLOBALS[name] or GUARDED_DEAD[name]) then
    io.stderr:write("yggdrasil-build: warning: manifest primitive not provided by this port: "
      .. name .. "\n")
  end
end

-- Relocatable chunks: no KDATA side-table indices baked into the bytecode.
C.NO_KDATA = true

-- ---- 3. read + prescan + compile ------------------------------------------
-- Prescan EVERYTHING first (kernel + user) so mutual/forward references —
-- including user code calling kernel functions — compile as direct
-- exact-arity calls, exactly like boot.lua's whole-kernel prescan.
local kernel_forms = R.read_all(read_file(shaken_dir .. "/" .. man.kernel))
local user_files = {}
for _, uf in ipairs(man.user) do
  user_files[#user_files+1] = { name = uf, forms = R.read_all(read_file(shaken_dir .. "/" .. uf)) }
end
-- ---- 3b. reference-closure check / certified-kernel backfill ---------------
-- Stage 1 must ship every kernel defun reachable from the program; verify it.
-- Walk every form collecting names in call (head) position that are neither
-- locally bound, port-provided (P.F / special forms), nor defined by a defun
-- in the shaken output. Any such name found in the port's vendored certified
-- 41.1 kernel (klambda/*.kl) is BACKFILLED into the kernel chunk — with a
-- loud warning, because each backfill is a stage-1 shaker bug that should be
-- fixed in yggdrasil.shen. Names found nowhere are warn-only (they may be
-- guarded-dead, like shen.write-string behind shen.char-stoutput?).
-- Limitation (same one stage 1 has): only head-position references are
-- traced; a function passed by bare name in argument position is invisible.
local function walk_calls(form, bound, called)
  if not R.is_cons(form) then return end
  local h = form[1]
  if R.is_symbol(h) then
    local n = h.name
    if n == "defun" and R.is_cons(form[2]) then
      local b2 = setmetatable({}, { __index = bound })
      local p = form[2][2][1]
      while R.is_cons(p) do b2[p[1].name] = true; p = p[2] end
      walk_calls(form[2][2][2][1], b2, called)
      return
    elseif n == "lambda" and R.is_cons(form[2]) then
      local b2 = setmetatable({ [form[2][1].name] = true }, { __index = bound })
      walk_calls(form[2][2][1], b2, called)
      return
    elseif n == "let" and R.is_cons(form[2]) then
      walk_calls(form[2][2][1], bound, called)            -- value: outer scope
      local b2 = setmetatable({ [form[2][1].name] = true }, { __index = bound })
      walk_calls(form[2][2][2][1], b2, called)
      return
    elseif not SPECIAL[n] and not bound[n] then
      called[n] = true
    end
  end
  local cur = R.is_symbol(h) and form[2] or form
  while R.is_cons(cur) do walk_calls(cur[1], bound, called); cur = cur[2] end
end

-- name -> defun form, from the certified kernel vendored in this checkout
local certified = {}
do
  local p = io.popen("ls '" .. root .. "/klambda'")
  if p then
    for line in p:lines() do
      local nm = line:match("^(.+)%.kl$")
      if nm then
        for _, f in ipairs(R.read_all(read_file(root .. "/klambda/" .. nm .. ".kl"))) do
          if R.is_cons(f) and R.is_symbol(f[1]) and f[1].name == "defun" then
            certified[f[2][1].name] = f
          end
        end
      end
    end
    p:close()
  end
end

local defined = {}   -- defuns present in the shaken output (kernel + user)
local function note_defined(forms)
  for _, f in ipairs(forms) do
    if R.is_cons(f) and R.is_symbol(f[1]) and f[1].name == "defun" then
      defined[f[2][1].name] = true
    end
  end
end
note_defined(kernel_forms)
for _, uf in ipairs(user_files) do note_defined(uf.forms) end

do
  local called = {}
  for _, f in ipairs(kernel_forms) do walk_calls(f, {}, called) end
  for _, uf in ipairs(user_files) do
    for _, f in ipairs(uf.forms) do walk_calls(f, {}, called) end
  end
  local queue = {}
  for n in pairs(called) do queue[#queue+1] = n end
  table.sort(queue)            -- deterministic output/warnings
  local unresolved = {}
  local i = 1
  while i <= #queue do
    local n = queue[i]; i = i + 1
    if not (defined[n] or P.F[n] or SPECIAL[n]) then
      local form = certified[n]
      if form then
        io.stderr:write("[yggdrasil] STAGE-1 UNDER-SHAKE: " .. n
          .. " is called but missing from " .. man.kernel
          .. "; backfilling from certified kernel\n")
        kernel_forms[#kernel_forms+1] = form
        defined[n] = true
        local more = {}
        walk_calls(form, {}, more)
        local names = {}
        for m in pairs(more) do names[#names+1] = m end
        table.sort(names)
        for _, m in ipairs(names) do
          if not called[m] then called[m] = true; queue[#queue+1] = m end
        end
      else
        unresolved[#unresolved+1] = n
      end
    end
  end
  for _, n in ipairs(unresolved) do
    io.stderr:write("yggdrasil-build: warning: " .. n
      .. " is referenced but provided nowhere (may be guarded-dead)\n")
  end
end

C.prescan(kernel_forms)
for _, uf in ipairs(user_files) do C.prescan(uf.forms) end

-- Defun arities (kernel + user) for the generated program's C.ARITY restore.
local defun_arity = {}
local function harvest_arity(forms)
  for _, f in ipairs(forms) do
    if R.is_cons(f) and R.is_symbol(f[1]) and f[1].name == "defun" then
      defun_arity[f[2][1].name] = C.ARITY[f[2][1].name]
    end
  end
end
harvest_arity(kernel_forms)
for _, uf in ipairs(user_files) do harvest_arity(uf.forms) end

-- Compile a form list into chunks of at most BATCH top-level statements
-- (each form compiles to one self-contained statement; batching keeps any
-- single Lua prototype comfortably below the parser/bytecode limits while
-- avoiding per-form chunk overhead). Each chunk is load-verified here at
-- build time and dumped to bytecode.
local BATCH = 150
local function compile_chunks(forms, label)
  local chunks = {}
  local parts, n = {}, 0
  local function flush()
    if n == 0 then return end
    local src = table.concat(parts, "\n")
    local name = ("yg:%s[%d]"):format(label, #chunks + 1)
    local fn = P.load_chunk(src, name)            -- build-time verify (load only)
    chunks[#chunks+1] = { name = name, src = src, dump = string.dump(fn, true) }
    parts, n = {}, 0
  end
  for _, f in ipairs(forms) do
    n = n + 1
    parts[n] = C.compile_top(f)
    if n >= BATCH then flush() end
  end
  flush()
  return chunks
end

io.stderr:write(("[yggdrasil] compiling %s: %d kernel forms\n"):format(man.kernel, #kernel_forms))
local kernel_chunks = compile_chunks(kernel_forms, man.kernel)
local user_chunks = {}
for _, uf in ipairs(user_files) do
  io.stderr:write(("[yggdrasil] compiling %s: %d user forms\n"):format(uf.name, #uf.forms))
  for _, ch in ipairs(compile_chunks(uf.forms, uf.name)) do
    user_chunks[#user_chunks+1] = ch
  end
end
assert(#C.KDATA == 0, "internal error: KDATA populated despite NO_KDATA")

-- ---- 4. emit ---------------------------------------------------------------
-- String quoting lifted from build/make-bundle.lua: escape NUL/controls/
-- backslash/quote with 3-digit decimal escapes; bytes >= 128 stay raw.
local function quote(s)
  return '"' .. s:gsub('[%z\1-\31\\"\127]', function(c)
    return string.format("\\%03d", string.byte(c))
  end) .. '"'
end

local out = {}
local function emit(s) out[#out+1] = s end

local jitv = rawget(_G, "jit")
emit(("-- %s : shaken Shen program (generated by bin/yggdrasil-build.lua)\n"):format(
  outpath:match("[^/\\]+$") or outpath))
emit(("-- source: %s (kernel-version=%s, %d kernel defuns/forms, user: %s)\n"):format(
  shaken_dir, tostring(man["kernel-version"]), #kernel_forms, table.concat(man.user, ", ")))
emit(("-- generated %s with %s; kernel chunks ship as precompiled bytecode for\n")
  :format(os.date("!%Y-%m-%dT%H:%M:%SZ"), jitv and jitv.version or _VERSION))
emit("-- that LuaJIT flavour, with embedded Lua source as the fallback.\n")
emit("--   luajit " .. (outpath:match("[^/\\]+$") or outpath) .. "\n\n")

if linked then
  emit(("package.path = %q .. package.path\n\n"):format(root .. "/?.lua;"))
else
  emit("local sources = {}\n")
  for _, m in ipairs({ "runtime", "compiler", "prims" }) do
    emit(("sources[%q] = %s\n"):format(m, quote(read_file(root .. "/" .. m .. ".lua"))))
  end
  emit([[
local loadstr = loadstring or load
for name, src in pairs(sources) do
  if package.loaded[name] == nil then
    package.preload[name] = function(...)
      return assert(loadstr(src, "@yggdrasil/" .. name .. ".lua"))(...)
    end
  end
end

]])
end

emit([[
local R = require("runtime")
local C = require("compiler")
local P = require("prims")

-- mcode-area tuning (see boot.lua): perf only, SHEN_JIT_OPT=off restores host defaults
do
  local jit_ok, jit = pcall(require, "jit")
  if jit_ok and jit and jit.opt and os.getenv("SHEN_JIT_OPT") ~= "off" then
    pcall(jit.opt.start,
      "sizemcode=2048", "maxmcode=131072", "maxtrace=8000", "maxside=400")
  end
end

-- minimal lib boot (derived from boot.lua): streams + globals the kernel reads
local G = P.GLOBALS
G["*stoutput*"] = P.mk_out_stream(function(s) io.stdout:write(s) end,
                                  function() io.stdout:flush() end, "stdout")
G["*sterror*"]  = P.mk_out_stream(function(s) io.stderr:write(s) end,
                                  function() io.stderr:flush() end, "stderr")
G["*stinput*"]  = P.mk_in_stream(function() local c = io.stdin:read(1); return c and string.byte(c) or nil end,
                                 function() end, "stdin")
G["*home-directory*"] = ""
G["*language*"]       = "Lua"
G["*implementation*"] = rawget(_G, "jit") and "LuaJIT" or _VERSION
G["*port*"]           = "shen-lua"
G["*porters*"]        = "shen-lua contributors"
G["*os*"]             = (package.config and package.config:sub(1,1) == "\\") and "Windows" or "Unix"
G["*release*"]        = "0.1"

]])

emit("-- defun arities captured at build time, restored for runtime eval-kl codegen\nlocal ARITY = {\n")
do
  local names = {}
  for name in pairs(defun_arity) do names[#names+1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    emit(("  [%q] = %d,\n"):format(name, defun_arity[name]))
  end
end
emit("}\nfor name, ar in pairs(ARITY) do C.ARITY[name] = ar end\n\n")

local function emit_chunks(var, chunks)
  emit("local " .. var .. " = {\n")
  for _, ch in ipairs(chunks) do
    emit(("  { name = %q, dump = %s,\n    src = %s },\n"):format(ch.name, quote(ch.dump), quote(ch.src)))
  end
  emit("}\n")
end
emit_chunks("KERNEL_CHUNKS", kernel_chunks)
emit_chunks("USER_CHUNKS", user_chunks)

emit(([[

-- Load every chunk before running any (a foreign-LuaJIT bytecode mismatch
-- falls back to the embedded source without partial side effects), then run
-- in order: kernel, native overrides, init, user.
local function load_all(chunks)
  local fns = {}
  for i, ch in ipairs(chunks) do
    local ok, fn = pcall(P.load_chunk, ch.dump, ch.name)
    if not ok then fn = P.load_chunk(ch.src, ch.name) end
    fns[i] = fn
  end
  return fns
end
local kfns, ufns = load_all(KERNEL_CHUNKS), load_all(USER_CHUNKS)

for i, fn in ipairs(kfns) do
  local ok, err = pcall(fn)
  if not ok then error("load error in " .. KERNEL_CHUNKS[i].name .. ": " .. tostring(err)) end
end

-- Native overrides REPLACE kernel KL functions: install AFTER the kernel
-- chunks, mirroring boot.lua's install_native_overrides order. The soa32
-- prolog_engine is intentionally not installed (expansion-time hook; the
-- shaken program runs the certified pure-KL CPS prolog).
P.install_native_prolog()
P.install_native_stdlib()

local init = P.F[%q]
if not init then error(%q .. " not defined after kernel load") end
init()

for i, fn in ipairs(ufns) do
  local ok, err = pcall(fn)
  if not ok then error("error in " .. USER_CHUNKS[i].name .. ": " .. tostring(err)) end
end
io.stdout:flush()
]]):format(man.init, man.init))

local fh = assert(io.open(outpath, "wb"))
local blob = table.concat(out)
fh:write(blob)
fh:close()
io.stderr:write(("[yggdrasil] wrote %s (%d bytes, %d kernel + %d user chunks%s)\n")
  :format(outpath, #blob, #kernel_chunks, #user_chunks, linked and ", linked" or ", self-contained"))
