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

M2 delivered every item on this list except two parts, which M2-016 moved to M3: serialization (M2 delivered conversion only: `FromBody` and `ToResponse` leave the body format to the application, and M2 has no codec) and schema/OpenAPI foundations (a schema needs a type-to-format mapping, which only a codec defines). Serialization has since been delivered by M3-009 (JSON); schema/OpenAPI remains an M3 candidate.

Each public API addition should be demonstrated by a small canonical example in `docs/DX.md` and executable tests.

Item scope, in the order cut. Each item's full scope paragraph is in [`docs/history/spec-items.md`](history/spec-items.md#m2-items); acceptance is in `feature_list.json`; the architecture record of each has a stub in `docs/ARCHITECTURE.md`, "Decision records".

| Item | Kind | Scope |
|---|---|---|
| M2-001 | production | one `Int` path value: `app.get["/users/{id}"](get_user)` |
| M2-002 | production | path/query split in `Request`; one `Int` query value (`/items?{limit}`) |
| M2-003 | decision | handler storage (typed box over `Variant`) |
| M2-004 | production | handler storage migration to the move-only `_Erased`, behavior unchanged |
| M2-005 | decision | argument extraction (positional binding, `FromBody`) |
| M2-006 | production | body-only `POST`, public `FromBody` |
| M2-007 | decision | typed responses (`ToResponse`) |
| M2-008 | production | typed results, `Response` conforming |
| M2-009 | production | `POST` `def(Int, B)` |
| M2-010 | decision | application errors (parametric raises, fixed 500) |
| M2-011 | production | raising handlers |
| M2-012 | decision | error responses (`ToErrorResponse` opt-in) |
| M2-013 | production | `ToErrorResponse` |
| M2-014 | decision | raw `Request -> Response` handlers |
| M2-015 | production | raw handlers on `get`/`post` |
| M2-016 | decision | M2 closure: complete; the contract below |

### M2 completion contract

