\\ examples/pcr/rules.shen — the authorization logic for proof-carrying requests.
\\
\\ A term of type (may S A R) is a PROOF that subject S may perform action A on
\\ resource R. The gateway never SEARCHES for such a term — the client carries
\\ one with the request (X-Proof), and the gateway merely CHECKS it against the
\\ judgment built from the request.
\\
\\ FACTS ARE LIVE. There are no fact axioms in this file: a fact leaf is a
\\ self-describing claim — [fact owns alice doc1] — discharged by the single
\\ side-condition rule below, which consults the gateway's versioned fact
\\ store (facts.lua, via the typed pcr.fact? bridge) AT PROOF-CHECK TIME.
\\ Grant a fact and proofs using it start checking; revoke it and the same
\\ proof bytes stop checking on the very next request — the engine memoizes
\\ no answers, so revocation has zero staleness at the checker.
\\
\\ The leaf carries its ground triple (Pred S R) because a side condition can
\\ only CHECK values, never BIND them: unification of the leaf against the
\\ client's proof term grounds Pred, S and R before the guard runs, which
\\ keeps rules like by-delegation (where S is not in the final judgment)
\\ working. It also makes every leaf readable in the audit log.
\\
\\ pcr.fact? must be registered (lua.function, app.lua) BEFORE this file is
\\ loaded under (tc +). The guard allows only the fact predicates below —
\\ a leaf can never assert a grant judgment like (may ...) directly.

(datatype authz
  \\ -- the ONE fact rule: a leaf is checked against the live store ----------
  if (pcr.fact? Pred S R)
  ________________________
  [fact Pred S R] : (Pred S R);

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
