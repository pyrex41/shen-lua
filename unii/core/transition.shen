\* unii/core/transition.shen -- pure event handling and command generation.

   (unii.transition State Event) --> [result State' Commands Decisions]

   Config lives inside State and is immutable within an epoch. The function
   reads no clock, filesystem, network or randomness; everything it learns
   arrives in the event. While a transition runs, commands and decisions are
   accumulated in reverse inside a result record and reversed at the end. *\

(define unii.init
  {unii.config --> unii.state}
  Cf -> (unii.mk-state Cf 0 0 [] 0 [] [] false 0 0)
    where (empty? (unii.config-errors Cf))
  Cf -> (error "unii.init: invalid configuration: ~A" (head (unii.config-errors Cf))))

(define unii.transition
  {unii.state --> unii.event --> unii.result}
  S [message-appended M Kd D C] -> (unii.finish (unii.on-message S M Kd D C))
  S [summary-completed J A B H T] -> (unii.finish (unii.on-completed S J A B H T))
  S [summary-failed J A C] -> (unii.finish (unii.on-failed S J A C))
  S [summary-uncertain J A R] -> (unii.finish (unii.on-uncertain S J A R))
  S [operator-retry J] -> (unii.finish (unii.on-operator-retry S J)))

(define unii.finish
  {unii.result --> unii.result}
  [result S Cs Ds] -> [result S (reverse Cs) (reverse Ds)])

\\ ------------------------------------------------------- state plumbing

(define unii.with-tree
  {unii.state --> number --> number --> (list unii.node) --> number --> (list unii.node)
   --> unii.state}
  [state Cf _ Js Ct] T Cv V VB Lv -> [state Cf [tree T Cv V VB Lv] Js Ct])

(define unii.with-live
  {unii.state --> (list unii.node) --> unii.state}
  S Lv -> (unii.with-tree S (unii.st-count S) (unii.st-covered S) (unii.st-view S)
                          (unii.st-view-bytes S) Lv))

(define unii.with-count
  {unii.state --> number --> unii.state}
  S T -> (unii.with-tree S T (unii.st-covered S) (unii.st-view S)
                         (unii.st-view-bytes S) (unii.st-live S)))

(define unii.with-jobs
  {unii.state --> (list unii.job) --> unii.state}
  [state Cf Tr _ Ct] Js -> [state Cf Tr Js Ct])

(define unii.with-counters
  {unii.state --> boolean --> number --> number --> unii.state}
  [state Cf Tr Js _] Bt R NC -> [state Cf Tr Js [counters Bt R NC]])

(define unii.decide
  {unii.decision --> unii.result --> unii.result}
  D [result S Cs Ds] -> [result S Cs [D | Ds]])

\\ Allocate the next command id and emit a client event.
(define unii.emit
  {unii.client-event --> unii.result --> unii.result}
  E [result S Cs Ds] ->
    (let NC (unii.st-next-cmd S)
      [result (unii.with-counters S (unii.st-batch S) (unii.st-rev S) (+ NC 1))
              [[emit-client-event (unii.command-id NC) E] | Cs] Ds]))

(define unii.reject
  {unii.state --> string --> unii.result}
  S R -> (unii.emit [input-rejected R] [result S [] [[event-rejected R]]]))

(define unii.built-nodes
  {unii.state --> (list unii.node)}
  S -> (append (unii.st-view S) (unii.st-live S)))

(define unii.leaf-job-count
  {unii.state --> number}
  S -> (unii.count-jobs (/. J (unii.leaf-job? J)) (unii.st-jobs S)))

\\ ---------------------------------------------------- message appended

(define unii.message-errors
  {unii.state --> number --> symbol --> string --> unii.content --> (list string)}
  S M Kd D [content B H _] ->
    (let Cf (unii.st-config S)
      (unii.collect-errors
        [(@p (= M (unii.st-count S)) "message id out of sequence")
         (@p (< (unii.st-count S) (unii.max-id)) "message id ceiling reached")
         (@p (unii.valid-kind? Kd) "unknown message kind")
         (@p (unii.non-empty? D) "missing message date")
         (@p (and (unii.nat? B) (<= B (unii.cf-chunk-max Cf))) "content bytes outside [0, chunk max]")
         (@p (unii.hex64? H) "content hash is not 64 lowercase hex digits")
         (@p (or (<= (unii.leaf-text-bytes Kd B) (unii.cf-cap Cf))
                 (< (unii.leaf-job-count S) (unii.cf-max-frontier Cf)))
             "unresolved message backlog is full")])))

(define unii.on-message
  {unii.state --> number --> symbol --> string --> unii.content --> unii.result}
  S M Kd D C -> (unii.accept-message S M Kd C)
    where (empty? (unii.message-errors S M Kd D C))
  S M Kd D C -> (unii.reject S (head (unii.message-errors S M Kd D C))))

(define unii.accept-message
  {unii.state --> number --> symbol --> unii.content --> unii.result}
  S M Kd [content B H Txt] ->
    (let S1 (unii.with-count S (+ M 1))
         LB (unii.leaf-text-bytes Kd B)
         Cf (unii.st-config S)
      (unii.settle S
        (if (<= LB (unii.cf-cap Cf))
            (unii.commit-node (unii.make-node (unii.leaf-key M) (unii.leaf-text Kd Txt) LB [exact-leaf])
                              [result S1 [] []])
            (unii.add-job (unii.new-job Cf [leaf-source M Kd H])
                          [result S1 [] []])))))

(define unii.add-job
  {unii.job --> unii.result --> unii.result}
  J [result S Cs Ds] ->
    [result (unii.with-jobs S (unii.insert-job J (unii.st-jobs S))) Cs
            [[job-created (unii.job-id J)] | Ds]])

\\ Record a newly built node, then build its parent if the sibling is built:
\\ losslessly when the joined text fits the cap, otherwise through a job.
(define unii.commit-node
  {unii.node --> unii.result --> unii.result}
  N Acc -> (unii.after-commit N (unii.place-node N Acc)))

\\ Put a node into the tree. A provisional node with the same key is replaced
\\ where it stands: in the view (keeping coverage) or in Live.
(define unii.place-node
  {unii.node --> unii.result --> unii.result}
  N [result S Cs Ds] ->
    (let K (unii.node-key N)
         D [node-committed K (unii.node-origin N) (unii.node-bytes N)]
         Old (unii.find-node K (unii.st-view S))
      (if (empty? Old)
          [result (unii.with-live S [N | (unii.remove-node K (unii.st-live S))]) Cs [D | Ds]]
          [result (unii.with-tree S (unii.st-count S) (unii.st-covered S)
                                  (unii.replace-node N (unii.st-view S))
                                  (+ (- (unii.st-view-bytes S) (unii.node-line-bytes (head Old)))
                                     (unii.node-line-bytes N))
                                  (unii.st-live S))
                  Cs [[view-replaced K] D | Ds]])))

(define unii.after-commit
  {unii.node --> unii.result --> unii.result}
  N Acc -> Acc where (unii.provisional? N)
  N [result S Cs Ds] ->
    (let K (unii.node-key N)
         P (unii.parent K)
         Sib (unii.find-real-node (unii.sibling K) (unii.built-nodes S))
      (if (or (empty? Sib)
              (or (not (unii.valid-key? P))
                  (or (unii.has-node? P (unii.built-nodes S))
                      (unii.has-job-for-key? P (unii.st-jobs S)))))
          [result S Cs Ds]
          (if (unii.left-child? K)
              (unii.build-parent N (head Sib) [result S Cs Ds])
              (unii.build-parent (head Sib) N [result S Cs Ds])))))

(define unii.build-parent
  {unii.node --> unii.node --> unii.result --> unii.result}
  A B Acc ->
    (let JB (unii.join-bytes (unii.node-bytes A) (unii.node-bytes B))
         Cf (unii.st-config (unii.acc-state Acc))
      (if (<= JB (unii.cf-cap Cf))
          (unii.commit-node
            (unii.make-node (unii.parent (unii.node-key A))
                            (unii.join-text (unii.node-text A) (unii.node-text B)) JB [joined])
            Acc)
          (unii.add-job
            (unii.new-job Cf [merge-source (unii.node-key A) (unii.node-key B)
                                           (unii.merge-token (unii.node-text A) (unii.node-text B))])
            Acc))))

(define unii.acc-state {unii.result --> unii.state} [result S _ _] -> S)

\\ --------------------------------------------------- summary outcomes

(define unii.on-completed
  {unii.state --> string --> number --> number --> string --> string --> unii.result}
  S J A B H T -> (unii.completed-job S (unii.find-job J (unii.st-jobs S)) J A B H T))

(define unii.completed-job
  {unii.state --> (list unii.job) --> string --> number --> number --> string --> string
   --> unii.result}
  S [] J _ _ _ _ -> [result S [] [[completion-ignored J "unknown or already completed job"]]]
  S [Job] J _ _ _ _ -> [result S [] [[completion-ignored J "job is not dispatched"]]]
    where (not (unii.dispatched? Job))
  S [Job] J A _ _ _ -> [result S [] [[completion-ignored J "attempt does not match job"]]]
    where (not (= A (unii.job-attempt Job)))
  S _ _ _ B H _ -> (unii.reject S "summary bytes or hash invalid")
    where (not (and (unii.pos-nat? B) (unii.hex64? H)))
  S [Job] J A B _ T -> (unii.settle S (unii.on-fit Job [candidate J A B T] [result S [] []]))
    where (<= B (unii.cf-cap (unii.st-config S)))
  S [Job] _ _ B _ _ -> (unii.settle S (unii.after-try Job (unii.job-best Job) [retry-too-long B]
                                                      [result S [] []])))

\\ A summary within the cap is a candidate. The job keeps the shortest
\\ (earliest on equal length) and still runs the rest of its round.
(define unii.on-fit
  {unii.job --> unii.candidate --> unii.result --> unii.result}
  Job C [result S Cs Ds] ->
    (let Bs (unii.better-candidate (unii.job-best Job) C)
         Best (head Bs)
         Ds1 (if (= Best C) [[candidate-kept (unii.cand-job C) (unii.cand-attempt C) (unii.cand-bytes C)] | Ds] Ds)
      (unii.after-try Job Bs [retry-seek-shorter (unii.cand-bytes Best)] [result S Cs Ds1])))

\\ After one try: the next try of the round, or the end of the round.
(define unii.after-try
  {unii.job --> (list unii.candidate) --> unii.retry --> unii.result --> unii.result}
  Job Bs Rt [result S Cs Ds] ->
    (if (< (unii.job-attempt Job) (unii.job-round-end Job))
        (let New (unii.next-try (unii.st-config S) Job Bs Rt)
          [result (unii.with-jobs S (unii.insert-job New (unii.remove-job (unii.job-id Job) (unii.st-jobs S))))
                  Cs [[job-retried (unii.job-id New) (unii.job-id Job)] | Ds]])
        (unii.end-round Job Bs "no summary within the leaf cap in a round of tries" [result S Cs Ds])))

\\ Commit the best candidate, or block when the round produced none. An
\\ over-cap summary is never a candidate, so it is never committed.
(define unii.end-round
  {unii.job --> (list unii.candidate) --> string --> unii.result --> unii.result}
  Job [] R Acc -> (unii.block Job R Acc)
  Job [[candidate J A B T] | _] _ [result S Cs Ds] ->
    (unii.commit-node (unii.make-node (unii.job-key Job) T B [summarized J A])
      [result (unii.with-jobs S (unii.remove-job (unii.job-id Job) (unii.st-jobs S))) Cs Ds]))

(define unii.on-failed
  {unii.state --> string --> number --> symbol --> unii.result}
  S J A C -> (unii.failed-job S (unii.find-job J (unii.st-jobs S)) J A C))

(define unii.failed-job
  {unii.state --> (list unii.job) --> string --> number --> symbol --> unii.result}
  S [] J _ _ -> [result S [] [[completion-ignored J "unknown or already completed job"]]]
  S [Job] J _ _ -> [result S [] [[completion-ignored J "job is not dispatched"]]]
    where (not (unii.dispatched? Job))
  S [Job] J A _ -> [result S [] [[completion-ignored J "attempt does not match job"]]]
    where (not (= A (unii.job-attempt Job)))
  S _ _ _ C -> (unii.reject S "unknown failure class")
    where (not (element? C (unii.failure-classes)))
  S [Job] _ _ permanent -> (unii.settle S (unii.end-round Job (unii.job-best Job) "permanent summary failure"
                                                         [result S [] []]))
  S [Job] _ _ C -> (unii.settle S (unii.after-try Job (unii.job-best Job) [retry-after-failure C]
                                                 [result S [] []])))

\\ ------------------------------------------------------ uncertain effects

(define unii.on-uncertain
  {unii.state --> string --> number --> (list unii.content) --> unii.result}
  S J A R -> (unii.uncertain-outcome S (unii.find-job J (unii.st-jobs S)) J A R))

(define unii.uncertain-outcome
  {unii.state --> (list unii.job) --> string --> number --> (list unii.content) --> unii.result}
  S [] J _ _ -> [result S [] [[completion-ignored J "unknown or already completed job"]]]
  S [Job] J _ _ -> [result S [] [[completion-ignored J "job is not dispatched"]]]
    where (not (unii.dispatched? Job))
  S [Job] J A _ -> [result S [] [[completion-ignored J "attempt does not match job"]]]
    where (not (= A (unii.job-attempt Job)))
  S [Job] _ _ R -> (unii.reject S "raw content does not match the job's source")
    where (not (unii.raw-fits? (unii.st-config S) (unii.job-source Job) R))
  S [Job] _ _ R -> (unii.settle S (unii.mark-uncertain Job R [result S [] []])))

\\ A leaf job's uncertain report carries the message itself (the boundary
\\ binds its bytes and hash to the text); a merge job's carries nothing.
(define unii.raw-fits?
  {unii.config --> unii.source --> (list unii.content) --> boolean}
  Cf [leaf-source _ _ H] [[content B H2 _]] -> (and (= H H2) (<= B (unii.cf-chunk-max Cf)))
  _ [merge-source _ _ _] [] -> true
  _ _ _ -> false)

