\\ policy.shen — a typed authorization engine, shared by the edge (shen-lua
\\ under OpenResty), the browser preview (ShenScript), and any other port.
\\ One source of truth for "who may do what", loaded under (tc +) so every rule
\\ is proved well-typed before the gateway serves a request.
\\
\\ The decision function returns not just allow/deny but the REASON — the same
\\ value the edge enforces and the preview UI renders, so an operator sees
\\ exactly why a request passed or failed. policy_proof.shen takes the same
\\ rules to their logical conclusion: an authorization IS a proof term (a
\\ permission you can typecheck), authz as type inhabitation.

\\ -- the domain --------------------------------------------------------------
\\ A principal carries its role and tenant; a resource carries its owner and
\\ tenant. Both are tagged so the typechecker proves every rule covers them.
(datatype principal
  Name : string; Role : string; Tenant : string;
  ==============================================
  [prin Name Role Tenant] : principal;)

(datatype resource
  Owner : string; Tenant : string;
  ================================
  [res Owner Tenant] : resource;)

\\ A decision is an allow or a deny, each carrying a human-readable reason.
(datatype decision
  R : string;
  =================
  [allow R] : decision;

  R : string;
  ================
  [deny R] : decision;)

\\ -- the rules ---------------------------------------------------------------
\\ Tenant isolation is checked FIRST and is absolute: no role, not even admin,
\\ crosses a tenant boundary. Within a tenant: owners may do anything; then
\\ role decides. Every branch returns a decision, so `decide` is total.

(define decide
  {principal --> string --> resource --> decision}
  [prin Name Role STenant] Action [res Owner RTenant]
    -> (if (not (= STenant RTenant))
           [deny (cn "cross-tenant: " (cn STenant (cn " cannot reach " RTenant)))]
           (if (= Name Owner)
               [allow (cn Name " owns this resource")]
               (decide-role Role Action))))

(define decide-role
  {string --> string --> decision}
  "admin"  _       -> [allow "admin role within tenant"]
  "member" "read"  -> [allow "member may read"]
  "member" "write" -> [allow "member may write"]
  "viewer" "read"  -> [allow "viewer may read"]
  Role     Action  -> [deny (cn "role " (cn Role (cn " may not " Action)))])

\\ -- accessors the host (edge / preview) calls ------------------------------
(define allowed?
  {decision --> boolean}
  [allow _] -> true
  [deny _]  -> false)

(define why
  {decision --> string}
  [allow R] -> R
  [deny R]  -> R)
