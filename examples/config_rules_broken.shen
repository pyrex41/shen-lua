\\ config_rules_broken.shen — ONE bug planted in the port rule.
\\
\\ (lua.format "..." N) feeds the NUMBER N straight to string.format's %q
\\ formatter. Plain Lua only discovers that at runtime, on the first invalid
\\ config that reaches the formatter. Shen rejects this file at LOAD time:
\\ lua.format is declared [string --> string --> string] (registered from
\\ Lua via lua.function before the load), so the call below is a
\\ compile-time type error.

(define broken-check-port
  {number --> (list string)}
  N -> (if (and (integer? N) (and (>= N 1) (<= N 65535)))
           []
           [(lua.format "port: %q is not an integer in 1..65535" N)]))