\\ The request may have reached the provider, so a second dispatch could
\\ duplicate a paid or side-effecting call. The job parks until an operator
\\ retries it. Memory does not wait for it: an uncertain leaf renders
\\ provisionally, and merges proceed around ranges whose parent is missing.
(define unii.mark-uncertain
  {unii.job --> (list unii.content) --> unii.result --> unii.result}
  Job R [result S Cs Ds] ->
    (let Id (unii.job-id Job)
         C (unii.job-command Job)
      (unii.provisional-for Job R
        (unii.emit [effect-uncertain Id C]
          [result (unii.with-jobs S (unii.replace-job Id (unii.uncertain-job Job C) (unii.st-jobs S)))
                  Cs [[job-uncertain Id C] | Ds]]))))

\\ The stand-in text is the best candidate of the job so far, else the raw
\\ leaf text (which may exceed the cap; it is never joined or merged).
(define unii.provisional-for
  {unii.job --> (list unii.content) --> unii.result --> unii.result}
  Job [[content B _ Txt]] Acc -> (unii.place-node (unii.provisional-node Job B Txt) Acc)
    where (unii.leaf-job? Job)
  _ _ Acc -> Acc)

(define unii.provisional-node
  {unii.job --> number --> string --> unii.node}
  Job B Txt -> (unii.provisional-text Job (unii.job-best Job) (unii.source-kind (unii.job-source Job)) B Txt))

