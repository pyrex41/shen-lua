-- test/freeze_cont_spec.lua — factoriser freeze/thaw continuation lowering.
-- Unique thaw inlines Else at the thaw site (no BIND). Several tail thaws
-- share one ::fail:: + goto (LuaJIT). Escaping freezes keep BIND.
--   luajit test/freeze_cont_spec.lua
package.path = (arg[0]:gsub("test/[^/]*$", "")) .. "?.lua;" .. package.path

local P = require("boot")
local R = require("runtime")
local C = require("compiler")
P.load_kernel(false)

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end

local function ev(s)
  local fs = R.read_all(s)
  local r
  for _, f in ipairs(fs) do r = P.eval(f) end
  return r
end

local function gensrc(s)
  return C.cdefun(R.read_all(s)[1])
end

-- ---------------------------------------------------------------------------
-- codegen: unique thaw inlines, no BIND
-- ---------------------------------------------------------------------------
do
  local src = gensrc([[
    (defun fc-u (X)
      (let G (freeze 7)
        (if (= X 0) (thaw G) X)))
  ]])
  check(not src:find("BIND", 1, true), "unique thaw: no BIND")
  check(src:find("return 7", 1, true), "unique thaw: Else inlined at thaw site")
end

-- ---------------------------------------------------------------------------
-- codegen: several tail thaws -> goto + shared label
-- ---------------------------------------------------------------------------
do
  local src = gensrc([[
    (defun fc-m (X)
      (let G (freeze 99)
        (if (cons? X)
            (if (= (hd X) 1) 1 (thaw G))
            (thaw G))))
  ]])
  check(src:find("goto fail", 1, true), "multi thaw: goto fail")
  check(src:find("::fail", 1, true), "multi thaw: shared fail label")
  local n99 = 0
  for _ in src:gmatch("return 99") do n99 = n99 + 1 end
  check(n99 == 1, "multi thaw: Else compiled once (got " .. n99 .. ")")
  check(not src:find("BIND", 1, true), "multi thaw: no BIND")
end

-- ---------------------------------------------------------------------------
-- escaping freeze still BINDs
-- ---------------------------------------------------------------------------
do
  local src = gensrc([[
    (defun fc-e (X)
      (let G (freeze X) (cons G ())))
  ]])
  check(src:find("BIND", 1, true), "escaping freeze keeps BIND")
end

-- thaw inside lambda is an escape
do
  local src = gensrc([[
    (defun fc-lam (X)
      (let G (freeze X)
        (lambda Y (thaw G))))
  ]])
  check(src:find("BIND", 1, true), "thaw inside lambda keeps BIND")
end

-- ---------------------------------------------------------------------------
-- semantics
-- ---------------------------------------------------------------------------
ev([[(defun fc-u (X)
      (let G (freeze 7)
        (if (= X 0) (thaw G) X)))]])
check(ev("(fc-u 0)") == 7, "unique thaw taken")
check(ev("(fc-u 3)") == 3, "unique thaw not taken")

ev([[(defun fc-m (X)
      (let G (freeze 99)
        (if (= X 1) 1
            (if (= X 2) 2
                (if (= X 3) 3 (thaw G))))))]])
check(ev("(fc-m 1)") == 1, "multi clause 1")
check(ev("(fc-m 2)") == 2, "multi clause 2")
check(ev("(fc-m 3)") == 3, "multi clause 3")
check(ev("(fc-m 0)") == 99, "multi fallthrough")

-- delayed eval: freeze body must not run unless thawed
P.GLOBALS["fc.*n*"] = 0
ev([[(defun fc-delay (X)
      (let G (freeze (do (set fc.*n* (+ 1 (value fc.*n*))) 42))
        (if (= X 0) (thaw G) X)))]])
check(ev("(fc-delay 5)") == 5, "delay: miss does not run freeze body")
check(P.GLOBALS["fc.*n*"] == 0, "delay: counter untouched on miss")
check(ev("(fc-delay 0)") == 42, "delay: hit runs freeze body")
check(P.GLOBALS["fc.*n*"] == 1, "delay: counter bumped once on hit")

-- nested factoriser shape
ev([[(defun fc-nest (X)
      (let G1 (freeze 0)
        (if (cons? X)
            (let G2 (freeze (thaw G1))
              (if (= (hd X) 1) 1 (thaw G2)))
            (thaw G1))))]])
check(ev("(fc-nest 5)") == 0, "nested: non-cons -> G1")
check(ev("(fc-nest (cons 1 ()))") == 1, "nested: hd 1")
check(ev("(fc-nest (cons 2 ()))") == 0, "nested: hd other -> G2 -> G1")

-- capture: freeze sees the outer binding, not a later let-shadow
ev([[(defun fc-cap (X)
      (let G (freeze X)
        (let X 999
          (if false 1 (thaw G)))))]])
check(ev("(fc-cap 8)") == 8, "freeze captures outer X, not inner let")

io.write(string.format("freeze_cont_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
