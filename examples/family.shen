\\ family.shen — Shen Prolog in twenty lines: facts, rules, queries.
\\
\\   bin/shen examples/family.shen
\\
\\ defprolog clauses compile onto the native soa32 engine; queries run
\\ through (prolog? ...), with (return ...) to extract bindings.

(defprolog parent
  abraham isaac <--;
  isaac jacob <--;
  jacob joseph <--;
  jacob benjamin <--;)

(defprolog ancestor
  X Y <-- (parent X Y);
  X Z <-- (parent X Y) (ancestor Y Z);)

(output "abraham is an ancestor of joseph: ~A~%"
        (prolog? (ancestor abraham joseph)))

(output "joseph is an ancestor of abraham: ~A~%"
        (prolog? (ancestor joseph abraham)))

(output "a child of jacob: ~A~%"
        (prolog? (parent jacob Child) (return Child)))

(output "an ancestor of benjamin: ~A~%"
        (prolog? (ancestor Anc benjamin) (return Anc)))
