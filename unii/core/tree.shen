\* unii/core/tree.shen -- node addressing, relations and canonical lines.

   (key L I) covers the half-open message interval [I * 2^L, (I + 1) * 2^L).
   Its children are (key L-1 2I) and (key L-1 2I+1). Public addresses are
   First+Count with Count = 2^L and First = I * Count. *\

(define unii.key-level {unii.key --> number} [key L _] -> L)
(define unii.key-index {unii.key --> number} [key _ I] -> I)

(define unii.key=
  {unii.key --> unii.key --> boolean}
  [key L1 I1] [key L2 I2] -> (and (= L1 L2) (= I1 I2)))

(define unii.valid-key?
  {unii.key --> boolean}
  [key L I] -> (and (unii.nat? L) (and (<= L 31) (and (unii.nat? I)
                (<= (* I (unii.pow2 L)) (- (unii.max-id) (- (unii.pow2 L) 1)))))))

(define unii.key-count {unii.key --> number} [key L _] -> (unii.pow2 L))
(define unii.key-first {unii.key --> number} [key L I] -> (* I (unii.pow2 L)))
(define unii.key-end {unii.key --> number} K -> (+ (unii.key-first K) (unii.key-count K)))

(define unii.leaf-key {number --> unii.key} M -> [key 0 M])

(define unii.parent
  {unii.key --> unii.key}
  [key L I] -> [key (+ L 1) (unii.half I)])

(define unii.left-child?
  {unii.key --> boolean}
  [key _ I] -> (unii.even? I))

(define unii.sibling
  {unii.key --> unii.key}
  [key L I] -> [key L (+ I 1)] where (unii.even? I)
  [key L I] -> [key L (- I 1)])

(define unii.children
  {unii.key --> (list unii.key)}
  [key 0 _] -> []
  [key L I] -> [[key (- L 1) (+ I I)] [key (- L 1) (+ (+ I I) 1)]])

\\ A sibling pair (A, B) in view order: A is a left child and B its sibling.
(define unii.sibling-pair?
  {unii.key --> unii.key --> boolean}
  [key L1 I1] [key L2 I2] -> (and (= L1 L2) (and (= I2 (+ I1 1)) (unii.even? I1))))

\\ Validate a public First+Count address against a chat of Total messages.
\\ Returns [] when invalid, else [Key].
(define unii.address->key
  {number --> number --> number --> (list unii.key)}
  First Count Total -> (unii.address-check First Count Total (unii.log2-exact Count))
    where (and (unii.nat? First) (and (unii.pos-nat? Count) (unii.nat? Total)))
  _ _ _ -> [])

(define unii.address-check
  {number --> number --> number --> number --> (list unii.key)}
  _ _ _ -1 -> []
  First Count Total L -> []
    where (or (> (+ First Count) Total)
              (not (= 0 (snd (unii.divmod-pow2 First L)))))
  First _ _ L -> [[key L (fst (unii.divmod-pow2 First L))]])

\\ ---------------------------------------------------------- canonical lines
\\ A view line is First "+" Count "|" Text LF. Line breaks (CR and LF) inside
\\ Text become single spaces, which keeps the byte length of Text unchanged,
\\ so line bytes are computed exactly from the host-measured text bytes.

(define unii.lf {--> string} -> (n->string 10))
(define unii.cr {--> string} -> (n->string 13))

(define unii.collapse-breaks
  {string --> string}
  "" -> ""
  (@s C Rest) -> (cn " " (unii.collapse-breaks Rest))
    where (or (= C (unii.lf)) (= C (unii.cr)))
  (@s C Rest) -> (cn C (unii.collapse-breaks Rest)))

(define unii.address-string
  {unii.key --> string}
  K -> (cn (str (unii.key-first K)) (cn "+" (str (unii.key-count K)))))

(define unii.address-bytes
  {unii.key --> number}
  K -> (+ (unii.decimal-width (unii.key-first K))
          (+ 1 (unii.decimal-width (unii.key-count K)))))

(define unii.line-bytes
  {unii.key --> number --> number}
  K TextBytes -> (+ (unii.address-bytes K) (+ 1 (+ TextBytes 1))))

(define unii.render-line
  {unii.key --> string --> string}
  K Text -> (cn (unii.address-string K)
                (cn "|" (cn (unii.collapse-breaks Text) (unii.lf)))))

(define unii.make-node
  {unii.key --> string --> number --> unii.origin --> unii.node}
  K Text Bytes O -> [node K Text Bytes [line (unii.render-line K Text) (unii.line-bytes K Bytes)] O])

\\ Exact leaf text: the kind attribution, ": ", then the content verbatim.
\\ Its byte size counts toward the leaf cap.
(define unii.leaf-text
  {symbol --> string --> string}
  Kind Content -> (cn (str Kind) (cn ": " Content)))

(define unii.leaf-text-bytes
  {symbol --> number --> number}
  Kind ContentBytes -> (+ (unii.kind-label-bytes Kind) (+ 2 ContentBytes)))

\\ Lossless join of two sibling texts: left, LF, right.
(define unii.join-text
  {string --> string --> string}
  A B -> (cn A (cn (unii.lf) B)))

(define unii.join-bytes
  {number --> number --> number}
  A B -> (+ A (+ 1 B)))

\\ ------------------------------------------------------------ node lookup

(define unii.find-node
  {unii.key --> (list unii.node) --> (list unii.node)}
  _ [] -> []
  K [N | Ns] -> [N] where (unii.key= K (unii.node-key N))
  K [_ | Ns] -> (unii.find-node K Ns))

(define unii.has-node?
  {unii.key --> (list unii.node) --> boolean}
  K Ns -> (not (empty? (unii.find-node K Ns))))

(define unii.remove-node
  {unii.key --> (list unii.node) --> (list unii.node)}
  _ [] -> []
  K [N | Ns] -> Ns where (unii.key= K (unii.node-key N))
  K [N | Ns] -> [N | (unii.remove-node K Ns)])
