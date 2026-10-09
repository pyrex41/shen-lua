\* unii/core/invariants.shen -- executable structural checks.

   (unii.invariant-errors State) returns [] for a well-formed state, else a
   list of violation descriptions. Checks are direct recursive functions over
   the bounded in-memory projections (view, live nodes, jobs); Prolog would
   not make these single-pass walks clearer. *\

(define unii.invariant-errors
  {unii.state --> (list string)}
  S -> (let Cf (unii.st-config S)
         (append (unii.partition-errors (unii.st-view S) 0 (unii.st-covered S))
         (append (unii.node-errors Cf (unii.st-view S))
         (append (unii.node-errors Cf (unii.st-live S))
         (append (unii.live-errors S (unii.st-live S))
         (append (unii.frontier-errors S (unii.st-covered S))
         (append (unii.job-errors S (unii.st-jobs S) [])
         (append (unii.provisional-errors S (unii.built-nodes S))
           (unii.collect-errors
             [(@p (<= (unii.st-covered S) (unii.st-count S)) "view covers past the message count")
              (@p (unii.nat? (unii.st-count S)) "message count outside [0, 2^31 - 1]")
              (@p (= (unii.st-view-bytes S) (unii.view-bytes-of (unii.st-view S)))
                  "cached view bytes differ from the rendered line sum")
              (@p (or (unii.st-batch S) (<= (unii.st-view-bytes S) (unii.cf-high Cf)))
                  "view above the high threshold outside batch mode")
              (@p (<= (unii.count-jobs (/. J (unii.dispatched? J)) (unii.st-jobs S))
                      (unii.cf-max-inflight Cf))
                  "more dispatched jobs than the inflight cap")
              (@p (<= (unii.count-jobs (/. J (unii.leaf-job? J)) (unii.st-jobs S))
                      (unii.cf-max-frontier Cf))
                  "unresolved leaves exceed the frontier bound")]))))))))))

\\ The view is an exact, aligned, gap-free partition of [0, Covered).
(define unii.partition-errors
  {(list unii.node) --> number --> number --> (list string)}
  [] At Covered -> [] where (= At Covered)
  [] _ _ -> ["view does not end at the covered boundary"]
  [N | _] _ _ -> ["view contains an invalid node key"]
    where (not (unii.valid-key? (unii.node-key N)))
  [N | _] At _ -> ["view has a gap, overlap or misaligned node"]
    where (not (= At (unii.key-first (unii.node-key N))))
  [N | Ns] _ Covered -> (unii.partition-errors Ns (unii.key-end (unii.node-key N)) Covered))

(define unii.node-errors
  {unii.config --> (list unii.node) --> (list string)}
  _ [] -> []
  Cf [N | Ns] -> ["node text exceeds the leaf cap"]
    where (and (> (unii.node-bytes N) (unii.cf-cap Cf)) (not (unii.provisional? N)))
  Cf [N | Ns] -> ["node line is not the canonical rendering of its text"]
    where (not (= [line (unii.node-line N) (unii.node-line-bytes N)]
                  (unii.make-line (unii.node-key N) (unii.node-text N) (unii.node-bytes N))))
  Cf [N | Ns] -> ["node origin inconsistent with its level"]
    where (not (unii.origin-fits? (unii.node-origin N) (unii.node-key N)))
  Cf [_ | Ns] -> (unii.node-errors Cf Ns))

(define unii.origin-fits?
  {unii.origin --> unii.key --> boolean}
  [exact-leaf] [key L _] -> (= L 0)
  [joined] [key L _] -> (> L 0)
  [summarized _ _] _ -> true
  [provisional _] [key L _] -> (= L 0))