(define unii.provisional-text
  {unii.job --> (list unii.candidate) --> symbol --> number --> string --> unii.node}
  Job [[candidate _ _ CB CT] | _] _ _ _ -> (unii.make-node (unii.job-key Job) CT CB [provisional (unii.job-id Job)])
  Job _ Kd B Txt -> (unii.make-node (unii.job-key Job) (unii.leaf-text Kd Txt) (unii.leaf-text-bytes Kd B)
                                    [provisional (unii.job-id Job)]))

(define unii.job-command
  {unii.job --> string}
  [job _ _ _ [dispatched C] _] -> C
  J -> (error "unii.job-command: job ~A is not dispatched" (unii.job-id J)))

\\ An operator retry gives a blocked or uncertain job one fresh round of
\\ MaxAttempts tries; if that round yields no candidate the job blocks again.
(define unii.on-operator-retry
  {unii.state --> string --> unii.result}
  S J -> (unii.operator-retry-job S (unii.find-job J (unii.st-jobs S))))

(define unii.operator-retry-job
  {unii.state --> (list unii.job) --> unii.result}
  S [] -> (unii.reject S "operator retry: unknown or already completed job")
  S [Job] -> (unii.reject S "operator retry: job is neither blocked nor uncertain")
    where (not (or (unii.blocked? Job) (unii.uncertain? Job)))
  S [Job] -> (unii.reject S "operator retry: attempt ceiling reached")
    where (> (+ (unii.job-attempt Job) (unii.cf-max-attempts (unii.st-config S))) (unii.max-id))
  S [Job] -> (let New (unii.fresh-round (unii.st-config S) Job)
               (unii.settle S
                 [result (unii.with-jobs S (unii.insert-job New (unii.remove-job (unii.job-id Job) (unii.st-jobs S))))
                         [] [[job-retried (unii.job-id New) (unii.job-id Job)]]])))

