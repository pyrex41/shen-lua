-- compiler.lua : compile KLambda forms to Lua source, then load().
-- Strategy: statement-based codegen.  `ctail` emits statements ending in a
-- `return` (or native if/elseif), so function bodies use real Lua control flow
-- and real tail calls (LuaJIT does proper TCO).  `cexpr` emits a Lua expression,
-- wrapping control forms in an IIFE only when used in value (non-tail) position.

local R = require("runtime")
local cons, is_cons, NIL = R.cons, R.is_cons, R.NIL
local is_symbol = R.is_symbol

local C = {}

-- list helpers over runtime cons
local function car(x) return x[1] end
local function cdr(x) return x[2] end
local function to_array(lst)
  local a = {}
  while is_cons(lst) do a[#a+1] = lst[1]; lst = lst[2] end
  return a
end
local function len(lst)
  local n = 0; while is_cons(lst) do n = n + 1; lst = lst[2] end; return n
end

-- ------------------------------------------------------------------
-- arity registry shared with runtime via the env table passed to load()
-- ------------------------------------------------------------------
C.ARITY = {}    -- function-name -> arity (known defuns + primitives)

-- ------------------------------------------------------------------
-- Lua string literal escaping
-- ------------------------------------------------------------------
local function qstr(s)
  return string.format("%q", s)
end

-- compile-time gensym for Lua locals
local gsn = 0
local function gen(prefix) gsn = gsn + 1; return (prefix or "t") .. gsn end

-- ------------------------------------------------------------------
-- Compilation context (module-global; we never compile in parallel).
--
-- For a single `defun` body, we hoist every `(freeze ...)` closure to a flat
-- list at the top of the impl function. Reason: KLambda emitted by the Shen
-- Prolog compiler (e.g. einsteins-riddle, t-star) chains 60+ continuation
-- closures inside argument positions; naive codegen would nest 60+ Lua
-- `function() ... end` bodies, which LuaJIT's parser rejects with "chunk has
-- too many syntax levels".
--
-- The trick:
--   * Each freeze body is compiled with its free variables abstracted as
--     parameters: `kbody[N] = function(cap1, cap2, ...) return BODY end`.
--     These bodies are emitted as a flat sequence inside the impl function.
--   * At each freeze occurrence, we emit `BIND(kbody[N], cap1, cap2, ...)` --
--     a plain call, no nested `function` literal at the use site. BIND is a
--     runtime helper that snapshots the captures and returns a 0-arity thunk.
--
-- This decouples freeze definitions from the surrounding `let` block scope,
-- so we don't need per-defun forward declarations of every let-var (which
-- would blow Lua's per-function 200-local limit on the larger t-star defun).
-- ------------------------------------------------------------------
local CTX  -- nil outside a defun compile; otherwise a fresh table per defun.

-- Self-tail-call -> loop lowering state. Non-nil only while compiling a defun
-- body whose direct tail self-calls may be lowered to a loop continue:
--   { name = <defun name>, arity = N, lnames = {param locals}, used = bool }
-- When a tail-position call (NAME a1..aN) matches name+exact arity, ctail
-- emits `p1, ..., pN = e1, ..., eN; goto tco` instead of a tail call, and
-- cdefun wraps the body in `while true do ... ::tco:: end`. Lua's multiple
-- assignment evaluates every RHS before assigning, so (f Y X)-style swaps are
-- handled without explicit temps (and we add zero locals toward the 200-local
-- limit). MUST be cleared while compiling any body that is hoisted into a
-- separate Lua function (KC bodies, the no-CTX IIFE fallback) — a `goto`
-- there would cross a function boundary and fail to parse.
local SELF

-- The lowering emits `goto`/labels, which PUC Lua 5.1 cannot parse (goto is
-- 5.2+/LuaJIT). Feature-detect once; without it every defun simply keeps the
-- proper-tail-call form (correctness identical -- this is a perf-only lever).
local HAS_GOTO = (loadstring or load)("do goto tco ::tco:: end") ~= nil

local function new_ctx()
  -- cbodies: hoisted bodies (both `freeze` bodies and value-position control
  --          forms), emitted into a single `KC` table at *chunk* scope (built
  --          once at load). Each is a constant function abstracting its free
  --          vars as params, so it never captures an impl-local as an upvalue
  --          (which would force a per-call FNEW). freeze use sites wrap KC[i]
  --          with BIND (snapshotting captures into a thunk); control forms just
  --          call KC[i] directly.
  return { cbodies = {} }
end

-- Collect the free variables of a form: KL names that appear as symbols in
-- the form, are bound in the outer `env`, and are NOT shadowed by inner
-- `let` / `lambda` bindings of the same name.
local function collect_free(form, env, bound, acc)
  if not is_cons(form) then
    if is_symbol(form) and env[form.name] and not bound[form.name] then
      acc[form.name] = true
    end
    return
  end
  local head = form[1]
  if is_symbol(head) and not env[head.name] then
    local op = head.name
    if op == "let" then
      local var = car(cdr(form)).name
      local val = car(cdr(cdr(form)))
      local body = car(cdr(cdr(cdr(form))))
      collect_free(val, env, bound, acc)
      local nb = {}; for k in pairs(bound) do nb[k] = true end; nb[var] = true
      collect_free(body, env, nb, acc)
      return
    elseif op == "lambda" then
      local var = car(cdr(form)).name
      local body = car(cdr(cdr(form)))
      local nb = {}; for k in pairs(bound) do nb[k] = true end; nb[var] = true
      collect_free(body, env, nb, acc)
      return
    end
  end
  local cur = form
  while is_cons(cur) do
    collect_free(cur[1], env, bound, acc)
    cur = cur[2]
  end
end


-- Loop-lowering safety scan: a lowered function's param locals MUTATE on each
-- iteration, so anything that captures a param BY REFERENCE and can outlive
-- the iteration would observe iteration N+1's values from a closure created in
-- iteration N. The only such construct in this codegen is `lambda` -> MKFUN,
-- whose Lua function literal captures impl locals as upvalues. Everything else
-- is immune:
--   * freeze       -> BIND(KC[i], caps...) snapshots capture VALUES at creation
--   * value-position control forms -> KC[i](caps...) called immediately
--   * trap-error / do-IIFE inline closures execute synchronously, before any
--     further mutation of the params
--   * let-locals are declared INSIDE the `while` block, so Lua closes upvalues
--     over them at each iteration's end (fresh per iteration)
-- So: refuse lowering iff some lambda in the body (outside freeze bodies) has
-- a param among its free variables. `env` is the param env (name -> truthy),
-- `bound` tracks shadowing let/lambda binders, mirroring collect_free.
local function lambda_captures_param(form, env, bound)
  if not is_cons(form) then return false end
  local head = form[1]
  if is_symbol(head) and not env[head.name] then
    local op = head.name
    if op == "freeze" then
      return false
    elseif op == "lambda" then
      -- collect_free over the whole lambda form sees through nested binders,
      -- so a hit at any depth inside this lambda is caught here.
      local fv = {}
      collect_free(form, env, bound, fv)
      return next(fv) ~= nil
    elseif op == "let" then
      local var = car(cdr(form)).name
      local val = car(cdr(cdr(form)))
      local body = car(cdr(cdr(cdr(form))))
      if lambda_captures_param(val, env, bound) then return true end
      local nb = {}; for k in pairs(bound) do nb[k] = true end; nb[var] = true
      return lambda_captures_param(body, env, nb)
    end
  end
  local cur = form
  while is_cons(cur) do
    if lambda_captures_param(cur[1], env, bound) then return true end
    cur = cur[2]
  end
  return false
end

-- Pure-tail-recursion scan: lowering only pays when the function becomes a
-- REAL loop, with no residual recursion left inside the loop body. A mixed
-- function (tak/ackermann shape: the tail self-call's arguments themselves
-- recurse, or another branch recurses non-tail) REGRESSES under lowering --
-- LuaJIT traces a self-tail-call chain well, but a loop whose body re-enters
-- the same function through non-tail calls keeps side-exiting the loop trace
-- (measured: tak(24,16,8) 2.1x slower when mixed-lowered). So: eligible iff
-- EVERY occurrence of the function's own name in the body is the head of a
-- direct call in TAIL position with the exact declared arity, and the
-- arguments of those calls are self-free. Any other occurrence -- bare-symbol
-- reference (value/partial application), wrong arity, a call in an argument,
-- inside lambda/freeze/trap-error or any non-tail position -- refuses
-- lowering, keeping today's codegen for the whole function. A let/lambda
-- binder that rebinds the name also refuses (the name would sometimes be a
-- variable; conservative). The tail-position map below mirrors ctail exactly:
-- if/cond results, let body, do-last, and/or second arg, type's expr.
local function contains_name(form, name)
  if is_symbol(form) then return form.name == name end
  local cur = form
  while is_cons(cur) do
    if contains_name(cur[1], name) then return true end
    cur = cur[2]
  end
  return false
end

local function pure_tail_self(form, name, arity, tailpos)
  if not is_cons(form) then
    -- a bare self-reference (value / partial application) is residual
    return not (is_symbol(form) and form.name == name)
  end
  local head = form[1]
  if is_symbol(head) then
    local op = head.name
    if op == name then
      -- direct self-call: lowerable iff in tail position with exact arity and
      -- self-free arguments (arguments are evaluated in non-tail position)
      local args = to_array(cdr(form))
      if not tailpos or #args ~= arity then return false end
      for i = 1, #args do
        if contains_name(args[i], name) then return false end
      end
      return true
    elseif op == "if" then
      local rest = cdr(form)
      if contains_name(car(rest), name) then return false end -- test: non-tail
      local cur = cdr(rest)
      while is_cons(cur) do
        if not pure_tail_self(cur[1], name, arity, tailpos) then return false end
        cur = cur[2]
      end
      return true
    elseif op == "cond" then
      local cur = cdr(form)
      while is_cons(cur) do
        local cl = cur[1]
        if contains_name(car(cl), name) then return false end  -- test: non-tail
        if not pure_tail_self(car(cdr(cl)), name, arity, tailpos) then return false end
        cur = cur[2]
      end
      return true
    elseif op == "let" then
      local var  = car(cdr(form))
      local val  = car(cdr(cdr(form)))
      local body = car(cdr(cdr(cdr(form))))
      if is_symbol(var) and var.name == name then return false end -- rebinds it
      if contains_name(val, name) then return false end            -- val: non-tail
      return pure_tail_self(body, name, arity, tailpos)
    elseif op == "do" then
      local forms = to_array(cdr(form))
      for i = 1, #forms - 1 do
        if contains_name(forms[i], name) then return false end     -- non-tail
      end
      return #forms == 0 or pure_tail_self(forms[#forms], name, arity, tailpos)
    elseif op == "and" or op == "or" then
      local a = car(cdr(form)); local b = car(cdr(cdr(form)))
      if contains_name(a, name) then return false end              -- a: non-tail
      return pure_tail_self(b, name, arity, tailpos)
    elseif op == "type" then
      return pure_tail_self(car(cdr(form)), name, arity, tailpos)  -- ctail: tail
    elseif op == "lambda" or op == "freeze" or op == "trap-error" then
      -- separate function bodies / pcall closure: any self-ref is residual
      return not contains_name(cdr(form), name)
    end
  end
  -- generic call (or computed head): everything here is non-tail
  return not contains_name(form, name)
end

-- environment: maps KL var name -> Lua local name. Implemented as a linked
-- table of scopes for cheap shadowing.
local function extend(env, kname, lname)
  local e = {}; for k,v in pairs(env) do e[k]=v end; e[kname]=lname; return e
end

local cexpr, ctail  -- forward

-- a symbol used as a *value* (self-evaluating) -> intern at runtime
local function symlit(name) return 'S(' .. qstr(name) .. ')' end

-- ------------------------------------------------------------------
-- atom / literal compilation
-- ------------------------------------------------------------------
local function catom(form, env)
  local t = type(form)
  if t == "number" then
    return string.format("%.17g", form):gsub("%.0$","")  -- numeric literal
  elseif t == "boolean" then
    return form and "true" or "false"
  elseif t == "string" then
    return qstr(form)
  elseif form == NIL then
    return "NIL"
  elseif is_symbol(form) then
    local lname = env[form.name]
    if lname then return lname end       -- bound variable
    return symlit(form.name)             -- self-evaluating symbol
  else
    error("catom: cannot compile " .. tostring(form))
  end
end

-- numeric literal needs care: keep integers exact
-- mtoint: PUC 5.3+ %d-format guard (string.format("%d", n) errors there for
-- an integral float outside int64 range). nil under LuaJIT/5.1: path unchanged.
local mtoint = math.tointeger
local function cnum(n)
  if n == math.floor(n) and n ~= math.huge and n ~= -math.huge then
    if mtoint then
      local i = mtoint(n)
      if i then return string.format("%d", i) end
      return string.format("%.17g", n)
    end
    return string.format("%d", n)
  end
  return string.format("%.17g", n)
end

-- ------------------------------------------------------------------
-- application
-- ------------------------------------------------------------------
local function ftab_ref(name)
  return 'F[' .. qstr(name) .. ']'
end

-- 2-arg numeric primitives that get inlined to an ENV fast-path helper
-- (see ENV.ADD/.../EQ in prims.lua and the call site in ccall). Track 1.1/1.2.
local ARITH2 = {
  ["+"]="ADD", ["-"]="SUB", ["*"]="MUL", ["/"]="DIV",
  [">"]="GT", ["<"]="LT", [">="]="GE", ["<="]="LE", ["="]="EQ",
}

-- Let-floating: rewrite (F a1...aN (let X V B)) -> (let X V (F a1...aN B)).
-- This collapses right-recursive let chains in continuation-passing code
-- (e.g. the Prolog backend generates many (let X (newpv A) (shen.gc A NEXT))
-- forms inside einsteins-riddle), which would otherwise compile to deeply
-- nested IIFEs that exceed Lua's chunk syntax-level limit.
--
-- This is sound when the let's value form V has no side effect that depends
-- on evaluating a1...aN first. We restrict to the LAST argument and require
-- preceding args to be atoms/unbound symbols (pure variable / literal refs)
-- so the visible evaluation order is preserved.
local function arg_pure(form, env)
  if not is_cons(form) then return true end
  return false
end
-- Recognised special forms that must NOT be treated as ordinary calls when
-- recursing for deep let-floating.
local SPECIAL_HEADS = {
  ["if"]=true, ["cond"]=true, ["let"]=true, ["do"]=true,
  ["trap-error"]=true, ["and"]=true, ["or"]=true,
  ["lambda"]=true, ["freeze"]=true, ["defun"]=true, ["type"]=true,
}
local function try_let_float(form, env)
  -- Never treat a binder / control form as if it were an ordinary call.
  -- In particular (lambda V BODY) and (freeze BODY) must NOT have their body
  -- floated out, because that would move the body's enclosed lets to an outer
  -- scope where the binder's variable (V) is no longer in scope when the body
  -- references it. (Concrete bug: defprolog `mapit` source has
  -- `(lambda Z112 (lambda Z113 (let W114 ... (let W115 (lambda ... Z113 ...) ...))))`
  -- where the inner lambda body's freeze references Z113. Floating the let
  -- out of `(lambda Z113 ...)` strands that Z113 reference outside its binder
  -- and the compiler emits `S("Z113")` (a self-evaluating symbol) instead of
  -- the captured Lua local -- causing mapit to silently produce false.)
  local head = car(form)
  if is_symbol(head) and not env[head.name] and SPECIAL_HEADS[head.name] then
    return nil
  end
  local args_node = cdr(form)
  if args_node == NIL then return nil end
  -- find the last cons cell of the arg list
  local prev_chain = {}
  local cur = args_node
  while cdr(cur) ~= NIL do
    prev_chain[#prev_chain+1] = car(cur)
    cur = cdr(cur)
  end
  local last = car(cur)
  -- preceding args must be pure (atoms / unbound symbols) so floating preserves
  -- the visible evaluation order.
  for i=1,#prev_chain do
    if not arg_pure(prev_chain[i], env) then return nil end
  end
  local x, val, new_last
  if is_cons(last) and is_symbol(car(last)) and car(last).name == "let"
     and not env["let"] then
    x   = car(cdr(last))
    val = car(cdr(cdr(last)))
    new_last = car(cdr(cdr(cdr(last))))
  elseif is_cons(last) and is_symbol(car(last))
         and not env[car(last).name]
         and not SPECIAL_HEADS[car(last).name] then
    -- Recurse: try to float a let out of the last arg's own last-arg chain.
    -- This collapses (F1 _ (F2 _ (let X V B))) into (let X V (F1 _ (F2 _ B))).
    local inner = try_let_float(last, env)
    if not (inner and is_cons(inner) and is_symbol(car(inner))
            and car(inner).name == "let") then
      return nil
    end
    x   = car(cdr(inner))
    val = car(cdr(cdr(inner)))
    new_last = car(cdr(cdr(cdr(inner))))
  else
    return nil
  end
  -- rebuild (F prev... new_last)
  local new_args = cons(new_last, NIL)
  for i=#prev_chain,1,-1 do new_args = cons(prev_chain[i], new_args) end
  local new_call = cons(car(form), new_args)
  return cons(R.intern("let"), cons(x, cons(val, cons(new_call, NIL))))
end

-- Flatten a deep right-spine call chain (F1 ... (F2 ... (F3 ... INNER)))
-- into a sequence of local assignments. Without this, the chained
-- shen.gc(A, shen.gc(A, shen.gc(A, ...))) calls produced by the Shen Prolog
-- compiler hit Lua's expression-complexity limit (~200 nested calls).
-- Only valid in statement (tail) position because we emit `local` bindings.
local function try_flatten_call_chain(form, env)
  -- Walk into the last-arg chain, building a list of call frames.
  local frames = {}   -- each: { head_form, prev_args_array }
  local cur = form
  while is_cons(cur) and is_symbol(car(cur)) and not env[car(cur).name]
        and not SPECIAL_HEADS[car(cur).name] do
    local args_node = cdr(cur)
    if args_node == NIL then break end
    local prev = {}
    local c = args_node
    while cdr(c) ~= NIL do prev[#prev+1] = car(c); c = cdr(c) end
    frames[#frames+1] = { car(cur), prev }
    cur = car(c)
  end
  if #frames < 16 then return nil end   -- not deep enough to flatten
  -- innermost value first
  local stmts = {}
  -- If the innermost form is a (do A1 A2 ... AN), emit A1..A_{N-1} as
  -- statement-level side-effects (via tiny IIFEs that capture nothing
  -- expensive) and use AN as the value expression. This avoids wrapping the
  -- whole innermost in a single IIFE that would capture every flattened
  -- local as an upvalue (Lua caps at 60 upvalues per function).
  local val_form = cur
  if is_cons(cur) and is_symbol(cur[1]) and not env["do"]
     and cur[1].name == "do" then
    local do_args = to_array(cdr(cur))
    for i=1,#do_args-1 do
      stmts[#stmts+1] = "(function() return " .. cexpr(do_args[i], env) .. " end)();"
    end
    val_form = do_args[#do_args]
  end
  local inner_name = gen("c")
  stmts[#stmts+1] = "local " .. inner_name .. " = " .. cexpr(val_form, env) .. ";"
  -- build each call up to but not including the outermost
  for i=#frames, 2, -1 do
    local frame = frames[i]
    local hname = frame[1].name
    local prev_strs = {}
    for j=1,#frame[2] do prev_strs[j] = cexpr(frame[2][j], env) end
    local arg_list
    if #prev_strs == 0 then arg_list = inner_name
    else arg_list = table.concat(prev_strs, ", ") .. ", " .. inner_name end
    local next_name = gen("c")
    -- use ccall semantics via a single-shot synthetic form
    local synth = cons(frame[1], NIL)
    -- prepend prev args + inner placeholder. Build a synthetic AST node so
    -- we can reuse ccall for arity-correct dispatch.
    -- We don't actually need the AST; emit a direct F[...] call using ARITY.
    local ar = C.ARITY[hname]
    local call_str
    if ar and #prev_strs + 1 == ar then
      call_str = ftab_ref(hname) .. "(" .. arg_list .. ")"
    else
      -- fall back to APP for unknown / mismatched arity
      call_str = "APP(" .. symlit(hname) .. ", " .. arg_list .. ")"
    end
    stmts[#stmts+1] = "local " .. next_name .. " = " .. call_str .. ";"
    inner_name = next_name
  end
  -- outermost: emit as return statement
  local frame = frames[1]
  local hname = frame[1].name
  local prev_strs = {}
  for j=1,#frame[2] do prev_strs[j] = cexpr(frame[2][j], env) end
  local arg_list
  if #prev_strs == 0 then arg_list = inner_name
  else arg_list = table.concat(prev_strs, ", ") .. ", " .. inner_name end
  local ar = C.ARITY[hname]
  local call_str
  if ar and #prev_strs + 1 == ar then
    call_str = ftab_ref(hname) .. "(" .. arg_list .. ")"
  else
    call_str = "APP(" .. symlit(hname) .. ", " .. arg_list .. ")"
  end
  stmts[#stmts+1] = "return " .. call_str
  return table.concat(stmts, " ")
end

-- compile a call (F a1..an) in expression position
local function ccall(form, env)
  local head = car(form)
  local args = to_array(cdr(form))
  local cargs = {}
  for i=1,#args do cargs[i] = cexpr(args[i], env) end
  local argstr = table.concat(cargs, ", ")

  if is_symbol(head) and not env[head.name] then
    local name = head.name
    local ar = C.ARITY[name]
    if ar ~= nil then
      if #args == ar then
        -- Track 1.1/1.2: inline 2-arg numeric prims to ENV fast-paths (ADD,
        -- SUB, ..., EQ) instead of an F-table hash lookup. The helpers guard on
        -- type(number) and fall back to F[name], preserving KL semantics + late
        -- binding. Only when the head isn't a locally-bound var (checked above).
        local helper = ARITH2[name]
        if helper and ar == 2 then
          return helper .. "(" .. argstr .. ")"
        end
        return ftab_ref(name) .. "(" .. argstr .. ")"
      else
        -- Arity mismatch at compile time: route through APP so dispatch uses
        -- the *current* runtime arity (FA[F[name]]) rather than the value of
        -- C.ARITY[name] captured at compile time. This matters whenever a
        -- function's arity changes between when a call site is compiled and
        -- when it executes -- e.g. when a later (define ...) redefines a
        -- function with a new arity (binary.shen redefines `complement` after
        -- tableauprolog.shen used it as a 6-arg Prolog predicate), or when
        -- Shen's `shen.update-lambdatable` evaluates a curry wrapper for the
        -- new arity *before* the new defun has been installed (depth.shen
        -- redefining `depth` from 3 to 4 args). Baking the stale arity into
        -- PARTIAL / over-app expressions would silently produce wrong-arity
        -- residual closures.
        if #args == 0 then return "APP(" .. symlit(name) .. ")" end
        return "APP(" .. symlit(name) .. ", " .. argstr .. ")"
      end
    else
      -- unknown arity: generic apply through function table / symbol
      if #args == 0 then return "APP(" .. symlit(name) .. ")" end
      return "APP(" .. symlit(name) .. ", " .. argstr .. ")"
    end
  else
    -- head is a bound variable or a compound expression -> generic apply
    local hv = cexpr(head, env)
    if #args == 0 then return "APP(" .. hv .. ")" end
    return "APP(" .. hv .. ", " .. argstr .. ")"
  end
end

-- Tail-position DIRECT self-call with exact declared arity -> loop continue.
-- Returns the replacement statement string, or nil if this form is not a
-- lowerable self-call. Anything that doesn't match (calls through APP /
-- partials / variables, arity mismatches, shadowed name) keeps ordinary
-- codegen and still works: the loop only replaces the tail self-call; the
-- function value installed in F is unchanged.
local function try_self_tail(form, env)
  if not SELF then return nil end
  local head = car(form)
  if not (is_symbol(head) and not env[head.name] and head.name == SELF.name) then
    return nil
  end
  local args = to_array(cdr(form))
  if #args ~= SELF.arity then return nil end
  SELF.used = true
  if #args == 0 then return "goto tco" end
  local cargs = {}
  for i = 1, #args do cargs[i] = cexpr(args[i], env) end
  return table.concat(SELF.lnames, ", ") .. " = "
         .. table.concat(cargs, ", ") .. "; goto tco"
end

-- detect a long (cons A (cons B ... TAIL)) spine and flatten it into a single
-- MKLIST({...}, tail) call, to avoid Lua's expression-nesting depth limit.
local function cons_chain(form)
  local elems = {}
  local cur = form
  while is_cons(cur) and is_symbol(car(cur)) and car(cur).name == "cons"
        and is_cons(cdr(cur)) and is_cons(cdr(cdr(cur))) and cdr(cdr(cdr(cur))) == NIL do
    elems[#elems+1] = car(cdr(cur))
    cur = car(cdr(cdr(cur)))
  end
  return elems, cur  -- elems (in order), final tail form
end

-- ------------------------------------------------------------------
-- constant folding of pure-data (cons ...) trees.
-- A form is constant data if it is an atom, a non-shadowed symbol, or
-- (cons A B) where A and B are constant data.  Such trees (quoted lists,
-- the giant kernel arity table, test-banner rcons forms) are built once at
-- compile time and referenced via the KDATA side table — this avoids Lua's
-- ~200-level expression-nesting parser limit and shrinks generated code.
-- KL cons cells are immutable, so sharing the constant is safe.
-- ------------------------------------------------------------------
C.KDATA = {}

-- When set, literal hoisting goes through the self-contained MKTREE
-- blueprint instead of the KDATA side table. Chunks compiled this way are
-- relocatable — no baked-in KDATA indices — which is what boot.lua's fasl
-- recorder needs to make cached user-program chunks replayable in sessions
-- whose KDATA population differs (e.g. nested loads, skipped typechecks).
C.NO_KDATA = false

-- Original spine-only const hoisting (kept for backward behavior on explicit (cons ...) forms).
local function const_count(form, env)
  local t = type(form)
  if t=="number" or t=="string" or t=="boolean" then return 1 end
  if form == NIL then return 1 end
  if is_symbol(form) then
    if env[form.name] then return nil end
    return 1
  end
  if is_cons(form) and is_symbol(car(form)) and car(form).name=="cons"
     and not env["cons"]
     and is_cons(cdr(form)) and is_cons(cdr(cdr(form))) and cdr(cdr(cdr(form)))==NIL then
    local a = const_count(car(cdr(form)), env); if not a then return nil end
    local b = const_count(car(cdr(cdr(form))), env); if not b then return nil end
    return a + b + 1
  end
  return nil
end
local function const_build(form)
  if is_cons(form) then
    return cons(const_build(car(cdr(form))), const_build(car(cdr(cdr(form)))))
  end
  return form
end
local function try_const(form, env)
  if C.NO_KDATA then return nil end
  if not (is_cons(form) and is_symbol(car(form)) and car(form).name=="cons") then return nil end
  local n = const_count(form, env)
  if n and n >= 24 then
    local v = const_build(form)
    local idx = #C.KDATA + 1
    C.KDATA[idx] = v
    return "KDATA[" .. idx .. "]"
  end
  return nil
end

-- General literal data hoisting for (cons ...) trees used as arguments
-- (e.g. embedded source forms passed to shen.record-kl in 41.2 stlib, giant
-- arity tables, etc.). A form is "literal data" only if it self-evaluates:
-- atoms / unbound symbols / NIL, or a `(cons L R)` call whose subtrees are
-- literal data. Crucially this MUST NOT match other calls like `(set ...)`,
-- `(shen.record-kl ...)`, or `(lambda ...)` — those have side effects /
-- semantics and cannot be replaced by their AST as a constant.
local function is_lit(form, env)
  local t = type(form)
  if t=="number" or t=="string" or t=="boolean" then return true end
  if form == NIL then return true end
  if is_symbol(form) then return not env[form.name] end
  if is_cons(form) then
    -- Only a (cons L R) call counts as data construction.
    -- The cons cell representing this call has shape:
    --   cons(cons-sym, cons(L, cons(R, NIL)))
    local head = form[1]
    if not (is_symbol(head) and head.name == "cons" and not env["cons"]) then
      return false
    end
    local rest = form[2]
    if not is_cons(rest) then return false end
    local rest2 = rest[2]
    if not is_cons(rest2) then return false end
    if rest2[2] ~= NIL then return false end
    return is_lit(rest[1], env) and is_lit(rest2[1], env)
  end
  return false
end
local function lit_count(form)
  if not is_cons(form) then return 1 end
  -- count cons-call nodes via the L and R arguments only
  local rest = form[2]
  return 1 + lit_count(rest[1]) + lit_count(rest[2][1])
end
-- Build the runtime cons tree value from a (cons L R) form recursively.
local function lit_build(form)
  if not is_cons(form) then return form end
  local rest = form[2]
  return cons(lit_build(rest[1]), lit_build(rest[2][1]))
end
local function try_lit_const(form, env)
  if C.NO_KDATA then return nil end
  if not is_cons(form) then return nil end
  if not is_lit(form, env) then return nil end
  local n = lit_count(form)
  if n >= 24 then
    local idx = #C.KDATA + 1
    C.KDATA[idx] = lit_build(form)
    return "KDATA[" .. idx .. "]"
  end
  return nil
end

-- ------------------------------------------------------------------
-- Deep cons-tree compilation.
--
-- A KLambda expression like `(cons A (cons B (cons (cons ...) ...)))` compiles
-- naively into deeply-nested `F["cons"](_, F["cons"](_, F["cons"](_, _)))`
-- expressions. Lua's parser refuses to compile expressions nested past about
-- 200 levels, so the 41.2 stlib's giant `shen.record-kl <name> <source-tree>`
-- calls (some have tree depth ~216 and ~7000 cons cells) blow up at load.
--
-- The fix: emit deep cons-trees through a flat blueprint array consumed by
-- the runtime helper `MKTREE`. The blueprint contains:
--   * `'v', <leaf-value-expr>` for each leaf (atom, unbound symbol,
--     literal cons subtree hoisted via KDATA, or non-cons-call subexpr like
--     `(protect Var)`), and
--   * `'c'` to pop the top two stack entries and replace them with a cons cell.
-- The whole expression becomes a single shallow call to MKTREE.
-- ------------------------------------------------------------------
local function count_cons_nodes(form)
  if not is_cons(form) then return 0 end
  if not (is_symbol(form[1]) and form[1].name == "cons") then return 0 end
  local rest = form[2]
  if not (is_cons(rest) and is_cons(rest[2]) and rest[2][2] == NIL) then return 0 end
  return 1 + count_cons_nodes(rest[1]) + count_cons_nodes(rest[2][1])
end

local function compile_cons_tree(form, env)
  local ops = {}
  local function visit(f)
    if is_cons(f) then
      -- prefer hoisting fully-literal subtrees as KDATA (one stack push)
      local hoisted = try_lit_const(f, env)
      if hoisted then
        ops[#ops+1] = "'v', " .. hoisted
        return
      end
      -- (cons L R) call: recurse into both halves, then emit 'c'
      if is_symbol(f[1]) and f[1].name == "cons" and not env["cons"] then
        local rest = f[2]
        if is_cons(rest) and is_cons(rest[2]) and rest[2][2] == NIL then
          visit(rest[1])
          visit(rest[2][1])
          ops[#ops+1] = "'c'"
          return
        end
      end
    end
    -- arbitrary leaf expression (constant, symbol, or non-cons call like `(protect V)`)
    ops[#ops+1] = "'v', " .. cexpr(f, env)
  end
  visit(form)
  return "MKTREE({" .. table.concat(ops, ", ") .. "})"
end

-- ------------------------------------------------------------------
-- cexpr : value position (returns a Lua expression string)
-- ------------------------------------------------------------------
function cexpr(form, env)
  if not is_cons(form) then
    if type(form)=="number" then return cnum(form) end
    return catom(form, env)
  end
  local head = car(form)
  if is_symbol(head) and head.name == "cons" and not env["cons"] then
    local k = try_const(form, env)
    if k then return k end
    -- If this is a deep cons-tree (would blow Lua's expression-nesting limit
    -- when compiled as nested F["cons"] calls), emit via the flat MKTREE
    -- blueprint instead. 60 nodes is well below the parser limit and gives
    -- the inline path a chance for moderately-sized forms.
    if count_cons_nodes(form) >= 60 then
      return compile_cons_tree(form, env)
    end
    local elems, tail = cons_chain(form)
    if #elems >= 16 then
      local parts = {}
      for i=1,#elems do parts[i] = cexpr(elems[i], env) end
      return "MKLIST({" .. table.concat(parts, ", ") .. "}, " .. cexpr(tail, env) .. ")"
    end
  end
  -- General large literal data (catches embedded source trees in stlib etc.)
  local k = try_lit_const(form, env)
  if k then return k end
  if is_symbol(head) and not env[head.name] then
    local op = head.name
    if op == "if" or op == "cond" or op == "let" or op == "do"
       or op == "trap-error" or op == "and" or op == "or" then
      -- Control form in value position. The obvious codegen wraps the tail
      -- compilation in an IIFE `(function() ... end)()`, but that closure
      -- captures every in-scope local it references (6-9 upvalues in the
      -- typechecker) and is re-allocated on EVERY evaluation -- measured at
      -- ~1490 bytes/inference, 64% of all typechecker allocation.
      --
      -- Instead, hoist the body to a *constant* function that takes its free
      -- variables as parameters (same KB-table mechanism as `freeze`), and
      -- call it. A nested function with no upvalues is created once at chunk
      -- load, not per evaluation, so this allocates nothing per call. Compile
      -- the body FIRST so any nested freezes/control-forms claim lower KB
      -- indices before we take ours.
      if CTX then
        local fv = {}
        collect_free(form, env, {}, fv)
        local lnames = {}
        for kname in pairs(fv) do lnames[#lnames+1] = env[kname] end
        table.sort(lnames)
        local params = table.concat(lnames, ", ")
        -- Compile the body FIRST so nested freezes/control-forms claim their KC
        -- indices before we take ours. The body references only its param free
        -- vars, globals, and KC (a load-time upvalue) -- never an impl local --
        -- so this stays a constant function with no per-call FNEW.
        -- Clear SELF: this body becomes a SEPARATE Lua function (KC[i]), so a
        -- self-call in here is not in impl's tail position and a `goto tco`
        -- would illegally cross the function boundary.
        local saved_self = SELF
        SELF = nil
        local body_stmts = ctail(form, env)
        SELF = saved_self
        local idx = #CTX.cbodies + 1
        CTX.cbodies[idx] = "function(" .. params .. ") " .. body_stmts .. " end"
        return "KC[" .. idx .. "](" .. params .. ")"
      end
      -- No per-defun context (top-level eval chunk): fall back to the IIFE.
      -- (Clear SELF here too: the IIFE is a separate function.)
      local saved_self = SELF
      SELF = nil
      local body_stmts = ctail(form, env)
      SELF = saved_self
      return "(function() " .. body_stmts .. " end)()"
    end
    -- For ordinary calls, opportunistically let-float a trailing let argument
    -- so that nested continuation-passing chains compile flat.
    local floated = try_let_float(form, env)
    if floated then return cexpr(floated, env) end
    if op == "lambda" then
      local v = car(cdr(form))
      local body = car(cdr(cdr(form)))
      local ln = gen("v")
      local e2 = extend(env, v.name, ln)
      return "MKFUN(1, function(" .. ln .. ") return " .. cexpr(body, e2) .. " end)"
    elseif op == "freeze" then
      local body = car(cdr(form))
      if CTX then
        -- Hoist the freeze body to the chunk-scope KC table (a constant function
        -- built once at load), abstracting its free vars as params; BIND snapshots
        -- the current captures into a thunk at the use site. Putting the body in
        -- KC rather than a per-impl-call table means the function literal is
        -- created ONCE, not on every call to the enclosing defun -- which in the
        -- recursive typechecker was a major per-inference allocation source.
        local fv = {}
        collect_free(body, env, {}, fv)
        local lnames = {}
        for kname in pairs(fv) do lnames[#lnames+1] = env[kname] end
        table.sort(lnames)  -- stable order for caller / body
        local body_str = cexpr(body, env)
        local idx = #CTX.cbodies + 1
        CTX.cbodies[idx] = "function(" .. table.concat(lnames, ", ") .. ") return "
                           .. body_str .. " end"
        local call_args = (#lnames == 0) and "" or (", " .. table.concat(lnames, ", "))
        return "BIND(KC[" .. idx .. "]" .. call_args .. ")"
      end
      return "MKFUN(0, function() return " .. cexpr(body, env) .. " end)"
    elseif op == "defun" then
      error("defun in expression position")
    elseif op == "type" then
      -- (type EXPR TYPE) : types erased at KL boundary -> just the expr
      return cexpr(car(cdr(form)), env)
    else
      return ccall(form, env)
    end
  else
    return ccall(form, env)
  end
end

-- ------------------------------------------------------------------
-- ctail : tail position (emits statements; control-flow returns)
-- ------------------------------------------------------------------
function ctail(form, env)
  if not is_cons(form) then
    return "return " .. (type(form)=="number" and cnum(form) or catom(form, env))
  end
  local head = car(form)
  if is_symbol(head) and not env[head.name] then
    local op = head.name
    if op == "if" then
      local test = car(cdr(form))
      local th   = car(cdr(cdr(form)))
      local el   = car(cdr(cdr(cdr(form)))) -- may be missing
      local s = "if (" .. cexpr(test, env) .. ") then " .. ctail(th, env)
      if is_cons(cdr(cdr(cdr(form)))) then
        s = s .. " else " .. ctail(el, env) .. " end"
      else
        s = s .. " else return false end"
      end
      return s
    elseif op == "cond" then
      -- (cond (test res) ... )
      local clauses = to_array(cdr(form))
      local parts = {}
      for i=1,#clauses do
        local cl = clauses[i]
        local test = car(cl)
        local res  = car(cdr(cl))
        if i == 1 then
          parts[#parts+1] = "if (" .. cexpr(test, env) .. ") then " .. ctail(res, env)
        else
          parts[#parts+1] = " elseif (" .. cexpr(test, env) .. ") then " .. ctail(res, env)
        end
      end
      parts[#parts+1] = " else return ERR(\"cond failure\") end"
      return table.concat(parts)
    elseif op == "let" then
      local v   = car(cdr(form))
      local val = car(cdr(cdr(form)))
      local body= car(cdr(cdr(cdr(form))))
      local ln = gen("v")
      local valc = cexpr(val, env)
      local e2 = extend(env, v.name, ln)
      return "local " .. ln .. " = " .. valc .. "; " .. ctail(body, e2)
    elseif op == "do" then
      local forms = to_array(cdr(form))
      local s = {}
      for i=1,#forms-1 do
        local es = cexpr(forms[i], env)
        -- Always turn intermediate do values into a statement via IIFE.
        -- This is guaranteed valid Lua syntax for any expression (var, call, etc.)
        -- and introduces no new named locals in the enclosing function scope.
        -- Critical for giant do-chains in 41.2 stlib.initialise-* and
        -- shen.initialise-lambda-forms.
        s[#s+1] = "(function() return " .. es .. " end)();"
      end
      s[#s+1] = ctail(forms[#forms], env)
      return table.concat(s, " ")
    elseif op == "and" then
      local a = car(cdr(form)); local b = car(cdr(cdr(form)))
      return "if (" .. cexpr(a, env) .. ") then " .. ctail(b, env) .. " else return false end"
    elseif op == "or" then
      local a = car(cdr(form)); local b = car(cdr(cdr(form)))
      return "if (" .. cexpr(a, env) .. ") then return true else " .. ctail(b, env) .. " end"
    elseif op == "trap-error" then
      local expr = car(cdr(form))
      local handler = car(cdr(cdr(form)))
      -- (trap-error E H): if E raises a Shen exception, apply H to it.
      local hc = cexpr(handler, env)
      return "local ok,res = pcall(function() return " .. cexpr(expr, env)
             .. " end); if ok then return res else return APP(" .. hc .. ", TOEXCN(res)) end"
    elseif op == "type" then
      return ctail(car(cdr(form)), env)
    elseif op == "lambda" or op == "freeze" then
      return "return " .. cexpr(form, env)
    else
      local floated = try_let_float(form, env)
      if floated then return ctail(floated, env) end
      -- try_flatten_call_chain BEFORE try_self_tail: a >=16-deep last-arg
      -- chain must still flatten (parser nesting limit); it then keeps an
      -- ordinary tail call for the outer frame, which is always correct.
      local flat = try_flatten_call_chain(form, env)
      if flat then return flat end
      local selfjump = try_self_tail(form, env)
      if selfjump then return selfjump end
      return "return " .. ccall(form, env)
    end
  else
    local floated = try_let_float(form, env)
    if floated then return ctail(floated, env) end
    local flat = try_flatten_call_chain(form, env)
    if flat then return flat end
    return "return " .. ccall(form, env)
  end
end

-- ------------------------------------------------------------------
-- top-level form compilation
-- ------------------------------------------------------------------
-- compile (defun NAME (PARAMS) BODY) -> Lua source registering into F-table.
local function cdefun(form)
  local name = car(cdr(form)).name
  local params = to_array(car(cdr(cdr(form))))
  local body = car(cdr(cdr(cdr(form))))
  local env = {}
  local lnames = {}
  for i=1,#params do
    local ln = gen("a")
    env[params[i].name] = ln
    lnames[i] = ln
  end
  C.ARITY[name] = #params
  local saved = CTX
  CTX = new_ctx()
  -- Self-tail-call -> loop lowering. Eligible unless:
  --   * the function is not PURELY tail-recursive -- some self-reference is a
  --     non-tail call, a partial application, or sits in a tail self-call's
  --     own arguments (see pure_tail_self: mixed lowering measurably regresses
  --     LuaJIT tracing, tak 2.1x), or
  --   * some lambda in the body closes over a param (its MKFUN upvalue would
  --     alias the mutating loop local; see lambda_captures_param), or
  --   * the name is an inlined 2-arg arithmetic prim (a self-call today
  --     compiles to the ADD/SUB/... numeric fast path, NOT a recursive call;
  --     lowering would change that pre-existing behavior).
  -- Semantics note: a lowered tail self-call no longer re-reads F[name] each
  -- iteration, so a mid-recursion redefinition of the function (or a track/
  -- step wrapper installed around F[name]) is not observed by an already-
  -- running loop. Non-tail self-calls and APP/partial calls are unaffected.
  local saved_self = SELF
  if HAS_GOTO and not ARITH2[name] and pure_tail_self(body, name, #params, true)
     and not lambda_captures_param(body, env, {}) then
    SELF = { name = name, arity = #params, lnames = lnames, used = false }
  else
    SELF = nil
  end
  local body_src = ctail(body, env)
  local lowered = SELF ~= nil and SELF.used
  SELF = saved_self
  if lowered then
    -- `while true` (not a bare backward goto) so LuaJIT emits a real LOOP
    -- bytecode -- the natural trace anchor. ::tco:: sits at the end of the
    -- block ("continue" idiom): every `goto tco` re-enters the loop with the
    -- params already reassigned; all other paths `return` out. let-locals are
    -- declared inside the block, so closures over them are closed at each
    -- iteration boundary (fresh per iteration).
    body_src = "while true do " .. body_src .. " ::tco:: end"
  end
  -- Hoisted (freeze ...) bodies AND value-position control-form bodies both go
  -- into a single chunk-scope KC table, built ONCE at load -- NOT inside impl.
  -- Each KC entry is a constant function abstracting its free vars as params
  -- (BIND snapshots a freeze's captures at the use site; a control form is just
  -- called). Because the table and its function literals are created once rather
  -- than on every impl call, the recursive typechecker no longer re-allocates a
  -- freeze-body table per inference. The BIND(KC[i],...) / KC[i](...) use sites
  -- stay flat, so deep CPS chains still compile under Lua's syntax-level limit.
  --
  -- We MUST forward-declare `local KC` and assign on a separate line so a KC
  -- body that references KC[j] (a nested hoist) captures KC as an upvalue.
  local kc_init = ""
  if #CTX.cbodies > 0 then
    local parts = { "local KC; KC = {" }
    for i, b in ipairs(CTX.cbodies) do
      parts[#parts+1] = "[" .. i .. "] = " .. b .. (i == #CTX.cbodies and "" or ",")
    end
    parts[#parts+1] = "};"
    kc_init = table.concat(parts, " ") .. " "
  end
  CTX = saved
  local src = "do " .. kc_init
            .. "local function impl(" .. table.concat(lnames, ", ") .. ") "
            .. body_src .. " end "
            .. "F[" .. qstr(name) .. "] = impl; FA[impl] = " .. #params .. " end"
  return src
end
C.cdefun = cdefun

-- Pre-scan a list of forms to register arities of all defuns (so mutual /
-- forward references compile as direct exact-arity calls).
function C.prescan(forms)
  for _,f in ipairs(forms) do
    if is_cons(f) and is_symbol(car(f)) and car(f).name == "defun" then
      local name = car(cdr(f)).name
      local params = car(cdr(cdr(f)))
      C.ARITY[name] = len(params)
    end
  end
end

-- expose expression compiler + a returning-chunk helper for eval
C.cexpr = cexpr
C.ctail = ctail
function C.compile_expr_chunk(form)
  return "return (" .. cexpr(form, {}) .. ")"
end

-- compile any top-level form to a Lua statement string
function C.compile_top(form)
  if is_cons(form) and is_symbol(car(form)) and car(form).name == "defun" then
    return cdefun(form)
  else
    -- a top-level expression: evaluate for side effects. Wrapped in do..end
    -- so a whole kernel file can be concatenated into ONE chunk (boot.lua's
    -- bytecode cache) without accumulating `local _` slots toward Lua's
    -- 200-locals-per-scope limit.
    return "do local _ = " .. cexpr(form, {}) .. "; end"
  end
end

return C
