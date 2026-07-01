\\ policy_proof.shen — authorization as TYPE INHABITATION.
\\
\\ policy.shen decides allow/deny by evaluating rules (and is what the edge
\\ runs). This file shows the same authorization model as a logic: a term of
\\ type (may S A R) is a PROOF that subject S may perform action A on resource
\\ R. Grant rules are inference rules; environment facts (ownership, roles,
\\ tenancy — what a directory or DB would supply) are axioms. A request is
\\ AUTHORIZED exactly when (may S A R) is inhabited, and the inhabiting term is
\\ the justification — the audit trail of *why*, checked by the type system.
\\
\\ A DENIED request is an UNINHABITED type: no rule builds the term, so it
\\ cannot typecheck (see perm-bob-delete, commented out). "Deny by default" is
\\ not a policy line you can forget to write — it is the absence of a proof.

(datatype authz
  \\ -- environment facts (axioms; would be fetched per request) --------------
  ______________________________
  [owns-fact] : (owns alice doc1);

  _________________________________
  [member-fact] : (has-role bob member);

  ____________________________________
  [tenant-fact] : (same-tenant bob doc1);

  \\ -- grant rules (universal in S, A, R) ------------------------------------
  \\ an owner may take ANY action on what they own
  P : (owns S R);
  ===============
  [by-owner P] : (may S A R);

  \\ a member, in the resource's tenant, may READ it
  P : (has-role S member); Q : (same-tenant S R);
  ===============================================
  [by-member-read P Q] : (may S read R);)

\\ -- authorizations, as checked proof terms ----------------------------------
\\ Each function's RESULT TYPE is the permission; the body is the proof. If the
\\ file loads under (tc +), the type checker has verified every authorization.

\\ alice OWNS doc1, so she may perform ANY action A on it (A is universal):
(define perm-alice-any
  { unit --> (may alice A doc1) }
  _ -> [by-owner [owns-fact]])

\\ bob is a member in doc1's tenant, so he may READ it:
(define perm-bob-read
  { unit --> (may bob read doc1) }
  _ -> [by-member-read [member-fact] [tenant-fact]])

\\ -- denial is the absence of a proof ----------------------------------------
\\ bob may NOT delete doc1: no grant rule produces (may bob delete _) for a
\\ member, and bob does not own doc1 — the type is uninhabited. Uncomment and
\\ the load fails with a type error: you cannot fabricate the proof.
\\ (define perm-bob-delete
\\   { unit --> (may bob delete doc1) }
\\   _ -> [by-member-read [member-fact] [tenant-fact]])   \\ proves `read`, not `delete`
