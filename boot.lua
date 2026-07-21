-- boot.lua : load the full Shen KLambda kernel into the Lua runtime and
-- initialise it. Returns the prims module P with everything live. (On the
-- S41.2 2026-07-11 kernel the kernel self-initialises at load time; see FILES
-- and initialise() below.)
local R = require("runtime")
local C = require("compiler")
local P = require("prims")

-- LuaJIT's default mcode area (512KB, 1000 traces) is far too small for the
-- compiled kernel: on macOS arm64 the suite triggers dozens of full
-- trace-cache flushes per run ("failed to allocate mcode memory"), costing
-- ~10-16% of total wall time re-JITting the same code. Raise the limits once
-- at boot. SHEN_JIT_OPT=off restores the host's defaults (embedders that
-- manage jit.opt themselves should set it).
do
  local jit_ok, jit = pcall(require, "jit")
  if jit_ok and jit and jit.opt and os.getenv("SHEN_JIT_OPT") ~= "off" then
    pcall(jit.opt.start,
      "sizemcode=2048", "maxmcode=131072", "maxtrace=8000", "maxside=400")
  end
end

local function find_kldir()
  local env = os.getenv("SHEN_KL_DIR")
  if env and env ~= "" then return env end

  -- 1. Vendored kernel inside this repo (preferred, makes the clone self-contained)
  if io.open("klambda/toplevel.kl", "r") then
    return "klambda"
  end

  -- 2. Common external locations (useful when developing against a full
  --    ShenOSKernel checkout or the legacy shen-c reference implementation)
  local candidates = {
    "../cl-source/ShenOSKernel-41.2/klambda",
    "../ShenOSKernel-41.2/klambda",
    -- legacy shen-c (22.4) clone for comparison / older certification
    "../shen-c/shen/src/kl",
    "../shen-c/klambda",
  }
  -- 3. Relative to this module's own location, so requiring shen-lua from
  --    another directory (LUA_PATH into a checkout, or a luarocks install)
  --    works without chdir. For a luarocks install boot.lua lives at
  --    <tree>/share/lua/5.1/boot.lua and copy_directories puts klambda at
  --    <tree>/lib/luarocks/rocks-5.1/shen/<version>/klambda.
  local src = debug.getinfo(1, "S").source
  local here = src:match("^@(.*)[/\\][^/\\]*$")
  if here then
    candidates[#candidates+1] = here .. "/klambda"
    local tree = here:match("^(.*)/share/lua/[%d.]+$")
    if tree then
      -- any installed version of the rock (scm-1, 0.9.0-1, ...): glob the
      -- rock directory rather than hardcoding a version string.
      local rocksdir = tree .. "/lib/luarocks/rocks-5.1/shen"
      local ls = io.popen('ls -1 "' .. rocksdir .. '" 2>/dev/null')
      if ls then
        for ver in ls:lines() do
          candidates[#candidates+1] = rocksdir .. "/" .. ver .. "/klambda"
        end
        ls:close()
      end
    end
  end
  for _,c in ipairs(candidates) do
    local f = io.open(c .. "/toplevel.kl", "r")
    if f then f:close(); return c end
  end

  -- Last resort: assume the vendored location (will produce a clear error)
  return "klambda"
end
local KLDIR = find_kldir() .. "/"
P.KLDIR = KLDIR   -- resolved .kl directory (trailing /), for typecheck_native
-- Boot order for the S41.2 (2026-07-11 refresh) kernel. The first 15 entries
-- are the refreshed KLambda modules. The refreshed kernel initialises itself
-- at LOAD time: declarations.kl runs top-level forms — (set *property-vector*
-- (vector 20000)), the environment `set`s, (shen.initialise-arity-table ...),
-- (put shen shen.external-symbols ...) and (shen.build-lambda-table ...) — that
-- the removed init.kl used to run from shen.initialise (see initialise()).
--
-- Order is NOT upstream Sources/make.shen order. make.shen relies on the
-- factorise pass + a macros bootstrap that runs last; shen-lua compiles KL
-- directly, so what matters is that a module's LOAD-TIME side effects see
-- their dependencies already defined:
--   * declarations' top-level init calls put/vector/hash/shen.lambda-entry
--     (sys), so sys precedes declarations;
--   * types.kl's 161 top-level (declare ...) forms actually RUN the type
--     checker at load (each declare infers the signature's variance), so every
--     function `declare` reaches transitively must already be defined:
--     shen.prolog-vector (macros.kl), shen.*sigf* + the arity table
--     (declarations.kl), and — new in the refresh — shen.rectify-type and the
--     rest of the inference machinery (t-star.kl). Pre-refresh t-star trailed
--     types; the refresh moved shen.rectify-type into t-star, so t-star must
--     now precede types. Hence the tail: macros declarations t-star types.
--
-- The trailing three are the community ShenOSKernel extensions, which Tarver's
-- refresh no longer ships as KLambda. shen-lua keeps vendoring them on top so
-- the CLI launcher etc. stay available; they are pure defuns/defmacros
-- referencing only public kernel functions, so they load unchanged.
--
-- NOTE: stlib is NOT here. The standard library is no longer a precompiled
-- klambda/stlib.kl; it is loaded from the S-lineage Shen sources under
-- lib/StLib/ by load_stdlib() (below), which the refresh's own install.shen
-- drives. See lib/StLib/PROVENANCE.md and klambda/PROVENANCE.md.
local FILES = {
  "yacc","core","load","prolog","reader","sequent","sys","toplevel",
  "track","writer","backend","macros","declarations","t-star","types",
  "extension-features","extension-expand-dynamic","extension-launcher"
}

-- ---- standard streams ----------------------------------------------------
-- *stoutput*/*sterror* write to stdout/stderr; *stinput* reads stdin bytes.
local out_stream = P.mk_out_stream(function(s) io.stdout:write(s) end, function() io.stdout:flush() end, "stdout")
local err_stream = P.mk_out_stream(function(s) io.stderr:write(s) end, function() io.stderr:flush() end, "stderr")
local in_stream  = P.mk_in_stream(function() local c = io.stdin:read(1); return c and string.byte(c) or nil end,
                                  function() end, "stdin")
P.GLOBALS["*stoutput*"] = out_stream
P.GLOBALS["*sterror*"]  = err_stream
P.GLOBALS["*stinput*"]  = in_stream
P.GLOBALS["*home-directory*"] = ""

-- ---- platform metadata (required by 41.2+ kernel) -------------------------
P.GLOBALS["*language*"]       = "Lua"
P.GLOBALS["*implementation*"] = rawget(_G, "jit") and "LuaJIT" or _VERSION
P.GLOBALS["*port*"]           = "shen-lua"
P.GLOBALS["*porters*"]        = "shen-lua contributors"
P.GLOBALS["*os*"]             = (package.config and package.config:sub(1,1) == "\\") and "Windows" or "Unix"
P.GLOBALS["*release*"]        = "0.1"  -- port release; kernel *version* comes from declarations.kl ("41.2")

-- ---- kernel bytecode cache -------------------------------------------------
-- Loading the kernel from .kl sources costs ~0.8s (read + parse + KL->Lua
-- compile + Lua parse). The generated chunks are deterministic, so we cache
-- string.dump'd bytecode of one concatenated chunk per kernel file, keyed on
-- an FNV-1a hash of everything that determines codegen: the .kl sources, the
-- compiler/reader/prims sources (prims registers primitive arities, which
-- select direct-call vs APP codegen), the file list, and the LuaJIT version/
-- arch (bytecode is not portable across either). SHEN_KERNEL_CACHE=off
-- disables; any other value overrides the cache path.
local CACHE_FORMAT = "SHENKC2"
-- LuaJIT's `bit` library drives the FNV-1a hashing behind both the kernel
-- bytecode cache and the user fasl cache. PUC Lua has no `bit` (5.3+ has
-- native bitwise operators, but this file must stay parseable by 5.1/LuaJIT),
-- so when it is absent both caches self-disable: cache_path()/fasl_dir()
-- return nil, which makes every hashing path (fnv1a/cache_key/fasl_key)
-- unreachable. Pure perf features — correctness is unaffected.
local has_bit, bit = pcall(require, "bit")
if not has_bit then bit = nil end

local function fnv1a(s, h)
  h = h or 2166136261
  local bxor, lshift, tobit, byte = bit.bxor, bit.lshift, bit.tobit, string.byte
  for i = 1, #s do
    h = bxor(h, byte(s, i))
    -- h = h * 16777619 in 32-bit (2^24 + 2^8 + 2^7 + 2^4 + 2^1 + 1):
    -- a direct multiply overflows the double-exact range under bit.band.
    h = tobit(h + lshift(h, 1) + lshift(h, 4) + lshift(h, 7) + lshift(h, 8) + lshift(h, 24))
  end
  return h
end

local function cache_path()
  if not bit then return nil end   -- PUC Lua: no `bit` -> no cache keys
  local p = os.getenv("SHEN_KERNEL_CACHE")
  if p == "off" or p == "0" then return nil end
  if p and p ~= "" then return p end
  return ".shen-kernel-cache.bin"
end

local function read_file(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local s = fh:read("*a"); fh:close()
  return s
end

local function module_source(name)
  local path = package.searchpath and package.searchpath(name, package.path)
  return read_file(path or (name .. ".lua")) or ""
end

-- key over kl sources + codegen-relevant module sources; returns hex string,
-- plus the kl sources themselves (the compile path needs them anyway).
local function cache_key()
  local h = fnv1a(jit and (jit.version .. jit.arch) or _VERSION)
  h = fnv1a(CACHE_FORMAT .. table.concat(FILES, ","), h)
  for _, m in ipairs({ "compiler", "runtime", "prims" }) do
    h = fnv1a(module_source(m), h)
  end
  local sources = {}
  for _, nm in ipairs(FILES) do
    local s = assert(read_file(KLDIR..nm..".kl"), "cannot open "..nm)
    sources[nm] = s
    h = fnv1a(s, h)
  end
  return bit.tohex(h), sources
end

-- The compiler hoists big literal (cons ...) trees into the C.KDATA side
-- table at COMPILE time; the emitted bytecode only carries KDATA[i] reads
-- (compiler.lua try_const/try_lit_const). Cached chunks therefore need KDATA
-- rebuilt before they run. Entries are pure literal data — numbers, strings,
-- booleans, interned symbols, NIL, cons cells — so they serialize exactly.
-- Tags: N<num>\n S<len>\n<bytes> Y<len>\n<name> B1\n/B0\n L\n(=NIL) C\n<car><cdr>
local function kdata_ser(v, out)
  while R.is_cons(v) do          -- cdr spine iteratively: it's the long axis
    out[#out+1] = "C\n"
    kdata_ser(v[1], out)
    v = v[2]
  end
  local t = type(v)
  if v == R.NIL then out[#out+1] = "L\n"
  elseif t == "number" then out[#out+1] = "N" .. string.format("%.17g", v) .. "\n"
  elseif t == "string" then out[#out+1] = "S" .. #v .. "\n" .. v
  elseif t == "boolean" then out[#out+1] = v and "B1\n" or "B0\n"
  elseif R.is_symbol(v) then out[#out+1] = "Y" .. #v.name .. "\n" .. v.name
  else error("unserializable KDATA value: " .. t) end
end

local function kdata_de(data, pos)
  local tag = data:sub(pos, pos)
  local e = data:find("\n", pos, true)
  if not e then error("truncated KDATA") end
  local arg = data:sub(pos + 1, e - 1)
  pos = e + 1
  if tag == "C" then
    local hd, tl
    hd, pos = kdata_de(data, pos)
    tl, pos = kdata_de(data, pos)
    return R.cons(hd, tl), pos
  elseif tag == "L" then return R.NIL, pos
  elseif tag == "N" then return tonumber(arg), pos
  elseif tag == "B" then return arg == "1", pos
  elseif tag == "S" or tag == "Y" then
    local len = tonumber(arg)
    local s = data:sub(pos, pos + len - 1)
    pos = pos + len
    if tag == "S" then return s, pos end
    return R.intern(s), pos
  end
  error("bad KDATA tag: " .. tostring(tag))
end

-- format: CACHE_FORMAT\n key\n nchunks\n { name\n #dump\n dump }*
--         narities\n { arity SP fname\n }*  nkdata\n { entry }*
local function write_cache(path, key, chunks, arity)
  local parts = { CACHE_FORMAT, "\n", key, "\n", tostring(#chunks), "\n" }
  for _, ch in ipairs(chunks) do
    parts[#parts+1] = ch.name .. "\n" .. #ch.dump .. "\n" .. ch.dump
  end
  local an = 0
  for _ in pairs(arity) do an = an + 1 end
  parts[#parts+1] = an .. "\n"
  for name, ar in pairs(arity) do
    parts[#parts+1] = ar .. " " .. name .. "\n"
  end
  parts[#parts+1] = #C.KDATA .. "\n"
  for i = 1, #C.KDATA do
    kdata_ser(C.KDATA[i], parts)
  end
  local tmp = path .. ".tmp"
  local fh = io.open(tmp, "wb")
  if not fh then return end  -- read-only dir: silently skip caching
  fh:write(table.concat(parts)); fh:close()
  os.remove(path)
  os.rename(tmp, path)
end

-- Parse a write_cache blob. key == nil skips the key check (used for the
-- embedded-kernel payload baked into a single-file bundle, where the build
-- pins the blob and per-chunk load failures fall back to a full compile).
local function parse_cache(data, key)
  local pos = 1
  local function line()
    local e = data:find("\n", pos, true)
    if not e then return nil end
    local s = data:sub(pos, e - 1); pos = e + 1
    return s
  end
  if line() ~= CACHE_FORMAT then return nil end
  local k = line()
  if key ~= nil and k ~= key then return nil end
  local n = tonumber(line() or ""); if not n then return nil end
  local chunks = {}
  for i = 1, n do
    local nm = line()
    local len = tonumber(line() or "")
    if not nm or not len or pos + len - 1 > #data then return nil end
    chunks[i] = { name = nm, dump = data:sub(pos, pos + len - 1) }
    pos = pos + len
  end
  local na = tonumber(line() or ""); if not na then return nil end
  local arity = {}
  for i = 1, na do
    local ln = line(); if not ln then return nil end
    local ar, name = ln:match("^(%-?%d+) (.*)$")
    if not ar then return nil end
    arity[name] = tonumber(ar)
  end
  local nk = tonumber(line() or ""); if not nk then return nil end
  local kdata = {}
  local kok, kerr = pcall(function()
    for i = 1, nk do
      kdata[i], pos = kdata_de(data, pos)
    end
  end)
  if not kok then return nil end
  return { chunks = chunks, arity = arity, kdata = kdata }
end

local function read_cache(path, key)
  local data = read_file(path)
  if not data then return nil end
  return parse_cache(data, key)
end

-- ---- load the kernel -----------------------------------------------------
-- Loads the 19 .kl modules in FILES (see above): the 15 refreshed S41.2
-- (2026-07-11) KLambda modules plus the vendored community stlib + 3 booted
-- extensions. The opt-in extension-programmable-pattern-matching.kl is
-- vendored but not booted.
-- The KLambda sources are vendored under `klambda/` so the repository
-- is self-contained. You can still override with SHEN_KL_DIR (e.g. to point
-- at a full ShenOSKernel checkout during development).

-- Native overrides, installed after the compiled KL defuns are all in F.
local function install_native_overrides()
  -- Hottest Prolog deref primitives (see prims.install_native_prolog).
  P.install_native_prolog()
  -- Hottest general-purpose kernel functions with native Lua
  -- (element?, assoc, map, reverse, fail, ...; see prims.install_native_stdlib).
  P.install_native_stdlib()
  -- Native soa32 Prolog/typecheck engine (prolog_engine.lua). Default on once
  -- the module ships; SHEN_PROLOG_ENGINE=legacy falls back to the compiled-KL
  -- CPS engine. Module absence is tolerated (pre-engine checkouts); any other
  -- load error is real and must propagate.
  if os.getenv("SHEN_PROLOG_ENGINE") ~= "legacy" then
    local ok, eng = pcall(require, "prolog_engine")
    if ok then
      eng.install(P)
    elseif not tostring(eng):find("module 'prolog_engine' not found", 1, true) then
      error(eng)
    end
  end
end

-- memoized: the fasl layer reuses the codegen key even when the kernel
-- cache is disabled (first call reads ~850KB and hashes it, ~ms).
local KERNEL_KEY
local function kernel_key()
  local k, sources = KERNEL_KEY, nil
  if not k then
    if P.KERNEL_CACHE_DATA then
      -- single-file bundle: no .kl files on disk; the embedded blob captures
      -- everything that determines codegen, so its hash is the kernel key.
      k = bit.tohex(fnv1a(P.KERNEL_CACHE_DATA))
    else
      k, sources = cache_key()
    end
    KERNEL_KEY = k
  end
  return k, sources
end

-- Load (don't run) every cached dump first, so a corrupt/foreign-arch cache
-- falls back to the full compile before any chunk has executed. Returns true
-- on success, false if any dump refused to load.
local function load_cached(cached, verbose, tag)
  local fns = {}
  for i, ch in ipairs(cached.chunks) do
    local lok, fn = pcall(P.load_chunk, ch.dump, ch.name)
    if not lok then return false end
    fns[i] = fn
  end
  -- Rebuild the compile-time literal pool FIRST: the cached bytecode
  -- reads KDATA[i]. Mutate C.KDATA in place — ENV.KDATA aliases it.
  for i, v in ipairs(cached.kdata) do C.KDATA[i] = v end
  for i, fn in ipairs(fns) do
    local rok, err = pcall(fn)
    if not rok then
      error("load error in "..cached.chunks[i].name..tag..": "..tostring(err))
    end
    if verbose then io.stderr:write("  loaded "..cached.chunks[i].name..tag.."\n") end
  end
  -- Restore defun arities harvested at compile time (prescan + cdefun);
  -- runtime compilation of user code needs them for direct-call codegen.
  for name, ar in pairs(cached.arity) do C.ARITY[name] = ar end
  return true
end

-- Full compile from .kl sources. extsources (name -> source string), when
-- given, overrides the on-disk KLDIR files (the single-file bundle embeds
-- them as P.KL_SOURCES). path/key, when given, write the bytecode cache.
local function compile_kernel(extsources, path, key, verbose)
  local all = {}
  for _,nm in ipairs(FILES) do
    local s = (extsources and extsources[nm]) or assert(read_file(KLDIR..nm..".kl"), "cannot open "..nm)
    local fs = R.read_all(s)
    all[nm] = fs
    C.prescan(fs)
  end
  local chunks = {}
  for _,nm in ipairs(FILES) do
    -- One concatenated chunk per kernel file: same statements in the same
    -- order as per-form loading (every top-level form compiles to a single
    -- self-contained `do ... end` statement), but loadstring'd once and
    -- dumpable for the bytecode cache.
    local parts = {}
    for i,f in ipairs(all[nm]) do
      parts[i] = C.compile_top(f)
    end
    local src = table.concat(parts, "\n")
    local fn = P.load_chunk(src, nm)
    local ok, err = pcall(fn)
    if not ok then
      error("load error in "..nm..": "..tostring(err))
    end
    chunks[#chunks+1] = { name = nm, dump = string.dump(fn) }
    if verbose then io.stderr:write("  loaded "..nm.."\n") end
  end
  if path then write_cache(path, key, chunks, C.ARITY) end
end

local function load_kernel(verbose)
  -- Embedded kernel (single-file bundle, see build/make-bundle.lua):
  -- P.KERNEL_CACHE_DATA holds a write_cache-format blob baked in at bundle
  -- build time, P.KL_SOURCES the .kl sources as a name -> string table.
  -- The blob is trusted as-is (no key check — the build pins it); if its
  -- bytecode refuses to load (a different LuaJIT version/arch than the
  -- build machine) we fall back to compiling the embedded sources. The
  -- on-disk cache file is bypassed entirely in this mode.
  if P.KERNEL_CACHE_DATA then
    local cached = parse_cache(P.KERNEL_CACHE_DATA, nil)
    if not (cached and load_cached(cached, verbose, " (embedded)")) then
      compile_kernel(assert(P.KL_SOURCES, "embedded kernel bytecode unusable and no embedded .kl sources"),
                     nil, nil, verbose)
    end
    install_native_overrides()
    return
  end

  local path = cache_path()
  local key, sources
  if path then
    key, sources = kernel_key()
    local cached = read_cache(path, key)
    if cached then
      if load_cached(cached, verbose, " (cached)") then
        install_native_overrides()
        return
      end
      os.remove(path)  -- corrupt/stale dump: recompile below and rewrite
    end
  end
  compile_kernel(sources, path, key, verbose)
  install_native_overrides()
end

-- ---- user-program fasl cache ----------------------------------------------
-- (load "x.shen") is dominated by the reader, macroexpansion, and — with tc
-- on — typechecking, all deterministic given the file content and the
-- session's load history. The persistent effects of a load are exactly
-- (load.kl): the top-level eval-kl chunks (eval-and-print / work-through),
-- the (declare Name Type) calls from shen.assumetypes on the tc path, and
-- the compile-time side state those compiles created (C.ARITY, C.KDATA,
-- shen.*gensym*). We record those during a load and replay them on a key
-- hit, skipping reader+macro+typecheck entirely — SBCL fasl semantics: "it
-- typechecked when compiled".
--
-- Key = codegen key + file content + tc flag + a ROLLING hash of all
-- previously loaded files (editing file A invalidates everything loaded
-- after it, make-style) + the names of live datatypes and macros (catches
-- most REPL-defined state). Replay requires #C.KDATA to equal the recorded
-- base (compiled bytecode hard-codes KDATA indices); a mismatch is a miss,
-- never an error.
--
-- A replayed load reproduces the per-form value/type echo: the bytes
-- shen.eval-and-print / shen.work-through write to (stoutput) are captured as
-- "e" records during the miss and re-pr'd (in stream order, after each form's
-- chunk) on replay, so warm-hit stdout matches cold. Still dropped by design:
-- the cosmetic "run time"/"typechecked in N inferences" banners (they are
-- emitted by `load` OUTSIDE shen.load-help and would add per-run timing noise).
-- Known: (destroy ...) at the REPL between loads is not in the key.
-- SHEN_FASL=off disables; SHEN_FASL_DIR overrides ~/.cache/shen-lua-fasl;
-- SHEN_FASL_DEBUG=1 logs hits/misses to stderr.
local FASL_FORMAT = "SHENFASL4"  -- 4: added "e" (per-form value/type echo)
                                 -- records; 3: "pc" (shen.compile-prolog)
local FASL_STACK = {}
local FASL_ROLL = 2166136261
local FASL_DEBUG = os.getenv("SHEN_FASL_DEBUG") == "1"

local function fasl_dir()
  if not bit then return nil end   -- PUC Lua: no `bit` -> no fasl keys
  local p = os.getenv("SHEN_FASL")
  if p == "off" or p == "0" then return nil end
  local d = os.getenv("SHEN_FASL_DIR")
  if d and d ~= "" then return d end
  local home = os.getenv("HOME")
  if not home or home == "" then return nil end
  return home .. "/.cache/shen-lua-fasl"
end

local function fasl_log(msg)
  if FASL_DEBUG then io.stderr:write("[fasl] " .. msg .. "\n") end
end

-- names of a KL list of symbols or (symbol . x) pairs (datatypes, *macros*)
local function kl_names(l)
  local parts = {}
  while R.is_cons(l) do
    local e = l[1]
    if R.is_symbol(e) then parts[#parts+1] = e.name
    elseif R.is_cons(e) and R.is_symbol(e[1]) then parts[#parts+1] = e[1].name
    else parts[#parts+1] = "?" end
    l = l[2]
  end
  return table.concat(parts, ",")
end

local function fasl_key(content)
  local env = (P.GLOBALS["shen.*tc*"] and "tc" or "raw")
    .. "|" .. (os.getenv("SHEN_PROLOG_ENGINE") or "native")
    .. "|" .. bit.tohex(FASL_ROLL)
    .. "|" .. kl_names(P.GLOBALS["shen.*datatypes*"])
    .. "|" .. kl_names(P.GLOBALS["*macros*"])
  return bit.tohex(fnv1a(content, fnv1a(env, fnv1a((kernel_key())))))
end

-- format: SHENFASL1\n nrec\n
--   { C\n name\n #dump\n dump          top-level eval-kl chunk
--   | D\n <ser name><ser type>          (declare ...) from assumetypes
--   | M\n <ser name>                    shen.record-macro (fn rebuilt by name)
--   | P\n <ser x><ser ptr><ser y>       (put ... *property-vector*)
--   | E\n #bytes\n bytes                per-form value/type echo (stoutput)
--   | G\n <ser name><ser val> }*        (set ...) outside any chunk
--   narity\n {ar SP name\n}*  kbase\n nkdata\n entries  gensym\n
local function fasl_write(path, rec, arity0)
  if rec.uncacheable then error(rec.uncacheable) end
  local parts = { FASL_FORMAT, "\n", tostring(rec.n), "\n" }
  for i = 1, rec.n do
    local r = rec[i]
    if r.k == "c" then
      parts[#parts+1] = "C\n" .. r.name .. "\n" .. #r.dump .. "\n" .. r.dump
    elseif r.k == "d" then
      parts[#parts+1] = "D\n"
      kdata_ser(r.name, parts)
      kdata_ser(r.typ, parts)
    elseif r.k == "m" then
      parts[#parts+1] = "M\n"
      kdata_ser(r.name, parts)
    elseif r.k == "lf" then
      parts[#parts+1] = "L\n"
      kdata_ser(r.name, parts)
    elseif r.k == "dt" then
      parts[#parts+1] = "T\n"
      kdata_ser(r.name, parts)
      kdata_ser(r.rules, parts)
    elseif r.k == "pc" then
      parts[#parts+1] = "Q\n"
      kdata_ser(r.name, parts)
      kdata_ser(r.rules, parts)
    elseif r.k == "sy" then
      parts[#parts+1] = "Z\n"
      kdata_ser(r.syns, parts)
    elseif r.k == "p" then
      parts[#parts+1] = "P\n"
      kdata_ser(r.x, parts)
      kdata_ser(r.pointer, parts)
      kdata_ser(r.y, parts)
    elseif r.k == "e" then
      -- raw echo bytes, length-prefixed (may contain newlines / non-ASCII);
      -- mirrors the "C" chunk framing — no trailing separator, the next
      -- record's kind letter starts immediately after the bytes.
      parts[#parts+1] = "E\n" .. #r.bytes .. "\n" .. r.bytes
    else -- "g"
      parts[#parts+1] = "G\n"
      kdata_ser(r.name, parts)
      kdata_ser(r.val, parts)
    end
  end
  local delta = {}
  for name, ar in pairs(C.ARITY) do
    if arity0[name] ~= ar then delta[#delta+1] = ar .. " " .. name end
  end
  parts[#parts+1] = #delta .. "\n"
  for _, d in ipairs(delta) do parts[#parts+1] = d .. "\n" end
  local g = P.GLOBALS["shen.*gensym*"]
  parts[#parts+1] = tostring(type(g) == "number" and g or 0) .. "\n"
  local tmp = path .. ".tmp"
  local fh = io.open(tmp, "wb")
  if not fh then return end
  fh:write(table.concat(parts)); fh:close()
  os.remove(path)
  os.rename(tmp, path)
end

local function fasl_read(path)
  local data = read_file(path)
  if not data then return nil end
  local pos = 1
  local function line()
    local e = data:find("\n", pos, true)
    if not e then return nil end
    local s = data:sub(pos, e - 1); pos = e + 1
    return s
  end
  if line() ~= FASL_FORMAT then return nil end
  local n = tonumber(line() or ""); if not n then return nil end
  local function de_n(count)
    local ok, vals = pcall(function()
      local out = {}
      for j = 1, count do out[j], pos = kdata_de(data, pos) end
      return out
    end)
    if ok then return vals end
    return nil
  end
  local recs = {}
  for i = 1, n do
    local k = line()
    if k == "C" then
      local nm = line()
      local len = tonumber(line() or "")
      if not nm or not len or pos + len - 1 > #data then return nil end
      recs[i] = { k = "c", name = nm, dump = data:sub(pos, pos + len - 1) }
      pos = pos + len
    elseif k == "D" then
      local v = de_n(2); if not v then return nil end
      recs[i] = { k = "d", name = v[1], typ = v[2] }
    elseif k == "M" then
      local v = de_n(1); if not v then return nil end
      recs[i] = { k = "m", name = v[1] }
    elseif k == "L" then
      local v = de_n(1); if not v then return nil end
      recs[i] = { k = "lf", name = v[1] }
    elseif k == "T" then
      local v = de_n(2); if not v then return nil end
      recs[i] = { k = "dt", name = v[1], rules = v[2] }
    elseif k == "Q" then
      local v = de_n(2); if not v then return nil end
      recs[i] = { k = "pc", name = v[1], rules = v[2] }
    elseif k == "Z" then
      local v = de_n(1); if not v then return nil end
      recs[i] = { k = "sy", syns = v[1] }
    elseif k == "P" then
      local v = de_n(3); if not v then return nil end
      recs[i] = { k = "p", x = v[1], pointer = v[2], y = v[3] }
    elseif k == "E" then
      local len = tonumber(line() or "")
      if not len or pos + len - 1 > #data then return nil end
      recs[i] = { k = "e", bytes = data:sub(pos, pos + len - 1) }
      pos = pos + len
    elseif k == "G" then
      local v = de_n(2); if not v then return nil end
      recs[i] = { k = "g", name = v[1], val = v[2] }
    else return nil end
  end
  local na = tonumber(line() or ""); if not na then return nil end
  local arity = {}
  for i = 1, na do
    local ln = line(); if not ln then return nil end
    local ar, name = ln:match("^(%-?%d+) (.*)$")
    if not ar then return nil end
    arity[name] = tonumber(ar)
  end
  local gensym = tonumber(line() or ""); if not gensym then return nil end
  return { recs = recs, arity = arity, gensym = gensym }
end

local function fasl_replay(cached)
  -- Recorded chunks are relocatable (compiled under C.NO_KDATA — literals
  -- ride inside the chunk via MKTREE/MKLIST, never the KDATA side table),
  -- so replay has no positional coupling to this session's compile state.
  for name, ar in pairs(cached.arity) do C.ARITY[name] = ar end
  for _, r in ipairs(cached.recs) do
    if r.k == "c" then
      P.load_chunk(r.dump, r.name)()
    elseif r.k == "d" then
      -- through the live F["declare"] so engine sig-table wrappers see it
      P.F["declare"](r.name, r.typ)
    elseif r.k == "m" then
      -- the macro's defun chunk replayed above; rebuild the (name . fn) pair
      local fn = P.F[r.name.name]
      if not fn then error("fasl: macro function missing: " .. r.name.name) end
      P.F["shen.record-macro"](r.name, fn)
    elseif r.k == "lf" then
      -- shen.lambda-entry returns the complete (name . curried-fn) entry
      -- (or () for arity 0/-1); the recorded put stored its tl. Rebuild and
      -- put the same shape. The arity property it reads was applied by the
      -- preceding "p" record (stream order).
      local entry = P.F["shen.lambda-entry"](r.name)
      local val = R.is_cons(entry) and entry[2] or entry
      P.F["put"](r.name, R.intern("shen.lambda-form"), val,
                 P.GLOBALS["*property-vector*"])
    elseif r.k == "dt" then
      P.F["shen.process-datatype"](r.name, r.rules)
    elseif r.k == "sy" then
      P.F["shen.process-synonyms"](r.syns)
    elseif r.k == "pc" then
      -- prolog?/defprolog expand at macroexpansion time through
      -- shen.compile-prolog, whose native-engine clause registration (the NP
      -- table in prolog_compile.lua) is a Lua-side effect no chunk reproduces;
      -- a replayed (shen.lua-run-queryK "name" ...) form would find its query
      -- gone. Re-execute the call: args are pure reader output, and the query
      -- gensym was baked in at record time so the name re-registers exactly.
      P.F["shen.compile-prolog"](r.name, r.rules)
    elseif r.k == "p" then
      P.F["put"](r.x, r.pointer, r.y, P.GLOBALS["*property-vector*"])
    elseif r.k == "e" then
      -- re-emit the per-form echo through the live `pr` so replay-time *hush*
      -- still gates it (a -q hit stays silent, exactly as a -q cold load).
      P.F["pr"](r.bytes, P.GLOBALS["*stoutput*"])
    else -- "g"
      P.F["set"](r.name, r.val)
    end
  end
  -- Fast-forward the gensym counter past every name the recording consumed,
  -- so post-replay gensyms can't collide with names baked into the chunks.
  local g = P.GLOBALS["shen.*gensym*"]
  if type(g) == "number" and cached.gensym > g then
    P.GLOBALS["shen.*gensym*"] = cached.gensym
  end
end

local function install_fasl()
  local dir = fasl_dir()
  if not dir then return end
  os.execute("mkdir -p '" .. dir .. "'")
  local F = P.F

  -- Persistent load effects that happen OUTSIDE an eval-kl chunk are all
  -- funneled through four kernel entry points; wrap each. The in_chunk dance
  -- (flag set while the original runs) makes the wrappers compose: declare's
  -- internal put, record-macro's internal set, etc. are suppressed because
  -- replaying the outer record reproduces them. Effects made by chunk
  -- EXECUTION are never recorded — replaying the chunk reproduces those.
  --
  --   declare           — shen.assumetypes on the tc load path
  --   shen.record-macro — defmacro processing runs at MACROEXPANSION time
  --                       (macros.kl shen.process-def); the macro fn value
  --                       can't serialize, so record the name and rebuild
  --                       the pair from F[name] on replay
  --   put               — expansion/typecheck-time property-vector writes
  --   set               — expansion-time global writes (process-datatype's
  --                       *datatypes*, process-synonyms' *synonyms*, ...)
  local function wrap_recorded(fname, mk)
    local orig = F[fname]
    F[fname] = function(...)
      local rec = FASL_STACK[#FASL_STACK]
      if rec and not rec.in_chunk then
        local r = mk(rec, ...)
        if r then
          rec.n = rec.n + 1
          rec[rec.n] = r
        end
        rec.in_chunk = true
        local ok, res = pcall(orig, ...)
        rec.in_chunk = false
        if not ok then error(res, 0) end
        return res
      end
      return orig(...)
    end
  end

  wrap_recorded("declare", function(rec, name, typ)
    return { k = "d", name = name, typ = typ }
  end)
  wrap_recorded("shen.record-macro", function(rec, name, fn)
    return { k = "m", name = name }
  end)
  -- (datatype ...) and (synonyms ...) do ALL their work at macroexpansion
  -- time (shen.macros dispatches to these; the expansion result is just the
  -- type name). Their state — *datatypes*/*alldatatypes* assoc entries with
  -- compiled-closure leaves — can't serialize, but their ARGUMENTS are pure
  -- reader output. Record the call; replay re-executes it (recompiling the
  -- datatype is much cheaper than the typechecking the replay skips). The
  -- in_chunk dance suppresses all their internal chunks/sets/puts.
  wrap_recorded("shen.process-datatype", function(rec, name, rules)
    return { k = "dt", name = name, rules = rules }
  end)
  wrap_recorded("shen.process-synonyms", function(rec, syns)
    return { k = "sy", syns = syns }
  end)
  -- shen.compile-prolog: defprolog AND prolog? expansion both funnel through
  -- it at macroexpansion time. Its kernel output (the query/predicate defun)
  -- is captured as an ordinary chunk, but prolog_compile.lua's native-engine
  -- clause registration (NP table) is a Lua-side effect that exists only at
  -- expansion time — without this record a replayed prolog? query dies with
  -- "native prolog query lost". Clause tokens are pure reader output.
  wrap_recorded("shen.compile-prolog", function(rec, name, rules)
    return { k = "pc", name = name, rules = rules }
  end)
  wrap_recorded("put", function(rec, x, pointer, y, vector)
    if vector ~= P.GLOBALS["*property-vector*"] then
      rec.uncacheable = "put to a non-property vector"
      return nil
    end
    if R.is_symbol(pointer) and pointer.name == "shen.lambda-form" then
      -- the value is a freshly eval'd curried lambda (sys.kl
      -- update-lambda-table) — not serializable; regenerated on replay
      -- from the live defun via shen.lambda-entry. The arity put that
      -- update-lambda-table does first is an ordinary "p" record, already
      -- applied by the time this replays (stream order).
      return { k = "lf", name = x }
    end
    return { k = "p", x = x, pointer = pointer, y = y }
  end)
  wrap_recorded("set", function(rec, name, val)
    local nm = R.is_symbol(name) and name.name or tostring(name)
    -- the gensym counter churns on every expansion-time gensym; the replay
    -- fast-forward (max) covers it without hundreds of noise records
    if nm == "shen.*gensym*" then return nil end
    return { k = "g", name = name, val = val }
  end)

  -- Per-form value/type echo (klambda/load.kl: shen.eval-and-print on the raw
  -- path, shen.work-through on the tc path) is a pr to (stoutput) that happens
  -- AFTER the form's eval-kl chunk has run and returned — i.e. with in_chunk
  -- false, unlike the form's own (output ...) side-effects (in_chunk true, and
  -- reproduced by re-running the chunk). Record those echo bytes as "e" records
  -- in stream order so replay re-emits them right after each chunk. We scope
  -- capture to the span of shen.load-help via rec.echoing, which excludes the
  -- "run time"/"typechecked in N inferences" banners that `load` prints outside
  -- load-help (those stay dropped by design). The bytes are captured even under
  -- *hush* (the string is computed regardless; pr just doesn't write it), so a
  -- miss recorded under -q still replays correctly to a non-hushed hit.
  do
    local orig_load_help = F["shen.load-help"]
    F["shen.load-help"] = function(...)
      local rec = P.FASL_REC
      if not rec then return orig_load_help(...) end
      local saved = rec.echoing
      rec.echoing = true
      local ok, res = pcall(orig_load_help, ...)
      rec.echoing = saved
      if not ok then error(res, 0) end
      return res
    end
    local orig_pr = F["pr"]
    F["pr"] = function(s, st)
      local rec = P.FASL_REC
      if rec and rec.echoing and not rec.in_chunk
         and type(s) == "string" and st == P.GLOBALS["*stoutput*"] then
        rec.n = rec.n + 1
        rec[rec.n] = { k = "e", bytes = s }
      end
      return orig_pr(s, st)
    end
  end

  local orig_load = F["load"]
  F["load"] = function(fname)
    if type(fname) ~= "string" then return orig_load(fname) end
    local fh = io.open(fname, "rb")
    if not fh then return orig_load(fname) end   -- let the kernel error
    local content = fh:read("*a"); fh:close()
    local key = fasl_key(content)
    local path = dir .. "/" .. key .. ".fasl"
    local cached = fasl_read(path)
    if cached then
      local ok, err = pcall(fasl_replay, cached)
      if ok then
        fasl_log("hit  " .. fname .. " " .. key)
        FASL_ROLL = fnv1a(content, FASL_ROLL)
        return R.intern("loaded")
      end
      os.remove(path)   -- stale beyond what the key caught: recompile next run
      error(err, 0)
    end
    fasl_log("miss " .. fname .. " " .. key)
    local rec = { n = 0, in_chunk = false }
    local arity0 = {}
    for k, v in pairs(C.ARITY) do arity0[k] = v end
    FASL_STACK[#FASL_STACK + 1] = rec
    P.FASL_REC = rec
    C.NO_KDATA = true   -- recorded chunks must be relocatable
    local ok, res = pcall(orig_load, fname)
    FASL_STACK[#FASL_STACK] = nil
    P.FASL_REC = FASL_STACK[#FASL_STACK]
    C.NO_KDATA = P.FASL_REC ~= nil
    if not ok then error(res, 0) end
    local wok, werr = pcall(fasl_write, path, rec, arity0)
    if not wok then fasl_log("uncacheable " .. fname .. ": " .. tostring(werr)) end
    FASL_ROLL = fnv1a(content, FASL_ROLL)
    return res
  end
end

-- ---- initialise ----------------------------------------------------------
-- ---- standard library (S-lineage lib/StLib sources) ----------------------
-- Tarver's S41.2 refresh ships the standard library as Shen SOURCES under
-- Lib/StLib (loaded into the SBCL image at install time), not as a precompiled
-- stlib.kl. shen-lua vendors those sources under lib/StLib/ and loads them the
-- same way: through the kernel's own (load ...) / define pipeline. Unlike raw
-- stlib.kl defuns (which the pre-refresh port booted as a kernel module), the
-- define path registers each function's arity property + shen.*lambdatable*
-- entry, so `(fn filter)` and a bare top-level `(filter ...)` now resolve
-- instead of raising "fn: filter is undefined".
--
-- We run upstream's own install.shen (its factorise toggles, the package +
-- systemf externals block, everything) with two mechanical rewrites:
--   1. its relative (load "Sub/file.shen") paths are made absolute against the
--      vendored directory, so no process chdir is needed (a chdir would
--      invalidate the KLDIR-relative reads the fasl kernel-key hashing does);
--   2. its (tc +) toggles are neutralised to (tc -), i.e. the stdlib is loaded
--      WITHOUT typechecking. This matches the pre-refresh behaviour (the old
--      precompiled stlib.kl registered no stdlib type signatures either — its
--      stlib.initialise was never called), it is markedly faster, and it keeps
--      the native typecheck drivers deferred at boot (a tc+ load would trigger
--      the typechecker and translate them eagerly). Functions are still fully
--      defined and arity-registered — only their type signatures are skipped.
-- SHEN_NO_STDLIB=1 skips the whole thing (a kernel-only embed); SHEN_STDLIB_DIR
-- overrides the location.
local STDLIB_LOADED = false
local function find_stdlib_dir()
  local env = os.getenv("SHEN_STDLIB_DIR")
  if env and env ~= "" then return env end
  -- module-relative first (chdir-independent: boot.lua sits at the repo root)
  local src = debug.getinfo(1, "S").source
  local here = src:match("^@(.*)[/\\][^/\\]*$")
  local candidates = {}
  if here then candidates[#candidates+1] = here .. "/lib/StLib" end
  candidates[#candidates+1] = "lib/StLib"
  for _, d in ipairs(candidates) do
    local f = io.open(d .. "/install.shen", "r")
    if f then f:close(); return d end
  end
  -- Single-file bundle: no lib/StLib on disk, but make-bundle.lua embedded the
  -- whole tree as P.STDLIB_SOURCES (relpath -> content). Materialise it once to
  -- a temp dir and load from there (reuses the ordinary file-based load path).
  if P.STDLIB_SOURCES then
    local base = os.tmpname(); os.remove(base)
    os.execute("mkdir -p '" .. base .. "'")
    for rel, content in pairs(P.STDLIB_SOURCES) do
      local full = base .. "/" .. rel
      local sub = full:match("^(.*)/[^/]*$")
      if sub then os.execute("mkdir -p '" .. sub .. "'") end
      local fh = io.open(full, "wb")
      if fh then fh:write(content); fh:close() end
    end
    return base
  end
  return nil
end

local function load_stdlib(verbose)
  if STDLIB_LOADED then return end
  if os.getenv("SHEN_NO_STDLIB") == "1" then return end
  local dir = find_stdlib_dir()
  if not dir then
    if verbose then io.stderr:write("  stdlib: lib/StLib not found; skipping (kernel-only)\n") end
    return
  end
  local script = read_file(dir .. "/install.shen")
  if not script then return end
  -- Rewrite the relative (load "X") targets to absolute so no chdir is needed.
  -- All install.shen load paths are relative; the replacement text is escaped
  -- for gsub's % handling.
  local prefix = ("(load \"" .. dir .. "/"):gsub("%%", "%%%%")
  script = script:gsub('%(load "', prefix)
  script = script:gsub("%(tc %+%)", "(tc -)")   -- load without typechecking (see above)
  local hush0 = P.GLOBALS["*hush*"]
  P.GLOBALS["*hush*"] = true       -- suppress the ~20 "loaded" echoes
  local ok, err = pcall(function()
    local forms = P.F["read-from-string"](script)
    while R.is_cons(forms) do
      P.F["eval"](forms[1])
      forms = forms[2]
    end
  end)
  P.GLOBALS["*hush*"] = hush0
  if not ok then
    error("stdlib load failed: " .. tostring(P.F["error-to-string"](err)), 0)
  end
  STDLIB_LOADED = true
  if verbose then io.stderr:write("  loaded stdlib from " .. dir .. "\n") end
end
P.load_stdlib = load_stdlib

local function initialise()
  -- Kernel environment setup (env globals, *property-vector*, arity table).
  --
  -- On the S41.2 (2026-07-11 refresh) kernel this all happens at LOAD time via
  -- top-level forms in declarations.kl — there is no `shen.initialise` function
  -- to call, so load_kernel() has already done it by the time we get here.
  --
  -- Older kernels (pre-refresh community ShenOSKernel, reachable via
  -- SHEN_KL_DIR) instead define `shen.initialise` and expect it to be called
  -- once, post-load. Preserve that path when the function is present.
  local r
  local fn = P.F["shen.initialise"]
  if fn then r = fn() end
  -- Register the lua.* interop entries in Shen's own arity/lambda-form
  -- tables (needs the *property-vector* the kernel just created).
  require("lua_interop").post_initialise()
  -- Load the standard library from its S-lineage Shen sources (lib/StLib).
  -- Done here, at the single post-kernel-init chokepoint every boot path runs
  -- (shen.boot, run-kernel-tests, the port specs), so the stdlib is present
  -- for all of them. SHEN_NO_STDLIB=1 opts out.
  load_stdlib()
  return r
end

P.load_kernel = function(verbose)
  load_kernel(verbose)
  install_fasl()   -- after native overrides so the declare wrapper composes
  -- Lua<->Shen interop surface (lua_interop.lua). Installed LAST so the
  -- typed bridge (lua.function) sees the fully composed F["declare"]
  -- (native-engine signature recording + fasl recording).
  require("lua_interop").install(P)
end
P.initialise = initialise

-- run a KL toplevel string (one or more forms) through eval
function P.run_kl_string(src)
  local forms = R.read_all(src)
  local last
  for _,f in ipairs(forms) do last = P.eval(f) end
  return last
end

return P
