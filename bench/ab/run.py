#!/usr/bin/env python3
"""Interleaved A/B runner for two shen-lua checkouts. Appends raw rows to
$OUT/results.jsonl; bench/ab/agg.py turns them into tables.

  BASE=/path/to/main-checkout NEW=/path/to/branch-checkout \
  TLA_DIR=/path/to/shencheck/lib/tla URDR_DIR=/path/to/urdr OUT=/tmp/ab \
  python3 bench/ab/run.py SUITE ROUNDS

SUITE: deep micro bench.lua boot coldboot kernel tla urdr. Each side gets its
own kernel cache and fasl dir under $OUT, so every round after the first is
warm. bench.lua expects the official tests at ../cl-source/ShenOSKernel-42/tests
relative to each checkout (a symlink to the vendored tests/ works).
"""
import subprocess, json, os, re, sys, time, hashlib
ROOTS = {"base": os.environ["BASE"], "new": os.environ["NEW"]}
HERE = os.path.dirname(os.path.abspath(__file__))
B = os.environ.get("OUT", "/tmp/shen-lua-ab")
os.makedirs(B, exist_ok=True)
TLA_DIR = os.environ.get("TLA_DIR", "")
URDR_DIR = os.environ.get("URDR_DIR", "")
def env(impl, extra=None):
    e = dict(os.environ, SHEN_KERNEL_CACHE=f"{B}/kc.{impl}.bin", SHEN_FASL_DIR=f"{B}/fasl.{impl}")
    e.update(extra or {}); return e
def rec(suite, impl, key, val, **kw):
    with open(f"{B}/results.jsonl", "a") as f:
        f.write(json.dumps(dict(suite=suite, impl=impl, key=key, val=val, **kw)) + "\n")
def shen_file(suite, impl, path, cwd, extra=None, digest=False):
    t0 = time.time(); r0 = os.times()
    p = subprocess.run([f"{ROOTS[impl]}/bin/shen", "--hush-load", path], cwd=cwd, env=env(impl, extra),
                       capture_output=True, text=True)
    r1 = os.times(); wall = time.time() - t0
    cpu = (r1.children_user - r0.children_user) + (r1.children_system - r0.children_system)
    for line in p.stdout.splitlines():
        m = re.match(r"^([^:|]+): ([0-9.eE-]+)", line)
        if m: rec(suite, impl, m.group(1).strip(), float(m.group(2)))
    rec(suite, impl, "process CPU (user+sys)", cpu)
    if digest:
        rec(suite, impl, "stdout md5", hashlib.md5(p.stdout.encode()).hexdigest()[:10], text=True,
            allpass=("ALL PASS" in p.stdout))
def cmd(suite, impl, key, argv, cwd, extra=None, parse=None):
    t0 = time.time(); r0 = os.times()
    p = subprocess.run(argv, cwd=cwd, env=env(impl, extra), capture_output=True, text=True)
    r1 = os.times()
    cpu = (r1.children_user - r0.children_user) + (r1.children_system - r0.children_system)
    rec(suite, impl, key + " wall", time.time() - t0); rec(suite, impl, key + " CPU", cpu)
    if parse: parse(p.stdout + p.stderr)
    return p
if __name__ == "__main__":
    which = sys.argv[1]; n = int(sys.argv[2])
    for i in range(n):
        for impl in ("base", "new"):
            if which == "micro":
                shen_file("micro", impl, f"{HERE}/micro.shen", HERE)
                shen_file("curried", impl, f"{HERE}/curmain.shen", HERE)
            elif which == "bench.lua":
                def parse(out, impl=impl):
                    for line in out.splitlines():
                        m = re.match(r"Cold startup: load=([0-9.]+)s init=([0-9.]+)s total=([0-9.]+)s", line)
                        if m: rec("bench.lua", impl, "startup total (in-process)", float(m.group(3)))
                        m = re.search(r"(fib\(\d+\)) = \d+\s+in ([0-9.]+)s", line)
                        if m: rec("bench.lua", impl, m.group(1), float(m.group(2)))
                        m = re.search(r"einstein best:\s+([0-9.]+)s", line)
                        if m: rec("bench.lua", impl, "Einstein riddle (best solve)", float(m.group(1)))
                    rec("bench.lua", impl, "raw", out[-600:], text=True)
                cmd("bench.lua", impl, "bench.lua process", ["luajit", "bench.lua"], ROOTS[impl], parse=parse)
            elif which == "boot":
                cmd("boot", impl, "warm `bin/shen -e (+ 1 2)`", [f"{ROOTS[impl]}/bin/shen", "-e", "(+ 1 2)"], B)
            elif which == "coldboot":
                for f in (f"{B}/kc.cold{impl}.bin",): 
                    if os.path.exists(f): os.remove(f)
                subprocess.run(["rm", "-rf", f"{B}/fasl.cold{impl}"])
                cmd("boot", impl, "cold `bin/shen -e (+ 1 2)` (no caches)", [f"{ROOTS[impl]}/bin/shen", "-e", "(+ 1 2)"], B,
                    extra=dict(SHEN_KERNEL_CACHE=f"{B}/kc.cold{impl}.bin", SHEN_FASL_DIR=f"{B}/fasl.cold{impl}"))
            elif which == "kernel":
                def parse(out, impl=impl):
                    m = re.findall(r"passed \.\.\. (\d+)", out); rec("kernel", impl, "passed", int(m[-1]) if m else -1)
                cmd("kernel", impl, "run-kernel-tests.lua", ["luajit", "run-kernel-tests.lua"], ROOTS[impl], parse=parse)
            elif which == "tla":
                for var, pre in (("portable", ""), ("native/lua.shen", '(set *tla-native* "native/lua.shen")'),
                                 ("lua.map", f'(set *tla-native* "{HERE}/lmap.shen")')):
                    if var == "lua.map" and impl == "base": continue
                    src = open(f"{HERE}/tla_bench.shen").read()
                    path = f"{B}/tla_{var.replace('/','_')}.shen"
                    open(path, "w").write(pre + "\n" + src)
                    shen_file("tla " + var, impl, path, TLA_DIR)
            elif which == "urdr":
                for s in ("prng", "search", "world"):
                    shen_file("urdr " + s, impl, f"shen/tests/{s}/run-tests.shen", URDR_DIR, digest=True)
            elif which == "deep":
                shen_file("deep", impl, f"{HERE}/deep.shen", HERE)
