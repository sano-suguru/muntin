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

M3-019 amended the contract (decided by M3-018): a route value is percent-decoded once when it is captured, before it is converted, so an escaped `Int` value whose decoded text is a valid `Int` (`/users/%34%32`, `?limit=%31%30`) is accepted where it was 400. A value written without escapes keeps its meaning, every invalid value is still 400 before the handler, and query keys, `Request` and raw handlers stay undecoded ([Route-value decoding and String route values decision (M3-018)](history/architecture-decisions.md#route-value-decoding-and-string-route-values-decision-m3-018)).

M3-023 amended the contract (decided by M3-022): a typed handler takes up to two route values, bound by position in the literal's order (path placeholders, then query placeholders), and a literal's query keys must differ. M2 is not reopened, because nothing that registers or answers today changes. By kind: the accepted set only grows (handlers with two route values register; no handler that registers today is rejected or registers differently); the overload set is added to (each method name gains its two slot-arity-3 overloads, and the existing declarations, signatures and `where` clause are unchanged); specific rejected-call diagnostics change (the two `at most one` messages are replaced by the two-value messages, a call with three request parameters and no state argument, which matched no overload, now reports a Muntin rule, including a stateful handler registered without its state (a three-parameter handler without a leading `State`, given a state, still matches none), and every call that still matches no overload lists eight candidates' notes instead of six); and runtime behavior is unchanged, the 400/404/500 boundary included ([Several route values decision (M3-022)](history/architecture-decisions.md#several-route-values-decision-m3-022)).

M3-025 amended the contract (decided by M3-024): an `Optional[Int]` or `Optional[String]` parameter is an optional route value. It binds a query placeholder only, is `None` when its key is absent, its value is empty or its pair has no `=`, and the handler supplies any default (`limit.or_else(20)`); a repeated key or an invalid present value is 400 as for a required value, and an application cannot tell `?q=` from no `q`. M2 is not reopened: the contract's "missing/duplicated/empty/invalid query value is 400 before the handler" still holds for every required value, and no route registered before had an optional one. By kind: the accepted set only grows (handlers with an optional value register; no handler that registered is rejected or registers differently); the overload set is unchanged; specific rejected-call diagnostics change (the two messages that list what a parameter may be name `Optional`, and a call with an `Optional[Int]` or `Optional[String]` parameter that got one of them now registers, gets one of three new messages, or gets the existing message of the next rule it breaks); and the runtime of every previously valid route is unchanged ([Optional query values decision (M3-024)](history/architecture-decisions.md#optional-query-values-decision-m3-024)).

M3-027 reopened the contract (decided by M3-026): a `get` route also answers `HEAD` on a path it matches, which M2 answered 404. That changes what an existing registration answers, so it is an M2 reopen under M2-016 ("a different 400/404/500 boundary"). By kind:
- `App.handle`: a `HEAD` request whose path a `get` route matches runs that route instead of getting 404: a typed handler gets the `GET`'s arguments and its answer, body included, is the `GET`'s; a raw handler receives the `HEAD` request (next bullet). "No route match is 404" still held for every other request, `HEAD` on a path no `get` route matches included, and for `head`, `Head` and `OPTIONS`; since M3-031 (below), each of them is 405 on a path a route of another method matches;
- the wire: every `HEAD` response through Flare carries no content, the 404s included (over cleartext HTTP/2 they carried `Not Found` before), and the adapter declares a `Content-Length` equal to the byte length of the body it would send for the `GET` (`App.handle`'s, or the adapter's own 400 or 500), and none for 1xx, 204, 205 or 304 (over HTTP/1.1, Flare still frames a 205 or 304 with `Content-Length: 0`). This is the Flare adapter's change, not `App.handle`'s;
- the raw escape hatch: a raw `get` handler can now receive `req.method == "HEAD"`; it still receives the whole `Request`;
- the accepted set, the overload set and every diagnostic are unchanged.

M3-031 reopened the contract (decided by M3-030): a request whose path some route matches, when no route on that path has its method, gets 405 `Method Not Allowed` with an `Allow` field, where M2 answered 404. That changes what existing registrations answer, so it is an M2 reopen under M2-016 ("a different 400/404/500 boundary"). By kind:
- 404: narrowed to a request whose path no route matches, whatever its method;
- 405: new, for the class above. `Allow` lists the methods of the routes whose path matches, each once, in first-registration order, with `HEAD` right after `GET`; every method is answered alike (`OPTIONS`, unknown and lowercase tokens included); no handler, conversion or decoding runs;
- 400 and 500: unchanged. Every 400 comes from a selected route, and selection is unchanged (the first registered matching route wins, a matched route never falls through, methods match byte for byte except `HEAD` to `GET`), so a request that becomes 405 was 404, never 400;
- route-value decoding and conversion, on the selected route only, and the raw escape hatch are unchanged; a raw route counts in `Allow` by its method;
- the accepted set, the overload set and every diagnostic are unchanged;
- the wire: through Flare, the 405 and its `Allow` go out as `App.handle` gives them, and a `HEAD` 405 has no content and `Content-Length: 18` (M3-027's rule). The adapter is unchanged.

Answering `OPTIONS` itself and CORS preflight are not decided; until then `OPTIONS` is answered like any method no route has ([Method not allowed decision (M3-030)](history/architecture-decisions.md#method-not-allowed-decision-m3-030)).

Every guarantee is decided in `App.handle` and the registration overloads, so both backends inherit it, except one: the contract's opening sentence holds for `HEAD`'s answer but not for its content. The in-memory response to `HEAD` keeps the body, and keeping it off the wire, with the length, is each network backend's obligation ([HEAD decision (M3-026)](history/architecture-decisions.md#head-decision-m3-026)). What Muntin does not provide today is in `docs/ARCHITECTURE.md`, "Other current limits and operational risks"; when M2 reopens is in `docs/ARCHITECTURE.md`, "When M2 reopens".

## M3 — composition and production ergonomics

An M3 area with an open design question is cut decision-first: a decision item picks the design with pinned-compiler evidence and names one exact production slice, which is the next item. Which kind an item is: `docs/DEVELOPMENT.md` section 2.

| Capability | Status |
|---|---|
| application state shared with handlers (`State[S]`) on `get`, `post` and raw handlers | shipped |
| request and response headers (`Headers`) | shipped |
| JSON bodies and results (`Json[T]`) | shipped |
| a chosen status for a JSON result (`Json(value, status=201)`; `Json(value)` stays 200) | shipped |
| request header fields from `TestClient` (`headers=`) | shipped |
| request header fields in typed `post` handlers (`WithHeaders[B]`) | shipped |
| registration on generic-arity slots (one `get`/`post` overload per request-slot arity) | shipped |
| request header fields in typed `get` handlers (a `Headers` parameter, last) | shipped |
| `String` route values, with every route value percent-decoded at capture | shipped |
| `PUT`, `PATCH` and `DELETE` (`app.put`/`app.patch` with `post`'s shapes, `app.delete` with `get`'s; `TestClient.put`, `.patch`, `.delete`) | shipped |
| two route values (path, query or one of each, bound in the literal's order) on every method | shipped |
| optional query values (`Optional[Int]`, `Optional[String]`; `None` when absent or empty) | shipped |
| `HEAD` through `get` routes (the `GET` route's steps; the backend sends no content and the body's length) | shipped |
| 405 `Method Not Allowed` with `Allow` for a request whose path a route of another method matches (404 when no route matches the path) | shipped |
| serving an `App` over cleartext HTTP/1.1 and h2c through the Flare adapter's `Server` (`Server.bind(host, port)`, `server.port()`, `server.serve(app)`; one thread, IP literals, no graceful shutdown; no core `app.run()`) | shipped |

### Remaining candidates

Each becomes its own item, a decision item first where it opens a design question.

- **OpenAPI/schema output**: needs a type-to-format mapping; codecs are hand-mapped today, so a schema source waits for a derived codec;
- **JSON follow-ups**: a configurable body cap, derived codecs, `+json` or missing `Content-Type`, top-level list results;
- **compile-time header names, a `FromHeaders` converter**: a converter makes Muntin choose a status for header values; `Headers` can conform to it without changing the `get` shapes;
- **more route values**: three or more values, a default written in the literal (`?{limit=20}`), other value types, a named carrier that checks placeholder names. A value type is a slot kind; a third value beside a body or `Headers` needs slot arity 4 ([M3-022](history/architecture-decisions.md#several-route-values-decision-m3-022));
- **more HTTP methods** (bodyless typed `post`, `put` and `patch` handlers, answering `OPTIONS` itself or a CORS preflight, 501 for a method Muntin does not implement, a typed `DELETE` body, methods outside `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE` or a generic entrypoint, a registered `HEAD`, `TestClient.head`): each has a revisit condition in [M3-020](history/architecture-decisions.md#http-methods-decision-m3-020), in [M3-026](history/architecture-decisions.md#head-decision-m3-026) for the two `HEAD` items, or in [M3-030](history/architecture-decisions.md#method-not-allowed-decision-m3-030) for `OPTIONS`, CORS preflight and 501. A bodyless shape is a rule change on `post`'s family;
- **more body shapes**: a Muntin text type conforming to `FromBody` (raw `String` is a route-value type, never a body), optional, multiple, streaming and binary bodies (binary needs a non-`String` body representation);
- **fallible conversions and parameter-name checking**: a raising `to_response`/`to_error_response` needs its own error answer; name checking needs function-parameter reflection, which Mojo 1.1.0 lacks;
- **broader raw handlers**: raw route values, `String`/`ToResponse` raw results (each a rule change on the arity overloads);
- middleware: decided by [Middleware decision (M3-034)](history/architecture-decisions.md#middleware-decision-m3-034) (functions with `App.use` and `Next`), next item M3-035; runtime-configured middleware, request-scoped typed context and per-route middleware are later items, each with a revisit condition there;
- structured errors, including application-level error mappers (rejected on Mojo 1.1.0 by M2-012; its revisit conditions apply);
- observability hooks, including logging of dropped handler errors;
- streaming;
- serving lifecycle beyond `Server`: graceful shutdown, signal handling, several serving threads, backend configuration (body size, timeouts, TLS) and one call that binds and serves, each with a revisit condition in [M3-032](history/architecture-decisions.md#serving-entrypoint-decision-m3-032), and host names, which M3-032 leaves out of its slice with none;
- performance benchmarks and allocation profiling.

## Long-term success criterion

Muntin earns its existence if application code is materially clearer, safer, or more statically verifiable than using a networking library directly while preserving an escape hatch for low-level work.

Raw benchmark wins alone are not sufficient. A thin Flare re-export is not sufficient. A beautiful API that cannot survive backend/toolchain evolution is not sufficient.
