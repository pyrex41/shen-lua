-- test/wide_compile_spec.lua — KL functions too wide for ordinary Lua.
--
--   luajit test/wide_compile_spec.lua
--
-- Each case is a defun whose ordinary Lua exceeds a Lua limit (200 locals,
-- 60 upvalues). prims.lua's P.eval then recompiles just that defun in wide
-- mode (compiler.lua, WIDE). Every case checks the ordinary code really is
-- rejected, so the case keeps exercising the wide path, and that the wide
-- code computes the same values with the same evaluation behaviour.

package.path = (arg[0]:gsub("test/[^/]*$", "")) .. "?.lua;" .. package.path

local shen = require("shen")
shen.boot{ quiet = true }
local R = require("runtime")
local C = require("compiler")
local P = shen.prims
local F = P.F
local loadstr = loadstring or load

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end
local function eq(got, want, name)
  if got == want then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n  want: ", tostring(want),
             "\n  got:  ", tostring(got), "\n")
  end
end

local function show(x)
  local t = {}
  while R.is_cons(x) do t[#t + 1] = tostring(x[1]); x = x[2] end
  return table.concat(t, " ")
end

local function nums(from, to, step)
  local t = {}
  for i = from, to, step or 1 do t[#t + 1] = tostring(i) end
  return table.concat(t, " ")
end

local function kl_list(xs)
  local s = "()"
  for i = #xs, 1, -1 do s = "(cons " .. xs[i] .. " " .. s .. ")" end
  return s
end

-- (let N1 E1 (let N2 E2 ... BODY)) from parallel name / expr lists
local function let_chain(names, exprs, body)
  local s = body
  for i = #names, 1, -1 do s = "(let " .. names[i] .. " " .. exprs[i] .. " " .. s .. ")" end
  return s
end

local function read1(src) return R.read_all(src)[1] end

-- the ordinary code is rejected with `why`; the wide code loads; P.eval
-- (the path every defun takes) installs a working function
local function define_wide(src, why, name)
  local form = read1(src)
  local _, err = loadstr(C.compile_top(form))
  check(err ~= nil and tostring(err):find(why, 1, true) ~= nil,
        name .. ": ordinary code exceeds " .. why .. " (" .. tostring(err) .. ")")
  local wide = C.compile_top(form, true)
  check(loadstr(wide) ~= nil, name .. ": wide code loads")
  P.eval(form)
  return form, wide
end

local N = 210

-- 1) more than 120 bindings live at once: the let split hands the whole live
--    set to the continuation as one table
do
  local names, exprs, refs = {}, {}, {}
  for i = 1, N do
    names[i] = "L" .. i
    exprs[i] = "(+ X " .. i .. ")"
    refs[i] = names[i]
  end
  local _, wide = define_wide("(defun wc-live (X) " .. let_chain(names, exprs, kl_list(refs)) .. ")",
                              "local variables", "all-live let chain")
  check(wide:find("return KC%[%d+%]%({") ~= nil, "all-live let chain: split passes a table")
  eq(show(F["wc-live"](10)), nums(11, 10 + N), "all-live let chain: every binding survives the split")

  -- the same live set captured by a freeze: BIND(KC[i], {...})
  define_wide("(defun wc-frz (X) " .. let_chain(names, exprs, "(freeze " .. kl_list(refs) .. ")") .. ")",
              "local variables", "wide freeze")
  local th = F["wc-frz"](0)
  eq(show(F["thaw"](th)), nums(1, N), "wide freeze: thaw sees every capture")
  eq(show(F["thaw"](th)), nums(1, N), "wide freeze: thawing twice gives the same value")
end

-- 2) a long let chain under a goto-kind failure continuation: the ordinary
--    code keeps the failure label in one function, which then cannot split.
--    In wide mode the failure path is a freeze/thaw closure instead.
do
  local names, exprs = {}, {}
  for i = 1, N do
    names[i] = "G" .. i
    exprs[i] = (i == 1) and "(+ X 1)" or ("(+ G" .. (i - 1) .. " 1)")
  end
  local body = "(if (= X 0) (thaw K) (if (= X 1) (thaw K) (cons G" .. N .. " (cons G1 ()))))"
  local src = "(defun wc-goto (X) (let K (freeze (do (set wc-fails (+ 1 (value wc-fails))) "
              .. "(cons fail (cons X ())))) " .. let_chain(names, exprs, body) .. "))"
  check(C.compile_top(read1(src)):find("goto fail", 1, true) ~= nil,
        "goto failure path: ordinary code uses a goto failure label")
  local _, wide = define_wide(src, "local variables", "goto failure path")
  check(wide:find("goto fail", 1, true) == nil, "goto failure path: wide code has no failure label")
  shen.eval("(set wc-fails 0)")
  eq(show(F["wc-goto"](5)), (5 + N) .. " 6", "goto failure path: success path value")
  eq(shen.eval("(value wc-fails)"), 0, "goto failure path: failure body not run on success")
  eq(show(F["wc-goto"](0)), "fail 0", "goto failure path: first failure exit")
  eq(show(F["wc-goto"](1)), "fail 1", "goto failure path: second failure exit")
  eq(shen.eval("(value wc-fails)"), 2, "goto failure path: failure body runs once per exit")
