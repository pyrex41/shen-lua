\\ app.shen — routing + storage orchestration (loaded with the typechecker OFF).
\\
\\ This is the effectful "shell" around the typed core in validate.shen. It
\\ dispatches on HTTP method + path, calls the typed validators, and talks to
\\ storage through the Lua interop bridge — `host.store_add` / `host.store_list`
\\ are plain Lua functions backed by an nginx lua_shared_dict (see app.lua).
\\ I/O is effectful, so this half is untyped on purpose; it still calls the
\\ typed functions (validate-message, find-val) from validate.shen directly.
\\
\\ Entry point: (route Method Path Body) -> [Status BodyVal], where BodyVal is
\\ a `val` (the same tagged shape as the input) that app.lua turns into JSON.

\\ -- val constructors (build the JSON response) -------------------------------
(define vstr   X -> [s X])
(define vbool  X -> [b X])
(define vnum   X -> [n X])
(define vobj   Pairs -> [obj Pairs])
(define varr   Vs -> [arr Vs])

\\ -- GET /api/messages : list the guestbook -----------------------------------
\\ host.store_list returns a Lua array of [name message] pairs, which the
\\ interop marshals to a Shen list of two-element lists.
(define row->val
  [Name Message] -> (vobj [["name" (vstr Name)] ["message" (vstr Message)]])
  _ -> (vobj []))

(define list-messages
  -> (let Rows (lua.call "host.store_list" [])
       [200 (vobj [["messages" (varr (map (function row->val) Rows))]])]))

\\ -- POST /api/messages : validate, then store --------------------------------
(define field-string
  K Es -> (first-string (find-val K Es)))

(define first-string
  [[s S]] -> S
  _ -> "")

(define store-message
  [obj Es] -> (lua.call "host.store_add"
                        [(field-string "name" Es) (field-string "message" Es)])
  _ -> 0)

(define create-message
  Body -> (let Errs (validate-message Body)
            (if (empty? Errs)
                (do (store-message Body)
                    [201 (vobj [["ok" (vbool true)]])])
                [400 (vobj [["errors" (varr (map (function vstr) Errs))]])])))

\\ -- the router ---------------------------------------------------------------
(define route
  "GET"  "/api/messages" _    -> (list-messages)
  "POST" "/api/messages" Body -> (create-message Body)
  _ _ _ -> [404 (vobj [["error" (vstr "not found")]])])
