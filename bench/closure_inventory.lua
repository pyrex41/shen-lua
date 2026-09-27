-- luajit bench/closure_inventory.lua klambda/*.kl
local R, IR = require('runtime'), require('closure_ir')
local functions, candidates, eliminated, escaping = 0, 0, 0, 0
for _,path in ipairs(arg) do
  local f=assert(io.open(path)); local source=f:read('*a'); f:close()
  for _,form in ipairs(R.read_all(source)) do
    if R.is_cons(form) and R.is_symbol(form[1]) and form[1].name=='defun' then
      local params={}; local p=form[2][2][1]
      while R.is_cons(p) do params[#params+1]=p[1]; p=p[2] end
      local _,records=IR.optimize(form[2][2][2][1],params)
      functions=functions+1
      for _,r in ipairs(records) do
        candidates=candidates+1
        if r.eliminated then
          eliminated=eliminated+1
          print('eliminated '..form[2][1].name..' kind='..r.kind..' calls='..r.calls)
        end
        if r.escapes then escaping=escaping+1 end
      end
    end
  end
end
print(string.format('defuns=%d candidates=%d eliminated=%d escaping_or_deferred=%d',functions,candidates,eliminated,escaping))
