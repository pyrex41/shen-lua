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

\\ this replica's effective count for Id (0 if unseen). Takes the MAX over all
\\ matching entries, so it is correct even for a malformed counter that carries
\\ a key more than once — which is what lets the laws below hold for EVERY typed
\\ gcounter, not only the well-formed (one-entry-per-id) ones gc-inc produces.
(define gc-get
  {string --> (list gtally) --> number}
  _ [] -> 0
  Id [[Id N] | Ts] -> (max-num N (gc-get Id Ts))
  Id [_ | Ts] -> (gc-get Id Ts))

\\ the join: canonicalize the union of both counters to one entry per id, each
\\ the max count seen for that id. Folding with gc-absorb dedups as it goes, so
\\ merge is idempotent/commutative/associative even on duplicate-key inputs.
(define gc-merge
  {gcounter --> gcounter --> gcounter}
  [gc As] [gc Bs] -> [gc (gc-collect Bs (gc-collect As []))])

\\ insert one tally into an accumulator, keeping the max if its id is present
(define gc-absorb
  {gtally --> (list gtally) --> (list gtally)}
  [Id N] [] -> [[Id N]]
  [Id N] [[Id M] | Ts] -> [[Id (max-num N M)] | Ts]
  T [T2 | Ts] -> [T2 | (gc-absorb T Ts)])

(define gc-collect
  {(list gtally) --> (list gtally) --> (list gtally)}
  [] Acc -> Acc
  [T | Ts] Acc -> (gc-collect Ts (gc-absorb T Acc)))

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

\\ strict "A dominates B": later timestamp wins; ties broken by replica id, and
\\ then by value. Breaking the final tie by value matters: two writes that
\\ collide on the same (timestamp, id) but carry different values are malformed
\\ (a replica never reuses a clock), yet they are still well-typed — so making
\\ the order TOTAL over (ts, id, value) keeps merge commutative/associative for
\\ every typed register, not just the well-formed ones.
(define lww-after?
  {string --> number --> string --> string --> number --> string --> boolean}
  V1 T1 I1 V2 T2 I2 -> (if (> T1 T2)
                           true
                           (if (< T1 T2)
                               false
                               (if (str-gt? I1 I2)
                                   true
                                   (if (str-gt? I2 I1)
                                       false
                                       (str-gt? V1 V2))))))

(define lww-merge
  {register --> register --> register}
  [lww V1 T1 I1] [lww V2 T2 I2] -> (if (lww-after? V1 T1 I1 V2 T2 I2)
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

\\ per-field merge, canonicalized the same way as gc-merge: fold every field of
\\ both documents into one accumulator, lww-merging when a key recurs. One entry
\\ per field name in the result, whatever order (or duplicates) the inputs had.
(define doc-merge
  {doc --> doc --> doc}
  [doc As] [doc Bs] -> [doc (doc-collect Bs (doc-collect As []))])

(define doc-absorb
  {field --> (list field) --> (list field)}
  [K R] [] -> [[K R]]
  [K R] [[K R2] | Fs] -> [[K (lww-merge R R2)] | Fs]
  F [F2 | Fs] -> [F2 | (doc-absorb F Fs)])

(define doc-collect
  {(list field) --> (list field) --> (list field)}
  [] Acc -> Acc
  [F | Fs] Acc -> (doc-collect Fs (doc-absorb F Acc)))
