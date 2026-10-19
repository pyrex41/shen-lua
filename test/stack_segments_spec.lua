-- test/stack_segments_spec.lua — deep non-tail recursion on fresh coroutine
-- stacks (runtime.lua M.seg, compiler.lua NT_SRC; pyrex41/shen-lua#93).
--   luajit test/stack_segments_spec.lua
-- Covers: recursion far past one LuaJIT stack through each kind of call site
-- (direct, mutual, APP, forward reference, native map callback, trap-error,
-- value-position control forms, freeze/thaw, lambdas), constant-stack loops
-- opening no segment, the count returning to its start after errors, Shen
-- errors crossing segments unchanged, and the trappable nesting limit.
package.path = (arg[0]:gsub("test/[^/]*$", "")) .. "?.lua;" .. package.path

local shen = require("shen")
shen.boot{quiet = true}
local R = shen.runtime

local npass, nfail = 0, 0
local function check(cond, name)
  if cond then npass = npass + 1
  else
    nfail = nfail + 1
    io.write("FAIL: ", name, "\n")
  end
end

local ev = shen.eval

-- evaluate; returns ok, value-or-message, segments opened, count afterwards
local function run(s)
  local t0 = R.seg.stats()
  local d0 = R.seg.SD[1]
  local ok, v = R.seg.pcall(ev, s)
  local t1, _, d1 = R.seg.stats()
  if not ok then
    v = getmetatable(v) == R.Excn and v.msg or tostring(v)
  end
  return ok, v, t1 - t0, d1 - d0
end

local DEEP = 100000   -- ~8x what one LuaJIT stack held

local function deep(name, defs, call, want)
  ev(defs)
  local ok, v, segs, drift = run(call)
  check(ok and v == want, name .. ": " .. tostring(v))
  check(segs > 0, name .. ": opened segments (" .. segs .. ")")
  check(drift == 0, name .. ": count back to its start")
end

deep("direct", "(define ss-d N -> (if (= N 0) 0 (+ 1 (ss-d (- N 1)))))",
     "(ss-d " .. DEEP .. ")", DEEP)
deep("mutual", [[
  (define ss-ma N -> (if (= N 0) 0 (+ 1 (ss-mb (- N 1)))))
  (define ss-mb N -> (if (= N 0) 0 (+ 1 (ss-ma (- N 1)))))]],
     "(ss-ma " .. DEEP .. ")", DEEP)
deep("APP (function argument)",
     "(define ss-h F N -> (if (= N 0) 0 (+ 1 (F F (- N 1)))))",
     "(ss-h (function ss-h) " .. DEEP .. ")", DEEP)
-- ss-fa calls ss-fb before it is defined: a CALLn forward reference
deep("forward reference", [[
  (define ss-fa N -> (if (= N 0) 0 (+ 1 (ss-fb (- N 1)))))
  (define ss-fb N -> (ss-fa N))]],
     "(ss-fa " .. DEEP .. ")", DEEP)
deep("native map callback",
     "(define ss-nest N -> (if (= N 0) [] [(ss-nest (- N 1))]))"
     .. "(define ss-walk X -> (if (cons? X) (map (function ss-walk) X) X))"
     .. "(define ss-depth X -> (if (cons? X) (+ 1 (ss-depth (hd X))) 0))",
     "(ss-depth (ss-walk (ss-nest " .. DEEP .. ")))", DEEP)
deep("trap-error body",
     "(define ss-t N -> (if (= N 0) 0 (+ 1 (trap-error (ss-t (- N 1)) (/. E -1)))))",
     "(ss-t " .. DEEP .. ")", DEEP)
deep("value-position if",
     "(define ss-v N -> (+ 1 (if (= N 0) -1 (ss-v (- N 1)))))",
     "(ss-v " .. DEEP .. ")", DEEP)
deep("freeze/thaw",
     "(define ss-z N -> (if (= N 0) 0 (+ 1 (thaw (freeze (ss-z (- N 1)))))))",
     "(ss-z " .. DEEP .. ")", DEEP)
deep("lambda body",
     "(define ss-l N -> (if (= N 0) 0 ((/. X (+ 1 (ss-l X))) (- N 1))))",
     "(ss-l " .. DEEP .. ")", DEEP)
deep("list built non-tail", "(define ss-mk N -> (if (= N 0) [] [N (ss-mk (- N 1))]))"
     .. "(define ss-len X -> (if (cons? X) (+ 1 (ss-len (hd (tl X)))) 0))",
     "(ss-len (ss-mk " .. DEEP .. "))", DEEP)

-- a let chain long enough that the compiler splits it into a function of
-- its own (wide_compile, #84): the split part counts itself
do
  local binds = {}
  for i = 1, 140 do
    binds[i] = "A" .. i .. " (+ " .. (i == 1 and "N" or ("A" .. (i - 1))) .. " 1)"
  end
  deep("split let chain",
       "(define ss-sl N -> (let " .. table.concat(binds, " ")
       .. " (if (= N 0) 0 (+ 1 (ss-sl (- N 1))))))",
       "(ss-sl " .. DEEP .. ")", DEEP)
end

-- tail calls stay tail calls: a constant-stack loop opens no segment, even
-- when the looping function counts itself and its arguments make calls
do
  ev([[(define ss-id X -> X)
       (define ss-loop N Acc -> (if (= N 0) Acc (ss-loop (ss-id (- N 1)) (+ Acc (ss-id 1)))))
       (define ss-pa N -> (if (= N 0) done (ss-pb (ss-id (- N 1)))))
       (define ss-pb N -> (ss-pa N))]])
  local ok, v, segs, drift = run("(ss-loop 1000000 0)")
  check(ok and v == 1000000 and segs == 0 and drift == 0, "self tail loop: no segment")
  ok, v, segs, drift = run("(ss-pa 1000000)")
  check(ok and v == R.intern("done") and segs == 0 and drift == 0,
        "mutual tail loop: no segment")
  -- continuations calling each other in tail position through lambdas
  ev([[(define ss-cps N K -> (if (= N 0) (K 0) (ss-cps (- N 1) (/. X (K (ss-id X))))))]])
  ok, v, segs, drift = run("(ss-cps 300000 (/. X X))")
  check(ok and v == 0 and segs == 0 and drift == 0, "lambda tail chain: no segment")
end

-- a Shen error raised deep inside crosses every segment unchanged, and the
-- count is back at its start once it is caught
do
  ev("(define ss-e N -> (if (= N 0) (simple-error \"bottom\") (+ 1 (ss-e (- N 1)))))")
  local ok, v, segs, drift = run("(trap-error (ss-e " .. DEEP .. ") (/. E (error-to-string E)))")
  check(ok and v == "bottom", "deep error caught by trap-error: " .. tostring(v))
  check(segs > 0 and drift == 0, "deep error: count restored")
  ok, v, segs, drift = run("(ss-e " .. DEEP .. ")")
  check(not ok and v == "bottom" and drift == 0, "deep error to the host: count restored")
  -- many caught errors from a few calls down never leak the count: a
  -- shallow call afterwards still opens no segment
  ev("(define ss-e3 N -> (+ 1 (+ 1 (ss-e 3))))")
  for _ = 1, 500 do run("(trap-error (ss-e3 0) (/. E 0))") end
  ok, v, segs, drift = run("(ss-d 50)")
  check(ok and v == 50 and segs == 0 and R.seg.SD[1] == 0, "no leak after 500 trapped errors")
end

-- the nesting cap raises a trappable Shen error instead of exhausting the C
-- stack: at the default cap (10000 segments of 160) ...
do
  local ok, v, _, drift = run("(trap-error (ss-d 2000000) (/. E (error-to-string E)))")
  check(ok and type(v) == "string" and v:find("stack depth limit exceeded", 1, true)
        and drift == 0, "default nesting cap is a trappable error: " .. tostring(v))
end
-- ... and at a lowered one
do
  local old = R.seg.limit(3)
  local ok, v = run("(trap-error (ss-d " .. DEEP .. ") (/. E (error-to-string E)))")
  R.seg.limit(old)
  check(ok and type(v) == "string" and v:find("stack depth limit exceeded", 1, true),
        "nesting cap is a trappable error: " .. tostring(v))
  local _, n = R.seg.stats()
  check(n == 0 and R.seg.SD[1] == 0, "nesting cap: state restored")
  ok, v = run("(ss-d " .. DEEP .. ")")
  check(ok and v == DEEP, "deep recursion works again after the cap")
end

io.write(string.format("stack_segments_spec: %d pass, %d fail\n", npass, nfail))
os.exit(nfail == 0 and 0 or 1)
