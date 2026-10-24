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

Muntin does not implement these unless an accepted milestone explicitly requires it: a custom async runtime or executor, socket management, TLS, HTTP/2, HTTP/3, QUIC, WebSockets (all backend concerns); dependency injection, a database layer, authentication, a template engine, deployment tooling; performance optimization before a baseline exists. It should not initially become a thin Flare re-export, a FastAPI syntax clone or a Rails/Django-scale full-stack framework. The Flare adapter never replaces Muntin's router, request/response model or middleware design with Flare's (`docs/ARCHITECTURE.md`, "Flare policy").

## M2 completion contract

M2's contract, the list of later items that amended or reopened it, and when M2 reopens are in [`history/m2-completion-contract.md`](history/m2-completion-contract.md). What Muntin answers today is in the [reference](reference/).

## M3 — composition and production ergonomics

An M3 area with an open design question is cut decision-first: a decision item picks the design with pinned-compiler evidence and names one exact production slice, which is the next item. Which kind an item is: `docs/DEVELOPMENT.md` section 2.

What each capability does for an application: the [guide](GUIDE.md) and the [reference](reference/); how and why: its decision.

| Capability | Decision | Status |
|---|---|---|
| application state shared with handlers (`State[S]`) | [M3-001](history/decisions/m3-001-application-state-decision.md) | shipped |
| a `State` whose type may borrow refused at compile time | [M3-074](history/decisions/m3-074-state-borrowing-decision.md) | shipped |
| request and response headers (`Headers`) | [M3-002](history/decisions/m3-002-headers-decision.md) | shipped |
| JSON bodies and results (`Json[T]`) | [M3-008](history/decisions/m3-008-json-codec-decision.md) | shipped |
| a chosen status for a JSON result (`Json(value, status=201)`) | [M3-028](history/decisions/m3-028-json-response-status-decision.md) | shipped |
| one-call JSON object members, chosen by the value's type (`out.field("id", self.id)`, `Optional` and `List` included) | [M3-075](history/decisions/m3-075-json-writer-members-decision.md) | shipped |
| JSON codecs derived from a struct's fields (`JsonFields`), and top-level `List` and `Optional` bodies and results | [M3-082](history/decisions/m3-082-derived-json-codecs-decision.md) | shipped |
| request header fields from `TestClient` (`headers=`) | [M3-010](history/decisions/m3-010-testclient-request-headers-decision.md) | shipped |
| request header fields in typed `post` handlers (`WithHeaders[B]`) | [M3-012](history/decisions/m3-012-typed-header-access-decision.md) | shipped |
| registration on generic-arity slots (one overload per request-slot arity) | [M3-014](history/decisions/m3-014-registration-structure-decision.md) | shipped |
| request header fields in typed `get` handlers (a `Headers` parameter, last) | [M3-016](history/decisions/m3-016-typed-get-header-access-decision.md) | shipped |
| `String` route values, every route value percent-decoded at capture | [M3-018](history/decisions/m3-018-route-value-decoding-and-string-route-values-decision.md) | shipped |
| `PUT`, `PATCH` and `DELETE` | [M3-020](history/decisions/m3-020-http-methods-decision.md) | shipped |
| bodyless typed `post`, `put` and `patch` handlers | [M3-048](history/decisions/m3-048-bodyless-typed-post-put-and-patch-handlers-decision.md) | shipped |
| two route values on every method | [M3-022](history/decisions/m3-022-several-route-values-decision.md) | shipped |
| route values named after their placeholders (`Param`), opt-in | [M3-050](history/decisions/m3-050-named-route-values-decision.md) | shipped |
| route conflicts refused at registration (most specific route first) | [M3-053](history/decisions/m3-053-route-conflict-decision.md) | shipped |
| application types as route values (`FromRouteValue`) | [M3-054](history/decisions/m3-054-application-route-value-types-decision.md) | shipped |
| three or more route values as one record (`RouteValues`) | [M3-061](history/decisions/m3-061-route-value-records-decision.md) | shipped |
| optional query values (`Optional[Int]`, `Optional[String]`) | [M3-024](history/decisions/m3-024-optional-query-values-decision.md) | shipped |
| `HEAD` through `get` routes | [M3-026](history/decisions/m3-026-head-decision.md) | shipped |
| `TestClient.head` | [M3-036](history/decisions/m3-036-testclient-head-decision.md) | shipped |
| 405 `Method Not Allowed` with `Allow` | [M3-030](history/decisions/m3-030-method-not-allowed-decision.md) | shipped |
| serving an `App` over cleartext HTTP/1.1 and h2c (`Server`, IP literals) | [M3-032](history/decisions/m3-032-serving-entrypoint-decision.md) | shipped |
| middleware functions (`app.use(f)`, compile-time configuration only) | [M3-034](history/decisions/m3-034-middleware-decision.md) | shipped |
| a request handed to `App.handle` reaches middleware without a copy (the owning `App.handle`, M3-064) | [M3-063](history/decisions/m3-063-request-context-decision.md) | shipped |
| request method and target bytes kept exactly through Flare | [M3-039](history/decisions/m3-039-request-target-and-method-bytes-decision.md) | shipped |
| requests without `Host` refused (400) through Flare, HTTP/1.1 and HTTP/2 | [M3-073](history/decisions/m3-073-request-host-decision.md) | shipped |
| invalid `Host` values refused (400) through Flare, on every version | [M3-076](history/decisions/m3-076-request-host-value-decision.md) | shipped |
| binary request and response bodies (`List[UInt8]`) | [M3-040](history/decisions/m3-040-binary-request-and-response-bodies-decision.md) | shipped |
| typed binary request bodies (`FromBytes`) | [M3-041](history/decisions/m3-041-typed-binary-request-bodies-decision.md) | shipped |
| typed binary request bodies with header fields (`WithHeaders[B]` around a `FromBytes`) | [M3-042](history/decisions/m3-042-typed-binary-request-bodies-with-header-fields-decision.md) | shipped |
| typed binary request body size limits (`FromBytes.max_bytes`) | [M3-043](history/decisions/m3-043-typed-binary-request-body-size-limits-decision.md) | shipped |
| graceful shutdown of `Server` on SIGTERM and SIGINT (`shutdown_grace_ms`) | [M3-045](history/decisions/m3-045-graceful-shutdown-decision.md) | shipped |
| a configurable receive body limit for `Server` (`max_body_bytes`) | [M3-044](history/decisions/m3-044-server-receive-body-limit-decision.md) | shipped |
| a configurable idle timeout for `Server` (`idle_timeout_ms`) | [M3-047](history/decisions/m3-047-server-idle-timeout-decision.md) | shipped |
| a request header field limit for `Server` (`max_header_fields`, 431 past it) | [M3-066](history/decisions/m3-066-request-header-conversion-decision.md) | shipped |
| several serving threads for `Server`, one `App` per worker (`serve[make](workers=n)`) | [M3-049](history/decisions/m3-049-multi-worker-serving-decision.md) | shipped |
| HTTPS for `Server` (`tls=Tls(cert_file=..., key_file=...)`) | [M3-051](history/decisions/m3-051-server-tls-decision.md) | shipped |
| HTTPS on several workers (`serve[make](workers=n)` on a `Server` bound with `tls`) | [M3-060](history/decisions/m3-060-tls-with-workers-decision.md) | shipped |
| reports of the errors behind the fixed 500, read by middleware (`Response.failure()`, `Failure`) | [M3-058](history/decisions/m3-058-dropped-error-report-decision.md) | shipped |
| reports of why Muntin answered 400 before a handler, read by middleware (`Response.rejection()`, `Rejection`) | [M3-084](history/decisions/m3-084-request-rejection-report-decision.md) | shipped |
| routes behind one guard that hands handlers a typed context (`Group`, `app.mount`) | [M3-080](history/decisions/m3-080-guarded-routes-and-request-context-decision.md) | shipped |

