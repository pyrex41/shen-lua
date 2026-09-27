package.path = (arg[0]:gsub('test/[^/]*$', '')) .. '?.lua;' .. package.path
local P, R, C = require('boot'), require('runtime'), require('compiler')
P.load_kernel(false)
local n = 0
local function ev(s)
  local r
  for _,f in ipairs(R.read_all(s)) do r=P.eval(f) end
  return r
end
local cases = {
  {'(let F (lambda X (+ N X)) (F 3))', 10, true},
  {'((lambda X (+ X N)) 3)', 10, true},
  {'(let F (lambda X (+ N X)) (let N 99 (F 3)))', 10, true},
  {'(let F (lambda N (+ N 1)) (+ (F 2) (F 3)))', 7, true},
  {'(let F (lambda X (+ N X)) (let F (lambda X X) (F 3)))', 3, true},
  {'(let F (lambda X (+ N X)) ((lambda G (G 3)) F))', 10, false},
  {'(let F (lambda X (+ N X)) (thaw (freeze (F 3))))', 10, false},
  {'(let F (lambda X (lambda Y (+ X Y))) ((F 3) 4))', 7, false},
  {'(let F (lambda X (+ X 1)) (F (F 2)))', 4, true},
  {'(let F (lambda X (+ N X)) (do (set cs-f F) ((value cs-f) 3)))', 10, false},
  {'(let F (lambda X (do (set cs-count (+ 1 (value cs-count))) X)) (do (F 2) (F 3)))', 3, true},
  {'(let F (lambda X (<-address N 1)) (do (address-> N 1 42) (F 0)))', 42, true, '(absvector 2)'},
  {'(let F (lambda X (address-> N 1 X)) (let G (lambda X (<-address N 1)) (do (F 42) (G 0))))', 42, true, '(absvector 2)'},
  {'(let F (lambda X (+ X N)) (F (do (set cs-count 9) 3)))', 10, true},
  {'(let F (lambda X (lambda Y (+ X Y))) (F 3 4))', 7, false},
  {'(let F (lambda X (simple-error "unused")) 9)', 9, true},
}
for _,on in ipairs{false,true} do
  C.CLOSURES=on
  for i,t in ipairs(cases) do
    ev('(set cs-count 0)')
    local def='(defun cs-test (N) '..t[1]..')'
    local src=C.cdefun(R.read_all(def)[1])
    ev(def)
    assert(ev('(cs-test '..(t[4] or '7')..')')==t[2], 'value case '..i..' mode '..tostring(on))
    if on and t[3] then assert(not src:find('MKFUN',1,true),'allocation case '..i) end
    if i==11 then assert(ev('(value cs-count)')==2,'effects once per call') end
    n=n+1
  end
  -- Escaped closures from recursive iterations must retain distinct captures.
  ev('(defun cs-build (N) (if (= N 0) () (cons (lambda X (+ N X)) (cs-build (- N 1)))))')
  assert(ev('(let L (cs-build 3) (+ ((hd L) 0) ((hd (tl L)) 0)))')==5)
  n=n+1
  ev('(defun cs-delay (N) (let F (lambda X (simple-error "delayed")) (if (= N 0) 7 (F 1))))')
  assert(ev('(cs-delay 0)')==7)
  assert(not pcall(ev,'(cs-delay 1)'))
  ev('(defun cs-once (N) (let F (lambda X (+ X X)) (F (do (set cs-count (+ 1 (value cs-count))) N))))')
  ev('(set cs-count 0)')
  assert(ev('(cs-once 7)')==14 and ev('(value cs-count)')==1)
  -- Function identity remains observable when a closure is used as a value.
  ev('(defun cs-identity (N) (let F (lambda X N) (= F F)))')
  assert(ev('(cs-identity 7)')==true)
  n=n+3
end
-- Inspect analysis records, not just runtime results.
local IR=require('closure_ir')
local _,report=IR.optimize(R.read_all('(let F (lambda X (+ N X)) (F 3))')[1],{R.intern('N')})
assert(#report==1 and report[1].eliminated and report[1].calls==1 and report[1].captures[1]=='N')
n=n+1
print('closure_ir_spec: '..n..' pass, 0 fail')
