-- boot.lua : load the full Shen KLambda kernel into the Lua runtime and
-- run (shen.initialise).  Returns the prims module P with everything live.
local R = require("runtime")
local C = require("compiler")
local P = require("prims")

local KLDIR = (os.getenv("SHEN_KL_DIR") or "/home/claude/shen-c/shen/src/kl") .. "/"
local FILES = {"toplevel","core","sys","dict","sequent","yacc","reader","prolog",
 "track","load","writer","macros","declarations","types","t-star","init",
 "extension-features","extension-factorise-defun"}

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

-- ---- load the kernel -----------------------------------------------------
local function load_kernel(verbose)
  local all = {}
  for _,nm in ipairs(FILES) do
    local fh = assert(io.open(KLDIR..nm..".kl"), "cannot open "..nm)
    local s = fh:read("*a"); fh:close()
    local fs = R.read_all(s)
    all[nm] = fs
    C.prescan(fs)
  end
  for _,nm in ipairs(FILES) do
    for _,f in ipairs(all[nm]) do
      local lua = C.compile_top(f)
      local ok, err = pcall(P.compile_and_load, lua, nm)
      if not ok then
        error("load error in "..nm..": "..tostring(err))
      end
    end
    if verbose then io.stderr:write("  loaded "..nm.."\n") end
  end
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
