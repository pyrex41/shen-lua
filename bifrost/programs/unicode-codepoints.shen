\\ unicode-codepoints.shen -- issue #80: strings are sequences of Unicode
\\ code points. Every non-ASCII string here is BUILT with n->string, so the
\\ result does not depend on how a port's reader decodes source bytes.
\\ Output is ASCII only (codes and lengths), one token per line.
(define u.zurich -> (cn "Z" (cn (n->string 252) "rich")))
(define u.check Name Got Want ->
  (do (output "~A ~A~%" Name (if (= Got Want) ok [Got /= Want])) ok))

(u.check n->string-252-is-one-char (length (explode (n->string 252))) 1)
(u.check n->string-8364-is-one-char (length (explode (n->string 8364))) 1)
(u.check n->string-128512-is-one-char (length (explode (n->string 128512))) 1)
(u.check string->n-252 (string->n (n->string 252)) 252)
(u.check string->n-8364 (string->n (n->string 8364)) 8364)
(u.check string->n-1114111 (string->n (n->string 1114111)) 1114111)
(u.check pos-1 (string->n (pos (u.zurich) 1)) 252)
(u.check pos-5 (pos (u.zurich) 5) "h")
(u.check tlstr (tlstr (cn (n->string 252) "x")) "x")
(u.check hdstr (string->n (hdstr (cn (n->string 8364) "uro"))) 8364)
(u.check explode-length (length (explode (u.zurich))) 6)
(u.check explode-codes (map (/. C (string->n C)) (explode (u.zurich))) [90 252 114 105 99 104])
(u.check hash-built-twice (= (hash (n->string 252) 1000) (hash (cn "" (n->string 252)) 1000)) true)
(u.check hash-agrees-with-= (= (hash (u.zurich) 99991) (hash (cn (cn "Z" (n->string 252)) "rich") 99991)) (= (u.zurich) (cn (cn "Z" (n->string 252)) "rich")))
(u.check equal-built (= (n->string 252) (cn "" (n->string 252))) true)
(u.check not-equal-bytes (= (u.zurich) "Zurich") false)
(u.check put-get (do (put (u.zurich) city yes) (get (cn "Z" (cn (n->string 252) "rich")) city)) yes)
(u.check at-s-pattern ((/. S (length (explode S))) (@s (n->string 252) (n->string 223))) 2)
