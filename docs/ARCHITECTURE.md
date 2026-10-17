# Muntin architecture

Muntin owns the application model. Transports adapt to `App.handle(Request) -> Response`; they do not define application semantics.

This file is how Muntin works now: its invariants, its structure and the [revisit index](#revisit-index). What an application sees is the [guide](GUIDE.md) and the [reference](reference/routing.md); why each part is as it is, the [decision records](history/architecture-decisions.md); scope, [`SPEC.md`](SPEC.md). Milestone tags such as (M3-015) name the item that built a part.

## Architectural thesis

Muntin's leverage comes from application-level developer experience and compile-time guarantees. Networking is replaceable infrastructure behind `App.handle`; where that ends is the [Flare policy](#flare-policy).

```text
Application code
      |
+--------------------------------+
| Muntin public API              |
| App / Request / Response       |
| routes, handlers, extraction,  |
| errors, state, headers, JSON,  |
| middleware functions           |
+---------------+----------------+
                |  App.handle (the backend seam)
       +--------+---------+
       v                  v
 in-memory backend   Flare adapter (Server)
 (TestClient)              |
                   HTTP/TLS/reactor (Flare)
```

## Invariants

- **A1. Muntin owns the public application API.** Application code imports Muntin concepts. Third-party transport types never appear in handler signatures, routing, middleware, state contracts or examples.
- **A2. Dependency direction points inward.** `src/muntin` does not import Flare; adapters depend on Muntin. Never invert this for an adapter's convenience (`scripts/check_boundaries.sh`).
- **A3. Replaceability is executable.** The in-memory path exercises the same dispatch as transport adapters. A refactor that lets it bypass real routing is a regression even if tests stay green.
- **A4. The backend seam stays narrow.** It exposes only what Muntin needs to accept a request, dispatch it and produce a response. No executor, reactor, TLS session, socket option or cancellation machinery in public contracts.
- **A5. Protocol mechanics stay outside core.** Wire parsing, sockets, TLS, HTTP/2, HTTP/3, QUIC, event loops and connection pools belong to backends.
- **A6. Async evolution must remain survivable.** No framework-specific executor, future or task model to fill a temporary language gap.
- **A7. Evidence before abstraction.** An abstraction needs a current requirement, two real implementations or a strong external constraint; a hypothetical backend is not enough.
- **A8. DX is an architectural input.** The application code in the guide and reference constrains internal design: if internal convenience would make ordinary application code more verbose, reconsider the internal abstraction first. Prefer the design that keeps `def get_user(id: Int) -> User` and `app.get["/users/{id}"](get_user)` simple without giving up correctness, type safety, escape hatches or transport independence. An ordinary route needs no handler adapter, backend trait, serializer registration or context object. Compile-time machinery must earn its place by simpler application code, earlier diagnostics or measured savings. Diagnostics are API: say what is wrong and the likely fix. Every public abstraction is expensive: expose one only when it cannot stay internal and does not leak a backend. If a desired API is impossible in the current Mojo, keep the semantic property and pin the limitation with a reproduction.

## Current architecture

Toolchain: Mojo 1.1.0 (8189361e) via pixi, pinned by `pixi.lock`; `scripts/check.sh` fails on any other Mojo version. Flare v0.12.0 (`8c6e1400`) exists only in the `flare` pixi environment.

### Modules and public surface

```text
src/muntin/__init__.mojo          exports App, Middleware, Next, FromBody, FromBytes, Failure, Headers, Request, Response,
                                  ToErrorResponse, ToResponse, FromJson, Json, JsonValue, JsonWriter, ToJson,
                                  FromRouteValue, Param, RouteValues, State, WithHeaders
src/muntin/http.mojo              Request, Response, Failure, Headers, ToResponse, ToErrorResponse; private _failed
src/muntin/body.mojo              FromBody, FromBytes; private _FromBodyOrBytes (their shared parent) and _body_text
src/muntin/headers_body.mojo      WithHeaders[B]; private _HeaderCarrier
src/muntin/app.mojo               App (route table, the five methods' overloads, use, handle), Next, Middleware;
                                  private middleware chain (_run), dispatch (_dispatch), matching (_match), slot
                                  extraction and the one rebind helper (_as)
src/muntin/_registration_rules.mojo
                                  private registration rules (_kind, _rule, _check, _admits) and the route-literal
                                  grammar, evaluated at compile time; imports only the types it classifies
src/muntin/route_value.mojo       Param, FromRouteValue, RouteValues; private _NamedValue
src/muntin/state.mojo             State[S]; private _InjectedState
src/muntin/json.mojo              Json[T], FromJson, ToJson, JsonValue, JsonWriter; private parser and limits
src/muntin/_handler_storage.mojo  private _Erased, _Shared, _build_record: the only module with unsafe operations
src/muntin/testing.mojo           TestClient
adapters/flare/muntin_flare.mojo  Flare adapter (Server, Tls, MuntinHandler); flare environment only
adapters/flare/flare_internals.mojo  every non-public Flare name the adapter uses, with what it is relied on for
```

The public surface is the exported names and `muntin.testing.TestClient`. `_`-prefixed names are reachable on Mojo 1.1.0 (no private fields) but are not API.

### Backend seam

- The only seam is `App.handle`, in two overloads that answer alike: one borrows the request, one takes it (M3-064). A backend builds a Muntin `Request`, calls `handle` and converts the `Response` back. Middleware runs inside `handle`, so every backend runs it. There is no backend trait until a second network backend exists (A7).
- `Request` and `Response` own their data: `String` method, target parts and fields, and the body as `List[UInt8]`, its one representation (M3-040). No backend type or buffer lifetime reaches application code.
- What every network backend owes Muntin's semantics ([M3-070](history/architecture-decisions.md#backend-coupling-decision-m3-070)): one `App` is never called from two threads at once; the raw target is passed undecoded (a typed route's value is decoded once, by Muntin); body bytes pass unchanged both ways; and a `HEAD` answer goes out with no content and a `Content-Length` equal to the body `App.handle` returned, none for 1xx, 204, 205 and 304 ([M3-026](history/architecture-decisions.md#head-decision-m3-026)). `App.handle` never removes a `HEAD` body; `TestClient.head` returns it unchanged.
- Keeping an `App` on one thread is not in that contract: it is the Flare adapter's (below). A backend that calls an `App` from several threads in turn must order the calls, and `State` values must then be thread-safe, which Muntin cannot check.
- Handlers are synchronous for every backend, with no async handler kind ([M3-071](history/architecture-decisions.md#handler-execution-model-decision-m3-071)).

### Registration

- `App.get`, `post`, `put`, `patch` and `delete` have eight overloads each: one per request-slot arity (0 to 3), stateless and stateful (M3-015). `put` and `patch` take `post`'s shapes, `delete` `get`'s ([M3-020](history/architecture-decisions.md#http-methods-decision-m3-020)). The shapes table is in [routing](reference/routing.md#registering-a-route).
- A request slot is a generic `var A` whose kind is decided at compile time from its type alone (`_kind`): a route value (`Int`, `String`, their `Optional`s by exact type equality, a `FromRouteValue` by conformance, bare or in a `Param`), a `RouteValues` record, a body (`FromBody`, `FromBytes`, `WithHeaders[B]`), `Request`, `Headers`, or, rejected, a `State` or a type of no kind. Kinds are disjoint: a type that would have two conversions (both body traits, a route value that is also a body, a record that is also either) is a kind of its own that the rules reject, so `_kind`'s order never picks a conversion silently (M2-005, M3-041, M3-054, M3-061).
- The stateful family takes a fixed leading `State[S]` and the state as the registration's second argument, so argument count separates the families and no two overloads accept the same handler (M3-001). A second injected kind needs its own decision.
- One ordered rule function, `_rule`, holds every rule but the result's: `_get_rule` for `GET` and `DELETE`, `_post_rule` for the others, which hands a bodyless shape to `_get_rule` (M3-048). `_check` asserts each rule with Muntin's message; `_admits`, the same rules as one Bool, guards the adapter's instantiation so the rule's message is what the compiler reports (M3-015). A new shape within arity 3 is a slot kind or a rule, not an overload; existing messages stay byte-identical when rules are added.
- The result is accepted only through `where (R == String or R == StaticString or conforms_to(R, ToResponse))` on every overload.
- **Growth budget** ([M3-052](history/architecture-decisions.md#registration-complexity-budget-decision-m3-052)): eight overloads per method name is a maintenance ceiling. Mojo 1.1.0 prints at most ten candidate notes per method name, so slot arity 4 (ten overloads) is the last under that cap; raising the ceiling is a decision of its own, compared with a carrier slot kind. A route-value record is one slot whatever its field count (M3-061).
- **Route conflicts** ([M3-053](history/architecture-decisions.md#route-conflict-decision-m3-053)): every registration goes through `App._add`, which aborts when an earlier route of the same method overlaps the new one and is not more specific (`_conflict`, `_covers`). It is a run-time check because each call sees only its own literal. `_RouteIndex` finds placeholder-free conflicts by shape in a `Dict` and compares only earlier routes with a placeholder; `tests/test_route_conflicts.mojo` checks it against `_conflict`.
- Mojo 1.1.0 cannot reflect function parameter names, so binding is positional and a name is compared only where written in a type (`Param`, M3-050; a record's fields, M3-061).

### Request handling

- `App.use` appends a thin function value to `App._middleware`. With none, `handle` calls `_dispatch` on the borrowed request. Otherwise the borrowing `handle` copies the request once and the owning one moves it, then `_run(0)` calls each middleware with a `Next` holding a pointer to the borrowed `App`, inside a `try` whose `except` is the fixed 500 with a `Failure.MIDDLEWARE` report (M3-035).
- Routes are a list scanned in registration order; the first route whose method and path match handles the request and never falls through. Registration refuses conflicts, so that route is the most specific. When none matches, `_allowed` collects the methods of routes whose path matches: 405 with `Allow`, else 404 ([M3-030](history/architecture-decisions.md#method-not-allowed-decision-m3-030)).
- On a typed route the steps run in the order the [reference](reference/routing.md#order-of-checks) gives. Query values are found in one scan of the query (`_query_spans`), and each value is percent-decoded once (`_decode_value`) before conversion.
- Transport through the handler box: an adapter receives the route's decoded values, then the JSON verdict and the header fields where its route needs them, as `List[String]`, and the body bytes borrowed (`_Erased.invoke(args, bytes)`). The body never travels as a `String`. A state never travels in the arguments; it is bound with the handler.
- Copies per request: a raw route copies the body once (its rebuilt `Request`), a typed text body once (its UTF-8 read), a `FromBytes` body never (it is borrowed); a `WithHeaders` or `Headers` route copies each field twice; the borrowing `App.handle` copies the whole request once more when middleware is registered.
- Every fixed 500 `src/muntin` makes goes through `_failed`, which sets `Response._failure` (at most one report). Public `Response` initializers leave it empty, copies keep it, and no backend reads it ([M3-058](history/architecture-decisions.md#dropped-error-report-decision-m3-058)).
- Error opt-in (M2-013): a raised value converts only when the handler's declared error type declares `ToErrorResponse` in its own declaration; bare `raises` is never mapped by message.

### Storage and ownership

These are safety invariants; each storage module's docstring states its own in full.

- **Handler box `_Erased`:** each route owns one move-only `_Erased`, a `ThinAllocation` header holding the invoke trampoline, the drop function and the erased pointer to the handler value. One `__init__[F, call]` instantiates both functions for the same `F`, so the pointer is only restored as that `F` (`tests/test_handler_storage.mojo` counts live values). `App` is `Movable`, not `Copyable`.
- **Middleware:** thin function values, no erasure. A `Next`'s origin is the borrowed `App`'s, so it cannot outlive that borrow, and it is made in `_run`'s frame, so moving the `App` between requests leaves nothing pointing at its old place.
- **State:** `State[S]` holds a sealed `_Shared[S]` (an atomic count and an `OwnedPointer[S]`). `state[]` is read-only through every handle and a reference from it is interior to its handle. Each registration copies the handle once; requests borrow it.
- **The State guarantee (M3-004), verbatim:** **Muntin must not introduce a Muntin-specific safe-code path that lets one `State` alias replace, mutate, swap, or prematurely destroy the shared payload observed through another alias. Toolchain-wide primitives that can violate the same property for standard-library types and existing Muntin storage (origin rebind, forged allocation or header replacement, `memmove`, stdlib-private fields) are outside this guarantee and are pinned as Mojo 1.1.0 toolchain-wide soundness gaps.** The pins are `tests/toolchain_soundness_gaps` (must build).
- **No erased value borrows** ([M3-065](history/architecture-decisions.md#request-context-storage-decision-m3-065), [M3-074](history/architecture-decisions.md#state-borrowing-decision-m3-074)): erasing a value's type drops its origins. So a request context value is never erased, and `State.__init__` refuses at compile time an `S` whose reflected name shows `{}` (an origin or a parameter pack). `AnyOrigin` behind a trait's associated type escapes the check (`tests/state_known_gaps/state_any_origin_associated_type.mojo`). Any later erased value follows the same rule.
- **The one rebind** (M3-015): `rebind_var` checks layout, not type, so it is called only in `_as[T, A]` in `app.mojo`, right after `comptime assert A == T`.
- **Route-value record construction** (M3-062): `_build_record` writes each field of a `MaybeUninit[T]` at its reflected offset, in field order; when a conversion raises, the fields already written are destroyed once and the storage is forgotten without `T`'s destructor. The record's `__init__` never runs. `tests/test_route_records.mojo` counts each field's conversions and destructions.
- **Unsafe confinement:** `scripts/check_unsafe.sh` fails if any `src/muntin` module but `_handler_storage.mojo` names an unsafe operation or the boxes' fields, imports anything but `_Erased`, `_Shared` and `_build_record` from it, or if `src/muntin` holds any `rebind_var` but the one in `_as`. It is a confinement guard, not a safety proof. The runtime check on the paths tests run is `SANITIZE=address ./scripts/test.sh` ([DEVELOPMENT](DEVELOPMENT.md#3-verify-with-the-strongest-available-oracle)).

### JSON

`Json[T]` conforms to `FromBody` when `T: FromJson` and to `ToResponse` when `T: ToJson`, so JSON adds no handler shape. The codec is Muntin's own (RFC 8259, strict, with Muntin's limits); `JsonValue` is a read-only position in a compact tape held in `_Shared`. A JSON parse holds at most about 29 MB at the 1 MiB cap, once per `App` at a time. Fields are mapped by hand: Mojo 1.1.0 reflection has no constructor ([M3-008](history/architecture-decisions.md#json-codec-decision-m3-008)).

### Flare adapter

The adapter module's docstring (`adapters/flare/muntin_flare.mojo`) states its conversion and serving policy; `flare_internals.mojo` lists every Flare internal it relies on. The user-visible contract is [serving](reference/serving.md).

- `_serve_app(app, request)` converts a Flare request, moves it into the owning `App.handle`, converts the response back and applies the `HEAD` rule at every exit, its own 400, 431 and 500 included. It never routes. `MuntinHandler` owns an `App` (tests and probes); `_BorrowedHandler`, which `Server` uses, borrows one and is not `Copyable`.
- Before the conversion: a request without `Host` is 400 (M3-073), then one with more fields than `max_header_fields` is 431 (M3-067). The conversion copies the method and target as strict UTF-8 without slicing them (M3-039), the body bytes unchecked (M3-040), and rebuilds the fields from Flare's public `HeaderMap.encode_to`, verified against `get_all` (fields × distinct names comparisons inside Flare, bounded by the field limit). Anything it cannot represent is 400 before `App.handle`.
- On the way out, the body is moved, not copied; connection-specific fields are dropped; each field is re-checked and a failure is 500.
- `Server` holds Flare's `HttpServer` and the field limit; `Server.bind` is its one spelling. `serve(app)` runs Flare's single-worker `serve` on the calling thread. `serve[make]` (M3-049) starts one thread per worker, each building its own `App` with `make` and running Flare's per-worker reactor loop on a close-on-exec copy of the listener; Flare's own multi-worker `serve` is not used, since its handler is copied before the workers start. So one `App` and its `State` values stay on one thread for the `App`'s life.
- The stop (M3-045): `_StopWatch` claims the process's one serving cell, installs a do-nothing handler with `SA_RESETHAND` on SIGTERM and SIGINT, and a watcher thread that sees a delivered signal as the disposition back at `SIG_DFL`. It then drains (Flare's `drain`, or `_drain_workers`, which parks every worker's listener copy on a pipe and closes the listener), waits the grace window, and ends the process with `_exit(128 + signal)` if the reactors have not returned `_REACTOR_STOP_MS` later. Nothing runs in signal context.
- TLS (M3-051) is Flare's `bind_tls` with the same configuration; `_check_tls_files` is a best-effort start-up diagnosis, and OpenSSL's load decides.
- Reliances with no test that fails when they stop holding ([M3-070](history/architecture-decisions.md#backend-coupling-decision-m3-070)): Flare's accept loop leaving on `ENOTSOCK` once its listener copy is parked (if not, one worker's connections go unserved through the window and the stop ends the process instead of returning); and one OpenSSL `SSL_CTX` used by every worker at once (if Flare modified it after `bind_tls`, concurrent handshakes could race; one worker avoids it).

### Mojo 1.1.0 facts the design rests on

- A function type is a trait, so stored handlers are thin function values; closures do not convert (`tests/spike_fail`).
- Parametric raises (`thin raises E`) infer the error type; an explicitly typed non-raising value spelled without `raises`, or with a borrowed parameter, converts to no generic slot (`storage_fail/typed_thin_value_handler.mojo`, `registration_fail/typed_value_to_owned_slot.mojo`).
- `rebind_var` checks layout, not the nominal type; generic `==` ignores origin identity, and `Origin.equals` works only in `where` clauses, which is why the result rule is one.
- Reflection exposes struct fields but not function parameter names or constructors.
- Module-level variables do not compile and thin handlers cannot capture: `State` is the only way a handler reads runtime data, and `serve[make]`'s workers share nothing.
- There are no private fields and no existentials; `__extension` is undocumented and never part of the contract.
- `ArcPointer.__getitem__` is mutable through any handle, which is why `State` uses `_Shared` (`tests/state_storage_known_gaps`).
- A trait may require a `comptime` member (`FromBytes.max_bytes`); under a refining trait's default a misspelled member is accepted silently (`tests/bytes_limit_known_gaps`).
- The runtime installs its own handler for SIGINT and SIGTERM in every binary and replaces an inherited ignore before `main`; a binary has runtime threads before `main`, none blocking any signal, so `Server.serve` relies on a handler, not a mask.

### Current limits

What Muntin does not do yet is `SPEC.md`, "Remaining candidates", and each item's decision record. Limits of the current code that are easy to miss:

- Bodies are whole `List[UInt8]` values: nothing is streamed and a request body is held in full (bounded by the `Server`'s `max_body_bytes` as Flare receives it). Multipart is not parsed.
- Route values are `Int`, `String`, their `Optional`s and application `FromRouteValue` types, bare or in a `Param`; two bare values, or any number in one `RouteValues` record. Not supported: an `Optional` of a `FromRouteValue` type, standard types such as `Bool` or `Float64`, a default written in the literal, an empty value distinct from an absent one, several values for one key, decoded query keys.
- Only `GET` (and `HEAD` through it), `POST`, `PUT`, `PATCH` and `DELETE` select routes; `OPTIONS` and others get 405 or 404, never 501 ([M3-030](history/architecture-decisions.md#method-not-allowed-decision-m3-030)).
- Middleware is functions with compile-time configuration only; there is no request-scoped context.
- Over HTTP/1.1, Flare v0.12.0 answers a method with any lowercase letter (`get`, `Get`) 400 before `App.handle`, and rejects target bytes outside `!`..`~`, so a static segment such as `/hello world` compiles and matches in memory but never arrives over HTTP/1.1.
- Over HTTP/1.1, Flare v0.12.0 frames every 304 with a `Content-Length`: a declared one, or else the body's length, so 0 only for an empty body. For `HEAD` the adapter removes the body and declares no length for a 304, so a `HEAD` 304 goes out with `Content-Length: 0`, which the adapter cannot remove, and a `HEAD` 205 too; over h2c neither carries a `content-length` ([M3-026](history/architecture-decisions.md#head-decision-m3-026), measured by `compat/flare/head/head_probe.mojo`).
- The adapter checks that `Host` is present, not its value.
- The adapter copies the request body once out of Flare's request (Flare's `Handler.serve` lends its request read-only). Measurements of what the adapter adds are in pull requests #114, #125 and #136.
- `main.mojo` uses `TestClient` because the default environment has no Flare; serving needs the `flare` environment.
- The loopback and `Server` tests need `fork(2)`; Windows is out of scope. Their first request can be slow on a cold start (up to about a minute on macOS CI).
- `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19. If the `flare` job breaks after that, compare `ImageOS`/`ImageVersion` in the `runner image` step before blaming Muntin or Flare; delete this line once a `flare` job has passed on Ubuntu 26.

## Revisit index

If one of these pins changes (a pinned fixture unexpectedly compiles, fails to compile or changes its expected diagnostic, or a pinned test's observation changes), reopen the linked decision rather than patching the test. The table maps pins to records (or, for a deferral without a record, its pull request); what each pin means is the record's "Revisit when" list and the fixture's opening comment.

| Pinned by | Record |
|---|---|
| `tests/spike_fail` | [M2 handler storage](history/architecture-decisions.md#handler-storage-decision-m2), [M2-016](history/architecture-decisions.md#m2-closure-m2-016) |
| `tests/extraction_fail`; `tests/spike_fail/extension_int.mojo` | [M2-005](history/architecture-decisions.md#argument-extraction-decision-m2-005) |
| `tests/response_fail` | [M2-007](history/architecture-decisions.md#typed-response-decision-m2-007) |
| `tests/error_fail`; `storage_fail/typed_thin_value_handler.mojo` | [M2-010](history/architecture-decisions.md#application-error-decision-m2-010) |
| `tests/error_response_fail` | [M2-012](history/architecture-decisions.md#error-response-decision-m2-012) |
| `tests/raw_fail` | [M2-014](history/architecture-decisions.md#raw-request-decision-m2-014), [M2-016](history/architecture-decisions.md#m2-closure-m2-016) |
| `tests/route_conflict_abort`; `tests/test_route_conflicts.mojo` | [M3-053](history/architecture-decisions.md#route-conflict-decision-m3-053) |
| `tests/middleware_fail`, `tests/middleware_api_fail` | [M3-034](history/architecture-decisions.md#middleware-decision-m3-034) |
| `tests/state_fail`; `tests/state_known_gaps/registrar_blind_mutation.mojo` (must build) | [M3-001](history/architecture-decisions.md#application-state-decision-m3-001) |
| `tests/state_storage_fail`; `tests/state_storage_known_gaps` and `tests/toolchain_soundness_gaps` (must build) | [M3-004](history/architecture-decisions.md#state-storage-decision-m3-004) |
| `tests/headers_fail`; `tests/headers_known_gaps` (must build); `compat/flare/headers/flare_header_probe.mojo` | [M3-002](history/architecture-decisions.md#headers-decision-m3-002); its "HTTP/1.1 request without Host accepted" case: [M3-073](history/architecture-decisions.md#request-host-decision-m3-073) |
| `test_every_request_field_reaches_the_handler_over_http1_and_h2c` in `adapters/flare/test_localhost_roundtrip.mojo` | [M3-066](history/architecture-decisions.md#request-header-conversion-decision-m3-066) |
| `tests/json_fail`; `tests/json_known_gaps` (must build); `test_number_limits_on_mojo_1_1_0` and `test_float_rounding_gaps_on_mojo_1_1_0` in `tests/test_json.mojo` | [M3-008](history/architecture-decisions.md#json-codec-decision-m3-008) |
| `tests/json_api_fail/positional_status.mojo` | [M3-028](history/architecture-decisions.md#json-response-status-decision-m3-028) |
| a `get`, `post`, `put`, `patch` or `delete` overload beyond the eight arity overloads | [M3-052](history/architecture-decisions.md#registration-complexity-budget-decision-m3-052), [M3-022](history/architecture-decisions.md#several-route-values-decision-m3-022), [M3-020](history/architecture-decisions.md#http-methods-decision-m3-020), [M3-014](history/architecture-decisions.md#registration-structure-decision-m3-014), [M3-007](history/architecture-decisions.md#stateful-raw-handlers-in-production-m3-007), [M3-012](history/architecture-decisions.md#typed-header-access-decision-m3-012) |
| a concurrent `App.handle`, an `App` called from several threads in turn, or a `Copyable` `App` | [M3-001](history/architecture-decisions.md#application-state-decision-m3-001), [M3-008](history/architecture-decisions.md#json-codec-decision-m3-008) |
| `tests/testclient_headers_api_fail`; `tests/headers_api_fail/request_headers_moved_in.mojo` | [M3-010](history/architecture-decisions.md#testclient-request-headers-decision-m3-010), [M3-011](history/architecture-decisions.md#testclient-request-headers-in-production-m3-011) |
| `tests/header_access_fail` | [M3-012](history/architecture-decisions.md#typed-header-access-decision-m3-012) |
| `tests/with_headers_api_fail` | [M3-012](history/architecture-decisions.md#typed-header-access-decision-m3-012), [M3-013](history/architecture-decisions.md#typed-header-access-in-production-m3-013) |
| another injected kind proposed | [M3-001](history/architecture-decisions.md#application-state-decision-m3-001), [M3-012](history/architecture-decisions.md#typed-header-access-decision-m3-012), [M3-014](history/architecture-decisions.md#registration-structure-decision-m3-014) |
| `tests/registration_fail`; `tests/registration_known_gaps` (must build); `header_access_fail/generic_slot_does_not_refine.mojo` or `state_fail/variadic_handler_type.mojo` compiles; `state_known_gaps/registrar_blind_mutation.mojo` stops building | [M3-014](history/architecture-decisions.md#registration-structure-decision-m3-014) |
| `tests/registration_api_fail` | [M3-015](history/architecture-decisions.md#registration-on-generic-arity-slots-in-production-m3-015), [M3-014](history/architecture-decisions.md#registration-structure-decision-m3-014) |
| a toolchain change that lets an overload see how a caller spelled a type; a new slot kind (generic forwarding reaches it too) | [M3-015 amendment](history/architecture-decisions.md#registration-structure-amendment-generic-forwarding-m3-015), [M3-024](history/architecture-decisions.md#optional-query-values-decision-m3-024) |
| `tests/string_route_api_fail` | [M3-018](history/architecture-decisions.md#route-value-decoding-and-string-route-values-decision-m3-018) |
| `tests/get_headers_api_fail` | [M3-016](history/architecture-decisions.md#typed-get-header-access-decision-m3-016) |
| `tests/methods_api_fail` | [M3-020](history/architecture-decisions.md#http-methods-decision-m3-020), [M3-026](history/architecture-decisions.md#head-decision-m3-026), [M3-036](history/architecture-decisions.md#testclient-head-decision-m3-036), [M3-030](history/architecture-decisions.md#method-not-allowed-decision-m3-030) |
| `tests/bodyless_api_fail` | [M3-048](history/architecture-decisions.md#bodyless-typed-post-put-and-patch-handlers-decision-m3-048) |
| `tests/route_values_api_fail`; `registration_api_fail/immutable_origin_result_*_3.mojo` | [M3-022](history/architecture-decisions.md#several-route-values-decision-m3-022) |
| `tests/named_values_api_fail`; `test_variable_names_are_not_compared` in `tests/test_named_values.mojo` | [M3-050](history/architecture-decisions.md#named-route-values-decision-m3-050) |
| `tests/optional_values_api_fail` | [M3-024](history/architecture-decisions.md#optional-query-values-decision-m3-024) |
| `tests/app_values_api_fail` | [M3-054](history/architecture-decisions.md#application-route-value-types-decision-m3-054) |
| `tests/route_records_api_fail`; `test_init_is_never_called` in `tests/test_route_records.mojo` | [M3-061](history/architecture-decisions.md#route-value-records-decision-m3-061) |
| `compat/flare/head/head_probe.mojo` | [M3-026](history/architecture-decisions.md#head-decision-m3-026), [M3-036](history/architecture-decisions.md#testclient-head-decision-m3-036) |
| `tests/test_method_not_allowed.mojo` and the 405 cases in `adapters/flare/test_muntin_flare.mojo` and `adapters/flare/test_localhost_roundtrip.mojo` | [M3-030](history/architecture-decisions.md#method-not-allowed-decision-m3-030) |
| `compat/flare/serve/workers_need_copyable.mojo` or `server_handler_not_copyable.mojo`; `server_positional_init.mojo` or `server_keyword_init.mojo`; `adapters/flare/test_server.mojo` | [M3-032](history/architecture-decisions.md#serving-entrypoint-decision-m3-032) |
| the method and target cases in `adapters/flare/test_muntin_flare.mojo` and `adapters/flare/test_localhost_roundtrip.mojo` | [M3-039](history/architecture-decisions.md#request-target-and-method-bytes-decision-m3-039) |
| `compat/flare/body/body_probe.mojo`; the body cases in `adapters/flare/test_muntin_flare.mojo` and `adapters/flare/test_localhost_roundtrip.mojo`; `tests/test_binary_body.mojo`; `tests/body_bytes_api_fail`; the re-pinned `tests/state_fail/closure_handler_storage.mojo` and the `TestClient` positional-`Headers` fixtures of `tests/testclient_headers_api_fail` and `tests/methods_api_fail` | [M3-038](history/architecture-decisions.md#request-body-bytes-decision-m3-038), [M3-040](history/architecture-decisions.md#binary-request-and-response-bodies-decision-m3-040) |
| `tests/test_bytes_body.mojo` and the `FromBytes` routes in `adapters/flare/test_localhost_roundtrip.mojo`; `tests/from_bytes_api_fail` | [M3-041](history/architecture-decisions.md#typed-binary-request-bodies-decision-m3-041) |
| `tests/test_bytes_headers_body.mojo` and the `WithHeaders[Payload]` route in `adapters/flare/test_localhost_roundtrip.mojo`; `tests/bytes_headers_api_fail`; `tests/with_headers_api_fail`'s three bound texts | [M3-042](history/architecture-decisions.md#typed-binary-request-bodies-with-header-fields-decision-m3-042) |
| `tests/test_bytes_limit.mojo` and the `Limited` routes in `adapters/flare/test_localhost_roundtrip.mojo`; `tests/bytes_limit_api_fail`; `tests/bytes_limit_known_gaps` (must build) | [M3-043](history/architecture-decisions.md#typed-binary-request-body-size-limits-decision-m3-043) |
| `adapters/flare/test_server.mojo`'s body limit cases and the `receive_app` cases in `adapters/flare/test_localhost_roundtrip.mojo`; `compat/flare/serve/server_bind_positional_limit.mojo`; the buffer-ring pin in `test_receive_limit_on_flare_bufring_path` | [M3-044](history/architecture-decisions.md#server-receive-body-limit-decision-m3-044) |
| `registration_fail/generic_handler_cannot_forward.mojo`, `registration_fail/method_alias_drops_self.mojo`; `state_fail/variadic_handler_type.mojo` and `header_access_fail/eleven_candidates_drop_a_note.mojo` for the budget | [M3-052](history/architecture-decisions.md#registration-complexity-budget-decision-m3-052) |
| `adapters/flare/test_server.mojo`'s head-of-line blocking tests | [M3-046](history/architecture-decisions.md#head-of-line-blocking-decision-m3-046) |
| `compat/flare/serve/serve_workers_capturing_make.mojo` or `serve_workers_runtime_closure.mojo`; `adapters/flare/flare_internals.mojo`; `adapters/flare/test_server.mojo`'s workers tests | [M3-049](history/architecture-decisions.md#multi-worker-serving-decision-m3-049) |
| `adapters/flare/test_server.mojo`'s idle timeout tests | [M3-047](history/architecture-decisions.md#server-idle-timeout-decision-m3-047) |
| `adapters/flare/test_tls.mojo` | [M3-051](history/architecture-decisions.md#server-tls-decision-m3-051) |
| `adapters/flare/test_tls.mojo`'s workers tests; `tls_context_addr` and `run_worker_loop` in `adapters/flare/flare_internals.mojo` | [M3-060](history/architecture-decisions.md#tls-with-workers-decision-m3-060) |
| `adapters/flare/test_server.mojo`'s stop tests | [M3-045](history/architecture-decisions.md#graceful-shutdown-decision-m3-045) |
| `compat/flare/stream/stream_probe.mojo` | [M3-056](history/architecture-decisions.md#streaming-responses-and-cancellation-decision-m3-056) |
| `tests/context_known_gaps/reflected_names_collide.mojo` (must build) | [M3-063](history/architecture-decisions.md#request-context-decision-m3-063) |
| `tests/context_known_gaps/erasure_drops_origin.mojo` (must build; `scripts/run_origin_gaps.sh` runs it under AddressSanitizer); `tests/context_fail` | [M3-065](history/architecture-decisions.md#request-context-storage-decision-m3-065) |
| `tests/state_fail/state_origin_*.mojo`, `state_pack_tuple.mojo` and `state_function_parameter_*.mojo`; `tests/test_state.mojo`'s owned-state, wrapper and function-parameter tests; `tests/state_known_gaps/state_any_origin_associated_type.mojo` (must build; `scripts/run_origin_gaps.sh` runs it under AddressSanitizer) | [M3-074](history/architecture-decisions.md#state-borrowing-decision-m3-074) |

## Request/Response ownership

`Request` and `Response` own their data. Do not optimize around zero-copy wire buffers if that leaks backend lifetimes into the public API; before changing the ownership model, measure the cost and record the requirement that justifies more lifetime complexity.

## Flare policy

Flare provides a substantial Mojo networking stack with its own routing and handlers; Muntin must not re-export those application abstractions.

- Allowed inside the adapter: Flare's server and bootstrap APIs, conversion between Flare and Muntin requests and responses, transport lifecycle integration, backend-specific optimizations hidden behind the adapter.
- Not allowed in Muntin's public API: Flare's `Request`/`Response`, `Router`, middleware types, extractors, or reactor, cancellation and runtime types.
- The Flare version is pinned; track Flare's `main` only for compatibility investigation.
- Three layers ([M3-070](history/architecture-decisions.md#backend-coupling-decision-m3-070)): `App.handle` and everything behind it is backend-independent; what every network backend owes it ([Backend seam](#backend-seam)) is Muntin's contract; serving (`Server`, its settings, threads, workers and stop) is the Flare adapter's, and its contract is in large part Flare v0.12.0's behavior. The first two are designed to carry over to another backend, not demonstrated.

A change that makes the adapter's code (not its tests) rely on something no public contract states, either a Flare name that is not public, or a behavior of Flare's, of a library it loads (OpenSSL) or of the operating system's that its documentation at the pin does not state (a format, an order, a timing, a side effect, a silent fallback; the request and response conversion included):

- names it where the code relies on it: a Flare name in `flare_internals.mojo` with what it is relied on for, a behavior in a "Relied on" statement beside the code (or in `flare_internals.mojo`'s docstring, with a pointer at the code);
- has a test that fails when it stops holding, on each platform that relies on it, and says whether it observes the condition or only an outcome, and which break it would miss. Where no test can, the statement says what a break would do and what detects or contains it, and the record names the risk left, which the owner accepts by merging;
- has a record that counts the reliance among the candidate's costs, says why Flare's public API and a proposal to Flare's maintainers were not taken instead, and states the adapter's size before and after: the entries in `scripts/check_flare_reliance.sh`'s lists and the lines of the adapter's modules (every `.mojo` file under `adapters/flare` but its `test_*.mojo` tests; 2,111 at M3-070).

Removing a reliance needs none of this. Replacing a non-public name with a public one whose undocumented behavior is then relied on needs all three, the third possibly its pull request. A change that takes the adapter's modules past 2,500 lines together waits for a decision that weighs the growth against a public entry point proposed to Flare and a narrower `Server`.

`scripts/check_flare_reliance.sh` (run by `check.sh`) is the mechanical part, a ratchet on names: it fails when a module other than `flare_internals.mojo` imports a `_`-prefixed Flare module or name, when `flare_internals.mojo`'s Flare imports or `_`-prefixed members and keywords differ from the script's lists, when a module imports a `test_*` module, when the modules pass 2,500 lines, or when it cannot read a module. Its header says what it reads; `scripts/test_check_flare_reliance.sh` pins that. A behavior has no name, so review applies the rest.

## Adapter translation policy

An adapter may contain inelegant conversion code if that keeps the public model stable; do not contort Muntin's API to make one adapter thin. If an adapter repeatedly copies large bodies or cannot express a common feature without severe cost, treat that as evidence for a focused core change, measured first.

## Architecture tests

Tests establish that an application route is dispatched through Muntin's app model; that the in-memory backend drives it without Flare or sockets; that core modules do not import Flare; that a real localhost request traverses Flare, the adapter, Muntin and back; and that the same handler runs on both paths unchanged.

## Architecture decision threshold

Record a decision before exposing any third-party type publicly; introducing a custom runtime, executor or task model; making a transport mandatory; adding unsafe memory or lifetime machinery to a public contract; changing request/response ownership semantics; changing the backend seam in a way that breaks adapters; making the Flare adapter rely on something no public contract states ([Flare policy](#flare-policy)); or freezing an API example as a compatibility promise.
