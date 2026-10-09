\* unii/core/types.shen -- record constructors, types and boundary validation.

   Every record is a tagged list whose head symbol names the constructor; the
   same shapes appear in docs/contracts/*.md and in host/schema.lua. Numbers
   in records are exact naturals bounded by unii.max-id unless stated.

   No datatype rule has more than five premises: at the pinned shen-lua
   revision the native Prolog engine fails (undefined shen.consume<N>) when a
   file defines a double-line rule with six or more premises over other user
   datatypes (probe: test/fixtures/upstream/, run by test_boundary.lua).
   Wider records are therefore nested; code goes through the accessor and
   constructor functions below rather than matching the nesting directly. *\

\\ (key L I) covers messages [I * 2^L, (I + 1) * 2^L).
(datatype unii.key
  L : number; I : number;
  =======================
  [key L I] : unii.key;)

\\ config Epoch LeafCap [view-budget Low High]
\\        [queue-limits MaxInflight LeadWindow MaxAttempts MaxFrontier ChunkMax]
(datatype unii.view-budget
  Lo : number; Hi : number;
  ==========================================
  [view-budget Lo Hi] : unii.view-budget;)

(datatype unii.queue-limits
  Inf : number; Lead : number; Att : number; Fr : number; Ch : number;
  =====================================================================
  [queue-limits Inf Lead Att Fr Ch] : unii.queue-limits;)

(datatype unii.config
  E : number; Cap : number; VB : unii.view-budget; QL : unii.queue-limits;
  =======================================================================
  [config E Cap VB QL] : unii.config;)

(datatype unii.origin
  ______________________________
  [exact-leaf] : unii.origin;

  ______________________________
  [joined] : unii.origin;

  J : string; A : number;
  ======================================
  [summarized J A] : unii.origin;)

\\ node Key Text TextBytes [line RenderedLine LineBytes] Origin
(datatype unii.line
  Ln : string; LB : number;
  ===============================
  [line Ln LB] : unii.line;)

(datatype unii.node
  K : unii.key; T : string; B : number; L : unii.line; O : unii.origin;
  ======================================================================
  [node K T B L O] : unii.node;)

\\ What a summary job compresses. Leaf sources carry the message's SHA-256;
\\ merge sources name their two children and a digest token of the child
\\ texts. Child texts are attached to the command at dispatch time.
(datatype unii.source
  M : number; Kd : symbol; H : string;
  ==========================================
  [leaf-source M Kd H] : unii.source;

  A : unii.key; B : unii.key; D : string;
  ==========================================
  [merge-source A B D] : unii.source;)

(datatype unii.retry
  ___________________________________
  [first-attempt] : unii.retry;

  N : number;
  ===================================
  [retry-too-long N] : unii.retry;

  C : symbol;
  ===================================
  [retry-after-failure C] : unii.retry;)

\\ A queued job carries the retry hint for its next dispatch.
(datatype unii.job-status
  Rt : unii.retry;
  ===================================
  [queued Rt] : unii.job-status;

  C : string;
  ===================================
  [dispatched C] : unii.job-status;

  R : string;
  ===================================
  [blocked R] : unii.job-status;)

\\ job Id Key Attempt Status Source
(datatype unii.job
  Id : string; K : unii.key; A : number; St : unii.job-status; Src : unii.source;
  ===============================================================================
  [job Id K A St Src] : unii.job;)

\\ content ByteLength Sha256Hex Text -- the host measures and hashes the text.
(datatype unii.content
  B : number; H : string; C : string;
  ======================================
  [content B H C] : unii.content;)

(datatype unii.event
  M : number; Kd : symbol; D : string; C : unii.content;
  ======================================================
  [message-appended M Kd D C] : unii.event;

  J : string; A : number; B : number; H : string; T : string;
  ========================================================================
  [summary-completed J A B H T] : unii.event;

  J : string; A : number; C : symbol;
  ========================================================================
  [summary-failed J A C] : unii.event;)

(datatype unii.summary-input
  M : number; Kd : symbol; H : string;
  ==================================================
  [leaf-input M Kd H] : unii.summary-input;

  A : unii.key; TA : string; B : unii.key; TB : string;
  ==================================================
  [merge-input A TA B TB] : unii.summary-input;)

(datatype unii.client-event
  R : number; B : number; N : number;
  ==================================================
  [view-changed R B N] : unii.client-event;

  J : string; R : string;
  ==================================================
  [memory-blocked J R] : unii.client-event;

  R : string;
  ==================================================
  [input-rejected R] : unii.client-event;)

(datatype unii.attempt
  A : number; Rt : unii.retry;
  ======================================
  [attempt A Rt] : unii.attempt;)

\\ submit-summary CommandId JobId Key [attempt N RetryHint] Input
(datatype unii.command
  C : string; J : string; K : unii.key; At : unii.attempt; I : unii.summary-input;
  ================================================================================
  [submit-summary C J K At I] : unii.command;

  C : string; E : unii.client-event;
  ========================================================================
  [emit-client-event C E] : unii.command;)

(datatype unii.decision
  K : unii.key; O : unii.origin; B : number;
  ===============================================
  [node-committed K O B] : unii.decision;

  K : unii.key;
  ===============================================
  [view-extended K] : unii.decision;

  K : unii.key;
  ===============================================
  [view-merged K] : unii.decision;

  B : boolean;
  ===============================================
  [batch-mode B] : unii.decision;

  R : number;
  ===============================================
  [view-revision R] : unii.decision;

  J : string;
  ===============================================
  [job-created J] : unii.decision;

  J : string; P : string;
  ===============================================
  [job-retried J P] : unii.decision;

  J : string; R : string;
  ===============================================
  [job-blocked J R] : unii.decision;

  R : string;
  ===============================================
  [event-rejected R] : unii.decision;

  J : string; R : string;
  ===============================================
  [completion-ignored J R] : unii.decision;)

\\ state Config [tree Count Covered View ViewBytes Live] Jobs
\\       [counters Batch Rev NextCmd]
\\   Count    accepted messages (T)
\\   Covered  end of the committed view: messages [0, Covered) are in it
\\   View     committed main view, oldest first
\\   Live     built nodes outside the view that may still be needed: leaves
\\            past Covered and built ancestors of view nodes
\\   Jobs     summary jobs in dispatch-priority order
\\   Batch    true while a byte-budget batch is unfinished
\\   Rev      main-view revision; NextCmd next command sequence number
(datatype unii.tree
  T : number; Cv : number; V : (list unii.node); VB : number; Lv : (list unii.node);
  ==================================================================================
  [tree T Cv V VB Lv] : unii.tree;)

(datatype unii.counters
  Bt : boolean; R : number; NC : number;
  ==========================================
  [counters Bt R NC] : unii.counters;)

(datatype unii.state
  Cf : unii.config; Tr : unii.tree; Js : (list unii.job); Ct : unii.counters;
  ===========================================================================
  [state Cf Tr Js Ct] : unii.state;)

(datatype unii.result
  S : unii.state; Cs : (list unii.command); Ds : (list unii.decision);
  ====================================================================
  [result S Cs Ds] : unii.result;)

\\ ---------------------------------------------------------------- accessors

(define unii.st-config {unii.state --> unii.config} [state X _ _ _] -> X)
(define unii.st-count {unii.state --> number} [state _ [tree X _ _ _ _] _ _] -> X)
(define unii.st-covered {unii.state --> number} [state _ [tree _ X _ _ _] _ _] -> X)
(define unii.st-view {unii.state --> (list unii.node)} [state _ [tree _ _ X _ _] _ _] -> X)
(define unii.st-view-bytes {unii.state --> number} [state _ [tree _ _ _ X _] _ _] -> X)
(define unii.st-live {unii.state --> (list unii.node)} [state _ [tree _ _ _ _ X] _ _] -> X)
(define unii.st-jobs {unii.state --> (list unii.job)} [state _ _ X _] -> X)
(define unii.st-batch {unii.state --> boolean} [state _ _ _ [counters X _ _]] -> X)
(define unii.st-rev {unii.state --> number} [state _ _ _ [counters _ X _]] -> X)
(define unii.st-next-cmd {unii.state --> number} [state _ _ _ [counters _ _ X]] -> X)

(define unii.mk-state
  {unii.config --> number --> number --> (list unii.node) --> number
   --> (list unii.node) --> (list unii.job) --> boolean --> number --> number
   --> unii.state}
  Cf T Cv V VB Lv Js Bt R NC -> [state Cf [tree T Cv V VB Lv] Js [counters Bt R NC]])

(define unii.cf-epoch {unii.config --> number} [config X _ _ _] -> X)
(define unii.cf-cap {unii.config --> number} [config _ X _ _] -> X)
(define unii.cf-low {unii.config --> number} [config _ _ [view-budget X _] _] -> X)
(define unii.cf-high {unii.config --> number} [config _ _ [view-budget _ X] _] -> X)
(define unii.cf-max-inflight {unii.config --> number} [config _ _ _ [queue-limits X _ _ _ _]] -> X)
(define unii.cf-lead {unii.config --> number} [config _ _ _ [queue-limits _ X _ _ _]] -> X)
(define unii.cf-max-attempts {unii.config --> number} [config _ _ _ [queue-limits _ _ X _ _]] -> X)
(define unii.cf-max-frontier {unii.config --> number} [config _ _ _ [queue-limits _ _ _ X _]] -> X)
(define unii.cf-chunk-max {unii.config --> number} [config _ _ _ [queue-limits _ _ _ _ X]] -> X)

(define unii.mk-config
  {number --> number --> number --> number --> number --> number --> number
   --> number --> number --> unii.config}
  E Cap Lo Hi Inf Lead Att Fr Ch -> [config E Cap [view-budget Lo Hi] [queue-limits Inf Lead Att Fr Ch]])

(define unii.node-key {unii.node --> unii.key} [node X _ _ _ _] -> X)
(define unii.node-text {unii.node --> string} [node _ X _ _ _] -> X)
(define unii.node-bytes {unii.node --> number} [node _ _ X _ _] -> X)
(define unii.node-line {unii.node --> string} [node _ _ _ [line X _] _] -> X)
(define unii.node-line-bytes {unii.node --> number} [node _ _ _ [line _ X] _] -> X)
(define unii.node-origin {unii.node --> unii.origin} [node _ _ _ _ X] -> X)

(define unii.job-id {unii.job --> string} [job X _ _ _ _] -> X)
(define unii.job-key {unii.job --> unii.key} [job _ X _ _ _] -> X)
(define unii.job-attempt {unii.job --> number} [job _ _ X _ _] -> X)
(define unii.job-status {unii.job --> unii.job-status} [job _ _ _ X _] -> X)
(define unii.job-source {unii.job --> unii.source} [job _ _ _ _ X] -> X)

(define unii.dispatched?
  {unii.job --> boolean}
  [job _ _ _ [dispatched _] _] -> true
  _ -> false)

(define unii.queued?
  {unii.job --> boolean}
  [job _ _ _ [queued _] _] -> true
  _ -> false)

(define unii.blocked?
  {unii.job --> boolean}
  [job _ _ _ [blocked _] _] -> true
  _ -> false)

(define unii.leaf-job?
  {unii.job --> boolean}
  [job _ _ _ _ [leaf-source _ _ _]] -> true
  _ -> false)

\\ ------------------------------------------------------------- validation

(define unii.message-kinds
  {--> (list symbol)}
  -> [user assistant tool-call tool-result report imported-note])

(define unii.valid-kind?
  {symbol --> boolean}
  K -> (element? K (unii.message-kinds)))

\\ ASCII byte length of a kind's attribution label, e.g. "tool-call".
(define unii.kind-label-bytes
  {symbol --> number}
  user -> 4
  assistant -> 9
  tool-call -> 9
  tool-result -> 11
  report -> 6
  imported-note -> 13
  K -> (error "unii.kind-label-bytes: unknown kind ~A" K))

(define unii.failure-classes
  {--> (list symbol)}
  -> [retryable permanent])

(define unii.hex-char?
  {string --> boolean}
  C -> (element? C ["0" "1" "2" "3" "4" "5" "6" "7" "8" "9"
                    "a" "b" "c" "d" "e" "f"]))

\\ Lowercase hex SHA-256 digest text: exactly 64 hex characters.
(define unii.hex64?
  {string --> boolean}
  S -> (unii.hex-loop S 0))

(define unii.hex-loop
  {string --> number --> boolean}
  "" N -> (= N 64)
  (@s C Rest) N -> (and (< N 64) (and (unii.hex-char? C) (unii.hex-loop Rest (+ N 1)))))

(define unii.non-empty?
  {string --> boolean}
  "" -> false
  _ -> true)

\\ Problems with a configuration record; [] means valid.
(define unii.config-errors
  {unii.config --> (list string)}
  [config E Cap [view-budget Lo Hi] [queue-limits Inf Lead Att Fr Ch]] ->
    (unii.collect-errors
      [(@p (unii.pos-nat? E) "epoch must be a positive natural")
       (@p (and (unii.nat? Cap) (and (>= Cap 32) (<= Cap 65536))) "leaf cap must be in [32, 65536]")
       (@p (unii.pos-nat? Lo) "view low target must be a positive natural")
       (@p (and (unii.nat? Hi) (> Hi Lo)) "view high threshold must exceed the low target")
       (@p (and (unii.pos-nat? Inf) (<= Inf 64)) "max inflight must be in [1, 64]")
       (@p (and (unii.pos-nat? Lead) (<= Lead 4096)) "lead window must be in [1, 4096]")
       (@p (and (unii.pos-nat? Att) (<= Att 16)) "max attempts must be in [1, 16]")
       (@p (and (unii.pos-nat? Fr) (<= Fr 1048576)) "max frontier must be in [1, 2^20]")
       (@p (and (unii.pos-nat? Ch) (<= Ch 1048576)) "chunk max must be in [1, 2^20]")]))

(define unii.collect-errors
  {(list (boolean * string)) --> (list string)}
  [] -> []
  [(@p true _) | Rest] -> (unii.collect-errors Rest)
  [(@p false Msg) | Rest] -> [Msg | (unii.collect-errors Rest)])

(define unii.default-config
  {--> unii.config}
  -> (unii.mk-config 1 512 64000 128000 8 8 5 4096 16384))
