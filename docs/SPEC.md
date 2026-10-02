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
- a real localhost HTTP request reaches a Muntin route through Flare and receives the expected response: `GET /hello` over loopback to Flare's `HttpServer` serving `MuntinHandler` returns status 200 and body `hello`, matching `TestClient` on the same app; the test is bounded, does not race readiness, leaves no server process behind, and runs in `./scripts/check_flare.sh` on both Ubuntu and macOS (M1-003);
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

M2-001, the first slice: `app.get["/users/{id}"](get_user)` with `def get_user(id: Int) -> String` on the production `App`, alongside existing `def() -> String` routes. `GET /users/42` calls the handler with `Int(42)`; a non-integer segment returns 400 without calling it; non-matching paths and methods return 404. The same `App` gives the same status and body through `TestClient` and a real loopback request through Flare, with routing and conversion in Muntin only. Out of scope: multiple or non-`Int` parameters, query/body extraction, other return types, raw handlers, middleware, `app.run()`. Acceptance is in `feature_list.json`.

M2-002, typed query extraction, first slice: Muntin core separates the request target into path and query when a `Request` is built, so route matching sees only the path (`/hello?x=1` routes to `/hello`, `/users/42?x=1` passes `Int(42)`), and both backends inherit the rule by passing the raw target. One query value reaches a handler as `Int`: `app.get["/items?{limit}"](list_items)` with `def list_items(limit: Int) -> String`; the route literal names the key because handler parameter names cannot be reflected. Missing, duplicated, empty or non-integer values return 400 without calling the handler; query keys and values are not percent-decoded. TestClient and a real loopback request through Flare give the same results from one registration, with query parsing in Muntin only. Out of scope: several or non-`Int` query values, optional/default values, path and query values in one handler, percent-decoding, repeated-value extraction, body extraction, other return types, raw handlers, `app.post`, `app.run()`. Acceptance is in `feature_list.json`.

M2-003, handler-storage decision gate: before any new handler shape, decide with pinned-compiler evidence how production `App` stores handlers. Candidates (closed `Variant`, safe concrete erasure, typed trampoline/erasure, compile-time specialization) are compared in isolated spikes that store representative mixed shapes, including an application-defined return type, in one route list behind one `handle(Request) -> Response`, while keeping `app.get["/users/{id}"](get_user)`. Production storage does not change in this item; a chosen migration is the next, separate item. The decision, evidence, and reconsideration thresholds are in `docs/ARCHITECTURE.md` ("Handler storage decision (M2)"); acceptance is in `feature_list.json`.

M2-004, handler-storage migration: production `App` stores handlers in the private typed box chosen by M2-003 instead of the closed `Variant`, with every public behavior unchanged: the same registration syntax and the same two non-raising shapes (`def() -> String`, `def(Int) -> String`), the same routing, query and 400/404 rules, compile-time route checks, `TestClient` and Flare loopback results. The unsafe operations live in one internal module that a canonical check confines, the stored handler has one owner with executable ownership and move evidence on the production type, and copy support is dropped unless production needs it. Out of scope: any new handler shape, `raises` handlers, application-defined parameter or return types, extraction or response-conversion traits. Acceptance is in `feature_list.json`.

M2-005, argument-extraction decision gate: before request-body extraction, decide with pinned-compiler evidence how Muntin turns request-derived raw values into typed handler arguments, as two separate questions: which request source (path segment, query value, body) fills each handler parameter, and how a raw value from that source becomes application type `T`. Alternatives for each are compared in spikes outside `src/muntin`, with an application-defined body type in a separate module from the library-side machinery. Production keeps exactly the M2-004 handler shapes and storage; the first body slice is the next, separate item. The decision is in `docs/ARCHITECTURE.md` ("Argument extraction decision"); acceptance is in `feature_list.json`.

M2-006, first request-body slice: production `App` accepts exactly one new shape, body-only `POST`: `app.post["/users"](create_user)` with `def create_user(body: CreateUser) -> String`, where `CreateUser` is an application-defined, possibly move-only type conforming to Muntin's public `FromBody` trait (`@staticmethod def from_body(body: String) raises -> Self`, refining `Deinitable & Movable`), checked with the M2-005 mechanism (`comptime assert conforms_to`, `Int` rejected by type equality). The route declares no path or query placeholder; the handler takes one required body parameter, does not raise, and is compatible with `def(var B) thin -> String`: `-> String` is the canonical shape, and Mojo 1.1.0 also accepts implicitly `String`-convertible returns such as `StaticString`, as `App.get` has since M2-001. Muntin converts the body before the handler; a conversion failure is 400 without invoking the handler; no route match is 404. `TestClient.post(target, body)` only builds the `Request`. The Flare adapter stays transport-only and gives the same results as `TestClient` over loopback. The M2-004 handler storage and its unsafe surface are unchanged. Out of scope: `(Int, B)` and every other multi-parameter shape, `Int`/`String`/`Request` bodies, bodies on `GET`, raising handlers, `-> Response` and other return types that do not convert to `String`, JSON, optional or multiple bodies. Acceptance is in `feature_list.json`.

