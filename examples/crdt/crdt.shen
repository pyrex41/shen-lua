\\ crdt.shen — conflict-free replicated data types, the SAME typed source loaded
\\ by every replica: the server (shen-lua under OpenResty), the browser
\\ (ShenScript), and — unchanged — shen-go / shen-rust. One merge function
\\ everywhere, so replicas cannot disagree about what "merge" means; that
\\ agreement is the whole correctness story of a state-based CRDT.
\\
\\ Pure, portable Shen: kernel primitives only (cn/str/tlstr/string->n/=), no
\\ host bridges, exactly like examples/openresty/rules.shen. Loaded under (tc +)
\\ so every merge/law function is proved well-typed before the first request.
\\
\\ A state-based CRDT is a join-semilattice: `merge` is the least-upper-bound
\\ (join), and Strong Eventual Consistency follows from three algebraic laws on
\\ merge — commutativity, associativity, idempotence — plus monotonic updates.
\\ Those three laws ARE the semilattice axioms. We encode them as checkable
\\ Shen functions (tier b: executable property checks) below; crdt_laws.shen
\\ takes one of them to tier c (a machine-checked sequent proof).

\\ ===========================================================================
\\ Shared helpers
\\ ===========================================================================

(define max-num {number --> number --> number} A B -> (if (> A B) A B))

\\ A deterministic TOTAL order on replica ids (lexicographic by codepoint).
\\ Ties in a Last-Writer-Wins clock must break identically on every replica or
\\ they diverge forever — so the tiebreak has to be a genuine total order, and
\\ it has to be pure/portable. string->n gives the codepoint of the head char.
(define str-gt?
  {string --> string --> boolean}
  "" _ -> false
  _ "" -> true
  S1 S2 -> (if (> (string->n S1) (string->n S2))
               true
               (if (< (string->n S1) (string->n S2))
                   false
                   (str-gt? (tlstr S1) (tlstr S2)))))

\\ ===========================================================================
\\ G-Counter — the "hello world" of state-based CRDTs.
\\
\\ State is a set of per-replica grow-only tallies [Id N]; value is their sum;
\\ merge is the pointwise MAX. max is commutative/associative/idempotent, so
\\ the laws hold by construction — this is the cleanest semilattice to see.
\\ ===========================================================================

(datatype gcounter
  Id : string; N : number;
  ========================
  [Id N] : gtally;

  Ts : (list gtally);
  ===================
  [gc Ts] : gcounter;)

\\ this replica's recorded count for Id (0 if it has never been seen)
(define gc-get
  {string --> (list gtally) --> number}
  _ [] -> 0
  Id [[Id N] | _] -> N
  Id [_ | Ts] -> (gc-get Id Ts))

(define gc-has?
  {string --> (list gtally) --> boolean}
  _ [] -> false
  Id [[Id _] | _] -> true
  Id [_ | Ts] -> (gc-has? Id Ts))

\\ the join: for each id, take the larger of the two replicas' counts
(define gc-merge
  {gcounter --> gcounter --> gcounter}
  [gc As] [gc Bs] -> [gc (append (gc-pointwise-max As Bs)
                                 (gc-only Bs As))])

(define gc-pointwise-max
  {(list gtally) --> (list gtally) --> (list gtally)}
  [] _ -> []
  [[Id N] | Rest] Bs -> [[Id (max-num N (gc-get Id Bs))] | (gc-pointwise-max Rest Bs)])

\\ tallies present in the FIRST counter but absent from the second
(define gc-only
  {(list gtally) --> (list gtally) --> (list gtally)}
  [] _ -> []
  [[Id N] | Rest] As -> (if (gc-has? Id As)
                            (gc-only Rest As)
                            [[Id N] | (gc-only Rest As)]))

(define gc-value
  {gcounter --> number}
  [gc Ts] -> (gc-sum Ts))

(define gc-sum
  {(list gtally) --> number}
  [] -> 0
  [[_ N] | Ts] -> (+ N (gc-sum Ts)))

\\ the only update: a replica bumps its OWN tally. Monotonic (counts only go
\\ up), which is what keeps every local update moving up the lattice.
(define gc-inc
  {string --> gcounter --> gcounter}
  Id [gc Ts] -> [gc (gc-bump Id Ts)])

(define gc-bump
  {string --> (list gtally) --> (list gtally)}
  Id [] -> [[Id 1]]
  Id [[Id N] | Ts] -> [[Id (+ N 1)] | Ts]
  Id [T | Ts] -> [T | (gc-bump Id Ts)])

