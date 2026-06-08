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
local function cnum(n)
  if n == math.floor(n) and n ~= math.huge and n ~= -math.huge then
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
        return ftab_ref(name) .. "(" .. argstr .. ")"
      elseif #args < ar then
        -- partial application
        local pack = (#args == 0) and "{}" or ("{" .. argstr .. "}")
        return "PARTIAL(" .. ftab_ref(name) .. ", " .. ar .. ", " .. pack .. ")"
      else
        -- over-application: apply arity, then APP the rest
        local first = {}
        for i=1,ar do first[i]=cargs[i] end
        local rest = {}
        for i=ar+1,#args do rest[#rest+1]=cargs[i] end
        return "APP(" .. ftab_ref(name) .. "(" .. table.concat(first,", ") .. "), "
                       .. table.concat(rest, ", ") .. ")"
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

-- General literal data hoisting for arbitrary cons trees (e.g. embedded source
-- forms passed to shen.record-kl in 41.1 stlib, giant tables, etc.).
-- Any tree of cons cells + atoms + unbound symbols is "literal data".
local function is_lit(form, env)
  local t = type(form)
  if t=="number" or t=="string" or t=="boolean" then return true end
  if form == NIL then return true end
  if is_symbol(form) then return not env[form.name] end
  if is_cons(form) then
    return is_lit(form[1], env) and is_lit(form[2], env)
  end
  return false
end
local function lit_count(form)
  if not is_cons(form) then return 1 end
  return 1 + lit_count(form[1]) + lit_count(form[2])
end
local function try_lit_const(form, env)
  if not is_cons(form) then return nil end
  if not is_lit(form, env) then return nil end
  local n = lit_count(form)
  if n >= 24 then
    local idx = #C.KDATA + 1
    C.KDATA[idx] = form   -- the runtime cons tree is the value; safe to share
    return "KDATA[" .. idx .. "]"
  end
  return nil
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
      -- control form in value position: wrap tail compilation in an IIFE
      return "(function() " .. ctail(form, env) .. " end)()"
    elseif op == "lambda" then
      local v = car(cdr(form))
      local body = car(cdr(cdr(form)))
      local ln = gen("v")
      local e2 = extend(env, v.name, ln)
      return "MKFUN(1, function(" .. ln .. ") return " .. cexpr(body, e2) .. " end)"
    elseif op == "freeze" then
      local body = car(cdr(form))
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
        -- Critical for giant do-chains in 41.1 stlib.initialise-* and
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
      return "return " .. ccall(form, env)
    end
  else
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
  local src = "do local function impl(" .. table.concat(lnames, ", ") .. ") "
            .. ctail(body, env) .. " end "
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
    -- a top-level expression: evaluate for side effects
    return "local _ = " .. cexpr(form, {}) .. ";"
  end
end

return C
