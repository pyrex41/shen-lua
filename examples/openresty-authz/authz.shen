\\ authz.shen — the TYPED core of the multi-tenant authorization demo.
\\
\\ This is the "structure the agent cannot bypass," in the type system. The
\\ policy itself (who may access what) is the Prolog proof chain in app.shen;
\\ this file owns the two things that must be provably total:
\\
\\   1. `decision` — an authorization verdict. The ONLY way app.shen turns a
\\      stored document into a response is `render-doc`, and `render-doc` is a
\\      total function over `decision` that reveals content for NO shape other
\\      than [granted ...]. So "a document reached the client" implies "a
\\      granted witness was constructed," checked at load time by Shen's
\\      sequent-calculus typechecker — the runtime analogue of Shen-Backpressure's
\\      shengen guard types, honest about the fact that the facts are dynamic.
\\
\\   2. `val` — the tagged JSON value space (identical to the guestbook example's
\\      rules.shen), so app.lua marshals one shape both ways.
\\
\\ Loaded under (tc +): a type error here aborts worker startup, before the
\\ server takes a request.

\\ -- the value space of a decoded JSON body (same tags as the guestbook) ------
(datatype val
  X : string;
  ============
  [s X] : val;

  X : number;
  ============
  [n X] : val;

  X : boolean;
  ============
  [b X] : val;

  Es : (list entry);
  ==================
  [obj Es] : val;

  Vs : (list val);
  ================
  [arr Vs] : val;)

(datatype entry
  K : string; V : val;
  ====================
  [K V] : entry;)

\\ -- the authorization verdict ------------------------------------------------
\\ [granted User Tenant Resource] : the proof chain closed — the request is
\\   authenticated as User, Resource belongs to Tenant, and User has access.
\\ [denied Why] : a premise failed; Why is the discharge report (which one).
(datatype decision
  U : string; T : string; R : string;
  ====================================
  [granted U T R] : decision;

  Why : string;
  =============
  [denied Why] : decision;)

\\ -- render-doc: the guarded projection ---------------------------------------
\\ Total over `decision`. Content is placed in the body for [granted ...] and
\\ for nothing else, so a document literally cannot be serialized on a denied
\\ path. This is where the type system does the enforcing.
(define render-doc
  {decision --> string --> val}
  [granted U T R] Content -> [obj [["ok" [b true]]
                                   ["user" [s U]]
                                   ["tenant" [s T]]
                                   ["resource" [s R]]
                                   ["content" [s Content]]]]
  [denied Why] _ -> [obj [["ok" [b false]] ["error" [s Why]]]])

\\ HTTP status for a decision — also total, also load-time checked.
(define decision-status
  {decision --> number}
  [granted _ _ _] -> 200
  [denied _] -> 403)
