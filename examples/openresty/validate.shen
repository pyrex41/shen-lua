\\ validate.shen — the TYPED core of the guestbook app.
\\
\\ Loaded by app.lua with the typechecker ON ((tc +) is done first, and Shen's
\\ `load` snapshots the tc mode once at load start). Every rule below is
\\ proved sound at load time: a type error in a validator is rejected before
\\ the server ever handles a request, exactly like examples/config_rules.shen.
\\
\\ This is the "pure typed core" half of the layered design. The effectful
\\ half — routing and storage, which touch nginx and a shared dict — lives in
\\ app.shen and runs untyped (I/O is inherently effectful). The two files load
\\ into the same environment, so app.shen calls these typed functions freely.

\\ -- the value space of a decoded JSON request body ---------------------------
\\ app.lua marshals a cjson-decoded body into the same tagged `val` shape used
\\ by examples/config_rules.shen:
\\   "x"     -> [s "x"]      true -> [b true]      8080 -> [n 8080]
\\   [...]   -> [arr [...]]  {k:v,...} -> [obj [[k v] ...]]
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

\\ -- typed helpers ------------------------------------------------------------

\\ key lookup in an object: [] = absent, [V] = present (a poor man's maybe).
\\ Also used (untyped) from app.shen to pull fields out of a request body.
(define find-val
  {string --> (list entry) --> (list val)}
  _ [] -> []
  K [[K V] | _] -> [V]
  K [_ | Es] -> (find-val K Es))

\\ build one "field: message" string. `fmt` is the typed bridge to
\\ string.format, declared [string --> string --> string], so it takes exactly
\\ one %s arg — we assemble the rest with the kernel's own typed string ops
\\ (`cn` concatenates, `str` renders a number). Max = 0 means "no bound to show".
(define field-error
  {string --> string --> number --> string --> string}
  Field Msg 0 _    -> (fmt (cn Field ": %s") Msg)
  Field Msg Max Tl -> (fmt (cn Field ": %s") (cn Msg (cn (str Max) Tl))))

\\ a required string field, present and within a length bound. `strlen` is the
\\ typed bridge to Lua's string.len (declared from app.lua before this load).
(define check-string
  {string --> number --> (list val) --> (list string)}
  Field Max [[s S]] -> (if (and (> (strlen S) 0) (<= (strlen S) Max))
                           []
                           [(field-error Field "must be 1.." Max " characters")])
  Field _ [_] -> [(field-error Field "must be a string" 0 "")]
  Field _ []  -> [(field-error Field "is required" 0 "")])

\\ -- the rules ----------------------------------------------------------------
\\ A guestbook entry is { "name": string(1..40), "message": string(1..280) }.

(define validate-message
  {val --> (list string)}
  [obj Es] -> (append (check-string "name" 40 (find-val "name" Es))
                      (check-string "message" 280 (find-val "message" Es)))
  _ -> ["body: must be a JSON object"])

(define valid-message?
  {val --> boolean}
  B -> (empty? (validate-message B)))
