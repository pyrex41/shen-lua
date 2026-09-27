package.path=(arg[0]:gsub('test/[^/]*$',''))..'?.lua;'..package.path
local P,R,C=require('boot'),require('runtime'),require('compiler')
P.load_kernel(false)
local native=P.F.map
local function ev(s) return P.run_kl_string(s) end
local function show(x)
  if R.is_cons(x) then return '('..show(x[1])..' '..show(x[2])..')' end
  return x==R.NIL and 'nil' or tostring(x)
end
local n=0
local function check(x,label) assert(x,label); n=n+1 end
for _,on in ipairs{false,true} do
  C.MAP_CLOSURES=on; P.F.map=native; C.ARITY.map=2
  local def='(defun mc-add (N L) (map (lambda X (+ N X)) L))'
  local src=C.cdefun(R.read_all(def)[1]); ev(def)
  check((src:find('MAP_BASE',1,true)~=nil)==on,'guard shape')
  check(show(ev('(mc-add 7 (cons 1 (cons 2 ())))'))=='(8 (9 nil))','captured addition')
  check(ev('(mc-add 7 ())')==R.NIL,'empty')
  -- Returned element closures must capture distinct loop items.
  ev('(defun mc-return (N L) (map (lambda X (lambda Y (+ X N))) L))')
  check(ev('(let L (mc-return 7 (cons 1 (cons 2 ()))) (+ ((hd L) 0) ((hd (tl L)) 0)))')==17,'escaped per-item capture')
  -- Multiple calls share mutable captured state in left-to-right order.
  ev('(defun mc-state (V L) (map (lambda X (do (address-> V 1 (+ (<-address V 1) X)) (<-address V 1))) L))')
  check(show(ev('(let V (absvector 2) (do (address-> V 1 0) (mc-state V (cons 1 (cons 2 ())))))'))=='(1 (3 nil))','shared state')
  ev('(defun mc-effects (L) (map (lambda X (do (set mc-count (+ 1 (value mc-count))) X)) L))')
  ev('(set mc-count 0)')
  check(not pcall(ev,'(mc-effects (cons 1 (cons 2 99)))'),'improper list fails')
  check(ev('(value mc-count)')==2,'improper tail never replays prefix')
  ev('(set mc-count 0)')
  ev('(defun mc-raise (L) (map (lambda X (do (set mc-count (+ 1 (value mc-count))) (if (= X 2) (simple-error "stop") X))) L))')
  check(not pcall(ev,'(mc-raise (cons 1 (cons 2 (cons 3 ()))))'),'callback raises')
  check(ev('(value mc-count)')==2,'stop at throwing callback')
  -- Dynamic redefinition: replacement may store and later invoke the callback.
  local saved
  P.F.map=function(f,l) saved=f; return P.APP(f,10) end
  P.FA[P.F.map]=2
  check(ev('(mc-add 7 ())')==17,'replacement consumer')
  check(P.APP(saved,20)==27,'replacement can retain callback')
  P.F.map=native
  -- Callee selection follows existing compiler entry-time lookup even if the
  -- list-producing expression changes F.map before the call.
  P.F['mc-list']=function() P.F.map=function() return 999 end; P.FA[P.F.map]=2; return R.cons(3,R.NIL) end
  P.FA[P.F['mc-list']]=0; C.ARITY['mc-list']=0
  ev('(defun mc-select (N) (map (lambda X (+ X N)) (mc-list)))')
  check(show(ev('(mc-select 7)'))=='(10 nil)','callee evaluation order')
  check(ev('(mc-select 7)')==999,'later invocation sees replacement')
  P.F.map=native
  local base=P.ENV.MAP_BASE
  P.ENV.MAP_BASE=nil; P.F.map=nil
  check(not pcall(ev,'(mc-add 7 ())'), 'absent consumer is not native')
  P.ENV.MAP_BASE=base; P.F.map=native
  ev('(defun mc-nested (A B) (map (lambda X (map (lambda Y (+ X Y)) B)) A))')
  check(show(ev('(mc-nested (cons 1 (cons 2 ())) (cons 10 (cons 20 ())))'))=='((11 (21 nil)) ((12 (22 nil)) nil))', 'nested specialized captures')
  ev('(defun mc-shadow (map N L) (map (lambda X (+ N X)) L))')
  check(P.F['mc-shadow'](function(f) return P.APP(f,10) end,7,R.NIL)==17, 'lexically shadowed consumer')
  local bounded=C.cdefun(R.read_all('(defun mc-bound (A B C D E F G H I L) (map (lambda X (nine A B C D E F G H I X)) L))')[1])
  check(not bounded:find('MAP_BASE',1,true), 'capture budget fallback')
  -- Unknown callback is deliberately outside the specialization.
  local unknown=C.cdefun(R.read_all('(defun mc-unknown (F L) (map F L))')[1])
  check(not unknown:find('MAP_BASE',1,true),'unknown callback fallback')
end
print('map_closure_spec: '..n..' pass, 0 fail')
