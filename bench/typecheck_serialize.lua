local R = require("runtime")
local Symbol, Cons, Vmt, NIL = R.Symbol, R.Cons, R.Vmt, R.NIL
local shen_pvar = R.intern("shen.pvar")
local getmt = getmetatable

local function ser(x, env)
  if x == NIL then return "()" end
  local t = type(x)
  if t == "boolean" then return tostring(x) end
  if t == "number" then return string.format("%.17g", x) end
  if t == "string" then return string.format("%q", x) end
  if t == "function" then return "#<fn>" end
  local mt = getmt(x)
  if mt == Symbol then return x.name end
  if mt == Cons then
    return "(" .. ser(x[1], env) .. " . " .. ser(x[2], env) .. ")"
  end
  if mt == Vmt then
    if x[2] == shen_pvar then
      local n = env[x]
      if not n then n = env.n + 1; env.n = n; env[x] = n end
      return "?" .. n
    end
    local parts = {}
    for i = 1, (x[1] or 0) + 1 do parts[i] = ser(x[i + 1], env) end
    return "#(" .. table.concat(parts, " ") .. ")"
  end
  return "#<obj>"
end

local function serialize(x)
  return ser(x, { n = 0 })
end


return serialize
