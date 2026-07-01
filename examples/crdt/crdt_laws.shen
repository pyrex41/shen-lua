\\ crdt_laws.shen — TIER (c): machine-checked proofs in Shen's sequent calculus.
\\
\\ crdt.shen checks the merge laws by EXECUTION (tier b: gc-commutative? etc.
\\ run over sample states). That tests instances. This file goes further: it
\\ encodes equational logic as a `datatype` and has Shen's TYPE CHECKER verify
\\ UNIVERSALLY-QUANTIFIED proofs — no inputs, all cases at once. Load it under
\\ (tc +): if it loads, every proof below has been checked; a wrong proof is a
\\ type error that aborts the load (see thm-bogus, commented out).
\\
\\ HONEST SCOPE. The three semilattice laws (comm/assoc/idem) are taken here as
\\ AXIOMS — they are what any CRDT merge must satisfy, and what tier (b)
\\ property-checks for the *executable* gc-merge. What the checker proves below
\\ are universal CONSEQUENCES of those axioms (e.g. absorption: re-merging
\\ already-merged state is a no-op — directly a convergence/stability fact).
\\ It does NOT re-derive the axioms from gc-merge's Lua definition; closing that
\\ model↔code gap (induction over the tally-list representation) is real proof
\\ engineering and is deliberately out of scope. So: tier (b) certifies the
\\ running code satisfies the laws on instances; tier (c) proves, for all
\\ inputs, the algebra those laws generate — and proves it by a checked
\\ derivation a theorem prover would recognize, not by testing.
\\
\\ This is also the answer to "is the sequent calculus enough?": yes — free
\\ variables in a rule are universally quantified (Prolog variables), `>>`
\\ gives hypothetical reasoning, and a proof is a term whose TYPE is the
\\ proposition (Curry–Howard). The trade vs Coq/Agda is trust + automation +
\\ totality, not raw expressiveness (see README).

\\ -- equational logic over a binary `join`, entirely at the type level --------
\\ A term of type (eq S T) is a PROOF that S = T. S and T are type expressions;
\\ the variables X Y Z W are universally quantified over each rule.
(datatype semilattice-proofs
  \\ equality is reflexive, symmetric, transitive ...
  ___________
  [refl] : (eq X X);

  P : (eq X Y);
  =============
  [sym P] : (eq Y X);

  P : (eq X Y); Q : (eq Y Z);
  ===========================
  [trans P Q] : (eq X Z);

  \\ ... and a congruence: equals rewrite under `join` on either side. The
  \\ context (the unchanged side) lives only in the TYPE, so unification with
  \\ the goal fixes it and the proof term stays free of value/type confusion.
  P : (eq X Y);
  =====================================
  [cong-l P] : (eq (join X W) (join Y W));

  P : (eq X Y);
  =====================================
  [cong-r P] : (eq (join W X) (join W Y));

  \\ the three SEMILATTICE AXIOMS — the defining laws of any state-based CRDT
  \\ merge (a join-semilattice). These are exactly the tier-(b) checks.
  ___________________________________
  [comm] : (eq (join X Y) (join Y X));

  _____________________________________________________
  [assoc] : (eq (join (join X Y) Z) (join X (join Y Z)));

  ___________________________
  [idem] : (eq (join X X) X);)

\\ -- the theorems ------------------------------------------------------------
\\ Each is a function whose RESULT TYPE is the proposition and whose body is the
\\ proof term. `unit` is just a placeholder argument so the signature is a
\\ well-formed arrow; the proof is the return value the checker validates.

\\ idempotence (re-stated as a proof object, one step)
(define proof-idempotent
  { unit --> (eq (join A A) A) }
  _ -> [idem])

\\ commutativity is symmetric (derive the mirror from the axiom)
(define proof-comm-sym
  { unit --> (eq (join B C) (join C B)) }
  _ -> [sym [comm]])

\\ ABSORPTION — the convergence-relevant one: merging B into an already-merged
\\ (join A B) changes nothing.  (join (join A B) B) = (join A B).
\\   [assoc]          : (join (join A B) B) = (join A (join B B))
\\   [cong-r [idem]]  : (join A (join B B)) = (join A B)        (rewrite (join B B)->B)
\\   [trans ...]      : (join (join A B) B) = (join A B)
(define proof-absorption
  { unit --> (eq (join (join A B) B) (join A B)) }
  _ -> [trans [assoc] [cong-r [idem]]])

\\ -- a WRONG proof is a TYPE ERROR. Uncomment to watch the load abort:
\\ [assoc] alone proves (join (join A B) B) = (join A (join B B)), NOT (join A B).
\\ (define proof-bogus
\\   { unit --> (eq (join (join A B) B) (join A B)) }
\\   _ -> [assoc])
