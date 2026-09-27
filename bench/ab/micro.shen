\\ Targeted micro suite: one case per change. Every hot loop is a define'd
\\ function called once from toplevel, so no toplevel-lambda overhead.
(define fwd-caller N Acc -> (if (= N 0) Acc (fwd-caller (- N 1) (fwd-callee Acc N))))
(define fwd-callee A B -> (+ A 1))

(define do-loop N Acc -> (if (= N 0) Acc (do-loop (- N 1) (do (set micro-x N) (+ Acc 1)))))

(define eq-loop N A B C -> (if (= N 0) C (eq-loop (- N 1) A B (if (= A B) (+ C 1) C))))
(define mk N -> (if (= N 0) [] [[N a] | (mk (- N 1))]))

(define upto N M -> (if (> N M) [] [N | (upto (+ N 1) M)]))
(define incs L -> (if (cons? L) [(+ 1 (hd L)) | (incs (tl L))] []))
(define rep-incs N L -> (if (= N 0) done (do (incs L) (rep-incs (- N 1) L))))
(define set-nth
  1 V [_ | Xs] -> [V | Xs]
  N V [X | Xs] -> [X | (set-nth (- N 1) V Xs)])
(define rep-setnth N L -> (if (= N 0) done (do (set-nth 7 x L) (rep-setnth (- N 1) L))))

(define timed Name F -> (let T0 (get-time run) R (thaw F) T1 (get-time run)
                          (output "~A: ~A~%" Name (- T1 T0))))

(timed "fwd-ref call x3M" (freeze (fwd-caller 3000000 0)))
(timed "do in loop x3M" (freeze (do-loop 3000000 0)))
(set micro-a (mk 50))
(set micro-b (mk 50))
(timed "= on 50-elt lists x200k" (freeze (eq-loop 200000 (value micro-a) (value micro-b) 0)))
(set micro-l1000 (upto 1 1000))
(timed "map-shaped builder 1000 x2000" (freeze (rep-incs 2000 (value micro-l1000))))
(set micro-l8 (upto 1 8))
(timed "set-nth 7 of 8 x1M" (freeze (rep-setnth 1000000 (value micro-l8))))
