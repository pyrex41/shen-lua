\* unii/core/jobs.shen -- summary job identity, ordering and dispatch.

   Job id: "j" Epoch "-" Level "-" Index "-a" Attempt "-" SourceToken.
   SourceToken is the first 16 hex digits of the message SHA-256 for a leaf,
   and "d" followed by unii.digest32 of the joined child texts for a merge.
   Identical inputs therefore give identical ids; retries differ only in the
   attempt.

   Jobs are kept in dispatch-priority order: leaf jobs by message id, then
   merge jobs by first message and level. A leaf job may dispatch only while
   fewer than LeadWindow unresolved leaves precede it; merge jobs exist only
   once both children are built. At most MaxInflight jobs are dispatched. *\

(define unii.prefix
  {number --> string --> string}
  0 _ -> ""
  _ "" -> ""
  N (@s C Rest) -> (cn C (unii.prefix (- N 1) Rest)))

(define unii.make-job-id
  {number --> unii.key --> number --> string --> string}
  E [key L I] A Token ->
    (cn "j" (cn (str E) (cn "-" (cn (str L) (cn "-" (cn (str I)
      (cn "-a" (cn (str A) (cn "-" Token))))))))))

(define unii.source-token
  {unii.source --> string}
  [leaf-source _ _ H] -> (unii.prefix 16 H)
  [merge-source _ _ D] -> D)

(define unii.merge-token
  {string --> string --> string}
  TA TB -> (cn "d" (str (unii.digest32 (unii.join-text TA TB)))))

(define unii.source-key
  {unii.source --> unii.key}
  [leaf-source M _ _] -> (unii.leaf-key M)
  [merge-source A _ _] -> (unii.parent A))

(define unii.new-job
  {unii.config --> unii.source --> number --> unii.retry --> unii.job}
  Cf Src A Rt -> (let K (unii.source-key Src)
                   [job (unii.make-job-id (unii.cf-epoch Cf) K A (unii.source-token Src))
                        K A [queued Rt] Src]))

(define unii.retry-job
  {unii.config --> unii.job --> unii.retry --> unii.job}
  Cf J Rt -> (unii.new-job Cf (unii.job-source J) (+ 1 (unii.job-attempt J)) Rt))

(define unii.block-job
  {unii.job --> string --> unii.job}
  [job Id K A _ Src] R -> [job Id K A [blocked R] Src])

(define unii.uncertain-job
  {unii.job --> string --> unii.job}
  [job Id K A _ Src] C -> [job Id K A [uncertain C] Src])

\\ ------------------------------------------------------------ ordering

(define unii.job-rank
  {unii.job --> number}
  J -> 0 where (unii.leaf-job? J)
  _ -> 1)

(define unii.job-before?
  {unii.job --> unii.job --> boolean}
  J1 J2 -> (< (unii.job-rank J1) (unii.job-rank J2))
    where (not (= (unii.job-rank J1) (unii.job-rank J2)))
  J1 J2 -> (< (unii.key-first (unii.job-key J1)) (unii.key-first (unii.job-key J2)))
    where (not (= (unii.key-first (unii.job-key J1)) (unii.key-first (unii.job-key J2))))
  J1 J2 -> (< (unii.key-level (unii.job-key J1)) (unii.key-level (unii.job-key J2))))

(define unii.insert-job
  {unii.job --> (list unii.job) --> (list unii.job)}
  J [] -> [J]
  J [K | Ks] -> [J K | Ks] where (unii.job-before? J K)
  J [K | Ks] -> [K | (unii.insert-job J Ks)])

(define unii.find-job
  {string --> (list unii.job) --> (list unii.job)}
  _ [] -> []
  Id [J | Js] -> [J] where (= Id (unii.job-id J))
  Id [_ | Js] -> (unii.find-job Id Js))

(define unii.remove-job
  {string --> (list unii.job) --> (list unii.job)}
  _ [] -> []
  Id [J | Js] -> Js where (= Id (unii.job-id J))
  Id [J | Js] -> [J | (unii.remove-job Id Js)])

(define unii.replace-job
  {string --> unii.job --> (list unii.job) --> (list unii.job)}
  _ _ [] -> []
  Id New [J | Js] -> [New | Js] where (= Id (unii.job-id J))
  Id New [J | Js] -> [J | (unii.replace-job Id New Js)])

(define unii.has-job-for-key?
  {unii.key --> (list unii.job) --> boolean}
  _ [] -> false
  K [J | Js] -> (or (unii.key= K (unii.job-key J)) (unii.has-job-for-key? K Js)))

(define unii.count-jobs
  {(unii.job --> boolean) --> (list unii.job) --> number}
  _ [] -> 0
  P [J | Js] -> (+ 1 (unii.count-jobs P Js)) where (P J)
  P [_ | Js] -> (unii.count-jobs P Js))

\\ ------------------------------------------------------------- dispatch

(datatype unii.dispatch-out
  Js : (list unii.job); Cs : (list unii.command); NC : number;
  ==============================================================
  [dispatch-out Js Cs NC] : unii.dispatch-out;)

(define unii.command-id
  {number --> string}
  N -> (cn "c" (str N)))

(define unii.summary-input
  {unii.source --> (list unii.node) --> unii.summary-input}
  [leaf-source M Kd H] _ -> [leaf-input M Kd H]
  [merge-source A B _] Nodes ->
    [merge-input A (unii.node-text (head (unii.find-node A Nodes)))
                 B (unii.node-text (head (unii.find-node B Nodes)))])

(define unii.dispatch
  {unii.config --> (list unii.job) --> (list unii.node) --> number --> unii.dispatch-out}
  Cf Js Nodes NC ->
    (unii.dispatch-loop (unii.cf-lead Cf) Js Nodes
      (- (unii.cf-max-inflight Cf) (unii.count-jobs (/. J (unii.dispatched? J)) Js))
      0 NC [] []))

(define unii.dispatch-loop
  {number --> (list unii.job) --> (list unii.node) --> number --> number --> number
   --> (list unii.job) --> (list unii.command) --> unii.dispatch-out}
  _ [] _ _ _ NC Acc Cs -> [dispatch-out (reverse Acc) (reverse Cs) NC]
  Lead [J | Js] Nodes Slots Seen NC Acc Cs ->
    (let Leaf (unii.leaf-job? J)
         Seen2 (if Leaf (+ Seen 1) Seen)
      (if (and (> Slots 0) (and (unii.queued? J) (or (not Leaf) (< Seen Lead))))
          (let C (unii.command-id NC)
               Out (unii.start-job J C Nodes)
            (unii.dispatch-loop Lead Js Nodes (- Slots 1) Seen2 (+ NC 1)
                                [(fst Out) | Acc] [(snd Out) | Cs]))
          (unii.dispatch-loop Lead Js Nodes Slots Seen2 NC [J | Acc] Cs))))

(define unii.start-job
  {unii.job --> string --> (list unii.node) --> (unii.job * unii.command)}
  [job Id K A [queued Rt] Src] C Nodes ->
    (@p [job Id K A [dispatched C] Src]
        [submit-summary C Id K [attempt A Rt] (unii.summary-input Src Nodes)])
  J _ _ -> (error "unii.start-job: job ~A is not queued" (unii.job-id J)))
