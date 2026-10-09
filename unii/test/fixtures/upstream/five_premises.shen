\\ Upstream regression probe (see unii/docs/HANDOFF.md, "Upstream issue").
\\ Loaded under (tc +) with SHEN_FASL=off by unii/test/test_boundary.lua.

(datatype probe5-key
  L : number; I : number;
  =======================
  [probe5-key L I] : probe5-key;)

(datatype probe5-node
  K : probe5-key; T : string; B : number; Ls : (list string); O : symbol;
  ==========================================================================
  [probe5-node K T B Ls O] : probe5-node;)

(define probe5-node-text
  {probe5-node --> string}
  [probe5-node _ T _ _ _] -> T)

(define mk-probe5-node
  {number --> string --> probe5-node}
  I T -> [probe5-node [probe5-key 0 I] T 1 [] a])
