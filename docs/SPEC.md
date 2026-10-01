# Muntin product specification

## Product intent

Muntin is a Mojo-native web application framework whose durable value lives above the transport layer: a small typed application API, routing, extraction, validation/serialization, middleware, errors, observability, testing, and strong developer ergonomics.

The project intentionally starts smaller than a production web framework. The first milestones prove the architecture and application model before expanding surface area.

## Product principles

- Muntin owns the application contract.
- Backends are replaceable implementation details.
- Developer experience is specified before broad internal abstraction.
- Static/compile-time validation is preferred where it produces clear value.
- Low-level escape hatches remain available.
- Real executable tests are the completion oracle.
- Current Mojo limitations are measured, not guessed around.

## M0 — architecture bootstrap

M0 is complete only when every M0 feature in `feature_list.json` has executable evidence.

### Repository and toolchain

- Initialize a coherent Mojo project using the currently supported project/package approach for the installed stable toolchain.
- Record the exact Mojo version used for verification.
- Provide executable `./scripts/check.sh` and `./scripts/test.sh` commands that fail on real errors.

### Muntin-owned application core

Implement the smallest useful contracts needed for request dispatch:

- application entry point (`App` or proven equivalent);
- Muntin-owned `Request`;
- Muntin-owned `Response`;
- minimal method/status/body representation;
- route/handler registration sufficient for one static `GET` route;
- a narrow backend/application dispatch seam.

Naming may change if Mojo constraints require it, but the dependency boundary may not be replaced with a Flare-owned application API.

### Demonstrable vertical slice

A checked-in executable test must prove:

```text
GET /hello -> status 200 -> body "hello"
```

The test must exercise Muntin's real routing/application dispatch, not call a standalone handler directly.

### Backend replaceability proof

- A small in-memory/reference backend or `TestClient` drives the application without opening a real network socket.
- The in-memory path exercises the same Muntin backend/application seam intended for real transports.
- No public Muntin API exposes or requires Flare types.
- Muntin core modules do not import Flare.

### M0 developer-experience guardrail

M0 does not need the full `docs/DX.md` API, but it must not create a public design that obviously prevents the canonical direction. The Hello World example should remain conceptually small: define a handler, register a route on an application, dispatch/test it.

If the exact target route syntax is unsupported, record a minimal compiler reproduction rather than creating speculative metaprogramming.

### Documentation and state

- `docs/ARCHITECTURE.md` matches the implemented dependency direction.
- `docs/DX.md` distinguishes proven API from aspirational syntax.
- `AGENT_PROGRESS.md` records the last verified state and next increment.
- `feature_list.json` changes a feature to passing only after executable evidence exists.
- `git diff --check` passes.

## Explicit M0 non-goals

Do not implement these merely because mature frameworks have them:

- custom async runtime/executor;
- raw production socket management;
- TLS;
- HTTP/2 or HTTP/3;
- QUIC;
- WebSockets;
- production Flare integration beyond a tiny disposable feasibility spike if needed;
- JSON/schema framework;
- dependency injection;
- database/ORM layer;
- authentication;
- OpenAPI generation;
- template engine;
- deployment tooling;
- performance optimization before a baseline exists.

## M0.5 — typed handler feasibility spike

Purpose: before adding a network backend, verify on Mojo 1.1.0 that the core typed-handler registration shape, `app.get["/users/{id}"](get_user)`, is feasible. Only that shape is in scope; multiple or non-`Int` path parameters, query parameters, raising handlers, state, JSON and async are not. Inserted ahead of M1 because the answer can change the public API; M2 still follows M1.

Non-goals: production routing, JSON, OpenAPI, middleware, Flare. Prototypes live in `tests/`; `src/muntin` does not change. Acceptance is in `feature_list.json` (M0.5-001 to M0.5-003).

## M1 — Flare transport adapter

After M0 is fully verified, integrate a released/pinned Flare version behind the existing Muntin backend seam.

M1 acceptance:

- compatible Mojo and Flare versions are recorded and reproducible;
- the adapter lives outside Muntin core and depends inward on Muntin contracts;
- application handlers keep Muntin-owned signatures;
- adapter contract tests pass, converting Flare request -> Muntin `Request` -> `App.handle` -> Muntin `Response` -> Flare response without a socket;
- the locked `flare` environment installs and `./scripts/check_flare.sh` passes in CI on both Ubuntu and macOS (M1-002);
- a real localhost HTTP request reaches a Muntin route through Flare and receives the expected response;
- all M0 architecture tests continue to pass without weakening their intent;
- any conversion/allocation impedance mismatch is documented.

M1 does not replace Muntin's router, request/response model, or public middleware design with Flare's equivalents.

## M2 — typed application ergonomics

M2 begins only after the transport seam is proven in both in-memory and real-network paths.

Explore and verify, in roughly this order:

- compile-time route literal representation where practical;
- typed path extraction;
- typed query extraction;
- request-body conversion/validation;
- typed response conversion/serialization;
- an application-error model compatible with current Mojo;
- `TestClient` ergonomics matching application semantics;
- foundations for schema/OpenAPI generation.

Each public API addition should be demonstrated by a small canonical example in `docs/DX.md` and executable tests.

## M3 — composition and production ergonomics

Potential work after M2 is stable:

- middleware;
- application state/context;
- structured errors;
- OpenAPI/schema output;
- observability hooks;
- streaming;
- graceful lifecycle integration;
- performance benchmarks and allocation profiling.

M3 scope should be cut into independently verifiable milestones rather than attempted as one framework rewrite.

## Long-term success criterion

Muntin earns its existence if application code is materially clearer, safer, or more statically verifiable than using a networking library directly while preserving an escape hatch for low-level work.

Raw benchmark wins alone are not sufficient. A thin Flare re-export is not sufficient. A beautiful API that cannot survive backend/toolchain evolution is not sufficient.
