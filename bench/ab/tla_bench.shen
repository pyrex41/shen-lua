\* Scale the election example and time tla.check. From lib/tla:
     <shen> script bench/election.shen
   Set *tla-native* first to use a port's native map. *\

(load "tla.shen")
(if (bound? *tla-native*) (load (value *tla-native*)) skip)
(load "examples/election.shen")

(define bench.run
  Cs Q -> (let Skip1 (set *computers* Cs)
               Skip2 (set *quorum* Q)
               T0 (get-time run)
               R (tla.check (election.init) (fn election.next)
                            [[deadlock false] [invariant one-leader (fn election.one-leader?)]])
               T1 (get-time run)
             (output "c~A (~A states): ~A~%"
                     (length Cs) (hd (tl R)) (- T1 T0))))

(bench.run [a b c] 2)
(bench.run [a b c d] 3)
(bench.run [a b c d e] 3)
(bench.run [a b c d e f] 4)
(bench.run [a b c d e f g] 4)
