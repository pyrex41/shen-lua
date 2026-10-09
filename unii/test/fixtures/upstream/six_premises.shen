\\ Upstream regression probe (see unii/docs/HANDOFF.md, "Upstream issue").
\\ Loaded under (tc +) with SHEN_FASL=off by unii/test/test_boundary.lua.

(datatype probe6-key
  L : number; I : number;
  =======================
  [probe6-key L I] : probe6-key;)

(datatype probe6-node
  K : probe6-key; T : string; B : number; Ls : (list string); O : symbol; X : number;
  ==========================================================================
  [probe6-node K T B Ls O X] : probe6-node;)

(define probe6-node-text
  {probe6-node --> string}
  [probe6-node _ T _ _ _ _] -> T)

(define mk-probe6-node
  {number --> string --> probe6-node}
  I T -> [probe6-node [probe6-key 0 I] T 1 [] a 2])
