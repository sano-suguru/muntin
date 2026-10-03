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

Status: **complete** (M2-016). What M2 guarantees and what it deliberately leaves out is the "M2 completion contract" below.

Explore and verify, in roughly this order:

- compile-time route literal representation where practical;
- typed path extraction;
- typed query extraction;
- request-body conversion/validation;
- typed response conversion/serialization;
- an application-error model compatible with current Mojo;
- `TestClient` ergonomics matching application semantics;
- foundations for schema/OpenAPI generation.

M2 delivered every item on this list except two parts, which M2-016 moved to M3: serialization (M2 delivered conversion only: `FromBody` and `ToResponse` leave the body format to the application, and no codec exists) and schema/OpenAPI foundations (a schema needs a type-to-format mapping, which only a codec defines).

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

M2-011, raising handlers in production: the M2-010 decision becomes production behavior, exactly as recorded in `docs/ARCHITECTURE.md` ("Application-error decision (M2-010)", "Next production slice"). The eight existing registration overloads keep their shapes and syntax; each function type gains one inferred `E: Deinitable` through parametric raises (`thin raises E`), so a non-raising handler infers `Never`, `raises` infers `Error` and `raises T` the application's `T`, on every argument shape and with `String`-compatible and `ToResponse` results. No route match, including a missing path segment, is 404; a matched route's path or query value that fails to gather or convert, and a `FromBody` failure, are 400 before the handler (`_parse_int` failures answered in the adapters); anything the handler raises is a fixed `500 Internal Server Error` whose body never carries the error text, whatever the error type, including types conforming to `ToResponse`, whose `to_response` does not run; the response conversion runs only after the handler returns; a raise escaping `invoke` is 500, never 400. `_Erased`, the unsafe surface and the Flare adapter are unchanged, `_handler_storage.mojo` changes one docstring sentence, and `ToResponse` stays non-raising. `TestClient` and real loopback through Flare agree for a raising route answering 500. Ordinary non-raising `def` handlers stay source-compatible; on Mojo 1.1.0 an explicitly typed non-raising thin function value (`var f: def() thin -> String`) does not convert to the parametric-raises function type, a known limitation accepted with this item (workarounds, fixture and revisit condition in `docs/ARCHITECTURE.md`, "Raising handlers in production (M2-011)"). Out of scope: application-defined error conversion, logging, raw `Request` handlers, fallible `ToResponse`, JSON, headers, new methods or argument shapes, middleware, state, storage or overload redesign. Acceptance is in `feature_list.json`.

M2-012, error-response decision gate: before any application-defined error response enters production, decide with pinned-compiler evidence whether and how an error a handler raises with `raises T` can explicitly opt into producing a `Response`, without changing what any handler that compiles today answers. The decision compares per-error-type conversion through a dedicated error-response contract (not `ToResponse` by implication), an application-level mapping (rejected if it needs heterogeneous storage, run-time type identity, new unsafe code, public `App` state or backend coupling) and keeping the fixed 500; proves the opt-in across a library/application module boundary and with move-only error types, without ambiguous overloads and without requiring every error type to conform; and decides bare `raises` (`Error`, never mapped by message), raised `ToResponse` values (500 unless the application opts in explicitly), ownership and fallibility of the conversion. Returned values and raised errors stay separate channels. Spikes run outside `src/muntin` with handlers and error types in an application module and handlers stored in the production `_Erased`. Production, `adapters/`, the overloads, `_Erased` and the unsafe surface are unchanged; `App.handle(Request) -> Response` stays the backend seam and backends never see application error types. The decision is in `docs/ARCHITECTURE.md` ("Error-response decision (M2-012)"); acceptance is in `feature_list.json`.

