# Muntin architecture

## Architectural thesis

Muntin's leverage should come from application-level developer experience and compile-time/type-system guarantees. Networking machinery is replaceable infrastructure.

The architectural fulcrum is the boundary between the **Muntin-owned application model** and **transport/backend adapters**.

```text
Application code
      |
      v
+--------------------------------+
| Muntin public API              |
| App / Request / Response       |
| routes / handlers              |
| later: extraction / middleware|
+---------------+----------------+
                |
         narrow backend seam
                |
       +--------+---------+
       |                  |
       v                  v
 in-memory            Flare adapter
 reference            (M1+)
 backend                   |
                           v
                 HTTP/TLS/QUIC/reactor
```

## Invariants

### A1. Muntin owns the public application API

Public application code imports Muntin-owned concepts. Third-party transport-library types must not appear in normal handler signatures, routing APIs, middleware contracts, application-state contracts, or canonical examples.

### A2. Dependency direction points inward

Muntin core/application modules do not import Flare. Backend adapters depend on Muntin's backend/application contract.

```text
muntin core  <-  in-memory backend
muntin core  <-  flare adapter
```

Never invert this relationship merely because an adapter has a convenient abstraction.

### A3. Replaceability is executable

Transport independence is not a diagram claim. M0 must include an in-memory/reference path that exercises the same application-dispatch seam intended for transport adapters.

A refactor that makes the in-memory path bypass real routing/dispatch is an architecture regression even if tests stay green.

### A4. The backend seam stays narrow

Do not invent a universal networking abstraction. The seam should expose only what Muntin needs to accept an application request, dispatch it, and produce an application response/lifecycle result.

Do not pre-abstract executor, reactor, poller, wakeup, TLS session, QUIC stream, socket option, or backend-specific cancellation machinery into public contracts.

### A5. Protocol mechanics stay outside core

Wire parsing, sockets, TLS, HTTP/2 flow control, HTTP/3, QUIC, platform event loops, connection pools, and protocol negotiation belong to networking backends/runtimes.

### A6. Async evolution must remain survivable

Do not publish a framework-specific executor/future/task model just to fill a temporary language/runtime gap. The Muntin application model should be able to adopt future Mojo async/runtime primitives with minimal application-level breakage.

### A7. Evidence before abstraction

Add an abstraction when a current requirement, two real implementations, or a strong external constraint justifies it. A hypothetical future backend is not enough.

The in-memory backend exists to prove the seam and provide deterministic tests, not to force every networking feature into a lowest-common-denominator interface.

### A8. DX is an architectural input

`docs/DX.md` is not decoration after implementation. Public API examples constrain internal design. If internal convenience would make ordinary application code materially more verbose, reconsider the internal abstraction first.

If the desired API is impossible in the current Mojo toolchain, preserve the intended semantic property and document the proven language limitation.

## Logical components

The exact package layout must follow the supported stable Mojo toolchain, but logical dependencies should resemble:

```text
muntin/
  application core
  request/response model
  routing/handler adaptation
  backend contract

muntin/testing/
  in-memory backend / TestClient

muntin/adapters/flare/
  Flare conversion and server integration
```

Filesystem names may change. Dependency direction may not.

## M0 core model

M0 needs only enough concepts to prove a real dispatch:

- `App` or equivalent application registry/dispatcher;
- Muntin-owned `Request`;
- Muntin-owned `Response`;
- minimal HTTP method/status/body representations;
- route registration for at least one static `GET` route;
- a backend/application dispatch entry point;
- an in-memory driver/test client.

Do not design the final middleware, schema, DI, async, or streaming system during M0.

### Implemented M0 layout (Mojo 1.1.0)

```text
src/muntin/__init__.mojo   public exports: App, Request, Response
src/muntin/http.mojo       Request(method, path, body), Response(status, body)
src/muntin/app.mojo        App: route table, get[path](handler), handle(Request) -> Response
src/muntin/testing.mojo    TestClient: in-memory backend, imports only muntin modules
```

