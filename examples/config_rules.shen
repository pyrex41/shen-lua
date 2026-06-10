\\ config_rules.shen — a TYPED validation layer for Lua config tables.
\\
\\ Loaded (and typechecked) by examples/config_check.lua. The Lua side
\\ marshals a nested config table into the tagged `val` representation below;
\\ everything from there on is statically typed Shen. The rules call back
\\ into Lua through the typed bridge (lua.function): string.format for
\\ message building and host.matches — a function DEFINED BY THE HOST Lua
\\ program — for Lua-pattern matching, which Shen's stdlib doesn't have.

\\ This file is loaded with the typechecker ON (config_check.lua does
\\ (tc +) first — Shen's `load` snapshots the tc mode once, at load start,
\\ so the switch has to happen before the load, not inside the file).
\\ The bridges lua.format and host.matches are registered from Lua, also
\\ before this load, with (lua.function Name Path Signature): that installs
\\ a marshaling wrapper as a Shen function and declares Signature, so the
\\ typechecker holds every call site below to it.

\\ -- the value space of marshaled Lua data -----------------------------------
\\ A Lua config value arrives as a tagged list:
\\   "x"            -> [s "x"]            booleans  -> [b true]
\\   8080           -> [n 8080]           {1, 2}    -> [arr [...]]
\\   {port = 8080}  -> [obj [["port" [n 8080]] ...]]
\\ The datatypes below give that raw cons structure a TYPE, so the validators
\\ can pattern-match it and the typechecker proves every match arm sound.

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

\\ -- typed generic helpers ----------------------------------------------------

\\ key lookup: [] = absent, [V] = present (a poor man's maybe)
(define find-val
  {string --> (list entry) --> (list val)}
  _ [] -> []
  K [[K V] | _] -> [V]
  K [_ | Es] -> (find-val K Es))

(define flat-map
  {(A --> (list B)) --> (list A) --> (list B)}
  _ [] -> []
  F [X | Xs] -> (append (F X) (flat-map F Xs)))

\\ -- the validation rules -----------------------------------------------------
\\ Each checker returns a (possibly empty) list of precise error messages.

(define check-service
  {(list val) --> (list string)}
  [[s S]] -> (if (host.matches S "^%l[%l%d%-]*$")
                 []
                 [(lua.format "service: %q is not a valid service name" S)])
  [_] -> ["service: must be a string"]
  [] -> ["service: missing required key"])

(define check-port
  {(list val) --> (list string)}
  [[n N]] -> (if (and (integer? N) (and (>= N 1) (<= N 65535)))
                 []
                 [(lua.format "port: %s is not an integer in 1..65535" (str N))])
  [_] -> ["port: must be a number"]
  [] -> ["port: missing required key"])

(define check-replicas
  {(list val) --> (list string)}
  [[n N]] -> (if (and (integer? N) (>= N 1))
                 []
                 [(lua.format "replicas: %s must be a positive integer" (str N))])
  [_] -> ["replicas: must be a number"]
  [] -> [])                                       \\ optional, defaults to 1

\\ dependent rule: cert is REQUIRED iff tls.enabled is true
(define check-tls
  {(list val) --> (list string)}
  [[obj Tls]] -> (check-tls-enabled (find-val "enabled" Tls) Tls)
  [_] -> ["tls: must be an object"]
  [] -> [])                                       \\ tls section is optional

(define check-tls-enabled
  {(list val) --> (list entry) --> (list string)}
  [[b true]] Tls -> (check-cert (find-val "cert" Tls))
  _ _ -> [])

(define check-cert
  {(list val) --> (list string)}
  [[s Cert]] -> (if (host.matches Cert "%.pem$")
                    []
                    [(lua.format "tls.cert: %q does not end in .pem" Cert)])
  _ -> ["tls.cert: required (a .pem path) when tls.enabled is true"])

(define check-hosts
  {(list val) --> (list string)}
  [[arr Vs]] -> (flat-map (/. V (check-host V)) Vs)
  [_] -> ["hosts: must be an array"]
  [] -> [])

(define check-host
  {val --> (list string)}
  [s H] -> (if (host.matches H "^[%l%d][%l%d%.%-]*$")
               []
               [(lua.format "hosts: %q is not a hostname" H)])
  _ -> ["hosts: every element must be a string"])

\\ -- entry points called from Lua ----------------------------------------------

(define validate-config
  {val --> (list string)}
  [obj Es] -> (append (check-service (find-val "service" Es))
               (append (check-port (find-val "port" Es))
                (append (check-replicas (find-val "replicas" Es))
                 (append (check-tls (find-val "tls" Es))
                         (check-hosts (find-val "hosts" Es))))))
  _ -> ["config: must be an object"])

(define valid-config?
  {val --> boolean}
  C -> (empty? (validate-config C)))
