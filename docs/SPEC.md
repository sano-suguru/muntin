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

## Milestones

| Milestone | Status | Scope |
|---|---|---|
| M0 | shipped | Muntin-owned `App`, `Request`, `Response`; `GET /hello` dispatched through an in-memory backend (`TestClient`) with no Flare dependency |
| M0.5 | shipped | feasibility of `app.get["/users/{id}"](get_user)` on Mojo 1.1.0 before any network backend |
| M1 | shipped | Flare adapter behind `App.handle`, outside core, with a real localhost round trip on Ubuntu and macOS |
| M2 | shipped | typed application API: routes, `Int` path/query values, typed bodies and results, application errors, raw `Request -> Response` handlers ("M2 completion contract" below) |
| M3 | active | composition and production ergonomics (below) |

A capability is shipped when the pull request implementing it merges into `main`. Decisions and the production slices they name: `docs/history/architecture-decisions.md`.

## Product boundaries

Muntin does not implement these unless an accepted milestone explicitly requires it: a custom async runtime or executor, socket management, TLS, HTTP/2, HTTP/3, QUIC, WebSockets (all backend concerns); dependency injection, a database layer, authentication, a template engine, deployment tooling; performance optimization before a baseline exists. The Flare adapter never replaces Muntin's router, request/response model or middleware design with Flare's (`docs/ARCHITECTURE.md`, "Flare policy").

## M2 completion contract

On Mojo 1.1.0, through `TestClient` and, for the same `App`, a real loopback request through the Flare adapter, M2 guarantees:

- **Registration:** `app.get[route](handler)` and `app.post[route](handler)` with a compile-time route literal and a plain `def` handler. A malformed literal, or a route whose placeholder count does not match the handler's parameters, fails to compile at the registration call (names are not compared; binding is positional).
- **Typed arguments:** GET `def()` and `def(Int)`; POST `def(B)` and `def(Int, B)` with an application-defined `B: FromBody`. At most one `Int` route value, from one `{name}` path segment or one `{key}` query item, bound by position; the body comes from the request body only and is converted by `B.from_body` before the handler.
- **Results:** `String` (or `String`-compatible) is a 200 text response; a result type `R: ToResponse` (an application type, or `Response` itself) is converted once, after the handler returns.
- **Errors:** handlers may be non-raising, `raises` or `raises T`. No route match is 404. A request failure (invalid route value, missing/duplicated/empty/invalid query value, `from_body` raise) is 400 before the handler. Anything the handler raises is a fixed 500 whose body never contains the error text, unless the declared `T` conforms to `ToErrorResponse` and answers with its own response. A matched route never falls through, and the first registered matching route wins.
- **Raw escape hatch:** `def h(req: Request) -> Response` on `get` and `post` with the same syntax, receiving Muntin's whole `Request` (`method`, `path`, `query`, `body`) with no typed extraction and no pre-handler 400, under the same error model.
- **Ownership of the API:** the public surface is `App`, `Request`, `Response`, `FromBody`, `ToResponse`, `ToErrorResponse` and `muntin.testing.TestClient`, all Muntin-owned. `_`-prefixed internals are importable on Mojo 1.1.0 but are not part of the contract. Backends call only `App.handle(Request) -> Response`, and no backend type or lifetime reaches application code.

M3-015 amended the contract (decided by M3-014): the registration overloads are one per request-slot arity with generic slots and a `where` clause on the result, rejected calls report the Muntin rule they break, an owned `var id: Int` route value and typed `-> StaticString` function values register, typed function values spell each request parameter `var`, and helpers generic over the result or a request parameter forward to `get` and `post`. Spellings, binding, the results of plain `def` handlers, errors, the raw escape hatch, ownership and the backend seam are unchanged ([Registration on generic-arity slots in production (M3-015)](history/architecture-decisions.md#registration-on-generic-arity-slots-in-production-m3-015)).

Every guarantee is decided in `App.handle` and the registration overloads, so both backends inherit it. What Muntin does not provide today is in `docs/ARCHITECTURE.md`, "Other current limits and operational risks"; when M2 reopens is in `docs/ARCHITECTURE.md`, "When M2 reopens".

## M3 — composition and production ergonomics

Each M3 area is cut decision-first: a decision item picks the design with pinned-compiler evidence and names one exact production slice, which is the next item.

| Capability | Status |
|---|---|
| application state shared with handlers (`State[S]`) on `get`, `post` and raw handlers | shipped |
| request and response headers (`Headers`) | shipped |
| JSON bodies and results (`Json[T]`) | shipped |
| request header fields from `TestClient` (`headers=`) | shipped |
| request header fields in typed `post` handlers (`WithHeaders[B]`) | shipped |
| registration on generic-arity slots (one `get`/`post` overload per request-slot arity) | shipped |
| request header fields in typed `get` handlers (a `Headers` parameter, last) | shipped |

### Remaining candidates

Each becomes its own decision-first item.

- **OpenAPI/schema output**: needs a type-to-format mapping; codecs are hand-mapped today, so a schema source waits for a derived codec;
- **JSON follow-ups**: a configurable body cap, derived codecs, `+json` or missing `Content-Type`, `Json(value, status=)`, top-level list results;
- **compile-time header names, a `FromHeaders` converter**: a converter makes Muntin choose a status for header values; `Headers` can conform to it without changing the `get` shapes;
- **more route values**: several values, path and query values together, optional/default query values, other value types. `String` route values, percent-decoded, are decided ([M3-018](history/architecture-decisions.md#string-route-value-decision-m3-018)) and are the next production item (M3-019); `Int` values stay undecoded. A value type is a slot kind and several values a rule, with no new overload up to slot arity 2;
- **more HTTP methods** (`put`, `patch`, `delete`, `POST` without a body): each new method is its own six arity overloads over the shared rules; the compiler's note budget is per method name, so they fit without restructuring. `POST` without a body is a rule change on `post`;
- **more body shapes**: a Muntin text type conforming to `FromBody` (raw `String` is a route-value type, never a body), optional, multiple, streaming and binary bodies (binary needs a non-`String` body representation);
- **fallible conversions and parameter-name checking**: a raising `to_response`/`to_error_response` needs its own error answer; name checking needs function-parameter reflection, which Mojo 1.1.0 lacks;
- **broader raw handlers**: raw route values, `String`/`ToResponse` raw results (each a rule change on the arity overloads);
- middleware;
- structured errors, including application-level error mappers (rejected on Mojo 1.1.0 by M2-012; its revisit conditions apply);
- observability hooks, including logging of dropped handler errors;
- streaming;
- lifecycle, including whether Muntin owns a public `app.run()` (serving is backend/lifecycle work, not part of the handler model);
- performance benchmarks and allocation profiling.

## Long-term success criterion

Muntin earns its existence if application code is materially clearer, safer, or more statically verifiable than using a networking library directly while preserving an escape hatch for low-level work.

Raw benchmark wins alone are not sufficient. A thin Flare re-export is not sufficient. A beautiful API that cannot survive backend/toolchain evolution is not sufficient.
