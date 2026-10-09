\* unii/core/tree.shen -- node addressing, relations and canonical lines.

   (key L I) covers the half-open message interval [I * 2^L, (I + 1) * 2^L).
   Its children are (key L-1 2I) and (key L-1 2I+1). Public addresses are
   First+Count with Count = 2^L and First = I * Count. *\

(define unii.key-level {unii.key --> number} [key L _] -> L)
(define unii.key-index {unii.key --> number} [key _ I] -> I)

(define unii.key=
  {unii.key --> unii.key --> boolean}
  [key L1 I1] [key L2 I2] -> (and (= L1 L2) (= I1 I2)))

\\ A key is valid when its interval ends at or below the v1 message-count
\\ ceiling 2^31 - 1 (so message ids run 0 .. 2^31 - 2).
(define unii.valid-key?
  {unii.key --> boolean}
  [key L I] -> (and (unii.nat? L) (and (<= L 30) (and (unii.nat? I)
                (<= (* I (unii.pow2 L)) (- (unii.max-id) (unii.pow2 L)))))))

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
\\ A view line is First "+" Count "|" Canonical(Text) LF
\\ (docs/contracts/numeric.md, "Canonical text"). Canonical text replaces
\\ each line break -- CR LF as one, lone CR, LF, NEL (U+0085), LS (U+2028),
\\ PS (U+2029) -- and every other C0 control and DEL with one space, and
\\ keeps all other bytes, including "|" and "%". Text arrives as valid UTF-8
\\ with an exact byte count (checked at the boundary); the rendering and its
\\ byte length are computed together, by byte index.

(define unii.lf {--> string} -> (n->string 10))

(define unii.byte-at
  {string --> number --> number}
  S I -> (string->n (pos S I)))

(define unii.canonical-text
  {string --> number --> (string * number)}
  S N -> (unii.canon-range S 0 N))

\\ Ranges are split in halves so the work stays O(n log n); a split never
\\ falls inside a UTF-8 sequence or between CR and LF.
(define unii.canon-range
  {string --> number --> number --> (string * number)}
  S I J -> (unii.canon-scan S I J "" 0) where (<= (- J I) 64)
  S I J -> (unii.canon-halves S I (unii.canon-split S I (+ I (unii.half (- J I))) J) J))

(define unii.canon-halves
  {string --> number --> number --> number --> (string * number)}
  S I M J -> (unii.canon-scan S I J "" 0) where (>= M J)
  S I M J -> (let A (unii.canon-range S I M)
                  B (unii.canon-range S M J)
               (@p (cn (fst A) (fst B)) (+ (snd A) (snd B)))))

(define unii.canon-split
  {string --> number --> number --> number --> number}
  _ _ M J -> J where (>= M J)
  S I M J -> (unii.canon-split S I (+ M 1) J)
    where (or (unii.continuation? (unii.byte-at S M))
              (and (= 10 (unii.byte-at S M)) (= 13 (unii.byte-at S (- M 1)))))
  _ _ M _ -> M)

(define unii.continuation?
  {number --> boolean}
  B -> (and (>= B 128) (< B 192)))

(define unii.canon-scan
  {string --> number --> number --> string --> number --> (string * number)}
  _ I J Acc Len -> (@p Acc Len) where (>= I J)
  S I J Acc Len -> (unii.canon-scan S (unii.canon-break-end S I J) J (cn Acc " ") (+ Len 1))
    where (> (unii.canon-break-end S I J) I)
  S I J Acc Len -> (unii.canon-scan S (+ I 1) J (cn Acc (pos S I)) (+ Len 1)))

\\ End index of the line break or control starting at I, or I when there is none.
(define unii.canon-break-end
  {string --> number --> number --> number}
  S I J -> (unii.canon-break-at S I J (unii.byte-at S I)))

(define unii.canon-break-at
  {string --> number --> number --> number --> number}
  S I J 13 -> (+ I 2) where (and (< (+ I 1) J) (= 10 (unii.byte-at S (+ I 1))))
  _ I _ B -> (+ I 1) where (or (< B 32) (= B 127))
  S I J 194 -> (+ I 2) where (and (< (+ I 1) J) (= 133 (unii.byte-at S (+ I 1))))
  S I J 226 -> (+ I 3) where (and (< (+ I 2) J)
                                  (and (= 128 (unii.byte-at S (+ I 1)))
                                       (element? (unii.byte-at S (+ I 2)) [168 169])))
  _ I _ _ -> I)

(define unii.address-string
  {unii.key --> string}
  K -> (cn (str (unii.key-first K)) (cn "+" (str (unii.key-count K)))))

(define unii.address-bytes
  {unii.key --> number}
  K -> (+ (unii.decimal-width (unii.key-first K))
          (+ 1 (unii.decimal-width (unii.key-count K)))))

\\ Line bytes from the canonical text's byte length.
(define unii.line-bytes
  {unii.key --> number --> number}
  K CanonBytes -> (+ (unii.address-bytes K) (+ 1 (+ CanonBytes 1))))

\\ Text is the node's raw text and Bytes its exact byte length.
(define unii.make-line
  {unii.key --> string --> number --> unii.line}
  K Text Bytes -> (let C (unii.canonical-text Text Bytes)
                    [line (cn (unii.address-string K) (cn "|" (cn (fst C) (unii.lf))))
                          (unii.line-bytes K (snd C))]))

(define unii.make-node
  {unii.key --> string --> number --> unii.origin --> unii.node}
  K Text Bytes O -> [node K Text Bytes (unii.make-line K Text Bytes) O])

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

(define unii.replace-node
  {unii.node --> (list unii.node) --> (list unii.node)}
  _ [] -> []
  N [M | Ns] -> [N | Ns] where (unii.key= (unii.node-key N) (unii.node-key M))
  N [M | Ns] -> [M | (unii.replace-node N Ns)])

\\ A provisional node stands in for a leaf whose summary job is uncertain:
\\ it renders, but it is never joined, merged or summarized from.
(define unii.provisional?
  {unii.node --> boolean}
  [node _ _ _ _ [provisional _]] -> true
  _ -> false)

(define unii.find-real-node
  {unii.key --> (list unii.node) --> (list unii.node)}
  K Ns -> (let F (unii.find-node K Ns)
            (if (and (cons? F) (unii.provisional? (head F))) [] F)))

(define unii.has-real-node?
  {unii.key --> (list unii.node) --> boolean}
  K Ns -> (not (empty? (unii.find-real-node K Ns))))

(define unii.has-provisional?
  {unii.key --> (list unii.node) --> boolean}
  K Ns -> (let F (unii.find-node K Ns)
            (and (cons? F) (unii.provisional? (head F)))))