Status of this contract: the M2 closure record, as decided in M2-016 (PR #24); it is not a list of what Muntin lacks today. M3 has since added application state (M3-003, M3-006, M3-007), request and response headers (M3-005) and JSON (M3-009), so the exclusions for runtime data in handlers, headers and codecs no longer describe the product; M2 itself still does not provide them. Current behavior: `docs/ARCHITECTURE.md`, "Current architecture", and `docs/DX.md`.

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

Status: **active**. M3-001 to M3-013 are merged and passing in `feature_list.json`. M3-014 (decision, the registration structure) is PR #43; M3-015, its production slice, reopens M2. Each row gives its PR, or `next` for an item not yet started. Each item is cut decision-first: a gate decides with pinned-compiler evidence and names an exact production slice, which is the next item.

| Item | Kind | Scope | PR / status |
|---|---|---|---|
| M3-001 | decision | application state: `State[S]` first handler parameter, bound at registration `app.get[route](handler, state)`; M2 stays closed | PR #25 |
| M3-002 | decision | request/response headers: `muntin.Headers`, raw-handler transport, no default fields, Flare mapping; typed extraction deferred | PR #28 |
| M3-003 | production | stateful `get` | PR #26 |
| M3-004 | decision | state storage: sealed `_Shared[S]`, the State guarantee and its toolchain-wide exclusions | PR #27 |
| M3-005 | production | headers | PR #29 |
| M3-006 | production | stateful `post` and the `State` guard | PR #30 |
| M3-007 | production | stateful raw `get`/`post` (completes the stateful family) | PR #31 |
| M3-008 | decision | JSON: `Json[T]` over `FromJson`/`ToJson`, Muntin-owned codec, 415/413 rules, 1 MiB cap | PR #32 |
| M3-009 | production | JSON | PR #36 |
| M3-010 | decision | `TestClient` request header fields: a keyword-only, defaulted `var headers: Headers` on `get` and `post` | PR #39 |
| M3-011 | production | `TestClient` request header fields | PR #40 |
| M3-012 | decision | typed header access: a `WithHeaders[B]` body carrier for typed `post` handlers, no overload and no injected slot; typed `get` stays raw | PR #41 |
| M3-013 | production | typed header access for `post` handlers (`WithHeaders[B]`) | PR #42 |
| M3-014 | decision | registration structure: one overload per handler arity with generic slots on the existing method names; spellings unchanged; reopens M2 for overload declarations, rejected-call diagnostics and two edges of the accepted set (results stay as production's through a `where` clause); raw `String` is a route value, never a body | PR #43 |
| M3-015 | production | registration on generic-arity slots for `get` and `post`, today's slot kinds and rules only; reopens M2 | next |

Each item's scope paragraph, and the result paragraphs written when it merged, are in [`docs/history/spec-items.md`](history/spec-items.md#m3-items) (the item order there is the order they were written, not the ID order); citations such as `docs/SPEC.md`, "M3-003 result" refer to those paragraphs. State went first because it was the M3 item most likely to change an M2 signature or M2-005's binding rule; it did not.

Delivered M3 areas, formerly on the candidate list: application state/context (M3-001, M3-004, M3-003, M3-006, M3-007), request and response headers (M3-002, M3-005), JSON and serialization (M3-008, M3-009), `TestClient` request header fields (M3-010, M3-011), typed header access for `post` handlers (M3-012, M3-013).

### Remaining candidates

Each becomes its own decision-first item. The reason each is additive is from M2-016 and later decisions; the list as it stood at M3-009 is preserved in `docs/history/spec-items.md`.

- **OpenAPI/schema output, and its foundations** (moved from M2): it needs a type-to-format mapping; the M3-008 codec maps fields by hand, so a schema source waits for a derived codec;
- **JSON follow-ups** left out of M3-009: a configurable body cap, derived codecs, `+json` or missing `Content-Type`, `Json(value, status=)`, top-level list results;
- **typed header access on `get`, compile-time header names, a `FromHeaders` converter:** left out by M3-012, which gave typed `post` handlers a body carrier (production since M3-013). Every measured typed header shape in `get`'s overload set exceeds Mojo 1.1.0's ten-note cap or changes an M2 signature, so `get` waits for registration on generic-arity slots (M3-014 selected it; M3-015 is its first slice), after which a `Headers` slot or the carrier adds no overload;
- **more route values:** non-`Int` types (`String` first, which also makes `/users/{name}` routable), several values, path and query values together, optional/default query values, percent-decoding. The M2-005 positional rule already covers several values; each type adds a converter. Each needs four overloads per method today, past the note cap; after M3-015 a value type is a slot kind and several values a rule (M3-014);
- **more HTTP methods** (`put`, `patch`, `delete`, `POST` without a body): a new method is its own overload set, and Mojo 1.1.0 counts the note budget per method name, so `put`, `patch` and `delete` fit without restructuring (M3-014, C1); after M3-015 each is the same arity overloads delegating to the shared engine. `POST` without a body adds shapes to `post`, so it waits for M3-015, after which it is a rule change;
- **more body shapes:** a Muntin text type conforming to `FromBody` (raw `String` is a route-value type and never a body: M3-014; whether other builtins can be bodies is this item's decision), optional, multiple and streaming bodies, and binary (bytes) bodies, which need a non-`String` body representation;
- **fallible conversions and parameter-name checking:** a raising `to_response`/`to_error_response` needs its own error answer (M2-007, M2-012). Name checking needs function-parameter reflection, which Mojo 1.1.0 lacks;
- **broader raw handlers:** raw route values, `String`/`ToResponse` raw results. Today each is an additive overload under the M2-014 parameter-list rule, past the note budget on `get` and `post` (M3-007); after M3-015 each is a rule change (M3-014);
- middleware;
- structured errors, including the application-level error mappers that M2-012 rejected on Mojo 1.1.0 (its revisit conditions apply);
- observability hooks, including logging of dropped handler errors;
- streaming;
- graceful lifecycle integration, including whether Muntin owns a public `app.run()` (serving is backend/lifecycle work, not part of the handler model);
- performance benchmarks and allocation profiling.

M3 scope should be cut into independently verifiable milestones rather than attempted as one framework rewrite.

Acceptance for every M3 item is in `feature_list.json`.

## Long-term success criterion

Muntin earns its existence if application code is materially clearer, safer, or more statically verifiable than using a networking library directly while preserving an escape hatch for low-level work.

Raw benchmark wins alone are not sufficient. A thin Flare re-export is not sufficient. A beautiful API that cannot survive backend/toolchain evolution is not sufficient.
