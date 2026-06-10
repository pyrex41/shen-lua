# shen-lua: Shen on LuaJIT — an executable walkthrough

*2026-06-10T22:19:30Z by Showboat 0.6.1*
<!-- showboat-id: ffd326d2-aa1e-49c3-92f1-fd432dcd8c66 -->

This document is executable proof of what shen-lua is and how it works, built with [showboat](https://github.com/simonw/showboat) (`uv tool install showboat`). Every code block below was actually run from the repo root; `showboat verify demo/walkthrough.md` re-runs them all and confirms the outputs still hold.

**What it is:** [Shen](https://shenlanguage.org) — a functional Lisp with pattern matching, an optional sequent-calculus type system, and integrated Prolog — running on LuaJIT. Shen programs compile to KLambda (a ~46-primitive Lisp kernel); this port compiles KLambda to Lua source, which LuaJIT trace-compiles to machine code. It passes the official Shen 41.1 kernel test suite and runs (slower) on plain Lua 5.1/5.4/5.5.

## 1. The language, through the launcher

`bin/shen` runs a REPL, loads files, or evaluates one-liners. Pattern matching and currying are core Shen:

```bash
bin/shen -e "(+ 1 2)" -e "(map (+ 10) [1 2 3])" 2>/dev/null
```

```output
3
[11 12 13]
```

Definitions use pattern matching; deep recursion is fine (the compiler emits real Lua tail calls, and purely tail-recursive functions become loops):

```bash
bin/shen -e "(define fact 0 -> 1 N -> (* N (fact (- N 1))))" -e "(fact 20)" 2>/dev/null | tail -1
```

```output
2432902008176640000
```

## 2. The type system (the reason Shen exists)

Shen's types are a sequent calculus, off by default, switched on with `(tc +)`. The typechecker is the kernel's own Shen code, running here on a native FFI substrate (more below). A well-typed definition is accepted with its signature; an ill-typed call is rejected at the prompt:

```bash
printf "(tc +)\n(define double {number --> number} X -> (* 2 X))\n(double 21)\n(double \"oops\")\n" | bin/shen 2>/dev/null | grep -E "fn double|42|type error" | sed "s/^ *//"
```

```output
(2+) (fn double) : (number --> number)
(3+) 42 : number
(4+) type error
```

## 3. Integrated Prolog

`defprolog` clauses compile onto a native engine (int32 struct-of-arrays over the LuaJIT FFI — terms are plain numbers, continuations are integers). Queries run through `(prolog? ...)`:

```bash
bin/shen examples/family.shen 2>/dev/null | grep -E "ancestor|child" | head -4
```

```output
abraham is an ancestor of joseph: true
joseph is an ancestor of abraham: false
a child of jacob: joseph
an ancestor of benjamin: jacob
```

## 4. Embedding: every Shen value IS a Lua value

`require("shen")` is the public API. No marshaling layer in the middle — cons cells are Lua tables, symbols are interned tables, functions are Lua functions:

```bash
luajit -e "
local shen = require(\"shen\")
shen.boot{quiet=true}
shen.eval([[(define mean {(list number) --> number} Xs -> (/ (sum Xs) (length Xs)))]])
print(\"mean:\", shen.call(\"mean\", shen.list({3, 4, 5, 6})))
print(\"curried:\", shen.call(\"+\", 1)(41))
print(\"to Lua:\", table.concat(shen.totable(shen.eval(\"(map (* 2) [1 2 3])\")), \",\"))"
```

```output
mean:	4.5
curried:	42
to Lua:	2,4,6
```

The typechecker is callable from the host — `shen.typecheck` judges whether an expression inhabits a type (this is what powers the [Shen-Backpressure runtime policy tier](https://github.com/pyrex41/Shen-Backpressure/pull/25), where authorization = type inhabitation, ~1000 kernel inferences per decision). It resets the kernel's inference counter per call, so `*maxinferences*` acts as a per-check budget:

```bash
luajit -e "
local shen = require(\"shen\")
shen.boot{quiet=true}
print(shen.tostring(shen.typecheck(\"[1 2]\", \"(list number)\")))
print(shen.typecheck([=[[1 \"a\"]]=], \"(list number)\"))
print(shen.tostring(shen.typecheck(\"(@p 1 [true])\", \"A\")))"
```

```output
(list number)
false
(number * (list boolean))
```

## 5. Interop runs the other way too — typed

`lua.call` reaches any Lua function from Shen. The deeper feature is `lua.function`: it registers a Lua function as a real Shen function **with a declared type**, so typechecked Shen code calls into Lua and the call sites are proved sound under `(tc +)`. The showcase (`examples/config_check.lua`) uses this to validate nested Lua config tables with Shen datatype rules — and the typechecker rejects a buggy *rules file* at load time:

```bash
bin/shen -e "(lua.call \"string.rep\" [\"ab\" 3])" 2>/dev/null | tail -1 && luajit examples/config_check.lua 2>/dev/null | grep -E "OK|problem|rejected" | head -3
```

```output
ababab
good         OK
bad          5 problem(s):
rejected by the typechecker: type error in rule 1 of broken-check-port
```

## 6. How it boots fast: two caches

First-ever boot compiles 21 `.kl` kernel files to Lua (~1 s). After that, a **kernel bytecode cache** (`string.dump` of the compiled chunks) boots in ~30 ms, and a **fasl-style cache** records each `(load)`-ed program so later runs skip the reader, macroexpansion *and typechecking*. Proof — a full kernel boot plus eval, wall-clock, must come in under 250 ms:

```bash
t0=$(luajit -e "io.write(os.clock())"); luajit -e "local shen=require(\"shen\"); shen.boot{quiet=true}; assert(shen.eval(\"(+ 1 2)\") == 3)" ; luajit -e "
local t0 = os.clock()
local shen = require(\"shen\"); shen.boot{quiet=true}
local ms = (os.clock() - t0) * 1000
print(string.format(\"boot+initialise under 250ms: %s\", tostring(ms < 250)))"
```

```output
boot+initialise under 250ms: true
```

## 7. Certification: the official 41.1 test suite, from this clone

The suite is vendored in `tests/`; this runs all 134 official kernel tests (typechecker, Prolog, the works) and prints the final tally:

```bash
luajit run-41.1-tests.lua 2>/dev/null | grep -E "^(passed|failed|pass rate)" | tail -3
```

```output
passed ... 134
failed ... 0
pass rate ... 100%
```

Same result under the legacy (pure compiled-KL) engine — the native FFI substrate is an optimization, never a semantic dependency:

```bash
SHEN_FASL=off SHEN_PROLOG_ENGINE=legacy luajit run-41.1-tests.lua 2>/dev/null | grep -E "^(passed|failed)" | tail -2
```

```output
passed ... 134
failed ... 0
```

And the typechecker's native engine is **bit-for-bit faithful**: on the reference typecheck it performs *exactly* the same inference sequence as the compiled-KL kernel — 431,741 inferences — across 27 golden corpus entries:

```bash
luajit bench/golden_typecheck.lua compare 2>/dev/null | tail -1
```

```output
golden compare: 27 pass, 0 fail
```

## 8. The whole system in one file

`build/make-bundle.lua` emits a single ~6 MB `shen-bundle.lua` embedding the Lua modules, precompiled kernel bytecode, and the `.kl` sources as fallback. Proof: build it, copy it ALONE to an empty directory, boot and run the typechecker there:

```bash
luajit build/make-bundle.lua >/dev/null 2>&1 && D=$(mktemp -d) && cp build/shen-bundle.lua "$D/" && cd "$D" && luajit -e "
local shen = require(\"shen-bundle\")
shen.boot{quiet=true}
print(\"eval:\", shen.eval(\"(+ 1 2)\"))
print(\"typecheck:\", shen.tostring(shen.typecheck(\"[1 2]\", \"(list number)\")))
print(\"files present:\", 1)" && rm -rf "$D"
```

```output
eval:	3
typecheck:	(list number)
files present:	1
```

## 9. Where it stands

Measured on this machine (Apple Silicon, interleaved min-of-N): warm suite ~2.3 s vs shen-cl on SBCL ~1.6 s (≈1.5× — was 5.5× before the native engine + caches + LuaJIT mcode tuning); reference typecheck 8.9× faster than the compiled-KL path at −93% allocation; Einstein's riddle 22× faster. Install: `luarocks install shen`, the [release bundle](https://github.com/pyrex41/shen-lua/releases/latest), or clone-and-run. See README.md for the full story and doc/PERF-HANDOFF.md for the measurement history.

*Re-verify this document any time:*

    showboat verify demo/walkthrough.md