\\ The lattice partial order ⊑ : A ⊑ B iff every count in A is ≤ B's. Equality
\\ is ⊑ both ways — order-independent, so it is the right notion for the laws.
(define gc-leq?
  {gcounter --> gcounter --> boolean}
  [gc As] B -> (gc-all-leq As B))

(define gc-all-leq
  {(list gtally) --> gcounter --> boolean}
  [] _ -> true
  [[Id N] | Rest] B -> (and (<= N (gc-get Id (gc-tallies B)))
                            (gc-all-leq Rest B)))

(define gc-tallies
  {gcounter --> (list gtally)}
  [gc Ts] -> Ts)

(define gc-eq?
  {gcounter --> gcounter --> boolean}
  A B -> (and (gc-leq? A B) (gc-leq? B A)))

\\ -- the semilattice laws, as executable property checks (tier b) -----------
(define gc-idempotent?
  {gcounter --> boolean}
  A -> (gc-eq? (gc-merge A A) A))

(define gc-commutative?
  {gcounter --> gcounter --> boolean}
  A B -> (gc-eq? (gc-merge A B) (gc-merge B A)))

(define gc-associative?
  {gcounter --> gcounter --> gcounter --> boolean}
  A B C -> (gc-eq? (gc-merge A (gc-merge B C))
                   (gc-merge (gc-merge A B) C)))

\\ ===========================================================================
\\ LWW-Register — last-writer-wins. The value is INDIVISIBLE from its clock:
\\ a register cannot be constructed without (timestamp, replica-id), so a merge
\\ that "forgets" to compare clocks cannot be written — the type forbids it.
\\ merge = pick the writer with the greater (timestamp, id); that pair is a
\\ total order, so max over it is a genuine semilattice join.
\\ ===========================================================================

(datatype register
  V : string; Ts : number; Id : string;
  =====================================
  [lww V Ts Id] : register;)

\\ strict "A was written after B": later timestamp wins; ties by replica id
(define lww-after?
  {number --> string --> number --> string --> boolean}
  T1 I1 T2 I2 -> (if (> T1 T2)
                     true
                     (if (< T1 T2)
                         false
                         (str-gt? I1 I2))))

(define lww-merge
  {register --> register --> register}
  [lww V1 T1 I1] [lww V2 T2 I2] -> (if (lww-after? T1 I1 T2 I2)
                                       [lww V1 T1 I1]
                                       [lww V2 T2 I2]))

(define lww-eq?
  {register --> register --> boolean}
  [lww V1 T1 I1] [lww V2 T2 I2] -> (and (= V1 V2) (and (= T1 T2) (= I1 I2))))

(define lww-idempotent?
  {register --> boolean}
  A -> (lww-eq? (lww-merge A A) A))

(define lww-commutative?
  {register --> register --> boolean}
  A B -> (lww-eq? (lww-merge A B) (lww-merge B A)))

(define lww-associative?
  {register --> register --> register --> boolean}
  A B C -> (lww-eq? (lww-merge A (lww-merge B C))
                    (lww-merge (lww-merge A B) C)))

\\ ===========================================================================
\\ LWW-Map (a document) — a map of field-name -> LWW-Register, merged
\\ per-field. This is the demoable CRDT: two clients edit the same record
\\ offline, each field keeps the last writer, and the documents converge.
\\ ===========================================================================

(datatype doc
  K : string; R : register;
  =========================
  [K R] : field;

  Fs : (list field);
  ================
  [doc Fs] : doc;)

(define doc-get
  {string --> (list field) --> (list register)}   \\ [] = absent, [R] = present
  _ [] -> []
  K [[K R] | _] -> [R]
  K [_ | Fs] -> (doc-get K Fs))

(define doc-has?
  {string --> (list field) --> boolean}
  _ [] -> false
  K [[K _] | _] -> true
  K [_ | Fs] -> (doc-has? K Fs))

(define doc-merge
  {doc --> doc --> doc}
  [doc As] [doc Bs] -> [doc (append (doc-merge-shared As Bs)
                                    (doc-only Bs As))])

(define doc-merge-shared
  {(list field) --> (list field) --> (list field)}
  [] _ -> []
  [[K R] | Rest] Bs -> [[K (doc-field-merge R (doc-get K Bs))] | (doc-merge-shared Rest Bs)])

(define doc-field-merge
  {register --> (list register) --> register}
  R [] -> R
  R [R2] -> (lww-merge R R2))

(define doc-only
  {(list field) --> (list field) --> (list field)}
  [] _ -> []
  [[K R] | Rest] As -> (if (doc-has? K As)
                           (doc-only Rest As)
                           [[K R] | (doc-only Rest As)]))
