\* unii/core/arith.shen -- exact bounded integer helpers.

   The core never applies `/`. Every quantity handled here is an integer in
   [0, 2^40) and only +, -, * and comparisons are used, so each result is
   exact both in LuaJIT doubles and in any Shen port with exact integers.
   Version 1 domain ceiling: message ids, counts and offsets are at most
   2^31 - 1 (2147483647). *\

(define unii.max-id
  {--> number}
  -> 2147483647)

(define unii.nat?
  {number --> boolean}
  X -> (and (integer? X) (and (>= X 0) (<= X 2147483647))))

(define unii.pos-nat?
  {number --> boolean}
  X -> (and (unii.nat? X) (> X 0)))

\\ 2^39 .. 2^0, the bit weights used by unii.divmod-pow2.
(define unii.pow2-desc
  {--> (list number)}
  -> [549755813888 274877906944 137438953472 68719476736 34359738368
      17179869184 8589934592 4294967296 2147483648 1073741824 536870912
      268435456 134217728 67108864 33554432 16777216 8388608 4194304 2097152
      1048576 524288 262144 131072 65536 32768 16384 8192 4096 2048 1024 512
      256 128 64 32 16 8 4 2 1])

(define unii.pow2
  {number --> number}
  0 -> 1
  L -> (* 2 (unii.pow2 (- L 1))) where (and (integer? L) (and (> L 0) (< L 40)))
  L -> (error "unii.pow2: exponent ~A outside [0, 39]" L))

\\ Floor quotient and remainder of N by 2^L, by binary long division from bit 39
\\ down. Requires 0 <= N < 2^40 and 0 <= L <= 39.
(define unii.divmod-pow2
  {number --> number --> (number * number)}
  N L -> (unii.dm-loop N L 39 (unii.pow2-desc) 0)
           where (and (integer? N) (and (>= N 0) (and (< N 1099511627776)
                 (and (integer? L) (and (>= L 0) (< L 40))))))
  N L -> (error "unii.divmod-pow2: ~A / 2^~A outside the exact domain" N L))

(define unii.dm-loop
  {number --> number --> number --> (list number) --> number --> (number * number)}
  M L B _ Q -> (@p Q M) where (< B L)
  M L B [P | Ps] Q -> (unii.dm-loop (- M P) L (- B 1) Ps (+ (+ Q Q) 1)) where (>= M P)
  M L B [_ | Ps] Q -> (unii.dm-loop M L (- B 1) Ps (+ Q Q))
  M _ _ [] Q -> (@p Q M))

(define unii.half
  {number --> number}
  N -> (fst (unii.divmod-pow2 N 1)))

(define unii.even?
  {number --> boolean}
  N -> (= 0 (snd (unii.divmod-pow2 N 1))))

\\ Smallest L with 2^L = N, or -1 when N is not a power of two in [1, 2^31].
(define unii.log2-exact
  {number --> number}
  N -> (unii.log2-loop N 0 1))

(define unii.log2-loop
  {number --> number --> number --> number}
  N L P -> L where (= N P)
  N L P -> -1 where (or (> P N) (> L 31))
  N L P -> (unii.log2-loop N (+ L 1) (+ P P)))

\\ Number of decimal digits of a natural number below 10^13.
(define unii.decimal-width
  {number --> number}
  N -> (unii.width-loop N 1 10))

(define unii.width-loop
  {number --> number --> number --> number}
  N W P -> W where (or (< N P) (>= W 13))
  N W P -> (unii.width-loop N (+ W 1) (* P 10)))

\\ A 32-bit djb2-style digest (h * 33 + byte mod 2^32) over the bytes of S as
\\ this port exposes them through pos/string->n. Used only to tag job ids with
\\ their source; the host records full SHA-256 provenance separately.
(define unii.digest32
  {string --> number}
  S -> (unii.digest-loop S 5381))

(define unii.digest-loop
  {string --> number --> number}
  "" H -> H
  (@s C Rest) H -> (unii.digest-loop Rest
                     (snd (unii.divmod-pow2 (+ (* H 33) (string->n C)) 32))))