### Remaining candidates

After the comparison with Flare alone, which showed a static-checking advantage on its sample but not the long-term success criterion, the owner resumed these candidates in this order ([M3-079](history/decisions/m3-079-comparison-with-flare-alone-decision.md)), and kept it after the comparison by authors new to Muntin, which did not meet its criterion: no author on either side missed a check, and Muntin's authors looked in fewer places on two of its four tasks ([M3-086](history/decisions/m3-086-comparison-by-new-authors-decision.md)).

In priority order: the first entry is the next item unless the user asks for another. Each becomes its own item, a decision item first where it opens a design question. An entry here is only what it solves and when to start. A revisit condition, or any other condition that binds later items, lives in the linked decision record or in [`history/deferrals.md`](history/deferrals.md); the issue holds the details, design targets and discussion.

1. **Linear request header conversion** ([#140](https://github.com/sano-suguru/muntin/issues/140)). Solves: the adapter's field check costs fields × distinct names comparisons inside Flare, which keeps `max_header_fields` low ([M3-066](history/decisions/m3-066-request-header-conversion-decision.md)). Start: when Flare ships an ordered field accessor on `HeaderMap` (asked in [ehsanmok/flare#39](https://github.com/ehsanmok/flare/issues/39)), then a pin change ([deferral](history/deferrals.md#linear-request-header-conversion)).

Then, in priority order, each with its issue:

2. derived JSON values inside hand-written codecs ([#195](https://github.com/sano-suguru/muntin/issues/195)): the production slice M3-088 of [M3-087](history/decisions/m3-087-derived-json-in-hand-written-codecs-decision.md);
3. OpenAPI and schema output ([#142](https://github.com/sano-suguru/muntin/issues/142));
4. body limits beyond `FromBytes`, including the fixed `Json[T]` cap ([#143](https://github.com/sano-suguru/muntin/issues/143)): the production slice M3-090 of [M3-089](history/decisions/m3-089-text-and-json-body-limits-decision.md);
5. `+json` media types or a missing `Content-Type` on JSON bodies ([#193](https://github.com/sano-suguru/muntin/issues/193));
6. a JSON body and result without the `Json` wrapper ([#194](https://github.com/sano-suguru/muntin/issues/194));
7. renamed and defaulted members and more field kinds for derived JSON ([#196](https://github.com/sano-suguru/muntin/issues/196));
8. compile-time header names and a `FromHeaders` converter ([#144](https://github.com/sano-suguru/muntin/issues/144));
9. more route values: a default in the literal, more value types, a check of the handler's own parameter names ([#145](https://github.com/sano-suguru/muntin/issues/145));
10. more HTTP methods: `OPTIONS`, CORS preflight, 501, a registered `HEAD` ([#146](https://github.com/sano-suguru/muntin/issues/146));
11. more body shapes: text type, optional, multiple, streaming, multipart ([#147](https://github.com/sano-suguru/muntin/issues/147));
12. fallible response conversions ([#148](https://github.com/sano-suguru/muntin/issues/148));
13. broader raw handlers ([#149](https://github.com/sano-suguru/muntin/issues/149));
14. more middleware: per-route, error types ([#150](https://github.com/sano-suguru/muntin/issues/150));
15. structured errors and application-level error mappers ([#152](https://github.com/sano-suguru/muntin/issues/152));
16. observability ([#153](https://github.com/sano-suguru/muntin/issues/153));
17. streamed responses ([#154](https://github.com/sano-suguru/muntin/issues/154));
18. serving lifecycle beyond `Server` ([#155](https://github.com/sano-suguru/muntin/issues/155); spreading connections over workers is [deferred](history/deferrals.md#spreading-kept-open-connections-over-workers-m3-069));
19. a connection cap for `Server` ([#156](https://github.com/sano-suguru/muntin/issues/156); [deferred](history/deferrals.md#connection-cap-for-server));
20. handler execution model ([#157](https://github.com/sano-suguru/muntin/issues/157));
21. performance benchmarks and allocation profiling ([#158](https://github.com/sano-suguru/muntin/issues/158)).

## Long-term success criterion

Muntin earns its existence if application code is materially clearer, safer, or more statically verifiable than using a networking library directly while preserving an escape hatch for low-level work.

Raw benchmark wins alone are not sufficient. A thin Flare re-export is not sufficient. A beautiful API that cannot survive backend/toolchain evolution is not sufficient.
