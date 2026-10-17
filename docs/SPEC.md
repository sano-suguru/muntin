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

Muntin does not implement these unless an accepted milestone explicitly requires it: a custom async runtime or executor, socket management, TLS, HTTP/2, HTTP/3, QUIC, WebSockets (all backend concerns); dependency injection, a database layer, authentication, a template engine, deployment tooling; performance optimization before a baseline exists. It is not a thin Flare re-export, a FastAPI syntax clone or a Rails/Django-scale full-stack framework. The Flare adapter never replaces Muntin's router, request/response model or middleware design with Flare's (`docs/ARCHITECTURE.md`, "Flare policy").

## M2 completion contract

M2's contract and the list of later items that amended or reopened it are kept, as history, in [`history/m2-completion-contract.md`](history/m2-completion-contract.md). What Muntin answers today is in the [reference](reference/).

## M3 — composition and production ergonomics

An M3 area with an open design question is cut decision-first: a decision item picks the design with pinned-compiler evidence and names one exact production slice, which is the next item. Which kind an item is: `docs/DEVELOPMENT.md` section 2.

What each capability does for an application: the [guide](GUIDE.md) and the [reference](reference/); how and why: its decision.

| Capability | Decision | Status |
|---|---|---|
| application state shared with handlers (`State[S]`) | [M3-001](history/architecture-decisions.md#application-state-decision-m3-001) | shipped |
| a `State` whose type may borrow refused at compile time | [M3-074](history/architecture-decisions.md#state-borrowing-decision-m3-074) | shipped |
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
| route values named after their placeholders (`Param`), opt-in | [M3-050](history/architecture-decisions.md#named-route-values-decision-m3-050) | shipped |
| route conflicts refused at registration (most specific route first) | [M3-053](history/architecture-decisions.md#route-conflict-decision-m3-053) | shipped |
| application types as route values (`FromRouteValue`) | [M3-054](history/architecture-decisions.md#application-route-value-types-decision-m3-054) | shipped |
| three or more route values as one record (`RouteValues`) | [M3-061](history/architecture-decisions.md#route-value-records-decision-m3-061) | shipped |
| optional query values (`Optional[Int]`, `Optional[String]`) | [M3-024](history/architecture-decisions.md#optional-query-values-decision-m3-024) | shipped |
| `HEAD` through `get` routes | [M3-026](history/architecture-decisions.md#head-decision-m3-026) | shipped |
| `TestClient.head` | [M3-036](history/architecture-decisions.md#testclient-head-decision-m3-036) | shipped |
| 405 `Method Not Allowed` with `Allow` | [M3-030](history/architecture-decisions.md#method-not-allowed-decision-m3-030) | shipped |
| serving an `App` over cleartext HTTP/1.1 and h2c (`Server`, IP literals) | [M3-032](history/architecture-decisions.md#serving-entrypoint-decision-m3-032) | shipped |
| middleware functions (`app.use(f)`, compile-time configuration only) | [M3-034](history/architecture-decisions.md#middleware-decision-m3-034) | shipped |
| a request handed to `App.handle` reaches middleware without a copy (the owning `App.handle`, M3-064) | [M3-063](history/architecture-decisions.md#request-context-decision-m3-063) | shipped |
| request method and target bytes kept exactly through Flare | [M3-039](history/architecture-decisions.md#request-target-and-method-bytes-decision-m3-039) | shipped |
| requests without `Host` refused (400) through Flare, HTTP/1.1 and HTTP/2 (the value is not checked) | [M3-073](history/architecture-decisions.md#request-host-decision-m3-073) | shipped |
| binary request and response bodies (`List[UInt8]`) | [M3-040](history/architecture-decisions.md#binary-request-and-response-bodies-decision-m3-040) | shipped |
| typed binary request bodies (`FromBytes`) | [M3-041](history/architecture-decisions.md#typed-binary-request-bodies-decision-m3-041) | shipped |
| typed binary request bodies with header fields (`WithHeaders[B]` around a `FromBytes`) | [M3-042](history/architecture-decisions.md#typed-binary-request-bodies-with-header-fields-decision-m3-042) | shipped |
| typed binary request body size limits (`FromBytes.max_bytes`) | [M3-043](history/architecture-decisions.md#typed-binary-request-body-size-limits-decision-m3-043) | shipped |
| graceful shutdown of `Server` on SIGTERM and SIGINT (`shutdown_grace_ms`) | [M3-045](history/architecture-decisions.md#graceful-shutdown-decision-m3-045) | shipped |
| a configurable receive body limit for `Server` (`max_body_bytes`) | [M3-044](history/architecture-decisions.md#server-receive-body-limit-decision-m3-044) | shipped |
| a configurable idle timeout for `Server` (`idle_timeout_ms`) | [M3-047](history/architecture-decisions.md#server-idle-timeout-decision-m3-047) | shipped |
| a request header field limit for `Server` (`max_header_fields`, 431 past it) | [M3-066](history/architecture-decisions.md#request-header-conversion-decision-m3-066) | shipped |
| several serving threads for `Server`, one `App` per worker (`serve[make](workers=n)`) | [M3-049](history/architecture-decisions.md#multi-worker-serving-decision-m3-049) | shipped |
| HTTPS for `Server` (`tls=Tls(cert_file=..., key_file=...)`) | [M3-051](history/architecture-decisions.md#server-tls-decision-m3-051) | shipped |
| HTTPS on several workers (`serve[make](workers=n)` on a `Server` bound with `tls`) | [M3-060](history/architecture-decisions.md#tls-with-workers-decision-m3-060) | shipped |
| reports of the errors behind the fixed 500, read by middleware (`Response.failure()`, `Failure`) | [M3-058](history/architecture-decisions.md#dropped-error-report-decision-m3-058) | shipped |

### Remaining candidates

In priority order: the first entry is the next item unless the user asks for another. Each becomes its own item, a decision item first where it opens a design question. Details, design targets and revisit conditions live in each linked issue or decision record; an entry here is only what it solves and when to start.

1. **`Host` value validation** ([#138](https://github.com/sano-suguru/muntin/issues/138)). Solves: the adapter passes any `Host` value Flare admits, so a malformed one reaches `App.handle`, against RFC 9112's 400 ([M3-073](history/architecture-decisions.md#request-host-decision-m3-073) checks presence only). Start: now; a decision item first.
2. **Comparison with Flare alone** ([#139](https://github.com/sano-suguru/muntin/issues/139)). Solves: shows, with the same applications written both ways, whether Muntin meets its long-term success criterion (below) and what its layer costs. Start: after the item above; a decision item whose pull request first states the question and what would settle it.
3. **Linear request header conversion** ([#140](https://github.com/sano-suguru/muntin/issues/140)). Solves: the adapter's field check is quadratic in the number of fields, which keeps `max_header_fields` low ([M3-066](history/architecture-decisions.md#request-header-conversion-decision-m3-066)). Start: when Flare ships an ordered field accessor on `HeaderMap` (pull request #119 drafts it), then a pin change.

Later, unordered, each with its issue:

- derived codecs and JSON follow-ups, the canonical `def create_user(body: CreateUser) -> User` ([#141](https://github.com/sano-suguru/muntin/issues/141));
- OpenAPI and schema output ([#142](https://github.com/sano-suguru/muntin/issues/142));
- body limits beyond `FromBytes` ([#143](https://github.com/sano-suguru/muntin/issues/143));
- compile-time header names and a `FromHeaders` converter ([#144](https://github.com/sano-suguru/muntin/issues/144));
- more route values: defaults, more value types, name-based binding ([#145](https://github.com/sano-suguru/muntin/issues/145));
- more HTTP methods: `OPTIONS`, CORS preflight, 501, a registered `HEAD` ([#146](https://github.com/sano-suguru/muntin/issues/146));
- more body shapes: text type, optional, multiple, streaming, multipart ([#147](https://github.com/sano-suguru/muntin/issues/147));
- fallible response conversions ([#148](https://github.com/sano-suguru/muntin/issues/148));
- broader raw handlers ([#149](https://github.com/sano-suguru/muntin/issues/149));
- more middleware: runtime-configured, per-route or per-group, error types ([#150](https://github.com/sano-suguru/muntin/issues/150));
- request context over a closed type ([#151](https://github.com/sano-suguru/muntin/issues/151));
- structured errors and application-level error mappers ([#152](https://github.com/sano-suguru/muntin/issues/152));
- observability ([#153](https://github.com/sano-suguru/muntin/issues/153));
- streamed responses ([#154](https://github.com/sano-suguru/muntin/issues/154));
- serving lifecycle beyond `Server` ([#155](https://github.com/sano-suguru/muntin/issues/155));
- a connection cap for `Server` ([#156](https://github.com/sano-suguru/muntin/issues/156));
- handler execution model ([#157](https://github.com/sano-suguru/muntin/issues/157));
- performance benchmarks and allocation profiling ([#158](https://github.com/sano-suguru/muntin/issues/158)).

## Long-term success criterion

Muntin earns its existence if application code is materially clearer, safer, or more statically verifiable than using a networking library directly while preserving an escape hatch for low-level work.

Raw benchmark wins alone are not sufficient. A thin Flare re-export is not sufficient. A beautiful API that cannot survive backend/toolchain evolution is not sufficient.
