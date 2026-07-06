# Strong Ideas: Shen at the Edge, in Systems Code, and in Ops

This repo shows the small version of a larger pattern: put the hard semantic
rules in typed Shen, then run the same rules wherever decisions are made.
`shen-lua` gives LuaJIT/OpenResty deployment, `shen-rust` gives native systems
embedding and verification, `shen-go` gives static operational binaries, and
browser-targeted Shen builds can remove client/server drift.

## The Shape

Write one compact Shen core for:

- domain types and invariants
- request validation and routing contracts
- authorization and policy rules
- state transition laws
- config generation rules
- explanation/proof terms for audit

Then project that core into the host that owns the boundary:

- **OpenResty/LuaJIT** for edge enforcement and hot-path request handling.
- **Rust** for native libraries, offline verification, crypto, Cedar
  integration, and performance-critical kernels.
- **Go** for CLIs, Kubernetes controllers, admission webhooks, operators, and
  CI checks.
- **JavaScript/browser builds** for client validation from the same source of
  truth.

The payoff is that policy, validation, generation, and audit stop being
separate hand-maintained implementations. The Shen file becomes the semantic
artifact; host code becomes glue, I/O, persistence, and acceleration.

## What Becomes Buildable

- **Verified API gateways and edge policy engines.** A request reaches a
  backend only if route, tenant, JWT claims, resource, action, and backend
  destination satisfy one typed policy.
- **Policy compilers with proof backpressure.** Generate Cedar, OpenResty,
  Kubernetes, JSON Schema, or other policy/config artifacts from Shen, then
  check that generated output still preserves the source invariant.
- **Infrastructure safety controllers.** Use Shen-Go to reject unsafe cluster
  changes: public ingress without proof, workloads without limits, secrets in
  untrusted namespaces, or tenant routes that break isolation.
- **Financial and ledger cores.** Encode balance conservation, settlement state
  machines, idempotency, replay protection, and audit completeness as rules and
  types, then serve them from Rust and gate them at the edge.
- **Agent guardrails and tool routers.** Treat every tool call as a typed state
  transition with capability policy, input contract, budget accounting, allowed
  side effects, and output obligations.

## A Good Product Slice

A first serious product would be a typed policy/config compiler:

```text
policy.shen
  -> openresty/policy.lua       request-time enforcement
  -> policy.cedar               authorization engine artifact
  -> admission-webhook          Go platform safety gate
  -> policy-verifier            Rust CI/audit verifier
  -> client-validator.js        browser-side drift prevention
```

The demo invariant should be concrete and end-to-end:

> No request can reach a tenant resource unless the route, credentials, tenant
> binding, resource action, and backend destination all agree on the same tenant
> and permission model.

That is the useful scary part: one small verified semantic core, enforced at
every boundary where the system can go wrong.
