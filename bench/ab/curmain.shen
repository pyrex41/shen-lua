(load "curlib.shen")
(define use3 N Acc -> (if (= N 0) Acc (use3 (- N 1) (lib3 Acc 1 N))))
(define timed Name F -> (let T0 (get-time run) R (thaw F) T1 (get-time run)
                          (output "~A: ~A~%" Name (- T1 T0))))
(timed "library call from a loading file x1M" (freeze (use3 1000000 0)))

