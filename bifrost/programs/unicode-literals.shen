\\ unicode-literals.shen -- issue #80: a non-ASCII string LITERAL in a UTF-8
\\ source file reads as its characters, prints back byte-identical, and agrees
\\ with the same string built from code points.
(define u.check Name Got Want ->
  (do (output "~A ~A~%" Name (if (= Got Want) ok [Got /= Want])) ok))

(u.check literal-length (length (explode "Zürich")) 6)
(u.check literal-string->n (string->n "ü") 252)
(u.check literal-euro (string->n "€") 8364)
(u.check literal-equals-built (= "ü" (n->string 252)) true)
(u.check literal-pos (pos "Zürich" 1) (n->string 252))
(u.check literal-tlstr (tlstr "üx") "x")
(u.check literal-hash (hash "ü" 1000) 252)
(u.check control-escape (= "c#252;" "ü") true)
(output "~A~%" "Grüße, Zoë: 5 €")