M2-007, typed-response decision gate: before any typed return enters production, decide with pinned-compiler evidence how an application-defined handler result `R` becomes a `Response` while `app.get["/users/{id}"](get_user)` and the M2-004 `_Erased` storage stay as they are. Candidates (a Muntin-owned conversion trait on application types, an explicit converter at registration, convention-based conversion without a trait, a direct `Response` special case) are compared in spikes outside `src/muntin`, with application return types in a separate module from the library-side code and handlers stored in the production `_Erased`. The decision covers the treatment of `String` and `String`-compatible returns (declared return type versus compatibility with the registered function type), `-> Response`, ownership of the result, whether conversion may raise, one policy across GET and POST, rejected alternatives, reconsideration conditions and the next production slice. Production keeps exactly the M2-006 handler shapes and storage; the only `src/muntin` change is `FromBody`'s docstring wording (`from_body(body: String)` is the current public contract; future body capabilities are additive). The decision is in `docs/ARCHITECTURE.md` ("Typed response decision (M2-007)"); acceptance is in `feature_list.json`.

M2-008, typed results in production: the M2-007 contract becomes production behavior, exactly as decided. `muntin` exports `trait ToResponse(Deinitable, Movable)` with a non-raising `def to_response(var self) -> Response`; `Response` conforms by returning itself by move, so `-> Response` is a direct escape hatch with no `Response`-specific overload. Each existing argument shape (GET `def()`, GET `def(Int)`, POST `def(B: FromBody)`) gains exactly one overload for a result `R: ToResponse` beside its unchanged `String` overload; `-> String` stays canonical and `String`-compatible returns such as `-> StaticString` keep resolving to the `String` overloads. The adapters are generic over the result and a compile-time response policy (`_text` / `_converted[R]`). The conversion runs once, after a successful handler call; 400 and 404 run neither. Route and body validation and their messages are unchanged on both overloads. `_handler_storage.mojo` is byte-identical, no unsafe code is added, and the Flare adapter stays transport-only; `TestClient` and real loopback through Flare agree for a `-> User`-style and a `-> Response` route. Out of scope: raising handlers or conversions, `(Int, B)`, raw `Request` handlers (including the recorded `var Request` overload issue), JSON, headers, content negotiation, middleware/state, new HTTP methods. Acceptance is in `feature_list.json`.

M2-009, route value then body: production `App` accepts exactly one new argument shape on `POST`, the M2-005 `(Int, B)` case: `app.post["/users/{id}"](update_user)` with `def update_user(id: Int, body: UpdateUser)`, returning `String` (or `String`-compatible) or `R: ToResponse` as decided in M2-008. `B` is an application-defined, possibly move-only `FromBody` type; the body slot rejects `Int` by type equality and requires `FromBody`. The route literal declares exactly one route value, from one path placeholder or one query placeholder, with the existing `Int` rules; binding is positional (route value, then body), never by name. One adapter converts the route value, then the body, then calls the handler once, then applies `_text` or `_converted[R]` once. No route match is 404 with nothing converted; an invalid matched path value, or a missing, duplicated, empty or invalid query value, is 400 before body conversion (a missing path segment does not match the route and is 404); a body conversion failure is 400 before the handler; a matched route never falls through. `_handler_storage.mojo` and the Flare adapter are unchanged, and `TestClient` and real loopback through Flare agree for path and query values, an invalid value, an invalid body and a typed result. Out of scope: more than one route value, path and query values together, two or optional bodies, `String`/builtin bodies, raising handlers or conversions, raw `Request` handlers, JSON, headers, new methods, middleware, state. Acceptance is in `feature_list.json`.

M2-010, application-error decision gate: before any raising handler enters production, decide with pinned-compiler evidence how a handler such as `def get_user(id: Int) raises -> User` registers with the existing syntax while `App.handle(Request) -> Response` stays the backend seam. The decision covers how raising handlers coexist with non-raising ones (widened function types, raising twins, or another compiler-supported mechanism, without relying on undocumented overload ranking), the exact boundary between request failures and handler failures (a failed conversion of a matched route's path value, a failed query-value gathering or conversion, and a failed `FromBody` conversion are 400 before the handler; no route match, including a missing path segment, is 404), where each is caught, what an unhandled handler error becomes on the wire and whether its text is exposed, and whether application-defined error conversion belongs in the first error model, based on what Mojo exposes at a `catch`. Spikes run outside `src/muntin` with handlers and error types in an application module and handlers stored in the production `_Erased`. Production, `adapters/` and the unsafe surface are unchanged; `ToResponse` stays non-raising. The decision is in `docs/ARCHITECTURE.md` ("Application-error decision (M2-010)"); acceptance is in `feature_list.json`.

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
