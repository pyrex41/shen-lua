\\ app.shen — the multi-tenant authz policy + router (loaded with tc OFF).
\\
\\ The POLICY lives here as a Prolog proof chain — deliberately kept inside the
\\ Datalog fragment (ground facts, no compound terms, safe rules, negation only
\\ on ground goals), so it terminates and stays decidable without a second
\\ engine: shen-lua's native soa32 Prolog engine (FFI/int32, JIT-friendly) does
\\ the reasoning. The leaf facts are read from the durable, event-sourced store
\\ through `lua.call`, so LMDB / the log file stays the single source of truth.
\\
\\ The proof chain mirrors Shen-Backpressure's authorization example:
\\   token -> authenticated user -> tenant membership -> resource access
\\
\\ CONSISTENCY: the identity (User) and tenant (Tenant) are resolved ONCE, in
\\ Shen, BEFORE the proof, and the same values are passed into the query, the
\\ [granted ...] witness, and the discharge report. That matters because under
\\ OpenResty `host-token-user` can go over a cosocket and YIELD — if the witness
\\ re-derived the user after the proof, another request could change state in
\\ the yield window and the witness could name a different user than the chain
\\ proved. Resolving once closes that window. The remaining leaf facts read
\\ inside the query (membership, role, revocation) are local, non-yielding reads.

\\ -- leaf facts: read the durable store (Shen -> Lua) --------------------------
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
\\ User/Tenant arrive already resolved (see the CONSISTENCY note above); the rule
\\ proves the remaining premises. `receive` derefs a logic var to its value so a
\\ leaf fact can be read from the store inside a guard.
(defprolog can-read
  User Tenant R <-- (when (not (= (receive User) "")))
                    (when (not (= (receive Tenant) "")))
                    (when (host-member? (receive User) (receive Tenant)))
                    (when (not (host-revoked? (receive User) (receive R))));)

\\ can-write: all of the above, and the "editor" role in that tenant.
(defprolog can-write
  User Tenant R <-- (when (not (= (receive User) "")))
                    (when (not (= (receive Tenant) "")))
                    (when (host-member? (receive User) (receive Tenant)))
                    (when (host-role? (receive User) (receive Tenant) "editor"))
                    (when (not (host-revoked? (receive User) (receive R))));)

\\ -- discharge reports: WHICH premise failed (for the audit log) --------------
\\ Only run on a denial, over the SAME resolved User/Tenant the proof used. They
\\ re-walk the premises to name the first failure; the membership/revocation
\\ re-reads are local and non-yielding, so they cannot observe a different state
\\ than the query did within one request.
(define reason-read
  User Tenant R -> (if (= User "") "unauthenticated: token does not identify a user"
                     (if (= Tenant "") "unknown resource"
                       (if (not (host-member? User Tenant)) (cn "not a member of tenant " Tenant)
                         (if (host-revoked? User R) "access to this resource was revoked"
                           "forbidden")))))

(define reason-write
  User Tenant R -> (if (= User "") "unauthenticated: token does not identify a user"
                     (if (= Tenant "") "unknown resource"
                       (if (not (host-member? User Tenant)) (cn "not a member of tenant " Tenant)
                         (if (not (host-role? User Tenant "editor")) "requires the editor role"
                           (if (host-revoked? User R) "access to this resource was revoked"
                             "forbidden"))))))

\\ -- authorize: resolve identity ONCE, run the gate, log, return a witness ----
\\ Every call appends a decision event to the durable proof log (host-log), so
\\ the audit trail is itself replayable state, not a side channel.
(define authorize-read
  Tok R -> (decide-read (host-token-user Tok) (host-owner-tenant R) R))

(define decide-read
  User Tenant R -> (if (prolog? (can-read (receive User) (receive Tenant) (receive R)))
                       (grant User Tenant R "read")
                       (deny User Tenant R "read" (reason-read User Tenant R))))

(define authorize-write
  Tok R -> (decide-write (host-token-user Tok) (host-owner-tenant R) R))

(define decide-write
  User Tenant R -> (if (prolog? (can-write (receive User) (receive Tenant) (receive R)))
                       (grant User Tenant R "write")
                       (deny User Tenant R "write" (reason-write User Tenant R))))

