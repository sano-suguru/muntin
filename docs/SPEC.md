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

Later items changed the contract. An amendment adds to it; a reopen changes what an existing registration answers or an M2 public type (M2-016). What each changed, by kind, is in its record:

- M3-015 amended it (registration overloads per request-slot arity with generic slots and a `where` clause on the result): [Registration structure decision (M3-014)](history/architecture-decisions.md#registration-structure-decision-m3-014), [Registration structure amendment: generic forwarding (M3-015)](history/architecture-decisions.md#registration-structure-amendment-generic-forwarding-m3-015), [Registration on generic-arity slots in production (M3-015)](history/architecture-decisions.md#registration-on-generic-arity-slots-in-production-m3-015);
- M3-019 amended it (route values percent-decoded once at capture; `String` route values): [Route-value decoding and String route values decision (M3-018)](history/architecture-decisions.md#route-value-decoding-and-string-route-values-decision-m3-018);
- M3-023 amended it (up to two route values, bound in the literal's order; distinct query keys): [Several route values decision (M3-022)](history/architecture-decisions.md#several-route-values-decision-m3-022);
- M3-025 amended it (`Optional[Int]` and `Optional[String]` query values): [Optional query values decision (M3-024)](history/architecture-decisions.md#optional-query-values-decision-m3-024);
- M3-027 reopened it (`HEAD` answered by `get` routes, with no content on the wire): [HEAD decision (M3-026)](history/architecture-decisions.md#head-decision-m3-026);
- M3-031 reopened it (405 with `Allow` where a route of another method matches the path): [Method not allowed decision (M3-030)](history/architecture-decisions.md#method-not-allowed-decision-m3-030);
- M3-038 reopened it (a body that is not UTF-8 refused by the adapter; replaced by M3-040): [Request body bytes decision (M3-038)](history/architecture-decisions.md#request-body-bytes-decision-m3-038);
- M3-039 reopened it (a method or target that is not UTF-8 is the adapter's 400): [Request target and method bytes decision (M3-039)](history/architecture-decisions.md#request-target-and-method-bytes-decision-m3-039);
- M3-040 reopened it (`Request.body` and `Response.body` are `List[UInt8]`): [Binary request and response bodies decision (M3-040)](history/architecture-decisions.md#binary-request-and-response-bodies-decision-m3-040);
- M3-041 amended it (`FromBytes` bodies): [Typed binary request bodies decision (M3-041)](history/architecture-decisions.md#typed-binary-request-bodies-decision-m3-041);
- M3-042 amended it (`WithHeaders[B]` around a `FromBytes`): [Typed binary request bodies with header fields decision (M3-042)](history/architecture-decisions.md#typed-binary-request-bodies-with-header-fields-decision-m3-042);
- M3-043 amended it (required `FromBytes.max_bytes` and its 413): [Typed binary request body size limits decision (M3-043)](history/architecture-decisions.md#typed-binary-request-body-size-limits-decision-m3-043);
- M3-048 amended it (bodyless typed `post`, `put` and `patch` handlers): [Bodyless typed post, put and patch handlers decision (M3-048)](history/architecture-decisions.md#bodyless-typed-post-put-and-patch-handlers-decision-m3-048).

Every guarantee is decided in `App.handle` and the registration overloads, so both backends inherit it, except one: the contract's opening sentence holds for `HEAD`'s answer but not for its content. The in-memory response to `HEAD` keeps the body, and keeping it off the wire, with the length, is each network backend's obligation ([HEAD decision (M3-026)](history/architecture-decisions.md#head-decision-m3-026)). What Muntin does not provide today is in `docs/ARCHITECTURE.md`, "Other current limits and operational risks"; when M2 reopens is in `docs/ARCHITECTURE.md`, "When M2 reopens".

## M3 — composition and production ergonomics

An M3 area with an open design question is cut decision-first: a decision item picks the design with pinned-compiler evidence and names one exact production slice, which is the next item. Which kind an item is: `docs/DEVELOPMENT.md` section 2.

What each capability does for an application: `docs/DX.md`; how and why: its decision.

| Capability | Decision | Status |
|---|---|---|
| application state shared with handlers (`State[S]`) | [M3-001](history/architecture-decisions.md#application-state-decision-m3-001) | shipped |
| request and response headers (`Headers`) | [M3-002](history/architecture-decisions.md#headers-decision-m3-002) | shipped |
| JSON bodies and results (`Json[T]`) | [M3-008](history/architecture-decisions.md#json-codec-decision-m3-008) | shipped |
| a chosen status for a JSON result (`Json(value, status=201)`) | [M3-028](history/architecture-decisions.md#json-response-status-decision-m3-028) | shipped |
| request header fields from `TestClient` (`headers=`) | [M3-010](history/architecture-decisions.md#testclient-request-headers-decision-m3-010) | shipped |
| request header fields in typed `post` handlers (`WithHeaders[B]`) | [M3-012](history/architecture-decisions.md#typed-header-access-decision-m3-012) | shipped |
| registration on generic-arity slots (one overload per request-slot arity) | [M3-014](history/architecture-decisions.md#registration-structure-decision-m3-014) | shipped |
| request header fields in typed `get` handlers (a `Headers` parameter, last) | [M3-016](history/architecture-decisions.md#typed-get-header-access-decision-m3-016) | shipped |
| `String` route values, every route value percent-decoded at capture | [M3-018](history/architecture-decisions.md#route-value-decoding-and-string-route-values-decision-m3-018) | shipped |
| `PUT`, `PATCH` and `DELETE` | [M3-020](history/architecture-decisions.md#http-methods-decision-m3-020) | shipped |
| bodyless typed `post`, `put` and `patch` handlers | [M3-048](history/architecture-decisions.md#bodyless-typed-post-put-and-patch-handlers-decision-m3-048) | shipped |
| two route values on every method | [M3-022](history/architecture-decisions.md#several-route-values-decision-m3-022) | shipped |
| optional query values (`Optional[Int]`, `Optional[String]`) | [M3-024](history/architecture-decisions.md#optional-query-values-decision-m3-024) | shipped |
| `HEAD` through `get` routes | [M3-026](history/architecture-decisions.md#head-decision-m3-026) | shipped |
| `TestClient.head` | [M3-036](history/architecture-decisions.md#testclient-head-decision-m3-036) | shipped |
| 405 `Method Not Allowed` with `Allow` | [M3-030](history/architecture-decisions.md#method-not-allowed-decision-m3-030) | shipped |
| serving an `App` over cleartext HTTP/1.1 and h2c (`Server`, IP literals) | [M3-032](history/architecture-decisions.md#serving-entrypoint-decision-m3-032) | shipped |
| middleware functions (`app.use(f)`, compile-time configuration only) | [M3-034](history/architecture-decisions.md#middleware-decision-m3-034) | shipped |
| request method and target bytes kept exactly through Flare | [M3-039](history/architecture-decisions.md#request-target-and-method-bytes-decision-m3-039) | shipped |
| binary request and response bodies (`List[UInt8]`) | [M3-040](history/architecture-decisions.md#binary-request-and-response-bodies-decision-m3-040) | shipped |
| typed binary request bodies (`FromBytes`) | [M3-041](history/architecture-decisions.md#typed-binary-request-bodies-decision-m3-041) | shipped |
| typed binary request bodies with header fields (`WithHeaders[B]` around a `FromBytes`) | [M3-042](history/architecture-decisions.md#typed-binary-request-bodies-with-header-fields-decision-m3-042) | shipped |
| typed binary request body size limits (`FromBytes.max_bytes`) | [M3-043](history/architecture-decisions.md#typed-binary-request-body-size-limits-decision-m3-043) | shipped |
| graceful shutdown of `Server` on SIGTERM and SIGINT (`shutdown_grace_ms`) | [M3-045](history/architecture-decisions.md#graceful-shutdown-decision-m3-045) | shipped |
| a configurable receive body limit for `Server` (`max_body_bytes`) | [M3-044](history/architecture-decisions.md#server-receive-body-limit-decision-m3-044) | shipped |
| a configurable idle timeout for `Server` (`idle_timeout_ms`) | [M3-047](history/architecture-decisions.md#server-idle-timeout-decision-m3-047) | shipped |
| several serving threads for `Server`, one `App` per worker (`serve[make](workers=n)`) | [M3-049](history/architecture-decisions.md#multi-worker-serving-decision-m3-049) | shipped |

### Remaining candidates

In priority order: the first entry is the next item unless the user asks for another. Each becomes its own item, a decision item first where it opens a design question.

- **comparison with Flare alone**: the same applications written against Flare directly and with Muntin, to measure what Muntin's application layer adds (clearer, safer, more statically checked handler code) and what it costs (throughput, latency, allocations, the adapter's copies). Muntin's long-term success criterion (below) is what it tests. A decision item: its pull request first states the question and what would settle it;

- **OpenAPI/schema output**: needs a type-to-format mapping; codecs are hand-mapped today, so a schema source waits for a derived codec;
- **body limits beyond `FromBytes`** ([M3-043](history/architecture-decisions.md#typed-binary-request-body-size-limits-decision-m3-043)): a limit for text bodies (`FromBody`), an `App`-wide or per-registration limit; a per-route receive limit or one refusal status across protocols ([M3-044](history/architecture-decisions.md#server-receive-body-limit-decision-m3-044), which made the `Server`-wide receive limit configurable);
- **JSON follow-ups**: a configurable body cap, derived codecs, `+json` or missing `Content-Type`, top-level list results;
- **compile-time header names, a `FromHeaders` converter**: a converter makes Muntin choose a status for header values; `Headers` can conform to it without changing the `get` shapes;
- **more route values**: three or more values, a default written in the literal (`?{limit=20}`), other value types, a named carrier that checks placeholder names. A value type is a slot kind; a third value beside a body or `Headers` needs slot arity 4 ([M3-022](history/architecture-decisions.md#several-route-values-decision-m3-022));
- **more HTTP methods** (answering `OPTIONS` itself or a CORS preflight, 501 for a method Muntin does not implement, a typed `DELETE` body, methods outside `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE` or a generic entrypoint, a registered `HEAD`): each has a revisit condition in [M3-020](history/architecture-decisions.md#http-methods-decision-m3-020), in [M3-026](history/architecture-decisions.md#head-decision-m3-026) for a registered `HEAD`, or in [M3-030](history/architecture-decisions.md#method-not-allowed-decision-m3-030) for `OPTIONS`, CORS preflight and 501. A bodyless shape is a rule change on `post`'s family;
- **more body shapes**: a Muntin text type conforming to `FromBody` (raw `String` is a route-value type, never a body), optional, multiple, streaming and multipart bodies;
- **fallible conversions and parameter-name checking**: a raising `to_response`/`to_error_response` needs its own error answer; name checking needs function-parameter reflection, which Mojo 1.1.0 lacks;
- **broader raw handlers**: raw route values, `String`/`ToResponse` raw results (each a rule change on the arity overloads);
- **more middleware**: runtime-configured middleware (middleware values, A in [M3-034](history/architecture-decisions.md#middleware-decision-m3-034), or a `State` bound to a middleware function), request-scoped typed context (an identity a handler receives), per-route or per-group middleware and middleware error types, each with a revisit condition there;
- structured errors, including application-level error mappers (rejected on Mojo 1.1.0 by M2-012; its revisit conditions apply);
- observability hooks, including logging of dropped handler errors;
- streaming;
- serving lifecycle beyond `Server`: a stop call, ending the grace window early when nothing is in flight (needs Flare to report live connections; [M3-045](history/architecture-decisions.md#graceful-shutdown-decision-m3-045)), one `State` value shared by several workers (needs a thread-safety bound Mojo 1.1.0 cannot check; [M3-049](history/architecture-decisions.md#multi-worker-serving-decision-m3-049), which shipped workers with one `App` each; [M3-046](history/architecture-decisions.md#head-of-line-blocking-decision-m3-046) pins the blocking that remains on one worker, and a longer idle timeout, which turns its dropped requests into waits, shipped with [M3-047](history/architecture-decisions.md#server-idle-timeout-decision-m3-047)), several processes serving one address as a supported form (measured once on Linux in M3-046; its stop semantics are open), backend configuration beyond the receive body limit and the idle timeout (other timeouts, a connection cap, TLS; the body limit shipped with [M3-044](history/architecture-decisions.md#server-receive-body-limit-decision-m3-044)) and one call that binds and serves, each with a revisit condition in [M3-032](history/architecture-decisions.md#serving-entrypoint-decision-m3-032), and host names, which M3-032 leaves out of its slice with none;
- performance benchmarks and allocation profiling.

## Long-term success criterion

Muntin earns its existence if application code is materially clearer, safer, or more statically verifiable than using a networking library directly while preserving an escape hatch for low-level work.

Raw benchmark wins alone are not sufficient. A thin Flare re-export is not sufficient. A beautiful API that cannot survive backend/toolchain evolution is not sufficient.