M2-013, application-defined error responses in production: the M2-012 decision becomes production behavior, exactly as recorded in `docs/ARCHITECTURE.md` ("Error-response decision (M2-012)", "Next production slice"). `muntin` exports `trait ToErrorResponse(Deinitable)` with a non-raising `def to_error_response(var self) -> Response`. A handler declared `raises T`, where `T` declares that conformance on its own struct (directly, through a refining trait, or as a documented conditional conformance), is answered with `T.to_error_response()` when it raises, on every argument shape (`def()`, `def(Int)`, `def(B)`, `def(Int, B)`) and with `String`-compatible and `ToResponse` results; the error is consumed once and the result conversion does not run. Every other handler error stays the fixed `500 Internal Server Error`: bare `raises` (`Error`, never mapped by message), a `raises T` whose `T` does not opt in, and a raised value conforming only to `ToResponse`. A returned value converts with `to_response` and a raised one with `to_error_response`, also for a type conforming to both; a type conforming only to `ToErrorResponse` cannot be returned, and a raising `to_error_response` does not conform. 400 and 404 run neither conversion. Undocumented `__extension` behavior is not supported API. Only `_handler_error[E]` changes behavior; the overloads, adapters, `App.handle`, `_Erased`, `_Call`, the unsafe surface and the Flare adapter are unchanged, and `TestClient` and real loopback through Flare agree for an opted-in error response. Out of scope: mapping `Error` or messages, application-level or per-route mappers, logging, fallible conversion, raw `Request` handlers, JSON, headers, middleware, state, new methods or shapes. Acceptance is in `feature_list.json`.

M2-014, raw-Request decision gate: before raw handlers enter production, decide with pinned-compiler evidence the smallest public contract for `def webhook(req: Request) -> Response` registered as `app.post["/webhook"](webhook)` (and on `app.get`) beside the typed handlers. The decision covers whether dedicated `Request` overloads keep the existing syntax (only if resolution is unambiguous by a documented rule and diagnostics stay understandable) or an explicit API is needed, the `Request` ownership spelling, whether raw handlers return only `Response`, how they raise under the existing error model (`raises`, `raises T`, `ToErrorResponse`) without special cases, and their request semantics: selected by method and path like any route, receiving the complete Muntin `Request` (method, path, query, body), with no typed extraction. The current failure of a raw handler on `app.post` (it reaches the generic body overload and fails on `FromBody`) must be removed by the selected design without ambiguous calls, a weaker `FromBody`, or a `Request`-specific exception in overload selection; a `Request` type-equality guard may only improve diagnostics for calls that are already invalid. Spikes run outside `src/muntin` against production's overload signatures and `_Erased`. Production, `adapters/`, `Request`, the unsafe surface and the seam are unchanged. The decision is in `docs/ARCHITECTURE.md` ("Raw Request decision (M2-014)"); acceptance is in `feature_list.json`.