(define grant
  User Tenant R Action -> (do (host-log User Action R "grant" "ok")
                              [granted User Tenant R]))

(define deny
  User Tenant R Action Why -> (do (host-log User Action R "deny" Why)
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

\\ present? distinguishes an ABSENT key ([]) from one present but empty (""), so
\\ a write can require its content field rather than silently storing "".
(define present?
  K Es -> (not (empty? (find-val K Es))))

\\ -- responses ----------------------------------------------------------------
(define bad-request
  Msg -> [400 [obj [["ok" [b false]] ["error" [s Msg]]]]])

(define bad-body
  -> (bad-request "body: must be a JSON object"))

\\ respond/write-through take a typed `decision`; both status and body come from
\\ the typed core (decision-status / render-doc), each total over `decision`.
(define respond
  [granted User Tenant R] -> [(decision-status [granted User Tenant R])
                              (render-doc [granted User Tenant R] (host-content R))]
  [denied Why]            -> [(decision-status [denied Why]) (render-doc [denied Why] "")])

(define do-read
  [obj Es] -> (respond (authorize-read (sfield "token" Es) (sfield "resource" Es)))
  _ -> (bad-body))

\\ a granted write requires a content field (missing -> 400, never a silent wipe),
\\ then mutates the store durably; a denied write touches nothing.
(define do-write
  [obj Es] -> (if (present? "content" Es)
                  (write-through (authorize-write (sfield "token" Es) (sfield "resource" Es))
                                 (sfield "content" Es))
                  (bad-request "content: is required"))
  _ -> (bad-body))

(define write-through
  [granted User Tenant R] Content -> (do (host-create Tenant R Content)
                                         [(decision-status [granted User Tenant R])
                                          (render-doc [granted User Tenant R] Content)])
  [denied Why] _ -> [(decision-status [denied Why]) (render-doc [denied Why] "")])

\\ -- admin mutations (require an admin token) ---------------------------------
(define require-admin
  Tok Body -> (if (host-is-admin? Tok) (Body) (admin-denied)))

(define admin-denied
  -> [403 [obj [["ok" [b false]] ["error" [s "admin token required"]]]]])

(define ok-obj
  -> [200 [obj [["ok" [b true]]]]])

(define do-grant
  [obj Es] -> (require-admin (sfield "token" Es)
                (freeze (do (host-grant (sfield "user" Es) (sfield "tenant" Es) (sfield "role" Es))
                            (ok-obj))))
  _ -> (bad-body))

(define do-revoke
  [obj Es] -> (require-admin (sfield "token" Es)
                (freeze (do (host-revoke (sfield "user" Es) (sfield "resource" Es))
                            (ok-obj))))
  _ -> (bad-body))

(define do-create
  [obj Es] -> (require-admin (sfield "token" Es)
                (freeze (do (host-create (sfield "tenant" Es) (sfield "resource" Es) (sfield "content" Es))
                            (ok-obj))))
  _ -> (bad-body))

\\ -- audit: the durable proof log (admin only — it lists users + reasons) -----
(define logrow->val
  [Seq U A R D Why] -> [obj [["seq" [n Seq]] ["user" [s U]] ["action" [s A]]
                             ["resource" [s R]] ["decision" [s D]] ["reason" [s Why]]]]
  _ -> [obj []])

(define do-audit
  [obj Es] -> (require-admin (sfield "token" Es)
                (freeze [200 [obj [["log" [arr (map (function logrow->val) (host-audit))]]]]]))
  _ -> (bad-body))

\\ -- the router ---------------------------------------------------------------
\\ Each handler validates its own body shape (an [obj ...] or a 400), so a
\\ bodyless POST to a real route is a 400, not a 404.
(define route
  "POST" "/api/read"          B -> (do-read B)
  "POST" "/api/write"         B -> (do-write B)
  "POST" "/api/admin/grant"   B -> (do-grant B)
  "POST" "/api/admin/revoke"  B -> (do-revoke B)
  "POST" "/api/admin/create"  B -> (do-create B)
  "POST" "/api/admin/audit"   B -> (do-audit B)
  _ _ _ -> [404 [obj [["error" [s "not found"]]]]])