(define unii.block
  {unii.job --> string --> unii.result --> unii.result}
  Job R [result S Cs Ds] ->
    (unii.emit [memory-blocked (unii.job-id Job) R]
      [result (unii.with-jobs S (unii.replace-job (unii.job-id Job) (unii.block-job Job R) (unii.st-jobs S)))
              Cs [[job-blocked (unii.job-id Job) R] | Ds]]))

\\ ------------------------------------------------------------- settle
\\ After any accepted change: extend the view with committed leaves, apply
\\ the byte-budget policy, dispatch ready jobs, and bump the view revision
\\ when the view changed. Old is the state before the event.

(define unii.settle
  {unii.state --> unii.result --> unii.result}
  Old Acc -> (unii.bump-revision Old (unii.dispatch-ready (unii.apply-policy (unii.extend-view Acc)))))

(define unii.extend-view
  {unii.result --> unii.result}
  [result S Cs Ds] ->
    (let Next (unii.find-node (unii.leaf-key (unii.st-covered S)) (unii.st-live S))
      (if (empty? Next)
          [result S Cs Ds]
          (let N (head Next)
            (unii.extend-view
              [result (unii.with-tree S (unii.st-count S) (+ 1 (unii.st-covered S))
                                      (append (unii.st-view S) [N])
                                      (+ (unii.st-view-bytes S) (unii.node-line-bytes N))
                                      (unii.remove-node (unii.node-key N) (unii.st-live S)))
                      Cs [[view-extended (unii.node-key N)] | Ds]])))))

