-- boot.lua : load the full Shen KLambda kernel into the Lua runtime and
-- run (shen.initialise).  Returns the prims module P with everything live.
local R = require("runtime")
local C = require("compiler")
local P = require("prims")

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
    "../cl-source/ShenOSKernel-41.1/klambda",
    "../ShenOSKernel-41.1/klambda",
    -- legacy shen-c (22.4) clone for comparison / older certification
    "../shen-c/shen/src/kl",
    "../shen-c/klambda",
  }
  for _,c in ipairs(candidates) do
    local f = io.open(c .. "/toplevel.kl", "r")
    if f then f:close(); return c end
  end

  -- Last resort: assume the vendored location (will produce a clear error)
  return "klambda"
end
local KLDIR = find_kldir() .. "/"
local FILES = {
  "toplevel","core","sys","dict","sequent","yacc","reader","prolog",
  "track","load","writer","macros","declarations","types","t-star","init",
  "extension-features","extension-expand-dynamic","extension-launcher",
  "compiler","stlib"
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

-- ---- platform metadata (required by 41.1+ kernel) -------------------------
P.GLOBALS["*language*"]       = "Lua"
P.GLOBALS["*implementation*"] = "LuaJIT"
P.GLOBALS["*port*"]           = "shen-lua"
P.GLOBALS["*porters*"]        = "shen-lua contributors"
P.GLOBALS["*os*"]             = (package.config and package.config:sub(1,1) == "\\") and "Windows" or "Unix"
P.GLOBALS["*release*"]        = "0.1"  -- port release; kernel *version* comes from init.kl ("41.1")

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
local bit = require("bit")

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

local function read_cache(path, key)
  local data = read_file(path)
  if not data then return nil end
  local pos = 1
  local function line()
    local e = data:find("\n", pos, true)
    if not e then return nil end
    local s = data:sub(pos, e - 1); pos = e + 1
    return s
  end
  if line() ~= CACHE_FORMAT or line() ~= key then return nil end
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

-- ---- load the kernel -----------------------------------------------------
-- Loads the 21 .kl files that make up Shen 41.1 (core + stlib + extensions).
-- The 41.1 KLambda sources are vendored under `klambda/` so the repository
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

local function load_kernel(verbose)
  local path = cache_path()
  local key, sources
  if path then
    key, sources = cache_key()
    local cached = read_cache(path, key)
    if cached then
      -- Load (don't run) every dump first, so a corrupt cache falls back to
      -- the full compile before any chunk has executed.
      local fns = {}
      local ok = true
      for i, ch in ipairs(cached.chunks) do
        local lok, fn = pcall(P.load_chunk, ch.dump, ch.name)
        if not lok then ok = false; break end
        fns[i] = fn
      end
      if ok then
        -- Rebuild the compile-time literal pool FIRST: the cached bytecode
        -- reads KDATA[i]. Mutate C.KDATA in place — ENV.KDATA aliases it.
        for i, v in ipairs(cached.kdata) do C.KDATA[i] = v end
        for i, fn in ipairs(fns) do
          local rok, err = pcall(fn)
          if not rok then
            error("load error in "..cached.chunks[i].name.." (cached): "..tostring(err))
          end
          if verbose then io.stderr:write("  loaded "..cached.chunks[i].name.." (cached)\n") end
        end
        -- Restore defun arities harvested at compile time (prescan + cdefun);
        -- runtime compilation of user code needs them for direct-call codegen.
        for name, ar in pairs(cached.arity) do C.ARITY[name] = ar end
        install_native_overrides()
        return
      end
      os.remove(path)  -- corrupt/stale dump: recompile below and rewrite
    end
  end

  local all = {}
  for _,nm in ipairs(FILES) do
    local s = (sources and sources[nm]) or assert(read_file(KLDIR..nm..".kl"), "cannot open "..nm)
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
  install_native_overrides()
end

-- ---- initialise ----------------------------------------------------------
local function initialise()
  -- (shen.initialise) sets up the environment, lambda-form tables, etc.
  local sym = R.intern("shen.initialise")
  local fn = P.F["shen.initialise"]
  if not fn then error("shen.initialise not defined after kernel load") end
  return fn()
end

P.load_kernel = load_kernel
P.initialise = initialise

-- run a KL toplevel string (one or more forms) through eval
function P.run_kl_string(src)
  local forms = R.read_all(src)
  local last
  for _,f in ipairs(forms) do last = P.eval(f) end
  return last
end

return P