M2-015, raw Request handlers in production: the M2-014 decision becomes production behavior, exactly as recorded in `docs/ARCHITECTURE.md` ("Raw Request decision (M2-014)", "Next production slice"), without widening the typed API. `app.get["/x"](handler)` and `app.post["/x"](handler)` each accept one raw shape, `def(var Request) thin raises E -> Response` with `E: Deinitable` inferred; `def h(req: Request) -> Response` is the canonical spelling and `var req: Request` also works. Raw handlers return `Response` only and use the existing error model unchanged (an opted-in `raises T` answers with `ToErrorResponse`, every other raise is the fixed 500). Route selection stays method + path, first registration wins across raw and typed routes, 404 otherwise; a raw route literal declares no path or query placeholder. After a raw route matches, Muntin performs no typed path/query/body extraction and generates no pre-handler 400; the handler receives Muntin's `Request` (`method`, `path`, `query`, `body`) with no backend type or lifetime, and its `Response` or `ToErrorResponse` may use any status. Selection on `post` rests on Mojo 1.1.0's documented "shorter parameter list" rule (the raw overloads' lists stay strictly shorter than every body overload a `Request -> Response` handler satisfies; equal lists are ambiguous, pinned by a retained fixture); the body overloads' `not B == Request` guard only improves diagnostics for already-invalid calls. `_handler_storage.mojo`, `_Erased`, `_Call`, the unsafe surface, `http.mojo`, `body.mojo`, `testing.mojo`, `__init__.mojo`, `Request`/`Response`, `TestClient`, the Flare adapter and the seam `App.handle(Request) -> Response` are unchanged; `TestClient` and real loopback through Flare agree for a raw `POST` route. Out of scope: raw route values, `String`/`ToResponse` raw results, headers, a raw target field, new methods, middleware, state. Acceptance is in `feature_list.json`.

M2-016, M2 closure decision: decide, without adding product behavior, whether the merged implementation satisfies M2's boundary, the handler/application programming model rather than feature breadth. Every M2 item maps to merged production behavior or to a decision whose production slice has merged. Each deferred capability is tested as a possible blocker: is it needed by a statement that `docs/DX.md` labels proven or production, by an M2 acceptance item, or by a `.claude/rules/public-api.md` rule? A statement that DX labels as a target does not count. A capability is a blocker only if its absence breaks a promised core workflow, contradicts the documented public API, or leaves the typed/raw boundary materially incomplete. Result: no blocker; M2 is complete. The classification, item mapping and revisit conditions are in `docs/ARCHITECTURE.md` ("M2 closure (M2-016)"); the contract is below. No change under `src/muntin` or `adapters/`, and no test or fixture changes. Acceptance is in `feature_list.json`.

### M2 completion contract

On Mojo 1.1.0, through `TestClient` and, for the same `App`, a real loopback request through the Flare adapter, M2 guarantees:

- **Registration:** `app.get[route](handler)` and `app.post[route](handler)` with a compile-time route literal and a plain `def` handler. A malformed literal, or a route whose placeholder count does not match the handler's parameters, fails to compile at the registration call (names are not compared; binding is positional).
- **Typed arguments:** GET `def()` and `def(Int)`; POST `def(B)` and `def(Int, B)` with an application-defined `B: FromBody`. At most one `Int` route value, from one `{name}` path segment or one `{key}` query item, bound by position; the body comes from the request body only and is converted by `B.from_body` before the handler.
- **Results:** `String` (or `String`-compatible) is a 200 text response; a result type `R: ToResponse` (an application type, or `Response` itself) is converted once, after the handler returns.
- **Errors:** handlers may be non-raising, `raises` or `raises T`. No route match is 404. A request failure (invalid route value, missing/duplicated/empty/invalid query value, `from_body` raise) is 400 before the handler. Anything the handler raises is a fixed 500 whose body never contains the error text, unless the declared `T` conforms to `ToErrorResponse` and answers with its own response. A matched route never falls through, and the first registered matching route wins.
- **Raw escape hatch:** `def h(req: Request) -> Response` on `get` and `post` with the same syntax, receiving Muntin's whole `Request` (`method`, `path`, `query`, `body`) with no typed extraction and no pre-handler 400, under the same error model.
- **Ownership of the API:** the public surface is `App`, `Request`, `Response`, `FromBody`, `ToResponse`, `ToErrorResponse` and `muntin.testing.TestClient`, all Muntin-owned. `_`-prefixed internals are importable on Mojo 1.1.0 but are not part of the contract. Backends call only `App.handle(Request) -> Response`, and no backend type or lifetime reaches application code.

Every guarantee is decided in `App.handle` and the registration overloads, so both backends inherit it. The executable tests cover it in memory; the loopback suite samples it over Flare (every argument shape, result policy, error kind and the raw route). Two documented differences: a static path segment containing a byte outside `!`..`~` (`/hello world`) compiles and matches in memory but never arrives over Flare, and an absolute-form target (`http://host/path`) is 404.

M2 deliberately does not provide (the M3 list below places each item):

- shared or runtime application data in handlers: a handler can read only its arguments and compile-time constants. On Mojo 1.1.0, module-level variables do not compile, handlers are thin functions that cannot capture, and M2 has no state API (M3-003 adds `State` for `get`, DX section 8). An in-memory store or a connection opened at startup therefore cannot reach a handler; the `users.get(id)` of DX sections 2, 4 and 19 is M3 (application state);
- a way to serve an `App` over a network from application code: there is no `app.run()` or other public lifecycle API. Serving today means application code imports Flare's `HttpServer` and the adapter's `MuntinHandler` (`adapters/flare/serve_probe.mojo`). That puts a backend type in application code, so it is unsupported and outside this contract;
- binary bodies: `Request.body` and `Response.body` are `String`, and the Flare adapter replaces invalid UTF-8 in a request body with U+FFFD;
- headers: `Request` has none, and `Response` sets none, so there is no Content-Type on the wire;
- JSON or any other codec, and no schema/OpenAPI output;
- methods other than `GET` and `POST`: those requests are 404;
- route values other than one `Int`: `String` and other types, several values, a path and a query value together, optional/default query values, percent-decoding and parameter-name checking are not supported. A dynamic segment that is not an `Int` (`ada` in `/users/ada`) cannot be captured: typed routes take only `Int` values, and raw routes declare no placeholders. A static route such as `app.get["/users/ada"]` still matches that path, subject to first-registration-wins (with `/users/{id}` registered first, `/users/ada` is 400);
- bodies other than one required `FromBody` body on `POST` (no `String`/builtin, optional, multiple or streaming bodies, and no `POST` without a body); raw handlers returning anything but `Response`;
- middleware, a logging/observability hook (a handler error is dropped unread), application-level or per-route error mappers, fallible response or error conversions;
- function values typed explicitly without `raises`: they do not register on Mojo 1.1.0. Write the type with `raises Never` (`def() thin raises Never -> String`; for raw handlers, `def(var Request) thin raises Never -> Response`). A plain `def` passed by name is unaffected (`docs/ARCHITECTURE.md`, "M2 closure (M2-016)", recorded compiler limitations);
- performance claims: routes are found by a linear scan, and request data is copied into `String`s.

## M3 — composition and production ergonomics

Status: active after M2-016. M3-001 (application state decision gate) and M3-004 (state storage decision gate) are decided, and the M3-001 slice M3-003 (stateful `get`) is implemented on M3-004's sealed box; M3-002 (headers decision gate) is next, below.

Potential work, each cut into its own decision-first item. These include the capabilities M2-016 deferred, with the reason each is additive:

- **request and response headers:** a new field on `Request`/`Response`, translated by each backend. Typed and raw handlers lack them alike, so the typed/raw boundary is complete for Muntin's current `Request`. Adding a non-`String` field reopens the raw transport (`_Call`'s `List[String]`, a revisit condition of M2-014);
- **JSON or another codec, and serialization:** the codec fills `from_body`/`to_response` without changing routing or binding (DX section 4). It needs response headers for its Content-Type;
- **OpenAPI/schema output, and its foundations** (moved from M2): it needs the type-to-format mapping that only a codec defines;
- **more route values:** non-`Int` types (`String` first, which also makes `/users/{name}` routable), several values, path and query values together, optional/default query values, percent-decoding. The M2-005 positional rule already covers several values; each type adds a converter;
- **more HTTP methods** (`put`, `patch`, `delete`, `POST` without a body): overload families that repeat the `get`/`post` contract;
- **more body shapes:** `String`/builtin, optional, multiple and streaming bodies, and binary (bytes) bodies, which need a non-`String` body representation;
- **fallible conversions and parameter-name checking:** a raising `to_response`/`to_error_response` needs its own error answer (M2-007, M2-012). Name checking needs function-parameter reflection, which Mojo 1.1.0 lacks;
- **broader raw handlers:** raw route values, `String`/`ToResponse` raw results. Each is an additive overload under the M2-014 parameter-list rule;
- middleware;
- **application state/context:** M2 handlers can read no runtime data (no globals on Mojo 1.1.0, no captures). Decided in M3-001 as an addition to M2, with no signature or binding change: a `State[S]` first parameter, bound at registration with `app.get[route](handler, state)`. First slice M3-003 (stateful `get`, implemented); stateful `post` and stateful raw handlers come in a later slice;
- structured errors, including the application-level error mappers that M2-012 rejected on Mojo 1.1.0 (its revisit conditions apply);
- observability hooks, including logging of dropped handler errors;
- streaming;
- graceful lifecycle integration, including whether Muntin owns a public `app.run()` (serving is backend/lifecycle work, not part of the handler model);
- performance benchmarks and allocation profiling.