(define unii.apply-policy
  {unii.result --> unii.result}
  [result S Cs Ds] ->
    (let Step (unii.apply-byte-policy (unii.st-config S) (unii.st-count S) (unii.st-view S)
                                      (unii.st-view-bytes S) (unii.st-live S) (unii.st-batch S))
      (unii.adopt-vstep Step [result S Cs Ds])))

(define unii.adopt-vstep
  {unii.vstep --> unii.result --> unii.result}
  [vstep V VB Lv Bt Ms] [result S Cs Ds] ->
    (let S1 (unii.with-tree S (unii.st-count S) (unii.st-covered S) V VB Lv)
         S2 (unii.with-counters S1 Bt (unii.st-rev S) (unii.st-next-cmd S))
         Ds1 (append (reverse (map (/. K [view-merged K]) Ms)) Ds)
      [result S2 Cs (if (= Bt (unii.st-batch S)) Ds1 [[batch-mode Bt] | Ds1])]))

(define unii.dispatch-ready
  {unii.result --> unii.result}
  [result S Cs Ds] ->
    (let Out (unii.dispatch (unii.st-config S) (unii.st-jobs S) (unii.built-nodes S)
                            (unii.st-next-cmd S))
      (unii.adopt-dispatch Out [result S Cs Ds])))