The backend seam is the single concrete method `App.handle(self, request: Request) -> Response`. A backend converts its input into a Muntin `Request`, calls `handle`, and converts the returned `Response` back. `TestClient` does exactly that without a socket; a future Flare adapter must do the same and must not route on its own. There is deliberately no backend trait yet (A7): one implementation exists, and the trait can be extracted when a second backend arrives.

Requests and responses own their data (`String` fields, copied in). No backend buffer lifetimes appear in the public types. `TestClient` borrows the `App` immutably through an origin parameter, so `App.handle` takes `self` read-only and dispatch cannot mutate routing state.

`scripts/check_boundaries.sh` enforces A2 mechanically: it fails if any module under `src/muntin` imports or mentions Flare or socket modules. `scripts/check.sh` runs it.

When `muntin/adapters/flare` arrives in M1 it must live outside the boundary-checked core path or the check must be scoped to exclude only that adapter directory.

### Handler storage candidate (M0.5)

The M0.5 spike's recommended router design stores heterogeneous handlers by erasing a thin function value to its address bits and restoring it in a trampoline instantiated for the same type. That is unsafe machinery, so under the decision threshold below it may enter `src/muntin` only as a private implementation detail: never in a public signature, with the erase/restore pair inside one generic function, and with the `size_of` guard. The safe fallback (handler as a compile-time parameter) is recorded in `docs/DX.md`. `App.handle(Request) -> Response` is the smallest seam that works for M0; streaming or async may change it later.

## Request/Response ownership

M0 should choose the simplest ownership model that compiles cleanly and supports deterministic tests. Do not prematurely optimize around zero-copy wire buffers if that leaks backend lifetimes into Muntin's durable API.

Before changing the ownership model later, measure the cost and document the concrete requirement that justifies additional lifetime complexity.

## Flare policy

Flare is a candidate backend because it already provides a substantial Mojo networking stack, including server/client protocols and its own routing/handler facilities. Muntin must not simply re-export those application abstractions.

Allowed inside the Flare adapter:

- Flare server/bootstrap APIs;
- conversion from Flare request data into Muntin request data/views;
- conversion from Muntin responses into Flare responses;
- transport lifecycle integration;
- backend-specific optimizations hidden behind the adapter.

Not allowed in durable Muntin public APIs:

- Flare `Request`/`Response` types;
- Flare `Router` as Muntin's routing contract;
- Flare middleware types as Muntin's middleware contract;
- Flare extractors as Muntin's only extraction model;
- Flare reactor/cancellation/runtime types in normal application handlers.

A pinned Flare version is required once M1 depends on it. Track `main` only for explicit compatibility investigation, never as the default reproducible dependency.

## Adapter translation policy

It is acceptable for `muntin/adapters/flare` to contain inelegant conversion code if that keeps the public/core model stable. Do not contort the Muntin API merely to make one adapter thin.

Conversely, if the adapter repeatedly copies large bodies or cannot express a common feature without severe cost, treat that as evidence for a focused core abstraction change. Measure and document the tradeoff first.

## Architecture tests

At minimum, tests should establish:

1. an application route is dispatched through the Muntin-owned app model;
2. the in-memory backend can drive that route without Flare or sockets;
3. core/public modules do not import Flare;
4. once M1 exists, a real localhost request traverses Flare -> adapter -> Muntin app -> adapter -> Flare;
5. the same application handler can be exercised by both in-memory and Flare paths without changing its public signature.

## Architecture decision threshold

Create an ADR or update this document before:

- exposing any third-party type publicly;
- introducing a custom runtime/executor/task model;
- making a transport mandatory;
- adding unsafe memory/lifetime machinery to a public contract;
- changing request/response ownership semantics;
- changing the backend seam in a way that breaks adapters;
- making a provisional DX example a frozen compatibility promise.