M3 scope should be cut into independently verifiable milestones rather than attempted as one framework rewrite.

M3-001, the first item, is the application state decision gate. State comes first for three reasons. It is the largest gap in the current product story: `def get_user(id: Int) -> User: return users.get(id)` cannot be written, because a handler can reach no repository or connection. It is also the M3 item most likely to change an M2 public signature or M2-005's binding rule (route values first, body last), and it is cheapest to learn that before other M3 work is built on top: an additive result confirms the M2-016 closure, and a breaking one reopens M2 while nothing depends on it yet. Headers, by contrast, are mostly an additive field on `Request`/`Response`.

M3-001 compares, with pinned-compiler evidence and at least: (1) injecting state as a handler argument, `def get_user(id: Int, state: State[Db]) -> User`; (2) state owned by the `App` with a typed accessor (for example `app.state[Db](...)`), with handlers receiving a state or context value; (3) no framework state feature, using an explicit pattern in the application. The central question is how a framework-injected parameter is told apart from route-value and body parameters at compile time, without undocumented overload ranking. That includes how it relates to M2-005's positional rule and to the placeholder-count checks at registration. The gate also decides:

- ownership and lifetime: who owns the state, whether handlers borrow it read-only or mutably, and how that fits `App.handle(self)` being read-only and `TestClient` borrowing the `App`;
- testability, with no hidden globals and no per-request allocation;
- the effect on `_Erased`, `_Call` and the unsafe surface;
- whether backends that hold an `App` (the Flare adapter's `MuntinHandler`) are affected; M2-012 rejected `App[on_error=m]` for exactly that coupling;
- whether any M2 public signature, binding rule or 400/404/500 boundary changes. If one does, M2 is reopened under the M2-016 condition, by an explicit decision. If none does, a scratch copy proves that every existing suite and fixture is unchanged.

If no candidate separates injected parameters cleanly, the decision records that and does not hurry a state API into production. The gate does not change production or `adapters/`.

M3-001 result: **selected A**, handler-argument injection with the state bound at registration. `def get_user(users: State[Users], id: Int) -> User` is registered as `app.get["/users/{id}"](get_user, users)`. The handler takes injected state exactly when its registration passes a second argument, a Muntin-owned `State[S]`. Its first parameter is then `State[S]` (the same `S`), and the rest is one M2 shape bound by M2-005 unchanged. M2 calls pass one argument, so the two families never meet in overload resolution. `State` is a shared handle, read-only through `state[]` (reference counted, no unsafe code). Each route keeps a copy inside the unchanged `_Erased` box, and requests only borrow it. `App` stays non-generic. `App.handle`, `_Erased`, `_Call`, `TestClient`, the Flare adapter and every M2 signature, binding rule and 400/404/500 boundary are unchanged, so M2 stays closed. A scoped registrar (`app.with_state(state).get[route](handler)`) leaves every M2 diagnostic unchanged and states the state once, but it is rejected on Mojo 1.1.0. Writes through its stored `Pointer` escape the compiler's interior-reference invalidation, so its safety would rest on a project invariant instead of the compiler. A1 costs only DX: 16 failing M2 diagnostics gain notes, and 12 of them lose detail notes. Pure handler-side injection (ambiguous on `post`), `App[S]` (infects every backend), an erased `App`-owned value (needs string type keys and an unsafe cast) and closures (do not convert to the stored trampoline) were rejected with compiler evidence. The decision, rejected candidates, cost and revisit conditions are in `docs/ARCHITECTURE.md`, "Application state decision (M3-001)".

M3-003, stateful `get` in production (the M3-001 slice): `muntin.State[S]` and four `App.get` overloads taking `(handler, state: State[S])`, for `def(State[S])` and `def(State[S], Int)`, each returning `String` or `R: ToResponse` and raising as M2-011. They follow the M2 request rules (404, the 400s before the handler, `ToErrorResponse` or the fixed 500) and the M2 route checks. `TestClient` and a real loopback request through Flare agree for a stateful `GET` route. `_handler_storage.mojo`, `_Erased`, `_Call`, `App.handle`, `Request`/`Response`, `TestClient`, the Flare adapter, the unsafe surface, and every existing test and fixture are unchanged. Out of scope: stateful `post` shapes, stateful raw handlers, the `post` `State` guard (all in a later slice), a scoped registrar, middleware, headers. Acceptance is in `feature_list.json`.

M3-002 is the request/response headers decision gate. Three other candidates depend on headers: a JSON response needs a Content-Type, middleware such as CORS or authentication reads and writes headers, and the DX section 9 webhook reads its signature header. Headers also change the backend seam and the raw-handler transport. M3-002 decides with pinned-compiler evidence: the Muntin-owned representation (type, case-insensitive names, repeated fields, ownership and copying, invalid bytes); how `Request` and `Response` carry headers without any backend type or lifetime; how a raw handler receives them, given `_Call`'s `List[String]` transport; what the Flare adapter maps in each direction; whether a `String` or `ToResponse` result gets a default Content-Type, and whether any wire bytes of existing responses change; and whether typed handlers get header extraction in the first production slice. The gate does not change production or `adapters/`.

M3-004, the state storage decision gate, comes from the M3-003 review. With an `ArcPointer` field, code holding a second `State` handle could free memory a `state[]` reference points into, with public std API alone (`ArcPointer.__getitem__` is mutable through any handle, and Mojo 1.1.0 has no private fields). The gate keeps M3-001's public API and decides only the representation. Its guarantee: Muntin must not introduce a Muntin-specific safe-code path that lets one `State` alias replace, mutate, swap, or prematurely destroy the shared payload observed through another alias. Toolchain-wide primitives that break the same property for std types and existing Muntin storage (origin `rebind`, forged allocation, `memmove`, stdlib-private fields) are outside it and pinned as Mojo 1.1.0 soundness gaps. It is not an M2 reopen, but it reverses M3-001's internal "no unsafe code" choice.

M3-004 result: **selected a sealed shared box** in the private storage module. `_Shared[S]` holds one field, a `ThinAllocation` of a header with an atomic count and an `OwnedPointer[S]`; its accessor borrows its receiver, so every reference is immutable. On every ordinary path through a second handle, replacing, mutating or swapping the value is a compile error; reassigning or moving a handle invalidates its references, as in PR #26. The toolchain-wide primitives still reach it, as they reach std types and `_Erased` on `main` (`tests/toolchain_soundness_gaps`); M2-004's wording is corrected to the same boundary. `check_unsafe.sh` changes one rule (`_Shared` may be imported), and PR #26's `OwnedPointer` exemption goes. A scratch copy of the M3-003 branch with the box passes `check.sh`, `test.sh` and `check_flare.sh`. Details, candidates and revisit conditions: `docs/ARCHITECTURE.md`, "State storage decision (M3-004)".

M3-003 result: `muntin.State[S]` (`src/muntin/state.mojo`) and the four stateful `App.get` overloads are production, exactly the slice. Measured against the stateless twins in `tests/test_state.mojo` (11 tests, through `TestClient`): the same route checks and messages, `Int` from a path segment or a query item, the 400s before the handler (the handler's call counter stays 0), `ToErrorResponse` or the fixed 500, 404, first registration wins. Each registration raises the handle's reference count by one; requests, whatever their outcome, leave it unchanged; dropping the `App` releases the routes' handles; the value is destroyed once across two `App` moves; `TestClient` serves the `App` before and after a move. A Flare loopback `GET /staff/{id}` equals `TestClient`. Of the 70 existing `compile_fail`, `storage_fail` and `body_fail` fixtures, 62 diagnostics are unchanged and 8 failing `get` calls gain the four `missing required argument: 'state'` notes, 3 of which lose trailing detail notes to Mojo's ten-note cap; every expected text still matches. `_Erased`, `_Call`, `_Route`, `App.handle`, `http.mojo`, `body.mojo`, `testing.mojo` and the Flare adapter are unchanged. `State` stores its value in M3-004's sealed `_Shared[S]`, added to `_handler_storage.mojo`: a `state[]` reference is immutable and interior to its handle (using it after the handle is reassigned is a compile error, `tests/state_get_fail/ref_after_*`), and a second handle cannot replace or mutate the shared value (`alias_payload_swap`, `alias_value_mutation`). `check_unsafe.sh` changes only to let `state.mojo` import `_Shared`.

Acceptance for the gates and for M3-003 is in `feature_list.json`.

## Long-term success criterion

Muntin earns its existence if application code is materially clearer, safer, or more statically verifiable than using a networking library directly while preserving an escape hatch for low-level work.

Raw benchmark wins alone are not sufficient. A thin Flare re-export is not sufficient. A beautiful API that cannot survive backend/toolchain evolution is not sufficient.
