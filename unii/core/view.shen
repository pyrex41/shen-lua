\* unii/core/view.shen -- coverage, merge order, hysteresis, rendering.

   Due score of the sibling pair (key L I), (key L I+1) with T messages:

       last = (I + 2) * 2^L - 1          zero-based index of its final message
       due  = (T - last) / 2^L  =  (T + 1) / 2^L - (I + 2)

   It is held exactly as [due Whole Frac L] meaning Whole + Frac / 2^L with
   (Q, Frac) = divmod(T + 1, 2^L) and Whole = Q - (I + 2). Comparison never
   divides: whole parts first, then Frac1 * 2^(L2 - L1) against Frac2 (for
   L1 <= L2), and Frac1 < 2^L1 keeps that product below 2^L2 <= 2^39.

   Selection takes the greatest due among adjacent aligned sibling pairs in
   the view whose parent is built. Ties go to the oldest pair: the scan runs
   oldest first and only a strictly greater score replaces the incumbent.
   Pairs in one view are disjoint, so their first messages differ and the
   stable-key tie-break of the plan never has to fire.

   Cost: one selection is a scan over the view (hundreds of lines at the
   default thresholds) plus a parent lookup per eligible pair. *\

(datatype unii.due
  W : number; F : number; L : number;
  ===================================
  [due W F L] : unii.due;)

(define unii.pair-due
  {number --> unii.key --> unii.due}
  T [key L I] -> (let QR (unii.divmod-pow2 (+ T 1) L)
                   [due (- (fst QR) (+ I 2)) (snd QR) L]))

(define unii.due>
  {unii.due --> unii.due --> boolean}
  [due W1 _ _] [due W2 _ _] -> (> W1 W2) where (not (= W1 W2))
  [due _ F1 L1] [due _ F2 L2] -> (> (* F1 (unii.pow2 (- L2 L1))) F2) where (<= L1 L2)
  [due _ F1 L1] [due _ F2 L2] -> (> F1 (* F2 (unii.pow2 (- L1 L2)))))

\\ Left key of the most due eligible pair, or [] when none is eligible.
(define unii.best-pair
  {(list unii.key) --> number --> (unii.key --> boolean) --> (list unii.key)}
  Keys T Built -> (unii.best-loop Keys T Built [] [due -1 0 0]))

(define unii.best-loop
  {(list unii.key) --> number --> (unii.key --> boolean) --> (list unii.key)
   --> unii.due --> (list unii.key)}
  [A B | Rest] T Built Best BD -> (unii.best-step A Rest T Built Best BD (unii.pair-due T A))
    where (unii.sibling-pair? A B)
  [_ | Rest] T Built Best BD -> (unii.best-loop Rest T Built Best BD)
  [] _ _ Best _ -> Best)

(define unii.best-step
  {unii.key --> (list unii.key) --> number --> (unii.key --> boolean) --> (list unii.key)
   --> unii.due --> unii.due --> (list unii.key)}
  A Rest T Built Best BD D -> (unii.best-loop Rest T Built [A] D)
    where (and (unii.due> D BD) (Built (unii.parent A)))
  _ Rest T Built Best BD _ -> (unii.best-loop Rest T Built Best BD))

\\ Replace the pair starting at A with its parent in a key list.
(define unii.merge-key-list
  {(list unii.key) --> unii.key --> (list unii.key)}
  [K _ | Ks] A -> [(unii.parent A) | Ks] where (unii.key= K A)
  [K | Ks] A -> [K | (unii.merge-key-list Ks A)]
  [] _ -> [])

