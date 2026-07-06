\\ examples/pcr/rules.shen — the authorization logic for proof-carrying requests.
\\
\\ A term of type (may S A R) is a PROOF that subject S may perform action A on
\\ resource R. The gateway never SEARCHES for such a term — the client carries
\\ one with the request (X-Proof), and the gateway merely CHECKS it against the
\\ judgment built from the request. Checking a given term is bounded by the
\\ term's size; search is the expensive, open-ended direction, and it never
\\ runs at request time.
\\
\\ Same logic as examples/policy/policy_proof.shen, promoted from an offline
\\ demonstration to the wire protocol — plus a delegation rule, because the
\\ payoff of carrying PROOFS instead of booleans is that proofs COMPOSE: a
\\ delegated permission is a nested term whose subterms are the entire audit
\\ chain of *why*.

(datatype authz
  \\ -- environment facts (axioms; a directory or DB would supply these) ------
  ______________________________
  [owns-fact] : (owns alice doc1);

  ______________________________________
  [alice-tenant] : (same-tenant alice doc1);

  _________________________________
  [member-fact] : (has-role bob member);

  ____________________________________
  [tenant-fact] : (same-tenant bob doc1);

  ______________________________________
  [deleg-fact] : (delegates alice carol);

  \\ -- grant rules (universal in S, A, R, T) ---------------------------------
  \\ an owner inside the resource's tenant may take ANY action on it
  P : (owns S R); Q : (same-tenant S R);
  ======================================
  [by-owner P Q] : (may S A R);

  \\ a member inside the resource's tenant may READ it
  P : (has-role S member); Q : (same-tenant S R);
  ===============================================
  [by-member-read P Q] : (may S read R);

  \\ whatever S may do, S may delegate: the delegate's proof CONTAINS the
  \\ delegator's proof — the full justification chain travels with the request
  P : (may S A R); Q : (delegates S T);
  =====================================
  [by-delegation P Q] : (may T A R);)
