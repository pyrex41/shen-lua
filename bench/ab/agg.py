#!/usr/bin/env python3
import json, statistics, collections, sys, os
rows = [json.loads(l) for l in open(os.path.join(os.environ.get("OUT", "/tmp/shen-lua-ab"), "results.jsonl"))]
d = collections.OrderedDict()
for r in rows:
    d.setdefault((r["suite"], r["key"]), {}).setdefault(r["impl"], []).append(r["val"])
cur = None
for (suite, key), v in d.items():
    if suite != cur:
        print(f"\n### {suite}\n\n| case | main min | main median | branch min | branch median | min ratio | n |\n|---|---:|---:|---:|---:|---:|---:|"); cur = suite
    b, n = v.get("base"), v.get("new")
    if any(isinstance(x, str) for x in (b or []) + (n or [])):
        print(f"| {key} | {sorted(set(map(str,b or [])))} | | {sorted(set(map(str,n or [])))} | | | |"); continue
    f = lambda xs: (f"{min(xs):.4g}", f"{statistics.median(xs):.4g}") if xs else ("—", "—")
    bm, bmed = f(b); nm, nmed = f(n)
    ratio = f"{min(n)/min(b):.2f}" if b and n and min(b) > 0 else "—"
    print(f"| {key} | {bm} | {bmed} | {nm} | {nmed} | {ratio} | {len(n or b)} |")
