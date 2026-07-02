\\ configc_broken.shen — configc with ONE planted generator bug, to show the
\\ typechecker rejecting it at load (the tier-a guarantee). The bug: the nginx
\\ generator feeds the numeric Port straight to `cn`, which is
\\ {string --> string --> string}. In an untyped templating language this is a
\\ runtime crash (or a silently wrong config file) the first time you generate;
\\ here `load` under (tc +) refuses the file before any config is compiled.

(datatype val
  X : string;
  ============
  [s X] : val;

  X : number;
  ============
  [n X] : val;

  Es : (list entry);
  ==================
  [obj Es] : val;)

(datatype entry
  K : string; V : val;
  ====================
  [K V] : entry;)

(define find-val
  {string --> (list entry) --> (list val)}
  _ [] -> []
  K [[K V] | _] -> [V]
  K [_ | Es] -> (find-val K Es))

(define get-num
  {number --> string --> (list entry) --> number}
  D K Es -> (num-or D (find-val K Es)))

(define num-or
  {number --> (list val) --> number}
  D []      -> D
  _ [[n N]] -> N
  D [_]     -> D)

\\ THE BUG: Port is a number; cn wants a string. (str Port) is the fix.
(define bad-listen
  {(list entry) --> string}
  Es -> (cn "    listen " (get-num 80 "port" Es)))
