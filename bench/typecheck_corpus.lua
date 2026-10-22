-- Repository-owned community 43.1 applications; hashes in fixtures.sha256.
-- Explicit types prevent the interpreter's primitive-object rules from turning
-- malformed arithmetic into an unrelated successful inferred judgment.
return {
  { name='core', cases={
    {'number', '5', 'number'},
    {'identity', '(/. X X)', '(A --> A)'},
    {'nested-hypotheses', '(/. F (/. X (F (F X))))', '((A --> A) --> (A --> A))'},
    {'shadowing', '(let X 1 (let X "s" X))', 'string'},
    {'map', '(map (/. X (* X X)) [1 2 3])', '(list number)'},
    {'reject-arithmetic', '(+ 1 "a")', 'number', false},
    {'reject-condition', '(if 1 2 3)', 'number', false},
    {'reject-branches', '(if true 1 "s")', 'number', false},
  }},
  { name='interpreter', fixture='tests/interpreter.shen', cases={
    {'interpreter-y', '[[[y-combinator [/. ADD [/. X [/. Y [if [= X 0] Y [[ADD [-- X]] [++ Y]]]]]]] 3] 4]', '(list l-formula)'},
    {'interpreter-y-inferred', '[[[y-combinator [/. ADD [/. X [/. Y [if [= X 0] Y [[ADD [-- X]] [++ Y]]]]]]] 3] 4]', 'A', true, '(list . (l-formula . ()))'},
    {'interpreter-nested', '[let X [++ 3] [if [= X 4] X 0]]', 'l-formula'},
    {'interpreter-call', '(normal-form [cons 1 []])', 'l-formula'},
    {'interpreter-reject', '(normal-form [cons 1 []])', 'number', false},
  }},
  { name='calculator', fixture='tests/calculator.shen', cases={
    {'calculator-tree', '[[num 2] + [[num 3] * [num 4]]]', 'arith-expr'},
    {'calculator-call', '(do-calculation [[num 2] + [num 3]])', 'number'},
    {'calculator-reject-leaf', '[num "bad"]', 'arith-expr', false},
    {'calculator-reject-operator', '[[num 2] bogus [num 3]]', 'arith-expr', false},
  }},
  { name='parser', fixture='bench/fixtures/parser.shen', cases={
    {'parser-function', '(fn <sent>)', '((list symbol) --> (str (list symbol) (list symbol)))'},
    {'parser-call', '(<sent> [the cat likes bill])', '(str (list symbol) (list symbol))'},
    {'parser-reject', '(<sent> [the cat likes bill])', 'number', false},
  }},
}
