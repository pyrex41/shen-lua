\\ configc.shen — a typed configuration COMPILER.
\\
\\ examples/config_rules.shen validates a config. This goes one step further:
\\ it validates AND, only if valid, EMITS deployment artifacts (a Kubernetes
\\ Deployment and an nginx server block) from the one config. The emit
\\ functions are typed over the `val` structure, so they cannot run on a config
\\ that hasn't typechecked, and `compile` returns EITHER the errors OR the
\\ generated files — never half of each.
\\
\\ Pure, portable Shen (cn/str/n->string only): the same source compiles configs
\\ on a CLI (luajit), at an admission webhook, or in a browser preview — one
\\ definition of "valid", one definition of "what it generates", everywhere.
\\ Loaded under (tc +): a bug in a generator (e.g. feeding a number where a
\\ string is required) is a type error at load, before any config is compiled.

\\ -- the value space of a config (same tagged shape as the other examples) ---
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

\\ a compile result: either the validation errors, or the generated files
(datatype artifact
  Name : string; Body : string;
  =============================
  [file Name Body] : artifact;)

(datatype output
  Errs : (list string);
  =====================
  [invalid Errs] : output;

  Files : (list artifact);
  ========================
  [compiled Files] : output;)

\\ -- generic helpers ---------------------------------------------------------
(define find-val
  {string --> (list entry) --> (list val)}
  _ [] -> []
  K [[K V] | _] -> [V]
  K [_ | Es] -> (find-val K Es))

(define lines
  {(list string) --> string}
  [] -> ""
  [L] -> L
  [L | Ls] -> (cn L (cn (n->string 10) (lines Ls))))

(define string-length
  {string --> number}
  "" -> 0
  S -> (+ 1 (string-length (tlstr S))))

\\ typed field readers with defaults (a poor man's "config with defaults")
(define get-str
  {string --> (list entry) --> string}
  K Es -> (str-or "" (find-val K Es)))

(define str-or
  {string --> (list val) --> string}
  D []      -> D
  _ [[s S]] -> S
  D [_]     -> D)

(define get-num
  {number --> string --> (list entry) --> number}
  D K Es -> (num-or D (find-val K Es)))

(define num-or
  {number --> (list val) --> number}
  D []      -> D
  _ [[n N]] -> N
  D [_]     -> D)

(define get-arr
  {string --> (list entry) --> (list val)}
  K Es -> (arr-or (find-val K Es)))

(define arr-or
  {(list val) --> (list val)}
  []         -> []
  [[arr Vs]] -> Vs
  [_]        -> [])

\\ -- validation (pure Shen; no host bridges, so it ports everywhere) ---------
(define validate-config
  {val --> (list string)}
  [obj Es] -> (append (check-service (find-val "service" Es))
               (append (check-port (find-val "port" Es))
                       (check-replicas (find-val "replicas" Es))))
  _ -> ["config: must be an object"])

(define check-service
  {(list val) --> (list string)}
  [[s S]] -> (if (> (string-length S) 0) [] ["service: must be non-empty"])
  [_]     -> ["service: must be a string"]
  []      -> ["service: required"])

(define check-port
  {(list val) --> (list string)}
  [[n N]] -> (if (and (integer? N) (and (>= N 1) (<= N 65535)))
                 []
                 ["port: must be an integer in 1..65535"])
  [_]     -> ["port: must be a number"]
  []      -> ["port: required"])

(define check-replicas
  {(list val) --> (list string)}
  [[n N]] -> (if (and (integer? N) (>= N 1)) [] ["replicas: must be a positive integer"])
  [_]     -> ["replicas: must be a number"]
  []      -> [])                                   \\ optional, defaults to 1

\\ -- the generators (typed over `val`; only reached for a valid config) ------
(define emit-k8s
  {val --> artifact}
  [obj Es] -> [file "deployment.yaml" (k8s-body (get-str "service" Es)
                                                (get-num 1 "replicas" Es)
                                                (get-num 80 "port" Es))]
  _ -> [file "deployment.yaml" ""])

(define k8s-body
  {string --> number --> number --> string}
  Service Replicas Port ->
    (lines ["apiVersion: apps/v1"
            "kind: Deployment"
            "metadata:"
            (cn "  name: " Service)
            "spec:"
            (cn "  replicas: " (str Replicas))
            "  selector:"
            (cn "    matchLabels: { app: " (cn Service " }"))
            "  template:"
            "    metadata:"
            (cn "      labels: { app: " (cn Service " }"))   \\ must match the selector
            "    spec:"
            "      containers:"
            (cn "        - name: " Service)
            (cn "          ports: [{ containerPort: " (cn (str Port) " }]"))]))

(define emit-nginx
  {val --> artifact}
  [obj Es] -> [file "server.conf" (nginx-body (get-str "service" Es)
                                              (get-num 80 "port" Es)
                                              (host-names (get-arr "hosts" Es)))]
  _ -> [file "server.conf" ""])

(define host-names
  {(list val) --> string}
  []           -> "_"
  [[s H]]      -> H
  [[s H] | Vs] -> (cn H (cn " " (host-names Vs)))
  [_ | Vs]     -> (host-names Vs))

(define nginx-body
  {string --> number --> string --> string}
  Service Port Hosts ->
    (lines [(cn "server {  # generated for " Service)
            (cn "    listen " (cn (str Port) ";"))
            (cn "    server_name " (cn Hosts ";"))
            "    location / {"
            (cn "        proxy_pass http://" (cn Service ";"))
            "    }"
            "}"]))

\\ -- the compiler: validate, then (only if clean) generate --------------------
(define compile-config
  {val --> output}
  C -> (compile-config-checked C (validate-config C)))

(define compile-config-checked
  {val --> (list string) --> output}
  C []   -> [compiled [(emit-k8s C) (emit-nginx C)]]
  _ Errs -> [invalid Errs])