\\ Line-count budget policy (used to compare against the gist's rollback push):
\\ every parent counts as built; merge the most due pair until the view has at
\\ most Budget lines. Returns the view and the merged parents in order.
(define unii.merge-keys-to-count
  {(list unii.key) --> number --> number --> ((list unii.key) * (list unii.key))}
  Keys T Budget -> (unii.count-loop Keys T Budget []))

(define unii.count-loop
  {(list unii.key) --> number --> number --> (list unii.key)
   --> ((list unii.key) * (list unii.key))}
  Keys T Budget Ms -> (@p Keys (reverse Ms)) where (<= (length Keys) Budget)
  Keys T Budget Ms -> (unii.count-step Keys T Budget Ms (unii.best-pair Keys T (/. K true))))

(define unii.count-step
  {(list unii.key) --> number --> number --> (list unii.key) --> (list unii.key)
   --> ((list unii.key) * (list unii.key))}
  Keys _ _ Ms [] -> (@p Keys (reverse Ms))
  Keys T Budget Ms [A | _] -> (unii.count-loop (unii.merge-key-list Keys A) T Budget
                                                [(unii.parent A) | Ms]))

\\ ------------------------------------------------- byte-budget hysteresis

\\ "<chat>" LF and "</chat>" LF.
(define unii.wrapper-bytes {--> number} -> 15)

(define unii.view-keys
  {(list unii.node) --> (list unii.key)}
  V -> (map (/. N (unii.node-key N)) V))

(define unii.sum-line-bytes
  {(list unii.node) --> number}
  [] -> 0
  [N | Ns] -> (+ (unii.node-line-bytes N) (unii.sum-line-bytes Ns)))

(define unii.view-bytes-of
  {(list unii.node) --> number}
  V -> (+ (unii.wrapper-bytes) (unii.sum-line-bytes V)))

(datatype unii.vstep
  V : (list unii.node); VB : number; Lv : (list unii.node); Bt : boolean;
  Ms : (list unii.key);
  ======================================================================
  [vstep V VB Lv Bt Ms] : unii.vstep;)

\\ Replace the view pair starting at A by its parent node P.
(define unii.merge-view-at
  {(list unii.node) --> unii.key --> unii.node --> (list unii.node)}
  [N _ | Ns] A P -> [P | Ns] where (unii.key= (unii.node-key N) A)
  [N | Ns] A P -> [N | (unii.merge-view-at Ns A P)]
  [] _ _ -> [])

(define unii.pair-line-bytes
  {(list unii.node) --> unii.key --> number}
  [N M | _] A -> (+ (unii.node-line-bytes N) (unii.node-line-bytes M))
    where (unii.key= (unii.node-key N) A)
  [_ | Ns] A -> (unii.pair-line-bytes Ns A)
  [] _ -> 0)

\\ Above High (or already in a batch): merge the most due eligible pairs until
\\ the view is at most Low. If parents are missing, stay in batch mode; the
\\ next transition continues the batch.
(define unii.apply-byte-policy
  {unii.config --> number --> (list unii.node) --> number --> (list unii.node)
   --> boolean --> unii.vstep}
  Cf T V VB Lv Bt -> (unii.batch-loop (unii.cf-low Cf) T V VB Lv [])
    where (or Bt (> VB (unii.cf-high Cf)))
  _ _ V VB Lv _ -> [vstep V VB Lv false []])

(define unii.batch-loop
  {number --> number --> (list unii.node) --> number --> (list unii.node)
   --> (list unii.key) --> unii.vstep}
  Low _ V VB Lv Ms -> [vstep V VB Lv false (reverse Ms)] where (<= VB Low)
  Low T V VB Lv Ms -> (unii.batch-step Low T V VB Lv Ms
                         (unii.best-pair (unii.view-keys V) T (/. K (unii.has-node? K Lv)))))

(define unii.batch-step
  {number --> number --> (list unii.node) --> number --> (list unii.node)
   --> (list unii.key) --> (list unii.key) --> unii.vstep}
  _ _ V VB Lv Ms [] -> [vstep V VB Lv true (reverse Ms)]
  Low T V VB Lv Ms [A | _] ->
    (let PK (unii.parent A)
         P (head (unii.find-node PK Lv))
         VB2 (+ (- VB (unii.pair-line-bytes V A)) (unii.node-line-bytes P))
      (unii.batch-loop Low T (unii.merge-view-at V A P) VB2 (unii.remove-node PK Lv)
                       [PK | Ms])))

\\ ---------------------------------------------------------------- render

\\ The canonical rendering of a view as a list of LF-terminated strings; the
\\ host concatenates them and must obtain exactly unii.view-bytes-of bytes.
(define unii.render-view
  {(list unii.node) --> (list string)}
  V -> (append [(cn "<chat>" (unii.lf))]
               (append (map (/. N (unii.node-line N)) V)
                       [(cn "</chat>" (unii.lf))])))
