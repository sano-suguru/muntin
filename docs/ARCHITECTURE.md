# Muntin architecture

Muntin owns the application model. Transports adapt to `App.handle(Request) -> Response`; they do not define application semantics.

This file is the current state: the thesis, the invariants, the [current architecture](#current-architecture) and a [revisit index](#revisit-index). Why each part is as it is (reasons, rejected candidates, measurements, revisit conditions) is in the [decision records](history/architecture-decisions.md), one record per decision. Milestone tags below, such as (M3-015), name the item; the links name a specific record. Public API and user-visible semantics: `docs/DX.md`. Product scope: `docs/SPEC.md`.

## Architectural thesis

Muntin's leverage should come from application-level developer experience and compile-time/type-system guarantees. Networking machinery is replaceable infrastructure.

The architectural fulcrum is the boundary between the **Muntin-owned application model** and **transport/backend adapters**.

```text
Application code
      |
      v
+--------------------------------+
| Muntin public API              |
| App / Request / Response       |
| routes / handlers              |
| extraction / errors (M2)       |
| state / headers / JSON (M3)    |
| later: middleware (M3)         |
+---------------+----------------+
                |
         narrow backend seam
                |
       +--------+---------+
       |                  |
       v                  v
 in-memory            Flare adapter
 reference            (M1+)
 backend                   |
                           v
                 HTTP/TLS/QUIC/reactor
```

## Invariants

### A1. Muntin owns the public application API

Public application code imports Muntin-owned concepts. Third-party transport-library types must not appear in normal handler signatures, routing APIs, middleware contracts, application-state contracts, or canonical examples.

### A2. Dependency direction points inward

Muntin core/application modules do not import Flare. Backend adapters depend on Muntin's backend/application contract.

```text
muntin core  <-  in-memory backend
muntin core  <-  flare adapter
```

Never invert this relationship merely because an adapter has a convenient abstraction.

### A3. Replaceability is executable

Transport independence is not a diagram claim. An in-memory/reference path exercises the same application-dispatch seam as transport adapters.

A refactor that makes the in-memory path bypass real routing/dispatch is an architecture regression even if tests stay green.

### A4. The backend seam stays narrow

Do not invent a universal networking abstraction. The seam should expose only what Muntin needs to accept an application request, dispatch it, and produce an application response/lifecycle result.

Do not pre-abstract executor, reactor, poller, wakeup, TLS session, QUIC stream, socket option, or backend-specific cancellation machinery into public contracts.

### A5. Protocol mechanics stay outside core

Wire parsing, sockets, TLS, HTTP/2 flow control, HTTP/3, QUIC, platform event loops, connection pools, and protocol negotiation belong to networking backends/runtimes.

### A6. Async evolution must remain survivable

Do not publish a framework-specific executor/future/task model just to fill a temporary language/runtime gap. The Muntin application model should be able to adopt future Mojo async/runtime primitives with minimal application-level breakage.

### A7. Evidence before abstraction

Add an abstraction when a current requirement, two real implementations, or a strong external constraint justifies it. A hypothetical future backend is not enough.

The in-memory backend exists to prove the seam and provide deterministic tests, not to force every networking feature into a lowest-common-denominator interface.

### A8. DX is an architectural input

`docs/DX.md` is not decoration after implementation. Public API examples constrain internal design. If internal convenience would make ordinary application code materially more verbose, reconsider the internal abstraction first.

If the desired API is impossible in the current Mojo toolchain, preserve the intended semantic property and document the proven language limitation.

## Logical components

The exact package layout must follow the supported stable Mojo toolchain, but logical dependencies should resemble:

```text
muntin/
  application core
  request/response model
  routing/handler adaptation
  backend contract

muntin/testing/
  in-memory backend / TestClient

muntin/adapters/flare/
  Flare conversion and server integration
```

Filesystem names may change. Dependency direction may not.

## Current architecture

Toolchain: Mojo 1.1.0 (8189361e) via pixi 0.81.0, pinned by `pixi.lock`; `scripts/check.sh` fails on any other Mojo version, so an upgrade is a deliberate change to the script and the docs. Flare v0.12.0 (commit `8c6e1400`) exists only in the separate `flare` pixi environment.

### Modules and public surface

```text
src/muntin/__init__.mojo          exports App, FromBody, Headers, Request, Response, ToErrorResponse, ToResponse,
                                  FromJson, Json, JsonValue, JsonWriter, ToJson, State, WithHeaders
src/muntin/http.mojo              Request (method, path, query, body, headers), Response (status, body, headers),
                                  Headers, ToResponse, ToErrorResponse
src/muntin/body.mojo              FromBody
src/muntin/headers_body.mojo      WithHeaders[B] (post/put/patch body carrier with the request's fields); private marker _HeaderCarrier
src/muntin/app.mojo               App: route table, the get/post/put/patch/delete overloads (one per request-slot arity), App.handle;
                                  private route matching (_match), slot extraction, adapters and the one rebind helper
src/muntin/_registration_rules.mojo
                                  private registration rules: slot kinds (_kind), the route-literal grammar (_split_literal,
                                  _path_part, _query_items, _is_param, _param_name) and the parsers built on it, _rule, _check,
                                  _admits;
                                  the rules are evaluated at compile time (_check, _admits); _route also uses _kind, _is_optional
                                  and _path_params, and _Route.__init__ _path_part, _query_items and _param_name, to build route
                                  metadata at registration; the one per-request part is the _is_param outer-shape predicate (_match);
                                  imported by app.mojo; imports only the types it classifies (.http, .body, .headers_body, .state)
src/muntin/state.mojo             State[S]; private marker _InjectedState
src/muntin/json.mojo              Json[T], FromJson, ToJson, JsonValue, JsonWriter; private parser, limits, _JsonBody
src/muntin/_handler_storage.mojo  private _Erased (handler box) and _Shared (State/JSON box); the only module with unsafe operations
src/muntin/testing.mojo           TestClient: in-memory backend (get, post, put, patch, delete)
adapters/flare/muntin_flare.mojo  Flare adapter (Server, MuntinHandler; private _BorrowedHandler), outside core, flare
                                  environment only
```

The public surface is the exported names and `muntin.testing.TestClient`. `_`-prefixed names are reachable from application code on Mojo 1.1.0 (no private fields) but are not API.

### Backend seam

- The only seam is `App.handle(self, request: Request) -> Response`. A backend builds a Muntin `Request`, calls `handle`, and converts the `Response` back. There is no backend trait until a second network backend exists (A7).
- `TestClient[origin: Origin[mut=False]]` holds a `Pointer[App, origin]`: it borrows the `App` immutably, so `TestClient(app)` copies nothing, and `App.handle` takes `self` read-only. `TestClient.get(target)`, `.post(target, body)`, `.put(target, body)`, `.patch(target, body)` and `.delete(target)` (with an empty body) send no header fields; `headers=` (keyword-only, defaulted, moved in) sends the given fields unchanged (M3-011). The client builds `Request(method, target, body, headers^)` and calls `App.handle`, nothing else.
- `Request(method, target, body, headers^)` (body and headers defaulted) splits `target` at its first `?` into `path` (all that routes match) and `query` (raw, undecoded, `""` when absent). Both backends pass the raw target, so the split is the same for both, and a typed route's value is decoded once, by Muntin (request handling, below); a backend that decoded the target first would decode values twice. `Request` and `Response` own `String` data; no backend type or buffer lifetime reaches application code.
- `HEAD` (M3-027, decided by [M3-026](history/architecture-decisions.md#head-decision-m3-026)): `App.handle` answers a `HEAD` request through the matching `GET` route, body included, and never removes a body: a typed handler receives the `GET`'s arguments, a raw handler the `HEAD` request (DX asks it to answer as for the `GET`). Keeping the content off the wire is each network backend's obligation: it sends the response's status and fields with no content, and declares a `Content-Length` equal to the byte length of the body it would have sent for the `GET` (`App.handle`'s, or its own answer where it answers without `App.handle`), none for a status that never carries content (1xx, 204, 205, 304). Here the in-memory response (with its body) and the wire response (without) differ; `TestClient` has no `head`, and a test calls `App.handle(Request("HEAD", ...))`.
- `scripts/check_boundaries.sh` fails if `src/muntin` imports or mentions Flare or socket modules (A2). `scripts/check_unsafe.sh` confines unsafe operations to `_handler_storage.mojo` and `rebind_var` to one helper in `app.mojo` (below).
- `App.handle` is never called concurrently today: `Server` serves on one reactor thread, Flare's multi-worker `serve` needs a `Copyable` handler, `App` is move-only and `Server`'s handler is not `Copyable`. That bounds JSON parse memory (one parse at a time per `App`) and makes interior mutability in a `State` value single-threaded; a concurrent backend or a `Copyable` `App` reopens both (revisit index).

### Registration surface

`App.get`, `App.post`, `App.put`, `App.patch` and `App.delete` have eight overloads each: one per request-slot arity (0 to 3), stateless and stateful (M3-015; slot arity 3: [M3-022](history/architecture-decisions.md#several-route-values-decision-m3-022)). `put` and `patch` are copies of `post` and take its shapes under its rules, `delete` a copy of `get` ([M3-020](history/architecture-decisions.md#http-methods-decision-m3-020)): `_rule` sends `GET` and `DELETE` to `_get_rule` and `POST`, `PUT` and `PATCH` to `_post_rule`, and a message that names a method names the registration's. A request slot is a handler parameter that comes from the request. The stateful family takes a fixed leading `State[S]`, which is not a slot, and the state as the registration's second argument, so the argument count separates the families and no two overloads of a method accept the same handler. Every slot is a generic `var A` whose kind is decided at compile time from its type alone: an `Int` or `String` route value or an `Optional` of either, a body (a `FromBody`, possibly move-only, or a `WithHeaders[B2]` carrier), the raw `Request`, the request `Headers` (on `get` and `delete`), or, rejected by the rules, a `State` or a type of no kind. Every handler type is `thin raises E` with `E: Deinitable` inferred (`Never` for a non-raising handler, `Error` for `raises`, the application's `T` for `raises T`). The result `R` is generic and accepted only through `where (R == String or R == StaticString or conforms_to(R, ToResponse))` on every overload, which the compiler checks by identity at the call site.

| Method | Stateless (`app.m[route](handler)`) | Stateful (`app.m[route](handler, state)`) | Results |
|---|---|---|---|
| `get`, `delete` | `def()`, `def(V)`, `def(Headers)`, `def(V, Headers)`, `def(V, V)`, `def(V, V, Headers)` | `def(State[S])`, `def(State[S], V)`, `def(State[S], Headers)`, `def(State[S], V, Headers)`, `def(State[S], V, V)`, `def(State[S], V, V, Headers)` | `String`, `StaticString`, or `R: ToResponse` |
| `post`, `put`, `patch` | `def(B)`, `def(V, B)`, `def(V, V, B)` | `def(State[S], B)`, `def(State[S], V, B)`, `def(State[S], V, V, B)` | same |
| `get`, `post`, `put`, `patch`, `delete` | raw `def(Request)` | raw `def(State[S], Request)` | `Response` only |

`V` is a route value: an `Int` or a `String` (M3-018), or an `Optional[Int]` or `Optional[String]` (M3-025), which binds a query placeholder only; two in one shape may be of any of these types (M3-022).

- **Route literals** are compile-time strings checked at the registration call: a leading `/`, static or `{name}` segments, an optional query part of `{key}` items joined by `&` (keys visible ASCII, none of `{}=&?#`). The placeholder count must equal the handler's route-value count (zero, one or two); raw routes declare none. An optional value binds a `{key}` item ([Optional query values decision (M3-024)](history/architecture-decisions.md#optional-query-values-decision-m3-024)): one alone needs exactly one query placeholder and no path placeholder, and of two values, one at a position below the literal's path count, where it would bind a path segment, is rejected. A literal's query keys must differ (`route declares a query parameter twice`, reported after every other rule); path names are not compared, so `/x/{a}/{a}` registers. Names are never compared with handler parameter names: binding is positional (the path placeholders left to right, then the query placeholders left to right, then the body or the `Headers`), so two values of one type declared in the other order receive each other's values (the accepted cost of M3-022). Literals are stored and split as runtime `String`s per request.
- **Disjointness** (M2-005): a slot is an `Int`, `String`, `Optional[Int]` or `Optional[String]` route value by exact type equality, never a body (so `StaticString`, `StringSlice`, application types and an `Optional` of any other type are no route value, and a `String` in the body position gets the `FromBody` messages); an ordinary body is an application type conforming to `FromBody`. `Json[T]` is a body or a result like any other, so JSON adds no shape.
- **Header carrier in the body slot** (M3-013): the body kind is `FromBody` or the private `_HeaderCarrier`, so `WithHeaders[B]` with `B: FromBody` is a body without being a `FromBody`, and the `FromBody` rule keeps its message. `FromBody` therefore does not name every type a `post` (`put`, `patch`) body slot accepts (the accepted cost). `get` (`delete`) takes no body; its typed handlers read fields through a `Headers` slot (below).
- **`Headers` slot on `get` and `delete`** (M3-016, M3-020): `Headers` is a slot kind by exact type equality, not a trait, so no application type is one. On `get` and `delete` it is accepted once, as the last slot, after at most two route values, with the placeholder rules of the route values it follows; any other of their shapes with a `Headers` slot is `a get handler takes one Headers, as its last parameter` (`a delete handler ...` on `delete`), checked after the `State`, `Request`, body and no-kind rules so their messages win. The route sets `_Route.headers`, which marks a route whose handler receives the fields (a carrier or a `Headers` slot). `post`, `put` and `patch` take no `Headers` slot (their last position is the body); `_post_rule` reports a first-slot `Headers` as a type of no kind, so every `post` rule for a `Headers` shape is the one it had before the kind existed (M3-019 reworded the no-kind message to name `String`).
- **One injected slot** (M3-001): a handler takes state exactly when its registration passes a second argument, a `State[S]`; it is then the first parameter, and the rest is one stateless shape. Argument count separates the two families. The slot is registration-bound; M3-012 keeps request header fields out of it (they travel in the body slot or, on `get` and `delete`, the `Headers` slot, above). A second injected kind, request-scoped injection included, needs its own decision, because a second injected kind doubles the stateful family (M3-014).
- **Rules guard the adapter** (M3-015): one ordered rule function (`_rule`) holds every registration rule except the result's. `_check` states each rule as a compile-time assert with Muntin's message, and `_admits`, the same rules as one Bool, guards the adapter's instantiation: without the guard Mojo 1.1.0 reports the adapter's own failure before the rule's message (`tests/registration_api_fail/slot_misuse_names_the_rule.mojo`). If the Bool ever rejects a shape the asserts accept, the guard's `else` aborts at registration instead of leaving the route unregistered. Rules that had a message before M3-015 keep it; new ones name the method. A `String` route value (M3-019) has its own one-value placeholder messages, so every `Int` message stays byte-identical, and the no-kind messages on `get` and before the `post` body name both route-value types. Two route values (M3-022) have one placeholder message per family whatever their types; three are reported before the placeholder count. At slot arity 3 each family's order extends rule by rule across the slots, so every arity-1 and arity-2 result is unchanged except the two retired `at most one` codes: on `get`, a `State`, a `Request`, a body, a no-kind slot, a `Headers` not last, three route values, then the placeholder count; on `post`, each rule over both slots before the last (a `Request`, a `State`, a body, a `Headers` or no-kind slot), then the placeholder count, then the last slot's body rules. An optional value (M3-025) has one placeholder message per family, checked where the one-value count is, and a path-position message checked right after the two-value count; the two no-kind messages name `Optional`, and every other message is unchanged. The distinct-query-keys rule runs last, in `_rule`, only for a shape every other rule accepts.
- **Raw handlers** select the one-slot overload like any other shape: `Request` is a slot kind, and the rule requires `Response` as the result and no placeholder.
- **Diagnostics:** a shape that selects an overload and breaks a rule reports the rule, `constraint failed: <rule>`; the primary line is `function instantiation failed` at the enclosing function, with the registration call in the next note. A call that selects none (more than three slots; with the state passed, a `State` that is owned, `mut`, a plain value or not first; a result outside the `where` clause) is `no matching method` with the eight candidates' notes; a rejected result's note is `violated constraint` and the clause. But when the call does not let the compiler decide the clause, the error is `invalid call to '<method>': lacking evidence to prove correctness` instead. That happens for a result with a local's immutable origin (`origin_text[ImmOrigin(origin_of(s))]`), and for a forwarding helper's generic result whose own `where` is neither one branch of the clause nor the whole clause (no `where`, or a partial disjunction such as `where (R == String or R == StaticString)`) (`tests/registration_api_fail/local_origin_result_rejected.mojo`, `generic_result_disjunction_lacks_evidence.mojo`, `generic_result_without_where_lacks_evidence.mojo`). A typed function value with a borrowed `Int`, `String` or `Headers` slot fails before any overload is chosen (`TODO: function type conversions between closures not supported yet`).
- **Arity budget:** Mojo 1.1.0 prints at most ten notes per diagnostic, counted per method name (`tests/header_access_fail/eleven_candidates_drop_a_note.mojo`, `tests/registration_fail/notes_are_per_method.mojo`), so each of the five method names has its own budget. Slot arity 3 makes eight overloads per method (forty across the five), with every candidate note printed; it is spent on two route values beside a body or `Headers` (M3-022). Notes under a candidate count too: a stateful call at slot arity 2 or 3 whose result the `where` clause rejects (`registration_api_fail/immutable_origin_result_*_state_{2,3}.mojo`) prints all eight candidate notes and drops a trailing type-mismatch sub-note (`(1 more notes omitted.)`). Slot arity 4 would make ten, where a rejected result loses one candidate note (an accepted cost); it is the last arity under the cap, which three route values and another request part on `get` would compete for. Slot arity 5 is past the cap.

### Request handling

Routes are a list scanned in registration order; the first route whose method and path segments match handles the request and never falls through, even when it answers 400. Methods compare byte for byte, except that a `HEAD` request also matches a `GET` route and runs that route's steps (M3-026; backend seam, above); a raw route receives the `HEAD` request. When the scan selects no route, a second scan (`_allowed`, beside `_match`) collects the methods of the routes whose path matches by the same `_match` test, nothing decoded: if there are any, the answer is 405 `Method Not Allowed` with one `Allow` field listing each once, in the order its first such route was registered, `HEAD` right after `GET`; otherwise it is 404 `Not Found` ([M3-030](history/architecture-decisions.md#method-not-allowed-decision-m3-030)). So `HEAD` on a path only routes of other methods match is 405, and `head`, `Head`, `OPTIONS` and unknown methods select nothing: 405 on a path some route matches, 404 elsewhere. `Allow` lists the methods that select a route on that path, not that the selected route's value or body checks pass. The query takes no part in selection. On a typed route, each step runs only if the previous one passed:

| Step | Where | Failure |
|---|---|---|
| method + path match on the raw path (static segments byte-equal, `{name}` one non-empty segment) | `App.handle` | 405 `Method Not Allowed` with `Allow` when a route of another method matches the path, else 404 `Not Found`; nothing decoded or converted |
| query values, one per `{key}` in the literal's order: pairs split on `&`, key/value at the first `=`, byte-equal undecoded keys | `App.handle`, one `try` with the next step | duplicated, or a required value missing: 400 `Bad Request`; an optional value's absent key is passed on as `""` (M3-025) |
| each route value decoded once (`_decode_value`): the path captures in place, left to right, then each query value, with `+` as a space first; `%` and two hex digits become that byte, every other byte is kept | `App.handle`, the same `try` | a required value empty, a bad escape, or decoded bytes that are not UTF-8: 400 `Bad Request`; an optional value's empty value is passed on as `""` |
| each route value `Int`, in order: the decoded text, optional `-`, ASCII digits, `Int` range (leading zeros allowed); a `String` takes the decoded text as is; an `Optional` slot is `None` for `""` and otherwise converts as its required type | adapter | 400 `Bad Request` |
| `Json[T]` bodies only: exactly one `Content-Type` whose media type is `application/json` | adapter, from the verdict `App.handle` appends | 415 `Unsupported Media Type` |
| `Json[T]` bodies only: body length at most 1,048,576 bytes | adapter | 413 `Content Too Large` |
| `WithHeaders[B]` bodies and the `Headers` slot (`get`, `delete`) only: the fields rebuilt through `Headers.add` | adapter | 500 `Internal Server Error` (only an in-memory `Headers` built through the `_fields` gap fails) |
| body conversion: `B.from_body(body)` for an ordinary body (for `Json[T]`: parse and `from_json`); for a `WithHeaders[B]` carrier, `_from_parts`, which calls the inner `B.from_body` | adapter | 400 `Bad Request`, handler not called |
| handler call (the only step in the handler `try`) | adapter, `_handler_error[E]` | `T.to_error_response()` if the declared `T` conforms to `ToErrorResponse`, else 500 `Internal Server Error`, error dropped unread |
| result: `String` or `StaticString` → 200 text with no fields; `R: ToResponse` → `to_response()` once | adapter | non-raising; a `Json[T]` serialization failure is the fixed 500 without fields and without `ToErrorResponse` |

A raise escaping `invoke` is 500, never 400. 400, 404 and 405 run neither the handler nor a conversion. A matched **raw** route runs none of the extraction steps and decodes nothing: `_raw_request` rebuilds a fresh `Request` (method, path, query, body and header fields) and moves it into the handler, which answers with any status; its errors follow the same `ToErrorResponse`/500 rule, and a rebuild failure is the fixed 500.

Error opt-in (M2-013): a raised value converts only when the handler's declared error type declares `ToErrorResponse` in its own struct declaration (directly, through a refining trait, or as a documented conditional conformance). Bare `raises` (`Error`) is never mapped by message; a raised `ToResponse`-only type, a same-named method without the conformance and a `Variant` of opted-in types are 500. A returned value converts with `to_response`, a raised one with `to_error_response`. Undocumented `__extension` behavior is not a supported opt-in.

Transport through the box: an adapter receives `List[String]` raw arguments, in this order: the route values if the route has any (the path captures left to right, then the query values in the literal's order, already decoded; an absent or empty optional value is `""`, which no decoded value is, so it needs no second channel), then the body, then, on a JSON body route, the verdict (`"1"` or `""`), then, on a carrier route (`WithHeaders[B]`) or a `Headers` route, each header field's name and value. The JSON adapters answer 415 unless the arguments are exactly (route values,) body and verdict `"1"`, or, for a carrier, the verdict `"1"` at that index followed by an even count. A raw route receives `method`, `path`, `query`, `body`, then each header field's name and value. Typed routes without a carrier or a `Headers` slot receive no header strings. A carrier or `Headers` route copies each field twice per request (into the arguments, then into the rebuilt `Headers`), as raw routes do. A state never travels in the arguments; it is bound with the handler. Each route value costs one decoded copy per request, and a `String` value a second copy at its slot; each query placeholder costs one scan of the query.

### Storage and ownership

- **Handler box `_Erased`:** each route owns one move-only `_Erased`, whose only field is a `ThinAllocation[_Header]` holding the invoke trampoline, the drop function and the erased pointer to the handler value (an `OwnedPointer[F]` allocation). One `__init__[F, call: _Call[F]]` instantiates both functions for the same `F`, so pairing is compiler- or construction-checked (the ownership oracle in `tests/test_handler_storage.mojo` counts live values). Cost: the handler cell and its header, both allocated at registration; nothing per request. `App` is `Movable`, not `Copyable`; `App.handle` iterates routes by index because 1.1.0's `for x in list` needs a `Copyable` element. Copying an `App` would need clone support back, with its own oracle.
- **State:** `State[S]` holds a sealed `_Shared[S]` (one `ThinAllocation` header with an atomic count and an `OwnedPointer[S]`; two allocations per `State`, none per request). `State(value)` moves the value in, `.copy()` shares it, `state[]` is read-only through every handle, and a reference from it is interior to its handle (using it after the handle is reassigned or moved is a compile error). Each registration copies the handle once into the route's `_Bound[H, S]`; requests borrow it. The value is dropped once, after the last handle. Read-only is shallow: interior mutability in `S` is the application's.
- **The State guarantee (M3-004), verbatim:** **Muntin must not introduce a Muntin-specific safe-code path that lets one `State` alias replace, mutate, swap, or prematurely destroy the shared payload observed through another alias. Toolchain-wide primitives that can violate the same property for standard-library types and existing Muntin storage (origin rebind, forged allocation or header replacement, `memmove`, stdlib-private fields) are outside this guarantee and are pinned as Mojo 1.1.0 toolchain-wide soundness gaps.** The pins are `tests/toolchain_soundness_gaps` (must build).
- **Same boundary for `_Erased`:** the ordinary safe-code paths Muntin exposes are closed (its own fields give no access; its pointer helpers are named `_unsafe_*`); the stdlib's private fields (`ThinAllocation._ptr`), the deprecated `memmove`, forged `alloc` headers and `rebind` reach it as they reach std types.
- **The one rebind** (M3-015): `comptime if A == Int` does not refine `A`, so a parsed `Int`, a rebuilt `Request` or `Headers` and a text result reach their generic type through `rebind_var`, which also accepts a different type of the same layout (`tests/registration_known_gaps/rebind_var_layout_twins.mojo`). It is called only in `_as[T, A]` in `app.mojo`, right after `comptime assert A == T` (exact for origin-free types; for a `StaticString` result exactness comes from the `where` clause), and `tests/registration_api_fail/rebind_rejects_layout_twin.mojo` pins that the helper rejects a twin.
- **Unsafe confinement:** `check_unsafe.sh` fails if any other `src/muntin` module names an unsafe pointer/ownership operation or the boxes' fields, imports anything but `_Erased` or `_Shared` from the storage module, or if the package root names the storage module or `_Erased`, or if the storage module imports anything but `std` and `.http` or names request, body or conversion names; and unless `src/muntin` contains exactly one `rebind_var[` (storage module, comments and docstrings included), in `app.mojo` on the line after `comptime assert A == T`, with no other module naming `rebind_var`. It is a confinement guard, not a safety proof, and does not check `tests/`.

### Headers

- `muntin.Headers` is an ordered list of fields: original casing, repeated names kept in order, ASCII case-insensitive `get` (`Optional[String]`, first value) and `get_all`; `len`, `name(i)`, `value(i)`. `add` appends and `set` removes every same-name field, then appends; both raise on a name that is not an RFC 9110 token or a value with a control byte (other than HTAB) or SP/HTAB at either end. Copies are explicit (`.copy()`).
- `Request.headers` is what the backend received; `Response.headers` is empty from `Response(status, body)` and `Response.text`. Muntin adds no default field: `String` results and `Response.text` set none, and `Json[T]` results set exactly `Content-Type: application/json`.
- Raw handlers read `req.headers` and set fields on their `Response`. Typed `post` handlers read them through a `WithHeaders[B]` body (M3-013): `input.headers` is the request's `Headers`, every field in order with its casing, repeats and empty values, and `input.body` is converted by `B.from_body`; `take_body(deinit self)` moves the body out. Muntin chooses no status for the fields `input.headers` exposes and gives them no meaning (a missing field is `None`; a value's status is the handler's error type to choose). Two existing checks still answer before the handler: a `Json[T]` body's `Content-Type` verdict (415), and the rebuild of a field an in-memory `Headers` holds invalidly (the fixed 500). The carrier composes with `State` and with `Json[T]`, and is the body on `put` and `patch` too. Typed `get` and `delete` handlers read them through a `Headers` parameter, last (M3-017): a fresh `Headers` rebuilt from the transported fields, which the handler borrows or owns, with the same semantics, no status chosen for a field and the same rebuild 500; changing it changes no `Request`. The JSON `Content-Type` check is not header extraction: it is a fixed verdict `App.handle` computes for `Json[T]` body routes only, carried or not.
- Known gap: `headers._fields` is reachable by name and bypasses `add` (`tests/headers_known_gaps`); the Flare adapter re-checks every outgoing field, and a carrier or `Headers` route answers such a request field with the fixed 500.

### JSON

- `Json[T]` conforms to `FromBody` when `T: FromJson` and to `ToResponse` when `T: ToJson` (conditional conformance); `take(deinit self)` moves the value out. `Json(value, *, status=200)` holds the result's status in a private field until `to_response`, which applies it only when `write_json` succeeds (a serialization failure stays the fixed 500); a body built by `from_body` holds the default, which nothing on the request path reads, and Muntin does not validate the value (M3-029, decided by [M3-028](history/architecture-decisions.md#json-response-status-decision-m3-028)). Applications map fields by hand in `from_json(JsonValue)` and `write_json(mut JsonWriter)`; there is no derived codec.
- The codec is Muntin's: the RFC 8259 grammar, strictly, with Muntin's limits (duplicate member names, nesting deeper than 64, comments, trailing commas, leading zeros, `NaN`, a byte order mark and lone surrogates are 400; extra members are ignored). `JsonValue` is a read-only position in a compact tape held in `_Shared`; parsing is linear apart from a per-object name sort, and member lookup scans the object, so reading k fields of an m-member object costs O(k·m). `int()` is exact; `float()` goes through Mojo 1.1.0 `atof` (long literals raise, some values are 1 ulp off), and `String(Float64)` in the writer is not always round-trip; both are pinned toolchain gaps.
- Request rule: exactly one `Content-Type` field whose media type (text before any `;`, SP/HTAB trimmed) is `application/json`, compared ASCII case-insensitively; parameters are ignored; missing, duplicated, other and `+json` types are 415. Fixed 1 MiB cap (1,048,576 bytes accepted, one more is 413); the parser also raises above it, so a raw handler's `Json[T].from_body` never parses an unbounded body. At the cap one parse adds at most about 29 MB of memory (`[0,0,...]`), about 5 MB for typical records. Only `Json[T]` bodies have the check and the cap; application `FromBody` types need no `Content-Type` and have no Muntin cap. Backend limits apply first (Flare's default `max_body_size` is 10 MB).
- `TestClient.post(target, body)` (or `.put`, `.patch`) sends no fields, so a JSON body route answers it 415; a test sends the field with `headers=` (M3-011) or through `app.handle(Request(..., headers^))`.

### Flare adapter

Two handlers implement Flare's `Handler` and answer through one module-level function, `_serve_app(app, request)`, which converts, calls `App.handle`, converts back and applies the `HEAD` rule, and never routes: `MuntinHandler` owns an `App` (the adapter's tests and probes use it), and the private `_BorrowedHandler[origin]`, which `Server` uses, holds a `Pointer[App, origin]` to a borrowed one, as `TestClient` does. Policy (module docstring):

- method and request target (path plus query, undecoded) copied verbatim; body bytes decoded as UTF-8 with invalid sequences replaced by U+FFFD (binary bodies are not representable); version and peer dropped;
- request header fields rebuilt from Flare's public `HeaderMap.encode_to` and verified against `len()` and `get_all(name)` by position (a first-colon parse would misread a name containing `:`, which Flare v0.12.0 refuses over cleartext HTTP/2 but the check does not rely on; a value that is not UTF-8, which Flare passes through byte for byte over HTTP/2, fails the check); a field that fails the check or `Headers.add` is answered 400 before `App.handle`;
- response status, body and fields copied, reason left to Flare; fields go out in order except `Content-Length`, `Transfer-Encoding`, `Connection`, `Keep-Alive`, `Proxy-Connection`, `Upgrade`, `TE`, `Trailer` and every field a `Connection` value names; each field is re-checked with `Headers.add`, and a failure answers 500;
- `HEAD` (M3-027): for a request whose method is exactly `HEAD`, `_serve_app` takes the response it would send at every exit (`App.handle`'s answer, `to_flare_response`'s fixed 500, its own 400), removes the body and, unless the status is 1xx, 204, 205 or 304, adds `Content-Length` with the body's byte length. Both steps are the adapter's because Flare v0.12.0 sends a `HEAD` response's content in DATA frames over cleartext HTTP/2 and over HTTP/1.1 frames an empty 200, 205 or 304 body as `Content-Length: 0`; it honors a declared `Content-Length` beside an empty body on both, and over h2c sends no `content-length` when none is declared. The rule lives in `_serve_app`, not `to_flare_response`, which takes no method. Measured by `compat/flare/head/head_probe.mojo`.

Serving (M3-033, decided by [M3-032](history/architecture-decisions.md#serving-entrypoint-decision-m3-032); user-visible contract: `docs/DX.md` section 1) is `Server`, a public type of the adapter module, outside the package; Muntin core has no `app.run()` and no serving API. `Server(Movable)` holds one field, Flare's `HttpServer`. Its one initializer takes keyword-only `_host` and `_port` and is called by `Server.bind(host, port)`, the one public spelling; no initializer takes a Flare value, so no Flare type appears in `Server`'s signatures. The initializer raises `port out of range: <port>` outside 0 to 65535, before Flare's `UInt16` conversion and before the host is parsed, then binds `SocketAddr(IpAddr.parse(host), UInt16(port))` with Flare's default `ServerConfig` (`IpAddr.parse` is `inet_pton`: IP literals only). Flare's bind listens, so a client may connect once `bind` returns. A bind failure raises Flare's error; dropping the `Server` drops the `HttpServer`, which closes the listener. `port()` reads `local_addr()`. `serve(mut self, app: App)` borrows the `App` and calls Flare's single-worker `serve` on the calling thread with `_BorrowedHandler(app)`, and nothing else: the handler's pointer lives no longer than that call, which `app`'s borrow outlives. When Flare's `serve` raises, the raise propagates; when it returns, `serve` returns, with no policy of its own. Nothing Muntin exposes sets Flare's stop flag (`close()`/`drain()`, which their docs say are called from another thread), so on Flare v0.12.0 a return means the reactor stopped (a failed poll, which Flare records and answers by returning normally): `serve` returning does not distinguish a stop from that, and a `main` that does nothing after it can end with status 0. There is no graceful shutdown, signal handling (Flare installs no signal handler on the cleartext path, so SIGINT and SIGTERM end the process by their default action), worker count or backend configuration. `_BorrowedHandler` is not `Copyable`, which keeps Flare's multi-worker `serve` out of reach (`compat/flare/serve/server_handler_not_copyable.mojo`); that is a guard, not the reason for one thread. Application code that builds Flare's `HttpServer` around `MuntinHandler` itself is still unsupported.

`adapters/flare/test_server.mojo` and the loopback suite bind with `Server.bind("127.0.0.1", 0)` in the parent and fork a child that calls `server.serve(app)`, so readiness is `bind` returning, with no sleep or retry; the parent kills the child (SIGKILL, or SIGTERM and SIGINT in the stop tests, after the child restores their default disposition) and reaps it, and the child arms a 30 s `alarm`.

### Mojo 1.1.0 facts the design rests on

- A function type such as `def() -> String` is a trait, so stored handlers are thin function values; closures and storable capturing handlers do not convert to `_Call[F]` (`tests/spike_fail`, `state_fail/closure_handler_storage.mojo`).
- Parametric raises (`thin raises E`) infer the error type without overload ranking. An explicitly typed non-raising function value (`var f: def() thin -> String`) does not convert to it; spell it `def() thin raises Never -> String` (raw: `def(var Request) thin raises Never -> Response`) (`storage_fail/typed_thin_value_handler.mojo`).
- An explicitly typed function value with a borrowed parameter converts to no generic slot (`registration_fail/typed_value_to_owned_slot.mojo`), so typed values and helper parameters spell each request parameter `var` (`def(var Int) thin raises Never -> String`; a leading `State[S]` keeps its spelling). Plain `def` handlers convert either way.
- `rebind_var` checks layout, not the nominal type (`registration_known_gaps/rebind_var_layout_twins.mojo`, `registration_fail/rebind_var_layout_mismatch.mojo`).
- Generic `==` keeps an origin's mutability but not its identity (`registration_known_gaps/generic_equality_ignores_origin_identity.mojo`), and `Origin.equals` works only in `where` clauses (`registration_fail/origin_equality_not_in_comptime_if.mojo`); a `where` clause on an overload compares by identity at the call site, which is why the result rule is one.
- Reflection exposes struct fields but not function parameter names, so binding is positional; reflection has no constructor, so codecs are hand-mapped.
- Module-level variables do not compile and thin handlers cannot capture, so `State` is the only way a handler reads runtime data.
- There are no private fields and no existentials; `__extension` is undocumented and never part of the supported contract (`__extension Int(...)` is rejected and `StaticString` is an alias, but `__extension SIMD(...)` in a trait's own module does give `Int` that bound while `conforms_to(Int, ...)` stays false, which is why the body slot rejects `Int` by type equality).
- `ArcPointer.__getitem__` is mutable through any handle, which is why `State` uses `_Shared` (`tests/state_storage_known_gaps`).

### Other current limits and operational risks

Not implemented (candidates in `docs/SPEC.md` M3): graceful shutdown, signal handling, several serving threads, backend configuration (body size, timeouts, TLS) and host names for `Server` (revisit conditions in [M3-032](history/architecture-decisions.md#serving-entrypoint-decision-m3-032)), middleware, compile-time header names or a `FromHeaders` converter, methods other than `GET`, `HEAD` (answered by `GET` routes), `POST`, `PUT`, `PATCH` and `DELETE` (they select no route: 405 with `Allow` on a path some route matches, 404 elsewhere; `OPTIONS` included), an answer to `OPTIONS` itself or to a CORS preflight, 501 `Not Implemented` for those methods (405 or 404 instead is a deliberate departure from RFC 9110's recommended 501: [M3-030](history/architecture-decisions.md#method-not-allowed-decision-m3-030)), a registered `HEAD` or `TestClient.head`, a body on a typed `delete` handler (a raw one reads it), route values beyond two `Int`, `String`, `Optional[Int]` or `Optional[String]` values (three or more, a default in the literal, an empty value distinct from an absent one, optional path values, several values for one key, other types or a conversion trait, a named carrier that checks names, decoded query keys, a raw-text form in a typed handler), raw route values and non-`Response` raw results, bodies other than one required body on `POST`, `PUT` and `PATCH` (a `FromBody`, or a `WithHeaders[B]` around one; no bodyless typed handler on them), binary bodies, fallible conversions, application-level error mappers, logging of dropped errors, a configurable JSON cap, derived codecs, `+json`, top-level list results, schema/OpenAPI, streaming, performance work.

- Absolute-form targets (`http://host/path`) become the whole `path` and are 404.
- Over HTTP/1.1, Flare v0.12.0 frames every 304 with a `Content-Length`: a declared one, or else the body's length, so 0 for an empty body. A `HEAD` 304 therefore goes out with `Content-Length: 0`, which the adapter cannot remove, and a `HEAD` 205 too (0 is a 205's `GET` content length); over h2c neither carries a `content-length` ([M3-026](history/architecture-decisions.md#head-decision-m3-026), measured by `compat/flare/head/head_probe.mojo`).
- Over HTTP/1.1, with Flare v0.12.0's default HTTP/1.1 parser settings, Flare answers a method with any lowercase letter (`get`, `Get`, `delete`) with 400 before `App.handle`, which would answer it as any method no route has (405 on a path some route matches, 404 elsewhere); an unknown uppercase method (`FOO`) reaches `App.handle` and gets that answer ([M3-020](history/architecture-decisions.md#http-methods-decision-m3-020), [M3-030](history/architecture-decisions.md#method-not-allowed-decision-m3-030)).
- Static path segments are not checked for target bytes: `/hello world` compiles and matches in memory but never arrives over Flare, which rejects target bytes outside `!`..`~`.
- `main.mojo` uses `TestClient` because it builds in the default environment, which has no Flare; serving needs the `flare` environment (`examples/hello_server.mojo`).
- The localhost round trip and `test_server.mojo` need `fork(2)` (Windows is out of scope); a serving child exits only by a signal or the 30 s alarm, because Flare v0.12.0's `close()`/`drain()` need a second thread. Its first `/hello` request is slow on a cold start (about 26 s locally once, up to 64 s on macOS CI); look there before blaming routing if it flakes.
- The `flare` CI job rebuilds Flare's C/C++ FFI wrappers on every run (about a minute, no cache). Flare's `Request` is `Movable` with `List[UInt8]` bodies, so the adapter copies into Muntin's `String` types. Flare HTTP/3 is unavailable from the conda build.

### When M2 reopens

M2 is closed (M2-016); its contract is `docs/SPEC.md`, "M2 completion contract". Reopen it, rather than add an M3 item, when a toolchain upgrade changes what the contract rests on (overload resolution, parametric raises inference, `conforms_to` detection), when a design must change an M2 public signature or semantics instead of adding to them (the `Request(method, target, body)` initializer, the 400/404/500 boundary, a fallible `ToResponse`/`ToErrorResponse`), or when a statement DX labels proven stops passing its test. Exact conditions: [M2 closure (M2-016)](history/architecture-decisions.md#m2-closure-m2-016).

## Revisit index

If one of these pins changes (a must-fail fixture compiles, or `scripts/build_one.sh` says a known gap or toolchain gap no longer builds), reopen the linked decision rather than patching the test in isolation. The exact conditions are the record's "Revisit when" list.

| Pinned by | Record |
|---|---|
| `tests/spike_fail` (a fixture compiles) | [Handler storage decision (M2)](history/architecture-decisions.md#handler-storage-decision-m2), reconsideration thresholds; a toolchain change here is also an M2 reopen trigger ([M2 closure (M2-016)](history/architecture-decisions.md#m2-closure-m2-016)) |
| `tests/extraction_fail`; `tests/spike_fail/extension_int.mojo` (also the M2-005 `Int` type-equality guard) | [Argument extraction decision (M2-005)](history/architecture-decisions.md#argument-extraction-decision-m2-005) |
| `tests/response_fail` | [Typed response decision (M2-007)](history/architecture-decisions.md#typed-response-decision-m2-007) |
| `tests/error_fail` (`raising_twin_overloads.mojo`, `typed_error_to_widened_type.mojo`, `extraction_and_handler_in_one_try.mojo`, ...); `storage_fail/typed_thin_value_handler.mojo` | [Application-error decision (M2-010)](history/architecture-decisions.md#application-error-decision-m2-010) |
| `tests/error_response_fail` | [Error-response decision (M2-012)](history/architecture-decisions.md#error-response-decision-m2-012) |
| `tests/raw_fail` (`equal_parameter_lists.mojo` pins the selection rule raw handlers used until M3-015) | [Raw Request decision (M2-014)](history/architecture-decisions.md#raw-request-decision-m2-014); a selection change also reopens M2 ([M2 closure (M2-016)](history/architecture-decisions.md#m2-closure-m2-016)) |
| `tests/state_fail`; `tests/state_known_gaps/registrar_blind_mutation.mojo` (must build) | [Application state decision (M3-001)](history/architecture-decisions.md#application-state-decision-m3-001) |
| `tests/state_storage_fail`; `tests/state_storage_known_gaps` (must build); `tests/toolchain_soundness_gaps` (must build) | [State storage decision (M3-004)](history/architecture-decisions.md#state-storage-decision-m3-004) |
| `tests/headers_fail`; `tests/headers_known_gaps` (must build); `compat/flare/headers/flare_header_probe.mojo` | [Headers decision (M3-002)](history/architecture-decisions.md#headers-decision-m3-002) |
| `tests/json_fail`; `tests/json_known_gaps` (must build; `relaxed_result_bound.mojo` pins rejected candidate 4b, for which the record lists no separate revisit condition); `test_number_limits_on_mojo_1_1_0` and `test_float_rounding_gaps_on_mojo_1_1_0` in `tests/test_json.mojo` | [JSON codec decision (M3-008)](history/architecture-decisions.md#json-codec-decision-m3-008) |
| `tests/json_api_fail/positional_status.mojo` (compiles or loses its text: `Json`'s `status` became positional, or the initializer's signature changed) | [JSON response status decision (M3-028)](history/architecture-decisions.md#json-response-status-decision-m3-028) |
| a `get`, `post`, `put`, `patch` or `delete` overload beyond the eight arity overloads (slot arity 4 or more: two more overloads per method name) | [Several route values decision (M3-022)](history/architecture-decisions.md#several-route-values-decision-m3-022) (it answered M3-020's slot-arity condition for arity 3; three route values or another request part compete for arity 4), [HTTP methods decision (M3-020)](history/architecture-decisions.md#http-methods-decision-m3-020) (copying an overload set per method against a generic entrypoint) and [Registration structure decision (M3-014)](history/architecture-decisions.md#registration-structure-decision-m3-014) (headroom through slot arity 4, full candidate notes through slot arity 3); the note budget was measured in [Stateful raw handlers in production (M3-007)](history/architecture-decisions.md#stateful-raw-handlers-in-production-m3-007) and [Typed header access decision (M3-012)](history/architecture-decisions.md#typed-header-access-decision-m3-012) |
| a concurrent `App.handle` or a `Copyable` `App` | [Application state decision (M3-001)](history/architecture-decisions.md#application-state-decision-m3-001) (interior mutability in `S`) and [JSON codec decision (M3-008)](history/architecture-decisions.md#json-codec-decision-m3-008) (re-derive the cap) |
| `tests/testclient_headers_api_fail` (a fixture compiles: production `TestClient`'s spelling or ownership changed); `tests/headers_api_fail/request_headers_moved_in.mojo` (compiles: `Request` no longer takes headers by move, the premise the client follows) | [TestClient request headers decision (M3-010)](history/architecture-decisions.md#testclient-request-headers-decision-m3-010) (revisit conditions) and [TestClient request headers in production (M3-011)](history/architecture-decisions.md#testclient-request-headers-in-production-m3-011) (current fixtures and mutations) |
| `tests/header_access_fail` (the toolchain pins: `eleven_candidates_drop_a_note.mojo` loses its text, `generic_slot_does_not_refine.mojo` or `struct_level_assert.mojo` compiles); a registration-structure decision (made: M3-014); header access proposed for typed `get` handlers (decided: M3-016) | [Typed header access decision (M3-012)](history/architecture-decisions.md#typed-header-access-decision-m3-012) |
| `tests/with_headers_api_fail` (a fixture compiles: production `WithHeaders` became a `FromBody`, its body bound relaxed, or a carrier shape registers on `get` or before a route value); generic application code needing every body-slot type under one bound | [Typed header access decision (M3-012)](history/architecture-decisions.md#typed-header-access-decision-m3-012) (revisit conditions, the accepted cost) and [Typed header access in production (M3-013)](history/architecture-decisions.md#typed-header-access-in-production-m3-013) (current fixtures and mutations) |
| another injected kind proposed | [Application state decision (M3-001)](history/architecture-decisions.md#application-state-decision-m3-001) (one injected slot) and [Typed header access decision (M3-012)](history/architecture-decisions.md#typed-header-access-decision-m3-012) (headers kept out of the slot), and [Registration structure decision (M3-014)](history/architecture-decisions.md#registration-structure-decision-m3-014) (it still doubles the stateful family) |
| `tests/registration_fail` (a fixture compiles or loses its text: notes no longer counted per method name, a typed borrowed function value converts to a generic slot, `rebind_var` accepts a different layout, `Origin.equals` works in a `comptime if`, or an exact `StaticString` overload lets `String` through); `tests/registration_known_gaps` (must build: `rebind_var` stops accepting a layout twin, generic `==` starts telling an origin's identity apart, or safe code can no longer erase a local's origin); `header_access_fail/generic_slot_does_not_refine.mojo` or `state_fail/variadic_handler_type.mojo` compiles; documented conformance extensions for standard-library types; slot arity 4 with complete rejected-result diagnostics required, or slot arity 5 (past the cap); `state_known_gaps/registrar_blind_mutation.mojo` stops building (re-measure the builder, C3) | [Registration structure decision (M3-014)](history/architecture-decisions.md#registration-structure-decision-m3-014) |
| `tests/registration_api_fail` (a fixture compiles or loses its text: a typed borrowed `Int` value registers, the rule guard or the rebind helper stops rejecting, or an overload's `where` clause stops rejecting an immutable-origin result) | [Registration on generic-arity slots in production (M3-015)](history/architecture-decisions.md#registration-on-generic-arity-slots-in-production-m3-015) (current fixtures and mutations) and [Registration structure decision (M3-014)](history/architecture-decisions.md#registration-structure-decision-m3-014) (revisit conditions) |
| a toolchain change that lets an overload see how a caller spelled a type; a new slot kind (generic forwarding reaches it too) | [Registration structure amendment: generic forwarding (M3-015)](history/architecture-decisions.md#registration-structure-amendment-generic-forwarding-m3-015); the `Optional` kinds reached it unchanged ([Optional query values decision (M3-024)](history/architecture-decisions.md#optional-query-values-decision-m3-024)) |
| `tests/string_route_api_fail` (a fixture compiles or loses its text: a `String` shape's placeholder rule, two `String` values' placeholder count, `StaticString` becoming a route value, `String` binding as a `post` body, a `mut String` selecting an overload, or a typed borrowed `String` value converting); a backend that delivers a decoded target; applications needing the encoded text in a typed handler, lossy decoding, decoded keys, or control characters rejected; an application route-value type (several route values: decided, M3-022; optional values: decided, M3-024) | [Route-value decoding and String route values decision (M3-018)](history/architecture-decisions.md#route-value-decoding-and-string-route-values-decision-m3-018) |
| `tests/get_headers_api_fail` (a fixture compiles or loses its text: the `Headers` rule, its placeholder rules, its order after the `Request` and body rules, a `mut Headers` selecting an overload, a typed borrowed `Headers` value converting, or a `post` message for a `Headers` shape); `POST` without a body decided; the R1 transport changed; another request part beside the fields proposed (several route values: decided, M3-022) | [Typed get header access decision (M3-016)](history/architecture-decisions.md#typed-get-header-access-decision-m3-016) |
| `tests/methods_api_fail` (a fixture compiles or loses its text: a body on a typed `delete` handler, a bodyless typed `put` or `patch` (stateless or stateful), a shape-family message that stops naming the registration's method, or `TestClient.put`, `.patch` or `.delete` taking positional or copied header fields); a typed `DELETE` body, a method outside the five, `HEAD` or `OPTIONS`, or bodyless typed `post` handlers decided; a backend that changes how it delivers these methods or their bodies | [HTTP methods decision (M3-020)](history/architecture-decisions.md#http-methods-decision-m3-020) (`HEAD`: decided, [M3-026](history/architecture-decisions.md#head-decision-m3-026); 405 with `Allow`: decided, [M3-030](history/architecture-decisions.md#method-not-allowed-decision-m3-030); answering `OPTIONS` itself still deferred) |
| `tests/route_values_api_fail` (a fixture compiles or loses its text: a two-value placeholder message, three route values registering, a repeated query key registering, or a four-parameter handler selecting an overload); `registration_api_fail/immutable_origin_result_*_3.mojo` (an arity-3 overload's `where` clause stops rejecting); Mojo reflecting function parameter names; `std.reflection` gaining a constructor or swapped values reported in applications; three route values needed (optional query values: decided, M3-024); another request part proposed for `get`; the note cap or the per-name budget changed | [Several route values decision (M3-022)](history/architecture-decisions.md#several-route-values-decision-m3-022) |
| `tests/optional_values_api_fail` (a fixture compiles or loses its text: an optional value's placeholder message, an optional value at a path position registering, an `Optional` of another type becoming a route value, or an `Optional` registering as a `post` body); Mojo reflecting function parameter defaults or names; a schema or OpenAPI output decided; an empty value needed distinct from an absent one; several values for one key; an application route-value type or conversion trait decided; a backend that delivers a decoded target or drops empty query pairs | [Optional query values decision (M3-024)](history/architecture-decisions.md#optional-query-values-decision-m3-024) |
| `compat/flare/head/head_probe.mojo` (an observation changes: Flare sends content for `HEAD` over HTTP/1.1, stops sending it over h2c, stops honoring a declared `Content-Length` beside an empty body, or lets a 304 go out over HTTP/1.1 without `Content-Length`; or an observation through the adapter's `_serve_app` changes, which `adapters/flare/test_localhost_roundtrip.mojo`'s h2c `HEAD` cases also pin); a registered `HEAD`, `TestClient.head` or `OPTIONS` proposed (405 with `Allow`: decided, [M3-030](history/architecture-decisions.md#method-not-allowed-decision-m3-030)); streaming responses decided | [HEAD decision (M3-026)](history/architecture-decisions.md#head-decision-m3-026) |
| `tests/test_method_not_allowed.mojo` and the 405 cases in `adapters/flare/test_muntin_flare.mojo` and `adapters/flare/test_localhost_roundtrip.mojo` (a backend, or a Flare upgrade, drops or rewrites `Allow` or frames a `HEAD` 405 differently); `OPTIONS` or CORS preflight decided; 501 needed for a method Muntin does not implement (a generic method entry point, a registration name beyond the six); a registered `HEAD` decided; applications needing their own 405 or 404; a route index or another lookup structure | [Method not allowed decision (M3-030)](history/architecture-decisions.md#method-not-allowed-decision-m3-030) |
| `compat/flare/serve/workers_need_copyable.mojo` or `server_handler_not_copyable.mojo` (builds: Flare drops the `Copyable` requirement, `App` becomes `Copyable`, or the private handler does: revisit the guard, not concurrency); `server_positional_init.mojo` or `server_keyword_init.mojo` (builds: a positional initializer or public keyword names); `adapters/flare/test_server.mojo` (a bind, port, borrowed-`App` or signal observation changes); a stop the serving thread can request, a second serving thread, a second network backend, backend configuration, a published package, or one call that binds and serves | [Serving entrypoint decision (M3-032)](history/architecture-decisions.md#serving-entrypoint-decision-m3-032) |

## Request/Response ownership

`Request` and `Response` own their data. Do not optimize around zero-copy wire buffers if that leaks backend lifetimes into the public API; before changing the ownership model, measure the cost and record the concrete requirement that justifies more lifetime complexity.

## Flare policy

Flare is a candidate backend because it already provides a substantial Mojo networking stack, including server/client protocols and its own routing/handler facilities. Muntin must not simply re-export those application abstractions.

Allowed inside the Flare adapter:

- Flare server/bootstrap APIs;
- conversion from Flare request data into Muntin request data/views;
- conversion from Muntin responses into Flare responses;
- transport lifecycle integration;
- backend-specific optimizations hidden behind the adapter.

Not allowed in durable Muntin public APIs:

- Flare `Request`/`Response` types;
- Flare `Router` as Muntin's routing contract;
- Flare middleware types as Muntin's middleware contract;
- Flare extractors as Muntin's only extraction model;
- Flare reactor/cancellation/runtime types in normal application handlers.

A pinned Flare version is required once M1 depends on it. Track `main` only for explicit compatibility investigation, never as the default reproducible dependency.

## Adapter translation policy

It is acceptable for `muntin/adapters/flare` to contain inelegant conversion code if that keeps the public/core model stable. Do not contort the Muntin API merely to make one adapter thin.

Conversely, if the adapter repeatedly copies large bodies or cannot express a common feature without severe cost, treat that as evidence for a focused core abstraction change. Measure and document the tradeoff first.

## Architecture tests

At minimum, tests should establish:

1. an application route is dispatched through the Muntin-owned app model;
2. the in-memory backend can drive that route without Flare or sockets;
3. core/public modules do not import Flare;
4. a real localhost request traverses Flare -> adapter -> Muntin app -> adapter -> Flare;
5. the same application handler can be exercised by both in-memory and Flare paths without changing its public signature.

## Architecture decision threshold

Record a decision before:

- exposing any third-party type publicly;
- introducing a custom runtime/executor/task model;
- making a transport mandatory;
- adding unsafe memory/lifetime machinery to a public contract;
- changing request/response ownership semantics;
- changing the backend seam in a way that breaks adapters;
- making a provisional DX example a frozen compatibility promise.
