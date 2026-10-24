# Muntin architecture

Muntin owns the application model. Transports adapt to `App.handle(Request) -> Response`; they do not define application semantics.

This file is how Muntin works now: its invariants, its structure and the [revisit index](#revisit-index). What an application sees is the [guide](GUIDE.md) and the [reference](reference/routing.md); why each part is as it is, the [decision records](history/architecture-decisions.md); scope, [`SPEC.md`](SPEC.md). Milestone tags such as (M3-015) name the item that built a part.

## Architectural thesis

Muntin's leverage should come from application-level developer experience and compile-time and type-system guarantees. Networking is replaceable infrastructure behind `App.handle`; where that ends is the [Flare policy](#flare-policy).

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

- **A1. Muntin owns the public application API.** Application code imports Muntin concepts. Third-party transport types never appear in normal handler signatures, routing, middleware contracts, application-state contracts or canonical examples.
- **A2. Dependency direction points inward.** `src/muntin` does not import Flare; adapters depend on Muntin. Never invert this for an adapter's convenience (`scripts/check_boundaries.sh`).
- **A3. Replaceability is executable.** The in-memory path exercises the same dispatch as transport adapters. A refactor that lets it bypass real routing is a regression even if tests stay green.
- **A4. The backend seam stays narrow.** Do not invent a universal networking abstraction. The seam should expose only what Muntin needs to accept an application request, dispatch it and produce an application response or lifecycle result. Do not pre-abstract executor, reactor, poller, wakeup, TLS session, QUIC stream, socket option or backend-specific cancellation machinery into public contracts.
- **A5. Protocol mechanics stay outside core.** Wire parsing, sockets, TLS, HTTP/2 flow control, HTTP/3, QUIC, platform event loops, connection pools and protocol negotiation belong to networking backends.
- **A6. Async evolution must remain survivable.** Do not publish a framework-specific executor, future or task model just to fill a temporary language or runtime gap. The application model should be able to adopt future Mojo async and runtime primitives with minimal application-level breakage.
- **A7. Evidence before abstraction.** Add an abstraction when a current requirement, two real implementations or a strong external constraint justifies it; a hypothetical future backend is not enough. The in-memory backend exists to prove the seam and provide deterministic tests, not to force every networking feature into a lowest-common-denominator interface.
- **A8. DX is an architectural input.** The guide and reference are not decoration after implementation: public API examples constrain internal design. If internal convenience would make ordinary application code materially more verbose, reconsider the internal abstraction first. If the desired API is impossible in the current Mojo toolchain, preserve the intended semantic property and document the proven language limitation. The design rules this invariant carries:
  - Decision rule: when choosing between competing designs, prefer the one that makes application code such as `def get_user(id: Int) -> User` with `app.get["/users/{id}"](get_user)` simpler, without sacrificing correctness, type safety, explicit escape hatches, transport independence or maintainable implementation boundaries.
  - Boilerplate: adding an ordinary route should not require application authors to define a handler adapter, implement a backend trait, manually register serializers, construct a context object or touch the networking transport. Ordinary handlers avoid framework-internal memory plumbing (allocators, connection contexts, backend lifecycle objects); low-level APIs may expose more control when an endpoint genuinely needs it.
  - Compile time: prefer compile-time work when it materially improves correctness, runtime cost or diagnostics, not merely because Mojo supports it. Compile-time machinery must earn its complexity through simpler application code, earlier diagnostics or measurable runtime savings.
  - Diagnostics are part of the API: a framework diagnostic should state what is wrong, where it is wrong, what Muntin expected and the likely fix, rather than an opaque generic type mismatch when Muntin can provide context.
  - Public API: treat every public abstraction as expensive. Before exposing one, ask whether it is genuinely necessary for application developers, whether it can remain internal, whether Mojo already provides the right idiom, whether it leaks a backend detail and whether users would reasonably depend on it for years. Prefer a small composable API over many convenience types.
  - Avoid hidden global state. Application code should not need to understand Flare or any other networking backend.

## Current architecture

Toolchain: Mojo 1.1.0 (8189361e) via pixi, pinned by `pixi.lock`; `scripts/check.sh` fails on any other Mojo version, so an upgrade is a deliberate change to the script and the docs. Flare v0.12.0 (`8c6e1400`) exists only in the `flare` pixi environment.

### Modules and public surface

```text
src/muntin/__init__.mojo          exports App, Group, Middleware, Next, FromBody, FromBytes, Failure, Headers, Rejection, Request, Response,
                                  ToErrorResponse, ToResponse, FromJson, Json, JsonFields, JsonValue, JsonWriter, ToJson,
                                  FromRouteValue, Param, RouteValues, State, WithHeaders
src/muntin/http.mojo              Request, Response, Failure, Rejection, Headers, ToResponse, ToErrorResponse; private _failed,
                                  _rejected_by
src/muntin/body.mojo              FromBody, FromBytes; private _FromBodyOrBytes (their shared parent) and _body_text
src/muntin/headers_body.mojo      WithHeaders[B]; private _HeaderCarrier and _convert_body (a body's conversion, bare or carried)
src/muntin/app.mojo               App and Group (one generic _App: the five methods' overloads, use, mount), Next,
                                  Middleware; private _Core (route table, handle, middleware chain _run, dispatch
                                  _dispatch), the adapters, guarded ones included, matching (_match), slot
                                  extraction
src/muntin/_registration_rules.mojo
                                  private registration rules (_kind, _rule, _check, _admits), evaluated at compile
                                  time, and the route-literal grammar, which route construction also uses at
                                  registration and _match per request (_is_param); imports the Muntin types its
                                  rules name (Response for the raw rule's result among them) and std.reflection,
                                  which reads a route-value record's fields; reads Json's refusals
src/muntin/route_value.mojo       Param, FromRouteValue, RouteValues; private _NamedValue
src/muntin/state.mojo             State[S]; private _InjectedState
src/muntin/json.mojo              Json[T], FromJson, ToJson, JsonFields, JsonValue, JsonWriter; private parser, limits
                                  and derived codec
src/muntin/_handler_storage.mojo  private _Erased, _Shared, _build_record: the only module with unsafe operations
src/muntin/_field_built.mojo      private _FieldBuilt, what _build_record may build
src/muntin/_rebind.mojo           private _as and _view: the only rebinds
src/muntin/testing.mojo           TestClient
adapters/flare/muntin_flare.mojo  Flare adapter (Server, Tls, MuntinHandler); flare environment only
adapters/flare/flare_internals.mojo  every non-public Flare name the adapter uses, with what it is relied on for
```

The public surface is the exported names and `muntin.testing.TestClient`. `_`-prefixed names are reachable on Mojo 1.1.0 (no private fields) but are not API.

### Backend seam

- The only seam is `App.handle`, in two overloads that answer alike: one borrows the request, one takes it (M3-064). A backend builds a Muntin `Request`, calls `handle` and converts the `Response` back. Middleware runs inside `handle`, so every backend runs it. There is no backend trait until a second network backend exists (A7).
- `Request` and `Response` own their data: `String` method, target parts and fields, and the body as `List[UInt8]`, its one representation (M3-040). No backend type or buffer lifetime reaches application code.
- What every network backend owes Muntin's semantics ([M3-070](history/decisions/m3-070-backend-coupling-decision.md)): one `App` is never called from two threads at once; the raw target is passed undecoded (a typed route's value is decoded once, by Muntin); body bytes pass unchanged both ways; and a `HEAD` answer goes out with the response's status and fields, no content, and a `Content-Length` equal to the byte length of the body it would have sent for the `GET` (`App.handle`'s, or its own answer where it answers without `App.handle`), none for a status that never carries content (1xx, 204, 205, 304) ([M3-026](history/decisions/m3-026-head-decision.md)). `App.handle` never removes a `HEAD` body; `TestClient.head`, an in-memory caller with no wire, returns it unchanged.
- Keeping an `App` on one thread is not in that contract: it is the Flare adapter's (below). A backend that calls an `App` from several threads in turn must order the calls (each returns before the next starts, and happens before it), and the application's `State` values must then be safe to use on another thread, with interior mutability synchronized as that needs; Muntin checks neither.
- Handlers are synchronous for every backend, with no async handler kind ([M3-071](history/decisions/m3-071-handler-execution-model-decision.md)).