end

-- 3) a lambda closing over more than 60 bindings: LAMW(KC[i], {...})
do
  local names, exprs, refs = {}, {}, { "Y" }
  for i = 1, 70 do
    names[i] = "A" .. i
    exprs[i] = "(+ X " .. i .. ")"
    refs[#refs + 1] = names[i]
  end
  local _, wide = define_wide("(defun wc-lam (X) " .. let_chain(names, exprs, "(lambda Y " .. kl_list(refs) .. ")") .. ")",
                              "upvalues", "wide lambda")
  check(wide:find("LAMW(", 1, true) ~= nil, "wide lambda: built by LAMW")
  local f = F["wc-lam"](0)
  eq(show(P.APP(f, 99)), "99 " .. nums(1, 70), "wide lambda: applies with every capture")
  eq(show(P.APP(f, 7)), "7 " .. nums(1, 70), "wide lambda: reusable")
end

-- 4) a curried lambda chain deeper than CURRY_DEPTH (the kernel's lambda
--    entry for a many-argument function) compiles to CURRY in ordinary code
do
  local depth = 40
  local s = "(cons Y1 (cons Y2 (cons Y" .. depth .. " ())))"
  for i = depth, 1, -1 do s = "(lambda Y" .. i .. " " .. s .. ")" end
  local form = read1("(defun wc-curry () " .. s .. ")")
  local src = C.compile_top(form)
  check(src:find("CURRY(", 1, true) ~= nil and loadstr(src) ~= nil,
        "curried chain: compiles to CURRY and loads")
  P.eval(form)
  local f1 = P.APP(F["wc-curry"](), "a")
  local fa, fb = P.APP(f1, "b"), P.APP(f1, "c")
  for i = 3, depth - 1 do fa = P.APP(fa, i); fb = P.APP(fb, i) end
  eq(show(P.APP(fa, "z")), "a b z", "curried chain: one branch")
  eq(show(P.APP(fb, "z")), "a c z", "curried chain: a sibling partial application is independent")
  eq(show(P.APP(fa, "y")), "a b y", "curried chain: a partial application is reusable")

  local shallow = "(cons Y1 ())"
  for i = 8, 1, -1 do shallow = "(lambda Y" .. i .. " " .. shallow .. ")" end
  check(C.compile_top(read1("(defun wc-shallow () " .. shallow .. ")")):find("CURRY", 1, true) == nil,
        "curried chain: a shallow chain keeps nested closures")
end

print(string.format("wide_compile_spec: %d pass, %d fail", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
