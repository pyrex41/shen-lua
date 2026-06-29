\\ rules.shen — the guestbook field rules, shared verbatim by server and browser.
\\
\\ Pure, portable Shen: no Lua bridges, no JS bridges, only kernel primitives
\\ (cn, str, tlstr). The SAME file loads under shen-lua (the server, inside
\\ OpenResty) and under ShenScript (the browser). One source of truth for what a
\\ valid guestbook entry is — the client runs it for instant feedback, the
\\ server re-runs the identical rules as the authoritative check, no drift.
\\
\\ It is also fully TYPED: the server loads it under (tc +), so a type error in
\\ any rule aborts startup before the first request. Errors are built with the
\\ typed kernel ops cn/str (not make-string) precisely so the rules typecheck
\\ and stay portable at the same time.

\\ -- the value space of a decoded JSON request body ---------------------------
\\   "x" -> [s "x"]   true -> [b true]   8080 -> [n 8080]
\\   [...] -> [arr [...]]   {k:v,...} -> [obj [[k v] ...]]
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

\\ -- typed, portable helpers --------------------------------------------------

\\ portable string length: Shen's kernel has no string-length primitive, so we
\\ peel the string one char at a time with tlstr. Works on every Shen port.
(define string-length
  {string --> number}
  "" -> 0
  S -> (+ 1 (string-length (tlstr S))))

\\ key lookup in an object: [] = absent, [V] = present (a poor man's maybe).
(define find-val
  {string --> (list entry) --> (list val)}
  _ [] -> []
  K [[K V] | _] -> [V]
  K [_ | Es] -> (find-val K Es))

\\ a required string field, present and within a length bound. The error string
\\ is assembled with cn/str — both typed (string-/number-> string) and portable.
(define check-string
  {string --> number --> (list val) --> (list string)}
  Field Max [[s S]] -> (if (and (> (string-length S) 0) (<= (string-length S) Max))
                           []
                           [(cn Field (cn ": must be 1.." (cn (str Max) " characters")))])
  Field _ [_] -> [(cn Field ": must be a string")]
  Field _ []  -> [(cn Field ": is required")])

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
