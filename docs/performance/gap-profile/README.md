# Smaller-judgment diagnostic, 2026-10-22

Source: a672a49; kernel ec16a9f; LuaJIT 2.1.1785763465, macOS arm64.
This is a sampling diagnostic, outside the accepted comparison timing cohorts.
No performance improvement is claimed. The 20-case harness first validates the
complete golden corpus and loads its authenticated fixtures. Profiling starts
after that. It covers 2,000 rounds of the other 19 judgments (38,000 calls),
excluding only interpreter-y-inferred. GC and JIT remain enabled, native is
required; routing receipts are disabled during profiling. The diagnostic loop
is fixed-order and retains one parsed expression/type pair per judgment.
It does not test application execution or representative production traffic.

Run from repository root, with the diagnostic script copied at the indicated
location (create .work/gap-profile first):

```
SHEN_KERNEL_CACHE=off SHEN_FASL=off SHEN_TYPECHECK_NATIVE=require \
SHEN_BENCH_REPEATS=1 luajit docs/performance/gap-profile/small.lua
```

The retained leaf sample profile reports cons 13%, protected calls 12%, generated
l-formula datatype functions 9%, materialize 9%, import 3%; dereference and
continuation dispatch are also visible. Sampling shares are approximate and do
not establish removable overhead or independent additive savings. Protected
calls preserve query unwinding, errors and stack-segment state; investigate
redundant layers without removing those guarantees. For boundary optimization,
attribute materializations to specific lifted guards before adding arena-native
operations; the equality guard already uses EQTERM.

Separately, corrected source-loading diagnostics retained in issue-98-evidence
show source reading/expansion 0.424s, source lowering 0.281s, KL-to-Lua defun/expr
emission 0.065s and actual Lua compilation 0.0039s across 144 calls. These are
inclusive diagnostic times from an earlier cohort, not additive phase totals
or fresh accepted timings. Prioritize the Shen front end over batching the Lua
compiler. The cold typed-load comparison is not a cache-hit measurement.