\\ Live nodes are built, unique, distinct from the view, and inside the chat.
(define unii.live-errors
  {unii.state --> (list unii.node) --> (list string)}
  _ [] -> []
  S [N | Ns] -> ["a live node duplicates a view node"]
    where (unii.has-node? (unii.node-key N) (unii.st-view S))
  S [N | Ns] -> ["a live node is duplicated"]
    where (unii.has-node? (unii.node-key N) Ns)
  S [N | Ns] -> ["a live node lies past the message count"]
    where (> (unii.key-end (unii.node-key N)) (unii.st-count S))
  S [_ | Ns] -> (unii.live-errors S Ns))

\\ Every message in [Covered, Count) is unresolved (one leaf job) or a
\\ committed leaf waiting in Live; the message at Covered must be unresolved.
(define unii.frontier-errors
  {unii.state --> number --> (list string)}
  S M -> [] where (>= M (unii.st-count S))
  S M -> ["the first uncovered message is not awaiting a summary"]
    where (and (= M (unii.st-covered S))
               (not (unii.has-job-for-key? (unii.leaf-key M) (unii.st-jobs S))))
  S M -> ["an uncovered message is neither pending nor built"]
    where (= (unii.leaf-states S M) 0)
  S M -> ["an uncovered message is both pending and built"]
    where (> (unii.leaf-states S M) 1)
  S M -> (unii.frontier-errors S (+ M 1)))

\\ A leaf job that has a provisional stand-in counts as built, not pending.
(define unii.leaf-states
  {unii.state --> number --> number}
  S M -> (let K (unii.leaf-key M)
           (+ (if (and (unii.has-job-for-key? K (unii.st-jobs S))
                       (not (unii.has-provisional? K (unii.st-live S)))) 1 0)
              (if (unii.has-node? K (unii.st-live S)) 1 0))))

(define unii.job-errors
  {unii.state --> (list unii.job) --> (list string) --> (list string)}
  _ [] _ -> []
  _ [J | _] Seen -> ["duplicate job id"] where (element? (unii.job-id J) Seen)
  S [J | _] _ -> ["a job targets an already built node"]
    where (unii.has-real-node? (unii.job-key J) (unii.built-nodes S))
  S [J | _] _ -> ["a job's attempt lies outside its round"]
    where (not (and (unii.pos-nat? (unii.job-attempt J)) (<= (unii.job-attempt J) (unii.job-round-end J))))
  S [J | _] _ -> ["a job keeps a candidate over the leaf cap"]
    where (and (cons? (unii.job-best J))
               (> (unii.cand-bytes (head (unii.job-best J))) (unii.cf-cap (unii.st-config S))))
  S [J | _] _ -> ["a leaf job targets a covered or future message"]
    where (and (and (unii.leaf-job? J) (not (unii.has-provisional? (unii.job-key J) (unii.built-nodes S))))
               (or (< (unii.key-first (unii.job-key J)) (unii.st-covered S))
                   (>= (unii.key-first (unii.job-key J)) (unii.st-count S))))
  S [J | _] _ -> ["a merge job is missing a built child"]
    where (and (not (unii.leaf-job? J)) (not (unii.children-built? S (unii.job-key J))))
  S [J | Js] Seen -> (unii.job-errors S Js [(unii.job-id J) | Seen]))

(define unii.children-built?
  {unii.state --> unii.key --> boolean}
  S K -> (unii.all-built? (unii.children K) (unii.built-nodes S)))

(define unii.all-built?
  {(list unii.key) --> (list unii.node) --> boolean}
  [] _ -> true
  [K | Ks] Ns -> (and (unii.has-node? K Ns) (unii.all-built? Ks Ns)))

\\ Every provisional node stands in for a leaf that still has a job.
(define unii.provisional-errors
  {unii.state --> (list unii.node) --> (list string)}
  _ [] -> []
  S [N | _] -> ["a provisional node has no job for its leaf"]
    where (and (unii.provisional? N) (not (unii.has-job-for-key? (unii.node-key N) (unii.st-jobs S))))
  S [_ | Ns] -> (unii.provisional-errors S Ns))
