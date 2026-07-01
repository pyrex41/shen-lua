\\ app.shen — the multi-tenant authz policy + router (loaded with tc OFF).
\\
\\ The POLICY lives here as a Prolog proof chain — deliberately kept inside the
\\ Datalog fragment (ground facts, no compound terms, safe rules, negation only
\\ on ground goals), so it terminates and stays decidable without a second
\\ engine: shen-lua's native soa32 Prolog engine (FFI/int32, JIT-friendly) does
\\ the reasoning. The leaf facts are NOT asserted into the engine — they are
\\ read from the durable, event-sourced store on demand through `lua.call`, so
\\ LMDB / the log file stays the single source of truth and no per-worker fact
\\ cache can go stale. Prolog composes; the store supplies the facts.
\\
\\ The proof chain mirrors Shen-Backpressure's authorization example:
\\   token -> authenticated user -> tenant membership -> resource access
\\ Each step must hold before the next is tried.

\\ -- leaf facts: read the durable store (Shen -> Lua) --------------------------
\\ `receive` injects a Shen runtime value (the token / resource) into the query;
\\ everything reachable from it is a ground call into the store.
(define host-token-user   Tok    -> (lua.call "host.token_user" [Tok]))
(define host-is-admin?    Tok    -> (lua.call "host.is_admin" [Tok]))
(define host-owner-tenant R      -> (lua.call "host.owner_tenant" [R]))
(define host-member?      U T    -> (lua.call "host.member" [U T]))
(define host-role?        U T Ro -> (lua.call "host.role" [U T Ro]))
(define host-revoked?     U R    -> (lua.call "host.revoked" [U R]))
(define host-content      R      -> (lua.call "host.content" [R]))
(define host-grant        U T Ro -> (lua.call "host.grant" [U T Ro]))
(define host-revoke       U R    -> (lua.call "host.revoke" [U R]))
(define host-create       T R C  -> (lua.call "host.create" [T R C]))
(define host-log      U A R D Wy -> (lua.call "host.log" [U A R D Wy]))
(define host-audit               -> (lua.call "host.audit" []))

\\ -- the policy, as a Prolog proof chain (Datalog fragment) -------------------
\\ can-read: authenticated, resource exists, member of its tenant, not revoked.
(defprolog can-read
  Tok R <-- (is U (host-token-user (receive Tok)))
            (when (not (= U "")))
            (is T (host-owner-tenant (receive R)))
            (when (not (= T "")))
            (when (host-member? U T))
            (when (not (host-revoked? U (receive R))));)

\\ can-write: all of the above, and the "editor" role in that tenant.
(defprolog can-write
  Tok R <-- (is U (host-token-user (receive Tok)))
            (when (not (= U "")))
            (is T (host-owner-tenant (receive R)))
            (when (not (= T "")))
            (when (host-member? U T))
            (when (host-role? U T "editor"))
            (when (not (host-revoked? U (receive R))));)

\\ -- discharge reports: WHICH premise failed (for the audit log) --------------
\\ The Prolog rule above is the authoritative gate; these only explain a denial,
\\ walking the same premises in order so the reason names the first that failed.
(define reason-read
  U T R -> (if (= U "") "unauthenticated: token does not identify a user"
             (if (= T "") "unknown resource"
               (if (not (host-member? U T)) (cn "not a member of tenant " T)
                 (if (host-revoked? U R) "access to this resource was revoked"
                   "forbidden")))))

(define reason-write
  U T R -> (if (= U "") "unauthenticated: token does not identify a user"
             (if (= T "") "unknown resource"
               (if (not (host-member? U T)) (cn "not a member of tenant " T)
                 (if (not (host-role? U T "editor")) "requires the editor role"
                   (if (host-revoked? U R) "access to this resource was revoked"
                     "forbidden"))))))

\\ -- authorize: run the gate, log the decision, return a typed witness --------
\\ Every call appends a decision event to the durable proof log (host-log), so
\\ the audit trail is itself replayable state, not a side channel.
(define authorize-read
  Tok R -> (if (prolog? (can-read (receive Tok) (receive R)))
               (grant Tok R "read")
               (deny Tok R "read" (reason-read (host-token-user Tok)
                                               (host-owner-tenant R) R))))

