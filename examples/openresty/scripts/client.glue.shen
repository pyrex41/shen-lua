\\ client.glue.shen — browser-only glue, appended to rules.shen at build time
\\ and baked into the shaken ShenScript artifact (see build-client.sh).
\\
\\ The server never loads this; it only loads rules.shen. validate-message is
\\ the SAME function on both ends — this just marshals the browser's two form
\\ strings into the tagged `val` it expects, and returns the (list string) of
\\ errors ([] = valid). Kept tiny and out of rules.shen so the shared file
\\ stays purely the rules.
(define check-fields
  Name Message -> (validate-message [obj [["name" [s Name]] ["message" [s Message]]]]))