(define unii.adopt-dispatch
  {unii.dispatch-out --> unii.result --> unii.result}
  [dispatch-out Js New NC] [result S Cs Ds] ->
    [result (unii.with-counters (unii.with-jobs S Js) (unii.st-batch S) (unii.st-rev S) NC)
            (append (reverse New) Cs) Ds])

(define unii.view-changed?
  {unii.state --> unii.state --> boolean}
  Old New -> (not (= (unii.st-view Old) (unii.st-view New))))

(define unii.bump-revision
  {unii.state --> unii.result --> unii.result}
  Old [result S Cs Ds] ->
    (if (unii.view-changed? Old S)
        (let R (+ 1 (unii.st-rev S))
             S1 (unii.with-counters S (unii.st-batch S) R (unii.st-next-cmd S))
          (unii.emit [view-changed R (unii.st-view-bytes S1) (length (unii.st-view S1))]
                     [result S1 Cs [[view-revision R] | Ds]]))
        [result S Cs Ds]))

\\ ------------------------------------------------------ host projections

(define unii.view-lines
  {unii.state --> (list string)}
  S -> (unii.render-view (unii.st-view S)))

\\ A turn may start only when every accepted message is in the view.
(define unii.view-ready?
  {unii.state --> boolean}
  S -> (= (unii.st-covered S) (unii.st-count S)))

\\ [Count Covered ViewBytes ViewLines Rev Batch? Queued Dispatched Blocked
\\  Uncertain ProvisionalLines]
(define unii.status
  {unii.state --> (list number)}
  S -> (let Js (unii.st-jobs S)
         [(unii.st-count S) (unii.st-covered S) (unii.st-view-bytes S)
          (length (unii.st-view S)) (unii.st-rev S) (if (unii.st-batch S) 1 0)
          (unii.count-jobs (/. J (unii.queued? J)) Js)
          (unii.count-jobs (/. J (unii.dispatched? J)) Js)
          (unii.count-jobs (/. J (unii.blocked? J)) Js)
          (unii.count-jobs (/. J (unii.uncertain? J)) Js)
          (unii.count-nodes (/. N (unii.provisional? N)) (unii.st-view S))]))

(define unii.count-nodes
  {(unii.node --> boolean) --> (list unii.node) --> number}
  _ [] -> 0
  P [N | Ns] -> (+ 1 (unii.count-nodes P Ns)) where (P N)
  P [_ | Ns] -> (unii.count-nodes P Ns))

\\ Jobs that wait for an operator: [Id "blocked" Reason] or
\\ [Id "uncertain" Command], in dispatch-priority order.
(define unii.stuck-jobs
  {unii.state --> (list (list string))}
  S -> (unii.stuck-loop (unii.st-jobs S)))

(define unii.stuck-loop
  {(list unii.job) --> (list (list string))}
  [] -> []
  [[job Id _ _ [blocked R] _] | Js] -> [[Id "blocked" R] | (unii.stuck-loop Js)]
  [[job Id _ _ [uncertain C] _] | Js] -> [[Id "uncertain" C] | (unii.stuck-loop Js)]
  [_ | Js] -> (unii.stuck-loop Js))
