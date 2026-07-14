\\ examples/pcr/rules.shen — the authority logic for proof-carrying tool calls.
\\
\\ A term of type (may S A R) is a PROOF that principal S — a human or an
\\ agent — may perform action A on resource R. The gateway never SEARCHES
\\ for such a term: the caller carries one with the request (X-Proof), and
\\ the gateway merely CHECKS it against the judgment built from the request.
\\ A delegation chain built at runtime (human -> agent -> spawned subagent)
\\ arrives pre-assembled inside the proof; checking it is bounded by its size.
\\
\\ FACTS ARE LIVE. There are no fact axioms in this file: a fact leaf is a
\\ self-describing claim — [fact owns alice crm-contacts] — discharged by the
\\ single side-condition rule below, which consults the gateway's versioned
\\ fact store (facts.lua, via the typed pcr.fact? bridge) AT PROOF-CHECK TIME.
\\ Grant a fact and proofs using it start checking; revoke it and the same
\\ proof bytes stop checking on the very next request — the engine memoizes
\\ no answers, so revocation has zero staleness at the checker. Revoking one
\\ delegation edge therefore kills every chain built through it, mid-run,
\\ while proofs that never used that edge keep working.
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

  \\ full delegation: whatever S may do, T may do — the delegate's proof
  \\ CONTAINS the delegator's proof, so the whole justification chain
  \\ travels with the request (alice -> her orchestrator agent)
  P : (may S A R); Q : (delegates S T);
  =====================================
  [by-delegation P Q] : (may T A R);

  \\ ATTENUATED delegation: S passes on READ and nothing else — the only
  \\ conclusion this rule can produce is (may T read R), so a subagent
  \\ holding delegates-read cannot construct a write proof AT ALL; the
  \\ attenuation is enforced by the type system, not by a runtime filter
  \\ (orchestrator -> the researcher subagent it spawns)
  P : (may S read R); Q : (delegates-read S T);
  =============================================
  [by-read-delegation P Q] : (may T read R);)