(define authorize-write
  Tok R -> (if (prolog? (can-write (receive Tok) (receive R)))
               (grant Tok R "write")
               (deny Tok R "write" (reason-write (host-token-user Tok)
                                                 (host-owner-tenant R) R))))

(define grant
  Tok R Action -> (let U (host-token-user Tok)
                    (let T (host-owner-tenant R)
                      (do (host-log U Action R "grant" "ok")
                          [granted U T R]))))

(define deny
  Tok R Action Why -> (do (host-log (host-token-user Tok) Action R "deny" Why)
                          [denied Why]))

\\ -- request field access -----------------------------------------------------
(define find-val
  _ [] -> []
  K [[K V] | _] -> [V]
  K [_ | Es] -> (find-val K Es))

(define sfield
  K Es -> (sfirst (find-val K Es)))

(define sfirst
  [[s S]] -> S
  _ -> "")

\\ -- handlers -----------------------------------------------------------------
\\ respond fetches the document ONLY on a granted decision (no content is even
\\ read on a denial), then hands both to the typed render-doc.
(define respond
  [granted U T R] -> [200 (render-doc [granted U T R] (host-content R))]
  [denied Why]    -> [403 (render-doc [denied Why] "")])

(define do-read
  Es -> (respond (authorize-read (sfield "token" Es) (sfield "resource" Es))))

(define do-write
  Es -> (let D (authorize-write (sfield "token" Es) (sfield "resource" Es))
          (write-through D Es)))

\\ a granted write actually mutates the store (durably), then reports; a denied
\\ write reports without touching anything.
(define write-through
  [granted U T R] Es -> (do (host-create T R (sfield "content" Es))
                            [200 (render-doc [granted U T R] (sfield "content" Es))])
  [denied Why]    _  -> [403 (render-doc [denied Why] "")])

\\ -- admin mutations (require an admin token) ---------------------------------
(define require-admin
  Tok Body -> (if (host-is-admin? Tok) (Body) (admin-denied)))

(define admin-denied
  -> [403 [obj [["ok" [b false]] ["error" [s "admin token required"]]]]])

(define ok-obj
  -> [200 [obj [["ok" [b true]]]]])

(define do-grant
  Es -> (require-admin (sfield "token" Es)
          (freeze (do (host-grant (sfield "user" Es) (sfield "tenant" Es) (sfield "role" Es))
                      (ok-obj)))))

(define do-revoke
  Es -> (require-admin (sfield "token" Es)
          (freeze (do (host-revoke (sfield "user" Es) (sfield "resource" Es))
                      (ok-obj)))))

(define do-create
  Es -> (require-admin (sfield "token" Es)
          (freeze (do (host-create (sfield "tenant" Es) (sfield "resource" Es) (sfield "content" Es))
                      (ok-obj)))))

\\ -- audit: the durable proof log --------------------------------------------
(define logrow->val
  [Seq U A R D Why] -> [obj [["seq" [n Seq]] ["user" [s U]] ["action" [s A]]
                             ["resource" [s R]] ["decision" [s D]] ["reason" [s Why]]]]
  _ -> [obj []])

(define do-audit
  -> [200 [obj [["log" [arr (map (function logrow->val) (host-audit))]]]]])

\\ -- the router ---------------------------------------------------------------
(define route
  "POST" "/api/read"          [obj Es] -> (do-read Es)
  "POST" "/api/write"         [obj Es] -> (do-write Es)
  "POST" "/api/admin/grant"   [obj Es] -> (do-grant Es)
  "POST" "/api/admin/revoke"  [obj Es] -> (do-revoke Es)
  "POST" "/api/admin/create"  [obj Es] -> (do-create Es)
  "GET"  "/api/audit"         _        -> (do-audit)
  _ _ _ -> [404 [obj [["error" [s "not found"]]]]])