### Registration surface

- `App.get`, `post`, `put`, `patch` and `delete` have eight overloads each: one per request-slot arity (0 to 3), stateless and stateful (M3-015). `put` and `patch` take `post`'s shapes, `delete` `get`'s ([M3-020](history/decisions/m3-020-http-methods-decision.md)). The shapes table is in [routing](reference/routing.md#registering-a-route).
- A request slot is a generic `var A` whose kind is decided at compile time from its type alone (`_kind`): a route value (`Int`, `String`, their `Optional`s by exact type equality, a `FromRouteValue` by conformance, bare or in a `Param`), a `RouteValues` record, a body (`FromBody`, `FromBytes`, `WithHeaders[B]`), `Request` (the raw handler), `Headers` (on `get` and `delete`, and on a bodyless `post`, `put` or `patch` handler), or, rejected, a `State` or a type of no kind. Kinds are disjoint: a type that would have two conversions (both body traits, a route value that is also a body, a record that is also either) is a kind of its own that the rules reject, so `_kind`'s order never picks a conversion silently (M2-005, M3-041, M3-054, M3-061).
- The stateful family takes a fixed leading `State[S]` and the state as the registration's second argument, so argument count separates the families and no two overloads accept the same handler (M3-001). A second injected kind needs its own decision.
- One ordered rule function, `_rule`, holds every rule but the result's: `_get_rule` for `GET` and `DELETE`, `_post_rule` for the others, which hands a bodyless shape to `_get_rule` (M3-048). `_check` asserts each rule with Muntin's message; `_admits`, the same rules as one Bool, guards the adapter's instantiation so the rule's message is what the compiler reports (M3-015); if the Bool ever rejects a shape the asserts accept, the guard's `else` aborts at registration instead of leaving the route unregistered. A new shape within arity 3 is a slot kind, or a rule in `_get_rule` or `_post_rule` with its message in `_check`, not an overload. A new rule keeps the existing messages unless its decision says otherwise. Because `_post_rule` hands every bodyless shape to `_get_rule`, a new slot kind also says whether it is bodyless, and a change to `get`'s rules or messages changes bodyless `post`, `put` and `patch` handlers too.
- The result is accepted only through `where (R == String or R == StaticString or conforms_to(R, ToResponse))` on every overload.
- **Growth budget** ([M3-052](history/decisions/m3-052-registration-complexity-budget-decision.md)): eight overloads per method name, in the two families, is a maintenance ceiling chosen by M3-052, not a compiler boundary. Mojo 1.1.0 prints at most ten notes per diagnostic, per method name, sub-notes included: at eight overloads a stateful call at slot arity 2 or 3 whose result the `where` clause rejects already drops a trailing sub-note, and slot arity 4 (ten overloads), the last arity under the cap, drops a candidate note for a rejected result; slot arity 5 is past it. A new request part is a slot kind or a rule when it can be one. Raising the ceiling (slot arity 4, a third family) is a decision of its own, taken for a concrete shape and comparing the overloads with a carrier slot kind that holds several parts; a method name beyond the five starts from a copy of the `get` or `post` set, and any rule of its own is decided with it. No check counts the overloads; review enforces the ceiling. A route-value record is one slot whatever its field count (M3-061); arity 3 still caps the slots.
- **Route conflicts** ([M3-053](history/decisions/m3-053-route-conflict-decision.md)): every registration goes through `App._add`, which aborts when an earlier route of the same method overlaps the new one and is not more specific (`_conflict`, `_covers`). It is a run-time check because each call sees only its own literal. `_RouteIndex` finds placeholder-free conflicts by shape in a `Dict` and compares only earlier routes with a placeholder; `tests/test_route_conflicts.mojo` checks it against `_conflict`.
- **Groups** ([M3-080](history/decisions/m3-080-guarded-routes-and-request-context-decision.md)): `App` is the guardless instantiation of the generic `_App[GS, GE, Ctx]` and `Group` the guarded ones, so the forty overloads serve both and `App` stays one concrete type; the routes, middleware and dispatch sit in the non-generic `_Core`, which `Next` points to. Each overload's guarded branch is one `_guarded_*` helper per arity and family: it sets a leading context slot aside and applies the rules to the slots after it, so the context is no slot kind and adds no overload, but counts toward arity 3. `mount` re-registers a group's routes through `_add` in order. The comment "Guarded groups" in `app.mojo` describes the transport.
- Mojo 1.1.0 cannot reflect function parameter names, so binding is positional and a name is compared only where written in a type (`Param`, M3-050; a record's fields, M3-061).

### Request handling

- `App.use` appends a thin function value to the middleware list of `_Core`. With none, `handle` calls `_dispatch` on the borrowed request. Otherwise the borrowing `handle` copies the request once and the owning one moves it, then `_run(0)` calls each middleware with a `Next` holding a pointer to the borrowed `App`'s `_Core`, inside a `try` whose `except` is the fixed 500 with a `Failure.MIDDLEWARE` report (M3-035).
- Routes are a list scanned in registration order; the first route whose method and path match handles the request and never falls through, even when it answers 400. Registration refuses conflicts, so that route is the most specific. When none matches, `_allowed` collects the methods of routes whose path matches: 405 with `Allow`, else 404 ([M3-030](history/decisions/m3-030-method-not-allowed-decision.md)).
- On a typed route the steps run in the order the [reference](reference/routing.md#order-of-checks) gives; on a guarded route the guard runs after decoding and before the conversions, and a decoding 400 waits behind it ([groups](reference/groups.md#rules)). Query values are found in one scan of the query (`_query_spans_at`, which also names a repeated key), and each value is percent-decoded once (`_decode_value`) before conversion.
- Transport through the handler box: an adapter receives `List[String]` arguments and the body bytes borrowed (`_Erased.invoke(args, bytes)`); the body never travels as a `String`. A typed route's arguments are its decoded route values (an absent or empty optional value is `""`), then the JSON verdict and the header fields' names and values where its route needs them; a raw route's are the method, path and query, then each field's name and value. A guarded route's end with every field's name and value and a verdict (`"1"`, or `"0"` for a deferred 400, the values replaced by its `Rejection`'s step, name and message). A state never travels in the arguments; it is bound with the handler.
- Copies per request: a raw route copies the body once (its rebuilt `Request`), a typed text body once (its UTF-8 read), a `FromBytes` body, bare or carried, never (it is borrowed); a raw, `WithHeaders` or `Headers` route copies each field twice (into the arguments, then into the rebuilt `Request` or `Headers`), and other typed routes receive no header strings; each route value costs one decoded copy, and a `String` value a second at its slot; the borrowing `App.handle` copies the whole request once more when middleware is registered, the owning one does not. A guarded route copies every field twice more (into the arguments, then the guard's `Headers`) and its route values once more; a handler that also reads the fields copies them twice as usual.
- Every fixed 500 `src/muntin` makes goes through `_failed`, and every 400 before a handler through `_rejected_by`; each sets `Response._report` (at most one report, a `Failure` or a `Rejection`). Public `Response` initializers leave it empty, copies keep it, and no backend reads it ([M3-058](history/decisions/m3-058-dropped-error-report-decision.md), [M3-084](history/decisions/m3-084-request-rejection-report-decision.md)). A slot's 400 holds its route value's position, which `_dispatch` turns into the name (`_name_rejected_value`); a `Rejection`'s fixed messages hold no request byte.
- Error opt-in (M2-013): a raised value converts only when the handler's declared error type declares `ToErrorResponse` in its own declaration; bare `raises` is never mapped by message.

### Storage and ownership

These are safety invariants; each storage module's docstring states its own in full.

- **Handler box `_Erased`:** each route owns one move-only `_Erased`, a `ThinAllocation` header holding the invoke trampoline, the drop function and the erased pointer to the handler value. One `__init__[F, call]` instantiates both functions for the same `F`, so the pointer is only restored as that `F` (`tests/test_handler_storage.mojo` counts live values). `App` is `Movable`, not `Copyable`.
- **Middleware:** thin function values, no erasure. A `Next`'s origin is the borrowed `App`'s, so it cannot outlive that borrow, and it is made in `_run`'s frame, so moving the `App` between requests leaves nothing pointing at its old place.
- **State:** `State[S]` holds a sealed `_Shared[S]` (an atomic count and an `OwnedPointer[S]`). `state[]` is read-only through every handle and a reference from it is interior to its handle. Read-only is shallow: interior mutability in `S` is the application's. Each registration copies the handle once; requests borrow it. The value is dropped once, after the last handle.
- **The State guarantee (M3-004), verbatim:** **Muntin must not introduce a Muntin-specific safe-code path that lets one `State` alias replace, mutate, swap, or prematurely destroy the shared payload observed through another alias. Toolchain-wide primitives that can violate the same property for standard-library types and existing Muntin storage (origin rebind, forged allocation or header replacement, `memmove`, stdlib-private fields) are outside this guarantee and are pinned as Mojo 1.1.0 toolchain-wide soundness gaps.** The pins are `tests/toolchain_soundness_gaps` (must build).
- **Guarded route box `_Guarded`:** the handler (or its `_Bound`), the group's guard and one copy of the guard's state share the route's one `_Erased` box, so the context the guard returns is made and consumed in the guarded adapter's frame, never stored or erased; its type passes `State`'s name filter (below). `tests/test_group.mojo` counts live contexts and states.
- **No erased value borrows** ([M3-065](history/decisions/m3-065-request-context-storage-decision.md), [M3-074](history/decisions/m3-074-state-borrowing-decision.md)): erasing a value's type drops its origins. So a request context value is never erased, and `State.__init__` refuses at compile time an `S` whose reflected name shows `{}` (an origin or a parameter pack). `AnyOrigin` can escape the check, for example behind a trait's associated type (`tests/state_known_gaps/state_any_origin_associated_type.mojo`), also inside an `Optional`, a `List` or a `Tuple` field, and no check found on Mojo 1.1.0 refuses it while still admitting owned states ([deferral](history/deferrals.md#closing-states-anyorigin-hole)). Any later erased value follows the same rule.
- **The rebinds** (M3-015, M3-083): `rebind_var` and `rebind` check layout, not type, so they are called only in `_rebind.mojo`'s `_as` (a value) and `_view` (a reference), each right after `comptime assert A == T`, which is exact for origin-free types; for a `StaticString` result exactness comes from the `where` clause.
- **Field-by-field construction** (M3-062, M3-083): `_build_record` builds only a `_FieldBuilt`, which only `RouteValues` and `JsonFields` refine. It writes each field of a `MaybeUninit[T]` at its reflected offset, in field order; when a conversion raises, the fields already written are destroyed once and the storage is forgotten without `T`'s destructor. `T`'s `__init__` never runs. `tests/test_route_records.mojo` and `tests/test_derived_json.mojo` count each field's conversions and destructions.
- **Unsafe confinement:** `scripts/check_unsafe.sh` fails if any `src/muntin` module but `_handler_storage.mojo` names an unsafe operation or the boxes' fields, imports anything but `_Erased`, `_Shared` and `_build_record` from it, if a third type refines `_FieldBuilt`, or if `src/muntin` holds a rebind but the two in `_rebind.mojo`. It is a confinement guard, not a safety proof, and does not check `tests/`. The runtime check on the paths tests run is `SANITIZE=address ./scripts/test.sh` ([DEVELOPMENT](DEVELOPMENT.md#3-verify-with-the-strongest-available-oracle)).

### JSON

`Json[T]` conforms to `FromBody` and `ToResponse` when `T` is a `FromJson` or `ToJson` type, a `JsonFields` struct, or a `List` or `Optional` of one, so JSON adds no handler shape; the registration rules refuse a `T` that cannot be read or written, naming the innermost field (`_refusal`). The codec is Muntin's own (RFC 8259, strict, with Muntin's limits); `JsonValue` is a read-only position in a compact tape held in `_Shared`. At the 1 MiB cap one parse adds at most about 29 MB of memory, and an `App` runs one parse at a time. A `JsonFields` codec is derived by reflection: the writer walks the fields; the reader, as Mojo 1.1.0 has no reflective constructor, builds through `_build_record` ([M3-082](history/decisions/m3-082-derived-json-codecs-decision.md)); a hand-written codec calls them through `JsonValue.read[T]` and `JsonWriter`'s `JsonFields` overloads ([M3-087](history/decisions/m3-087-derived-json-in-hand-written-codecs-decision.md)). Reading a float is Muntin's own correctly rounded conversion ([M3-078](history/decisions/m3-078-json-float-reading-decision.md)); writing one goes through `String(Float64)`, which is not always round-trip, a pinned toolchain gap ([responses](reference/responses.md)).

### Flare adapter

The adapter module's docstring (`adapters/flare/muntin_flare.mojo`) states its conversion and serving policy; `flare_internals.mojo` lists every Flare internal it relies on. The user-visible contract is [serving](reference/serving.md).

- `_serve_app(app, request)` converts a Flare request, moves it into the owning `App.handle`, converts the response back and applies the `HEAD` rule to the response it would send at every exit: `App.handle`'s answer, `to_flare_response`'s fixed 500, its own 400 and 431. It never routes. `MuntinHandler` owns an `App` (tests and probes); `_BorrowedHandler`, which `Server` uses, borrows one and is not `Copyable`.
- Before the conversion: an HTTP/1.1 or HTTP/2 request without a `Host` field (any casing; HTTP/1.0 needs none) is 400 (M3-073), and so is one whose `Host` value, on any version, is not `uri-host [ ":" port ]`, or is empty over HTTP/2 (M3-076); then one with more fields than `max_header_fields` is 431 (M3-067). The conversion copies the method and target as strict UTF-8 without slicing them (M3-039), the body bytes unchecked (M3-040), and rebuilds the fields from Flare's public `HeaderMap.encode_to`, verified against `get_all` (fields × distinct names comparisons inside Flare, bounded by the field limit). Anything it cannot represent is 400 before `App.handle`.
- On the way out, the body is moved, not copied; connection-specific fields are dropped; each field is re-checked and a failure is 500.
- `Server` holds Flare's `HttpServer` and the field limit; `Server.bind` is its one spelling. `serve(app)` runs Flare's single-worker `serve` on the calling thread. `serve[make]` (M3-049) starts one thread per worker, each building its own `App` with `make` and running Flare's per-worker reactor loop on a close-on-exec copy of the listener; Flare's own multi-worker `serve` is not used: it needs a `Copyable` handler, copied before the workers start, so an `App` could not be built on its worker, and its stop has no window for every worker. So one `App` and its `State` values stay on one thread for the `App`'s life.
- The stop (M3-045): `_StopWatch` claims the process's one serving cell, installs a do-nothing handler with `SA_RESETHAND` on SIGTERM and SIGINT, and a watcher thread that sees a delivered signal as the disposition back at `SIG_DFL`. It then drains (Flare's `drain`, or `_drain_workers`, which parks every worker's listener copy on a pipe and closes the listener), waits the grace window, and ends the process with `_exit(128 + signal)` if the reactors have not returned `_REACTOR_STOP_MS` later. Nothing runs in signal context.
- TLS (M3-051) is Flare's `bind_tls` with the same configuration; `_check_tls_files` is a best-effort start-up diagnosis, and OpenSSL's load decides.
- Two reliances of the workers have no test that fails when they stop holding ([M3-070](history/decisions/m3-070-backend-coupling-decision.md)):
  - Flare's accept loop leaving on `ENOTSOCK` once its listener copy is parked (M3-049's stop). No test can place a reactor between reading readiness and the swap; a control point there, or a Flare change to the loop, is when to add one. If it stopped holding, that reactor would retry the accept and never read its stop byte: its open connections go unserved through the window, and the watcher's bound (`_REACTOR_STOP_MS` after the window) ends the process with `128 + signal` instead of `serve` returning. Risk left: one worker's connections lost and the code after `serve` skipped at a stop.
  - One OpenSSL `SSL_CTX` used by every worker at once (M3-060). OpenSSL's [threads page](https://docs.openssl.org/3.0/man7/openssl-threads/) says a factory object such as an `SSL_CTX` must not be modified after it has created other objects, and nothing about creating objects from one concurrently; the workers rely on Flare not modifying it after `bind_tls` (not read in Flare's source for M3-070), and `test_https_workers_handshake_on_every_worker` shows one handshake on each worker, not several at once (a test that starts handshakes on every worker together would close it). If it stopped holding, concurrent handshakes would race inside OpenSSL: failed handshakes or a crash of the process, every worker with it, and nothing detects or contains it. Risk left: that, on a TLS `Server` with more than one worker; one worker avoids it.

### Mojo 1.1.0 facts the design rests on

- A function type is a trait, so stored handlers are thin function values; closures do not convert (`tests/spike_fail`).
- Parametric raises (`thin raises E`) infer the error type without overload ranking. An explicitly typed non-raising function value (`var f: def() thin -> String`) does not convert to it; spell it `def() thin raises Never -> String` (`storage_fail/typed_thin_value_handler.mojo`).
- An explicitly typed function value with a borrowed parameter converts to no generic `var A` slot, so typed values and helper parameters spell each request parameter `var` (`def(var Int) thin raises Never -> String`; a leading `State[S]` keeps its spelling); plain `def` handlers convert either way (`registration_fail/typed_value_to_owned_slot.mojo`).
- `rebind_var` checks layout, not the nominal type. Generic `==` keeps an origin's mutability but not its identity, and `Origin.equals` works only in `where` clauses; a `where` clause on an overload compares by identity at the call site, which is why the result rule is one.
- Reflection exposes struct fields but not function parameter names or constructors.
- Module-level variables do not compile and thin handlers cannot capture: `State` is the only way a handler reads runtime data, and `serve[make]`'s workers share nothing.
- There are no private fields and no existentials; `__extension` is undocumented and never part of the contract.
- `ArcPointer.__getitem__` is mutable through any handle, which is why `State` uses `_Shared` (`tests/state_storage_known_gaps`).
- A trait may require a `comptime` member (`FromBytes.max_bytes`); under a refining trait's default a misspelled member is accepted silently (`tests/bytes_limit_known_gaps`).
- The runtime installs its own handler for SIGHUP, SIGINT, SIGQUIT and SIGTERM in every binary and replaces an inherited ignore before `main`; a binary has runtime threads before `main`, none blocking any signal, so `Server.serve` relies on a handler, not a mask.

### Current limits

What Muntin does not do yet is `SPEC.md`, "Remaining candidates", and each item's decision record. Limits of the current code that are easy to miss:

- Bodies are whole `List[UInt8]` values: nothing is streamed and a request body is held in full (bounded by the `Server`'s `max_body_bytes` as Flare receives it). Multipart is not parsed.
- Route values are `Int`, `String`, their `Optional`s and application `FromRouteValue` types, bare or in a `Param`; at most two values as separate parameters (both bare or both `Param`s), or any number in one `RouteValues` record. Not supported: an optional path value (an `Optional` binds a query placeholder only), an `Optional` of a `FromRouteValue` type, standard types such as `Bool` or `Float64`, a default written in the literal, an empty value distinct from an absent one, several values for one key, decoded query keys.
- Only `GET` (and `HEAD` through it), `POST`, `PUT`, `PATCH` and `DELETE` select routes; `OPTIONS` and others get 405 or 404, never 501 ([M3-030](history/decisions/m3-030-method-not-allowed-decision.md)).
- Middleware is functions with compile-time configuration only; a typed request value comes only from a group's guard, which sees the header fields alone and runs only on that group's routes.
- Over HTTP/1.1, with its default HTTP/1.1 parser settings, Flare v0.12.0 answers a method with any lowercase letter (`get`, `Get`) 400 before `App.handle`, and rejects target bytes outside `!`..`~`, so a static segment such as `/hello world` compiles and matches in memory but never arrives over HTTP/1.1.
- Over HTTP/1.1, Flare v0.12.0 frames every 304 with a `Content-Length`: a declared one, or else the body's length, so 0 only for an empty body. For `HEAD` the adapter removes the body and declares no length for a 304, so a `HEAD` 304 goes out with `Content-Length: 0`, which the adapter cannot remove, and a `HEAD` 205 too; over h2c neither carries a `content-length` ([M3-026](history/decisions/m3-026-head-decision.md), measured by `compat/flare/head/head_probe.mojo`).
- The adapter checks a `Host` value's syntax only; it neither normalizes it nor compares it with the server's names. An `Upgrade: h2c` request without a valid `Host` gets Flare's 101 before the adapter's 400 on stream 1. Over HTTP/2 Flare drops every `host` beside `:authority`, comparing only the last with it (none when `:authority` is empty), and a second `host`, so the adapter never sees them.
- The adapter copies the request body once out of Flare's request (Flare's `Handler.serve` lends its request read-only). Measurements of what the adapter adds are in pull requests #114, #125 and #136, and on the current request path in #169.
- `main.mojo` uses `TestClient` because the default environment has no Flare; serving needs the `flare` environment.
- The localhost round trip and `test_server.mojo` need `fork(2)`; Windows is out of scope. `test_server.mojo`'s `::1` case needs IPv6: it is skipped only when `socket(AF_INET6, ...)` fails with `EAFNOSUPPORT` and the environment variable `CI` is unset, so it always runs on the CI runners (GitHub Actions sets `CI`), and a host that creates IPv6 sockets but cannot bind `::1` fails it rather than skipping it. The round trip's first `/hello` request is slow on a cold start (about 26 s locally once, up to 64 s on macOS CI); look there before blaming routing if it flakes.
- The `flare` CI job rebuilds Flare's C/C++ FFI wrappers on every run (about a minute, no cache). Flare HTTP/3 is unavailable from the conda build.
- `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19. If the `flare` job breaks after that, compare `ImageOS`/`ImageVersion` in the `runner image` step before blaming Muntin or Flare; delete this line once a `flare` job has passed on Ubuntu 26.

## Revisit index

If one of these pins changes (a pinned fixture unexpectedly compiles, fails to compile or changes its expected diagnostic, or a pinned test's observation changes), reopen the linked decision rather than patching the test in isolation. The table only maps pins, and a few conditions that cross records, to records (or, for a deferral without a record, its pull request); what each pin means and every other condition is the record's "Revisit when" list, and each fixture's opening comment says what it pins.

| Pinned by | Record |
|---|---|
| `tests/spike_fail` | [M2 handler storage](history/decisions/m2-handler-storage-decision.md), [M2-016](history/decisions/m2-016-m2-closure.md) |
| `tests/extraction_fail`; `tests/spike_fail/extension_int.mojo` | [M2-005](history/decisions/m2-005-argument-extraction-decision.md) |
| `tests/response_fail` | [M2-007](history/decisions/m2-007-typed-response-decision.md) |
| `tests/error_fail`; `storage_fail/typed_thin_value_handler.mojo` | [M2-010](history/decisions/m2-010-application-error-decision.md) |
| `tests/error_response_fail` | [M2-012](history/decisions/m2-012-error-response-decision.md) |
| `tests/raw_fail` | [M2-014](history/decisions/m2-014-raw-request-decision.md), [M2-016](history/decisions/m2-016-m2-closure.md) |
| `tests/route_conflict_abort`; `tests/test_route_conflicts.mojo` | [M3-053](history/decisions/m3-053-route-conflict-decision.md) |
| `tests/middleware_fail`, `tests/middleware_api_fail` | [M3-034](history/decisions/m3-034-middleware-decision.md) |
| `tests/state_fail`; `tests/state_known_gaps/registrar_blind_mutation.mojo` (must build) | [M3-001](history/decisions/m3-001-application-state-decision.md) |
| `tests/state_storage_fail`; `tests/state_storage_known_gaps` and `tests/toolchain_soundness_gaps` (must build) | [M3-004](history/decisions/m3-004-state-storage-decision.md) |
| `tests/headers_fail`; `tests/headers_known_gaps` (must build); `compat/flare/headers/flare_header_probe.mojo` | [M3-002](history/decisions/m3-002-headers-decision.md); its "HTTP/1.1 request without Host accepted" case: [M3-073](history/decisions/m3-073-request-host-decision.md); its `Host` value and `host` cases: [M3-076](history/decisions/m3-076-request-host-value-decision.md) |
| `test_every_request_field_reaches_the_handler_over_http1_and_h2c` in `adapters/flare/test_localhost_roundtrip.mojo` | [M3-066](history/decisions/m3-066-request-header-conversion-decision.md) |
| `tests/json_fail`; `tests/json_known_gaps` (must build); `test_float_writer_gap_on_mojo_1_1_0` in `tests/test_json.mojo` | [M3-008](history/decisions/m3-008-json-codec-decision.md) |
| `tests/json_api_fail/positional_status.mojo` | [M3-028](history/decisions/m3-028-json-response-status-decision.md) |
| `tests/json_api_fail/field_*.mojo`, `tests/json_api_fail/generic_writer_forwarding.mojo` | [M3-075](history/decisions/m3-075-json-writer-members-decision.md) |
| `tests/json_api_fail/derived_*.mojo` | [M3-082](history/decisions/m3-082-derived-json-codecs-decision.md) |
| `tests/json_api_fail/hand_written_derived_*.mojo`; `json_known_gaps/hand_written_derived_unused_codec_builds.mojo` stops building | [M3-087](history/decisions/m3-087-derived-json-in-hand-written-codecs-decision.md) |
| a `get`, `post`, `put`, `patch` or `delete` overload beyond the eight arity overloads (slot arity 4 or more: two more overloads per method name) | [M3-052](history/decisions/m3-052-registration-complexity-budget-decision.md), [M3-022](history/decisions/m3-022-several-route-values-decision.md), [M3-020](history/decisions/m3-020-http-methods-decision.md), [M3-014](history/decisions/m3-014-registration-structure-decision.md), [M3-007](history/decisions/m3-007-stateful-raw-handlers-in-production.md), [M3-012](history/decisions/m3-012-typed-header-access-decision.md) |
| a concurrent `App.handle`, an `App` called from several threads in turn, or a `Copyable` `App` | [M3-001](history/decisions/m3-001-application-state-decision.md), [M3-008](history/decisions/m3-008-json-codec-decision.md) |
| `tests/testclient_headers_api_fail`; `tests/headers_api_fail/request_headers_moved_in.mojo` | [M3-010](history/decisions/m3-010-testclient-request-headers-decision.md), [M3-011](history/decisions/m3-011-testclient-request-headers-in-production.md) |
| `tests/header_access_fail` | [M3-012](history/decisions/m3-012-typed-header-access-decision.md) |
| `tests/with_headers_api_fail` | [M3-012](history/decisions/m3-012-typed-header-access-decision.md), [M3-013](history/decisions/m3-013-typed-header-access-in-production.md) |
| another injected kind proposed | [M3-001](history/decisions/m3-001-application-state-decision.md), [M3-012](history/decisions/m3-012-typed-header-access-decision.md), [M3-014](history/decisions/m3-014-registration-structure-decision.md) |
| `tests/registration_fail`; `tests/registration_known_gaps` (must build); `header_access_fail/generic_slot_does_not_refine.mojo` or `state_fail/variadic_handler_type.mojo` compiles; `state_known_gaps/registrar_blind_mutation.mojo` stops building | [M3-014](history/decisions/m3-014-registration-structure-decision.md) |
| `tests/registration_api_fail` | [M3-015](history/decisions/m3-015-registration-on-generic-arity-slots-in-production.md), [M3-014](history/decisions/m3-014-registration-structure-decision.md) |
| a toolchain change that lets an overload see how a caller spelled a type; a new slot kind (generic forwarding reaches it too) | [M3-015 amendment](history/decisions/m3-015-registration-structure-amendment-generic-forwarding.md), [M3-024](history/decisions/m3-024-optional-query-values-decision.md) |
| `tests/string_route_api_fail` | [M3-018](history/decisions/m3-018-route-value-decoding-and-string-route-values-decision.md) |
| `tests/get_headers_api_fail` | [M3-016](history/decisions/m3-016-typed-get-header-access-decision.md) |
| `tests/methods_api_fail` | [M3-020](history/decisions/m3-020-http-methods-decision.md), [M3-026](history/decisions/m3-026-head-decision.md), [M3-036](history/decisions/m3-036-testclient-head-decision.md), [M3-030](history/decisions/m3-030-method-not-allowed-decision.md) |
| `tests/bodyless_api_fail` | [M3-048](history/decisions/m3-048-bodyless-typed-post-put-and-patch-handlers-decision.md) |
| `tests/route_values_api_fail`; `registration_api_fail/immutable_origin_result_*_3.mojo` | [M3-022](history/decisions/m3-022-several-route-values-decision.md) |
| `tests/named_values_api_fail`; `test_variable_names_are_not_compared` in `tests/test_named_values.mojo` | [M3-050](history/decisions/m3-050-named-route-values-decision.md) |
| `tests/optional_values_api_fail` | [M3-024](history/decisions/m3-024-optional-query-values-decision.md) |
| `tests/app_values_api_fail` | [M3-054](history/decisions/m3-054-application-route-value-types-decision.md) |
| `tests/route_records_api_fail`; `test_init_is_never_called` in `tests/test_route_records.mojo` | [M3-061](history/decisions/m3-061-route-value-records-decision.md) |
| `compat/flare/head/head_probe.mojo` | [M3-026](history/decisions/m3-026-head-decision.md), [M3-036](history/decisions/m3-036-testclient-head-decision.md) |
| `tests/test_method_not_allowed.mojo` and the 405 cases in `adapters/flare/test_muntin_flare.mojo` and `adapters/flare/test_localhost_roundtrip.mojo` | [M3-030](history/decisions/m3-030-method-not-allowed-decision.md) |
| `compat/flare/serve/workers_need_copyable.mojo` or `server_handler_not_copyable.mojo`; `server_positional_init.mojo` or `server_keyword_init.mojo`; `adapters/flare/test_server.mojo` | [M3-032](history/decisions/m3-032-serving-entrypoint-decision.md) |
| the method and target cases in `adapters/flare/test_muntin_flare.mojo` and `adapters/flare/test_localhost_roundtrip.mojo` | [M3-039](history/decisions/m3-039-request-target-and-method-bytes-decision.md) |
| `compat/flare/body/body_probe.mojo`; the body cases in `adapters/flare/test_muntin_flare.mojo` and `adapters/flare/test_localhost_roundtrip.mojo`; `tests/test_binary_body.mojo`; `tests/body_bytes_api_fail`; the re-pinned `tests/state_fail/closure_handler_storage.mojo` and the `TestClient` positional-`Headers` fixtures of `tests/testclient_headers_api_fail` and `tests/methods_api_fail` | [M3-038](history/decisions/m3-038-request-body-bytes-decision.md), [M3-040](history/decisions/m3-040-binary-request-and-response-bodies-decision.md) |
| `tests/test_bytes_body.mojo` and the `FromBytes` routes in `adapters/flare/test_localhost_roundtrip.mojo`; `tests/from_bytes_api_fail` | [M3-041](history/decisions/m3-041-typed-binary-request-bodies-decision.md) |
| `tests/test_bytes_headers_body.mojo` and the `WithHeaders[Payload]` route in `adapters/flare/test_localhost_roundtrip.mojo`; `tests/bytes_headers_api_fail`; `tests/with_headers_api_fail`'s three bound texts | [M3-042](history/decisions/m3-042-typed-binary-request-bodies-with-header-fields-decision.md) |
| `tests/test_bytes_limit.mojo` and the `Limited` routes in `adapters/flare/test_localhost_roundtrip.mojo`; `tests/bytes_limit_api_fail`; `tests/bytes_limit_known_gaps` (must build) | [M3-043](history/decisions/m3-043-typed-binary-request-body-size-limits-decision.md) |
| `adapters/flare/test_server.mojo`'s body limit cases and the `receive_app` cases in `adapters/flare/test_localhost_roundtrip.mojo`; `compat/flare/serve/server_bind_positional_limit.mojo`; the buffer-ring pin in `test_receive_limit_on_flare_bufring_path` | [M3-044](history/decisions/m3-044-server-receive-body-limit-decision.md) |
| `registration_fail/generic_handler_cannot_forward.mojo`, `registration_fail/method_alias_drops_self.mojo`; `state_fail/variadic_handler_type.mojo` and `header_access_fail/eleven_candidates_drop_a_note.mojo` for the budget | [M3-052](history/decisions/m3-052-registration-complexity-budget-decision.md) |
| `adapters/flare/test_server.mojo`'s head-of-line blocking tests | [M3-046](history/decisions/m3-046-head-of-line-blocking-decision.md) |
| `compat/flare/serve/serve_workers_capturing_make.mojo` or `serve_workers_runtime_closure.mojo`; `adapters/flare/flare_internals.mojo`; `adapters/flare/test_server.mojo`'s workers tests | [M3-049](history/decisions/m3-049-multi-worker-serving-decision.md) |
| `adapters/flare/test_server.mojo`'s idle timeout tests | [M3-047](history/decisions/m3-047-server-idle-timeout-decision.md) |
| `adapters/flare/test_tls.mojo` | [M3-051](history/decisions/m3-051-server-tls-decision.md) |
| `adapters/flare/test_tls.mojo`'s workers tests; `tls_context_addr` and `run_worker_loop` in `adapters/flare/flare_internals.mojo` | [M3-060](history/decisions/m3-060-tls-with-workers-decision.md) |
| `adapters/flare/test_server.mojo`'s stop tests | [M3-045](history/decisions/m3-045-graceful-shutdown-decision.md) |
| `compat/flare/stream/stream_probe.mojo` | [M3-056](history/decisions/m3-056-streaming-responses-and-cancellation-decision.md) |
| `tests/context_known_gaps/reflected_names_collide.mojo` (must build) | [M3-063](history/decisions/m3-063-request-context-decision.md) |
| `tests/context_known_gaps/erasure_drops_origin.mojo` (must build; `scripts/run_origin_gaps.sh` runs it under AddressSanitizer); `tests/context_fail` | [M3-065](history/decisions/m3-065-request-context-storage-decision.md) |
| `tests/group_api_fail`; `tests/route_conflict_abort/mounted_group.mojo`; `tests/test_group.mojo` (live contexts and states) | [M3-080](history/decisions/m3-080-guarded-routes-and-request-context-decision.md) |
| `tests/state_fail/state_origin_*.mojo`, `state_pack_tuple.mojo`, `state_pack_in_type_argument.mojo`, `state_empty_struct_parameter.mojo` and `state_function_parameter_*.mojo`; `tests/test_state.mojo`'s owned-state, wrapper and function-parameter tests; `tests/state_known_gaps/state_any_origin_associated_type.mojo` (must build; `scripts/run_origin_gaps.sh` runs it under AddressSanitizer) | [M3-074](history/decisions/m3-074-state-borrowing-decision.md) |
| `tests/state_fail/state_any_origin_*.mojo`; `tests/state_known_gaps/state_any_origin_in_*.mojo` (must build; `scripts/run_origin_gaps.sh` runs them under AddressSanitizer) | [deferral](history/deferrals.md#closing-states-anyorigin-hole), [pull request #175](https://github.com/sano-suguru/muntin/pull/175) |

## Request/Response ownership

`Request` and `Response` own their data. Do not optimize around zero-copy wire buffers if that leaks backend lifetimes into the public API; before changing the ownership model, measure the cost and record the concrete requirement that justifies more lifetime complexity.

The owning `App.handle` (M3-064) removes the request copy before middleware, not every copy: the Flare adapter still copies the body out of Flare's request, and routes copy what [request handling](#request-handling) lists.

## Flare policy

Flare provides a substantial Mojo networking stack with its own routing and handlers; Muntin must not re-export those application abstractions.

- Allowed inside the adapter: Flare's server and bootstrap APIs, conversion between Flare and Muntin requests and responses, transport lifecycle integration, backend-specific optimizations hidden behind the adapter.
- Not allowed in durable Muntin public APIs: Flare's `Request`/`Response` types; Flare's `Router` as Muntin's routing contract; Flare middleware types as Muntin's middleware contract; Flare extractors as Muntin's only extraction model; Flare reactor, cancellation and runtime types in normal application handlers.
- The Flare version is pinned; track Flare's `main` only for explicit compatibility investigation, never as the default reproducible dependency.
- Three layers ([M3-070](history/decisions/m3-070-backend-coupling-decision.md)): `App.handle` and everything behind it is backend-independent (A2, A3); what every network backend owes it ([Backend seam](#backend-seam)) is Muntin's contract, which a second backend keeps; serving is the Flare adapter's, not a seam: `Server`, its settings, its threads, `serve[make]`'s workers (how many `App`s exist, on which threads and for how long, and so what one `State` value sees) and its stop. With workers, its stop watcher, worker table and listener parking drive Flare's per-worker loop through the internals in `adapters/flare/flare_internals.mojo` and rely on how that loop registers, polls and leaves; serving's contract ([serving](reference/serving.md)) is in large part Flare v0.12.0's behavior. The first two layers are designed to carry over to another backend, not demonstrated: there is one network backend.

A change that makes the adapter's code (not its tests, which list their own Flare internals in `flare_internals.mojo`'s docstring) rely on something no public contract states:

- a Flare name that is not public;
- a behavior of Flare's, of a library Flare loads (OpenSSL) or of the operating system's that its documentation at the pin does not state (the docstrings of Flare's public names and its README; OpenSSL's and the system's manual pages): a format, an order, a timing, a side effect, a silent fallback. The request and response conversion is included: a loopback case is its test, not an exemption.

Such a change:

- names it where the code relies on it: a Flare name in `flare_internals.mojo` with what it is relied on for, a behavior in a "Relied on" statement beside the code that relies on it (or in `flare_internals.mojo`'s docstring, with a comment at that code pointing to it);
- has a test that fails when it stops holding, on each platform that relies on it, and says whether the test observes the condition itself or only an outcome of it, and which break it would miss (an outcome test does not show an order or a memory ordering). Where no test can, the statement says what a break would do and what, if anything, detects or contains it at run time, and the record names the risk left, which the owner accepts by merging;
- has a record (the decision item's, or the one whose slice it implements) that counts the reliance among the candidate's costs, says why Flare's public API, and a proposal to Flare's maintainers, were not taken instead, and states the adapter's size before and after: the entries in `scripts/check_flare_reliance.sh`'s lists and the lines of the adapter's modules, every `.mojo` file under `adapters/flare` but its `test_*.mojo` tests (2,111 at M3-070).

Removing a reliance needs none of this. Replacing a non-public Flare name with a public one whose undocumented behavior is then relied on needs all three, but the third may be its pull request instead of a record. A change that takes those modules past 2,500 lines together, whatever it relies on, waits for a decision that weighs the growth against a public entry point proposed to Flare and against a narrower `Server`.

`scripts/check_flare_reliance.sh` (run by `check.sh`) is the mechanical part, a ratchet on names rather than a Mojo parser. Over the adapter's modules (`test_*` tests aside), it fails when a module other than `flare_internals.mojo` imports a `_`-prefixed Flare module or name; when `flare_internals.mojo`'s Flare imports, or the `_`-prefixed members and keyword arguments its code uses, differ from the script's lists either way, so a new name shows in the diff and a stale entry cannot stay; when a module imports a `test_*` module, which it does not read; when the modules pass 2,500 lines together; and when it cannot list or read a module, or a module holds what it does not read, rather than skip code. Its header says what it reads; `scripts/test_check_flare_reliance.sh` (also run by `check.sh`) pins what it reads, what it refuses and what it leaves out. A behavior has no name, and a private member or keyword outside `flare_internals.mojo` looks like Muntin's own, so review applies the rest.

## Adapter translation policy

An adapter may contain inelegant conversion code if that keeps the public model stable; do not contort Muntin's API to make one adapter thin. If an adapter repeatedly copies large bodies or cannot express a common feature without severe cost, treat that as evidence for a focused core change; measure and document the tradeoff first.

## Architecture tests

At minimum, tests should establish that an application route is dispatched through Muntin's app model; that the in-memory backend drives it without Flare or sockets; that core modules do not import Flare; that a real localhost request traverses Flare, the adapter, Muntin and back; and that the same application handler can be exercised by both paths without changing its public signature.

## Architecture decision threshold

Record a decision before exposing any third-party type publicly; introducing a custom runtime, executor or task model; making a transport mandatory; adding unsafe memory or lifetime machinery to a public contract; changing request/response ownership semantics; changing the backend seam in a way that breaks adapters; making the Flare adapter rely on something no public contract states ([Flare policy](#flare-policy)); or making a provisional API example a frozen compatibility promise.
