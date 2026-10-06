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

Toolchain: Mojo 1.1.0 (8189361e) via pixi 0.81.0, pinned by `pixi.lock`; `scripts/check.sh` fails on any other Mojo version, so an upgrade is a deliberate change to the script and the docs. Flare v0.11.0 (commit `59bda50f`) exists only in the separate `flare` pixi environment.

### Modules and public surface

```text
src/muntin/__init__.mojo          exports App, FromBody, Headers, Request, Response, ToErrorResponse, ToResponse,
                                  FromJson, Json, JsonValue, JsonWriter, ToJson, State, WithHeaders
src/muntin/http.mojo              Request (method, path, query, body, headers), Response (status, body, headers),
                                  Headers, ToResponse, ToErrorResponse
src/muntin/body.mojo              FromBody
src/muntin/headers_body.mojo      WithHeaders[B] (post body carrier with the request's fields); private marker _HeaderCarrier
src/muntin/app.mojo               App: route table, the get/post overloads (one per request-slot arity), App.handle;
                                  private registration rules, slot extraction, adapters and the one rebind helper
src/muntin/state.mojo             State[S]; private marker _InjectedState
src/muntin/json.mojo              Json[T], FromJson, ToJson, JsonValue, JsonWriter; private parser, limits, _JsonBody
src/muntin/_handler_storage.mojo  private _Erased (handler box) and _Shared (State/JSON box); the only module with unsafe operations
src/muntin/testing.mojo           TestClient: in-memory backend (get, post)
adapters/flare/muntin_flare.mojo  Flare adapter (MuntinHandler), outside core, flare environment only
```

The public surface is the exported names and `muntin.testing.TestClient`. `_`-prefixed names are reachable from application code on Mojo 1.1.0 (no private fields) but are not API.

### Backend seam

- The only seam is `App.handle(self, request: Request) -> Response`. A backend builds a Muntin `Request`, calls `handle`, and converts the `Response` back. There is no backend trait until a second backend exists (A7).
- `TestClient[origin: Origin[mut=False]]` holds a `Pointer[App, origin]`: it borrows the `App` immutably, so `TestClient(app)` copies nothing, and `App.handle` takes `self` read-only. `TestClient.get(target)` and `.post(target, body)` send no header fields; `headers=` (keyword-only, defaulted, moved in) sends the given fields unchanged (M3-011). The client builds `Request(method, target, body, headers^)` and calls `App.handle`, nothing else.
- `Request(method, target, body, headers^)` (body and headers defaulted) splits `target` at its first `?` into `path` (all that routes match) and `query` (raw, undecoded, `""` when absent). Both backends pass the raw target, so the split is the same for both. `Request` and `Response` own `String` data; no backend type or buffer lifetime reaches application code.
- `scripts/check_boundaries.sh` fails if `src/muntin` imports or mentions Flare or socket modules (A2). `scripts/check_unsafe.sh` confines unsafe operations to `_handler_storage.mojo` and `rebind_var` to one helper in `app.mojo` (below).
- `App.handle` is never called concurrently today: Flare's multi-worker `serve` needs a `Copyable` handler and `App` is move-only. That bounds JSON parse memory (one parse at a time per `App`) and makes interior mutability in a `State` value single-threaded; a concurrent backend or a `Copyable` `App` reopens both (revisit index).

### Registration surface

`App.get` and `App.post` have six overloads each: one per request-slot arity (0, 1 or 2), stateless and stateful (M3-015). A request slot is a handler parameter that comes from the request. The stateful family takes a fixed leading `State[S]`, which is not a slot, and the state as the registration's second argument, so the argument count separates the families and no two overloads of a method accept the same handler. Every slot is a generic `var A` whose kind is decided at compile time from its type alone: an `Int` route value, a body (a `FromBody`, possibly move-only, or a `WithHeaders[B2]` carrier), the raw `Request`, or, rejected by the rules, a `State` or a type of no kind. Every handler type is `thin raises E` with `E: Deinitable` inferred (`Never` for a non-raising handler, `Error` for `raises`, the application's `T` for `raises T`). The result `R` is generic and accepted only through `where (R == String or R == StaticString or conforms_to(R, ToResponse))` on every overload, which the compiler checks by identity at the call site.

| Method | Stateless (`app.m[route](handler)`) | Stateful (`app.m[route](handler, state)`) | Results |
|---|---|---|---|
| `get` | `def()`, `def(Int)` | `def(State[S])`, `def(State[S], Int)` | `String`, `StaticString`, or `R: ToResponse` |
| `post` | `def(B)`, `def(Int, B)` | `def(State[S], B)`, `def(State[S], Int, B)` | same |
| `get`, `post` | raw `def(Request)` | raw `def(State[S], Request)` | `Response` only |

- **Route literals** are compile-time strings checked at the registration call: a leading `/`, static or `{name}` segments, an optional query part of `{key}` items joined by `&` (keys visible ASCII, none of `{}=&?#`). The placeholder count must equal the handler's route-value count (zero or one `Int`); raw routes declare none. Names are never compared with handler parameter names: binding is positional (route values in the literal's order, then the body). Literals are stored and split as runtime `String`s per request.
- **Disjointness** (M2-005): a slot is an `Int` route value by type equality, never a body; an ordinary body is an application type conforming to `FromBody`. `Json[T]` is a body or a result like any other, so JSON adds no shape.
- **Header carrier in the body slot** (M3-013): the body kind is `FromBody` or the private `_HeaderCarrier`, so `WithHeaders[B]` with `B: FromBody` is a body without being a `FromBody`, and the `FromBody` rule keeps its message. `FromBody` therefore does not name every type a `post` body slot accepts (the accepted cost). `get` takes no body, so typed `get` handlers read no fields and use the raw `get`.
- **One injected slot** (M3-001): a handler takes state exactly when its registration passes a second argument, a `State[S]`; it is then the first parameter, and the rest is one stateless shape. Argument count separates the two families. The slot is registration-bound; M3-012 keeps request header fields out of it (they travel in the body slot, above). A second injected kind, request-scoped injection included, needs its own decision, because a second injected kind doubles the stateful family (M3-014).
- **Rules guard the adapter** (M3-015): one ordered rule function (`_rule`) holds every registration rule except the result's. `_check` states each rule as a compile-time assert with Muntin's message, and `_admits`, the same rules as one Bool, guards the adapter's instantiation: without the guard Mojo 1.1.0 reports the adapter's own failure before the rule's message (`tests/registration_api_fail/slot_misuse_names_the_rule.mojo`). If the Bool ever rejects a shape the asserts accept, the guard's `else` aborts at registration instead of leaving the route unregistered. Rules that had a message before M3-015 keep it; new ones name the method.
- **Raw handlers** select the one-slot overload like any other shape: `Request` is a slot kind, and the rule requires `Response` as the result and no placeholder.
- **Diagnostics:** a shape that selects an overload and breaks a rule reports the rule, `constraint failed: <rule>`; the primary line is `function instantiation failed` at the enclosing function, with the registration call in the next note. A call that selects none (more than two slots; with the state passed, a `State` that is owned, `mut`, a plain value or not first; a result outside the `where` clause) is `no matching method` with the six candidates' notes; a rejected result's note is `violated constraint` and the clause. But when the call does not let the compiler decide the clause, the error is `invalid call to '<method>': lacking evidence to prove correctness` instead. That happens for a result with a local's immutable origin (`origin_text[ImmOrigin(origin_of(s))]`), and for a forwarding helper's generic result whose own `where` is neither one branch of the clause nor the whole clause (no `where`, or a partial disjunction such as `where (R == String or R == StaticString)`) (`tests/registration_api_fail/local_origin_result_rejected.mojo`, `generic_result_disjunction_lacks_evidence.mojo`, `generic_result_without_where_lacks_evidence.mojo`). A typed function value with a borrowed `Int` slot fails before any overload is chosen (`TODO: function type conversions between closures not supported yet`).
- **Arity budget:** Mojo 1.1.0 prints at most ten notes per diagnostic, counted per method name (`tests/header_access_fail/eleven_candidates_drop_a_note.mojo`, `tests/registration_fail/notes_are_per_method.mojo`). Slot arity 3 would make eight overloads per method with every candidate note printed; slot arity 4 makes ten, where a rejected result loses one candidate note (an accepted cost); slot arity 5 is past the cap.

### Request handling

Routes are a list scanned in registration order; the first route whose method and path segments match handles the request and never falls through, even when it answers 400. The query takes no part in selection. On a typed route, each step runs only if the previous one passed:

| Step | Where | Failure |
|---|---|---|
| method + path match (static segments byte-equal, `{name}` one non-empty segment) | `App.handle` | 404 `Not Found`, nothing converted |
| query value: pairs split on `&`, key/value at the first `=`, byte-equal keys, no percent-decoding, `+` not a space | `App.handle`, its own `try` | missing, duplicated, empty or invalid: 400 `Bad Request` |
| route value `Int`, on routes with one: optional `-`, ASCII digits, `Int` range (leading zeros allowed) | adapter | 400 `Bad Request` |
| `Json[T]` bodies only: exactly one `Content-Type` whose media type is `application/json` | adapter, from the verdict `App.handle` appends | 415 `Unsupported Media Type` |
| `Json[T]` bodies only: body length at most 1,048,576 bytes | adapter | 413 `Content Too Large` |
| `WithHeaders[B]` bodies only: the fields rebuilt through `Headers.add` | adapter | 500 `Internal Server Error` (only an in-memory `Headers` built through the `_fields` gap fails) |
| body conversion: `B.from_body(body)` for an ordinary body (for `Json[T]`: parse and `from_json`); for a `WithHeaders[B]` carrier, `_from_parts`, which calls the inner `B.from_body` | adapter | 400 `Bad Request`, handler not called |
| handler call (the only step in the handler `try`) | adapter, `_handler_error[E]` | `T.to_error_response()` if the declared `T` conforms to `ToErrorResponse`, else 500 `Internal Server Error`, error dropped unread |
| result: `String` or `StaticString` → 200 text with no fields; `R: ToResponse` → `to_response()` once | adapter | non-raising; a `Json[T]` serialization failure is the fixed 500 without fields and without `ToErrorResponse` |

A raise escaping `invoke` is 500, never 400. 400 and 404 run neither the handler nor a conversion. A matched **raw** route runs none of the extraction steps: `_raw_request` rebuilds a fresh `Request` (method, path, query, body and header fields) and moves it into the handler, which answers with any status; its errors follow the same `ToErrorResponse`/500 rule, and a rebuild failure is the fixed 500.

Error opt-in (M2-013): a raised value converts only when the handler's declared error type declares `ToErrorResponse` in its own struct declaration (directly, through a refining trait, or as a documented conditional conformance). Bare `raises` (`Error`) is never mapped by message; a raised `ToResponse`-only type, a same-named method without the conformance and a `Variant` of opted-in types are 500. A returned value converts with `to_response`, a raised one with `to_error_response`. Undocumented `__extension` behavior is not a supported opt-in.

Transport through the box: an adapter receives `List[String]` raw arguments, in this order: the one route value if the route has one (the path capture or the query value, never both), then the body, then, on a JSON body route, the verdict (`"1"` or `""`), then, on a carrier route (`WithHeaders[B]`), each header field's name and value. The JSON adapters answer 415 unless the arguments are exactly (route value,) body and verdict `"1"`, or, for a carrier, the verdict `"1"` at that index followed by an even count. A raw route receives `method`, `path`, `query`, `body`, then each header field's name and value. Typed routes without a carrier receive no header strings. A carrier route copies each field twice per request (into the arguments, then into the rebuilt `Headers`), as raw routes do. A state never travels in the arguments; it is bound with the handler.

### Storage and ownership

- **Handler box `_Erased`:** each route owns one move-only `_Erased`, whose only field is a `ThinAllocation[_Header]` holding the invoke trampoline, the drop function and the erased pointer to the handler value (an `OwnedPointer[F]` allocation). One `__init__[F, call: _Call[F]]` instantiates both functions for the same `F`, so pairing is compiler- or construction-checked (the ownership oracle in `tests/test_handler_storage.mojo` counts live values). Cost: the handler cell and its header, both allocated at registration; nothing per request. `App` is `Movable`, not `Copyable`; `App.handle` iterates routes by index because 1.1.0's `for x in list` needs a `Copyable` element. Copying an `App` would need clone support back, with its own oracle.
- **State:** `State[S]` holds a sealed `_Shared[S]` (one `ThinAllocation` header with an atomic count and an `OwnedPointer[S]`; two allocations per `State`, none per request). `State(value)` moves the value in, `.copy()` shares it, `state[]` is read-only through every handle, and a reference from it is interior to its handle (using it after the handle is reassigned or moved is a compile error). Each registration copies the handle once into the route's `_Bound[H, S]`; requests borrow it. The value is dropped once, after the last handle. Read-only is shallow: interior mutability in `S` is the application's.
- **The State guarantee (M3-004), verbatim:** **Muntin must not introduce a Muntin-specific safe-code path that lets one `State` alias replace, mutate, swap, or prematurely destroy the shared payload observed through another alias. Toolchain-wide primitives that can violate the same property for standard-library types and existing Muntin storage (origin rebind, forged allocation or header replacement, `memmove`, stdlib-private fields) are outside this guarantee and are pinned as Mojo 1.1.0 toolchain-wide soundness gaps.** The pins are `tests/toolchain_soundness_gaps` (must build).
- **Same boundary for `_Erased`:** the ordinary safe-code paths Muntin exposes are closed (its own fields give no access; its pointer helpers are named `_unsafe_*`); the stdlib's private fields (`ThinAllocation._ptr`), the deprecated `memmove`, forged `alloc` headers and `rebind` reach it as they reach std types.
- **The one rebind** (M3-015): `comptime if A == Int` does not refine `A`, so a parsed `Int`, a rebuilt `Request` and a text result reach their generic type through `rebind_var`, which also accepts a different type of the same layout (`tests/registration_known_gaps/rebind_var_layout_twins.mojo`). It is called only in `_as[T, A]` in `app.mojo`, right after `comptime assert A == T` (exact for origin-free types; for a `StaticString` result exactness comes from the `where` clause), and `tests/registration_api_fail/rebind_rejects_layout_twin.mojo` pins that the helper rejects a twin.
- **Unsafe confinement:** `check_unsafe.sh` fails if any other `src/muntin` module names an unsafe pointer/ownership operation or the boxes' fields, imports anything but `_Erased` or `_Shared` from the storage module, or if the package root names the storage module or `_Erased`, or if the storage module imports anything but `std` and `.http` or names request, body or conversion names; and unless `src/muntin` contains exactly one `rebind_var[` (storage module, comments and docstrings included), in `app.mojo` on the line after `comptime assert A == T`, with no other module naming `rebind_var`. It is a confinement guard, not a safety proof, and does not check `tests/`.

### Headers

- `muntin.Headers` is an ordered list of fields: original casing, repeated names kept in order, ASCII case-insensitive `get` (`Optional[String]`, first value) and `get_all`; `len`, `name(i)`, `value(i)`. `add` appends and `set` removes every same-name field, then appends; both raise on a name that is not an RFC 9110 token or a value with a control byte (other than HTAB) or SP/HTAB at either end. Copies are explicit (`.copy()`).
- `Request.headers` is what the backend received; `Response.headers` is empty from `Response(status, body)` and `Response.text`. Muntin adds no default field: `String` results and `Response.text` set none, and `Json[T]` results set exactly `Content-Type: application/json`.
- Raw handlers read `req.headers` and set fields on their `Response`. Typed `post` handlers read them through a `WithHeaders[B]` body (M3-013): `input.headers` is the request's `Headers`, every field in order with its casing, repeats and empty values, and `input.body` is converted by `B.from_body`; `take_body(deinit self)` moves the body out. Muntin chooses no status for the fields `input.headers` exposes and gives them no meaning (a missing field is `None`; a value's status is the handler's error type to choose). Two existing checks still answer before the handler: a `Json[T]` body's `Content-Type` verdict (415), and the rebuild of a field an in-memory `Headers` holds invalidly (the fixed 500). The carrier composes with `State` and with `Json[T]`. Typed `get` handlers read no fields; a `get` route that needs them is raw. The JSON `Content-Type` check is not header extraction: it is a fixed verdict `App.handle` computes for `Json[T]` body routes only, carried or not.
- Known gap: `headers._fields` is reachable by name and bypasses `add` (`tests/headers_known_gaps`); the Flare adapter re-checks every outgoing field, and a carrier route answers such a request field with the fixed 500.

### JSON

- `Json[T]` conforms to `FromBody` when `T: FromJson` and to `ToResponse` when `T: ToJson` (conditional conformance); `take(deinit self)` moves the value out. Applications map fields by hand in `from_json(JsonValue)` and `write_json(mut JsonWriter)`; there is no derived codec.
- The codec is Muntin's: the RFC 8259 grammar, strictly, with Muntin's limits (duplicate member names, nesting deeper than 64, comments, trailing commas, leading zeros, `NaN`, a byte order mark and lone surrogates are 400; extra members are ignored). `JsonValue` is a read-only position in a compact tape held in `_Shared`; parsing is linear apart from a per-object name sort, and member lookup scans the object, so reading k fields of an m-member object costs O(k·m). `int()` is exact; `float()` goes through Mojo 1.1.0 `atof` (long literals raise, some values are 1 ulp off), and `String(Float64)` in the writer is not always round-trip; both are pinned toolchain gaps.
- Request rule: exactly one `Content-Type` field whose media type (text before any `;`, SP/HTAB trimmed) is `application/json`, compared ASCII case-insensitively; parameters are ignored; missing, duplicated, other and `+json` types are 415. Fixed 1 MiB cap (1,048,576 bytes accepted, one more is 413); the parser also raises above it, so a raw handler's `Json[T].from_body` never parses an unbounded body. At the cap one parse adds at most about 29 MB of memory (`[0,0,...]`), about 5 MB for typical records. Only `Json[T]` bodies have the check and the cap; application `FromBody` types need no `Content-Type` and have no Muntin cap. Backend limits apply first (Flare's default `max_body_size` is 10 MB).
- `TestClient.post(target, body)` sends no fields, so a JSON body route answers it 415; a test sends the field with `headers=` (M3-011) or through `app.handle(Request(..., headers^))`.

### Flare adapter

`MuntinHandler` owns an `App` and implements Flare's `Handler`; its `serve` converts, calls `App.handle` and converts back, and never routes. Policy (module docstring):

- method and request target (path plus query, undecoded) copied verbatim; body bytes decoded as UTF-8 with invalid sequences replaced by U+FFFD (binary bodies are not representable); version and peer dropped;
- request header fields rebuilt from Flare's public `HeaderMap.encode_to` and verified against `len()` and `get_all(name)` by position (over cleartext HTTP/2 a name may contain `:`, which a first-colon parse would misread); a field that fails the check or `Headers.add` is answered 400 before `App.handle`;
- response status, body and fields copied, reason left to Flare; fields go out in order except `Content-Length`, `Transfer-Encoding`, `Connection`, `Keep-Alive`, `Proxy-Connection`, `Upgrade`, `TE`, `Trailer` and every field a `Connection` value names; each field is re-checked with `Headers.add`, and a failure answers 500.

Serving is test-fixture code only: `adapters/flare/test_localhost_roundtrip.mojo` binds in the parent, forks a child that serves `MuntinHandler`, and kills it with SIGKILL (the child also arms a 30 s `alarm`). There is no `app.run()` or other public lifecycle API, and application code that imports Flare's `HttpServer` and `MuntinHandler` itself is unsupported.

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

Not implemented (candidates in `docs/SPEC.md` M3): `app.run()`/lifecycle, middleware, typed header access on `get` (it stays raw), compile-time header names or a `FromHeaders` converter, methods other than `GET`/`POST` (they are 404), route values other than one `Int` (no `String`, several, path and query together, optional/default, percent-decoding), raw route values and non-`Response` raw results, bodies other than one required body on `POST` (a `FromBody`, or a `WithHeaders[B]` around one), binary bodies, fallible conversions, application-level error mappers, logging of dropped errors, a configurable JSON cap, derived codecs, `+json`, `Json(value, status=)`, top-level list results, schema/OpenAPI, streaming, performance work.

- Absolute-form targets (`http://host/path`) become the whole `path` and are 404.
- Static path segments are not checked for target bytes: `/hello world` compiles and matches in memory but never arrives over Flare, which rejects target bytes outside `!`..`~`.
- `main.mojo` imports `muntin.testing` only because `app.run()` does not exist.
- The localhost round trip needs `fork(2)` (Windows is out of scope); the child exits only by SIGKILL or the 30 s alarm, because v0.11.0's `close()`/`drain()` need a second thread. Its first `/hello` request is slow on a cold start (about 26 s locally once, up to 64 s on macOS CI); look there before blaming routing if it flakes.
- The `flare` CI job rebuilds Flare's C/C++ FFI wrappers on every run (about a minute, no cache). Flare v0.11.0's old server spellings (`bind_many`, `serve_tls`, ...) are shims removed in v0.12: use `HttpServer.bind`/`serve`. Flare's `Request` is `Movable` with `List[UInt8]` bodies, so the adapter copies into Muntin's `String` types. Flare HTTP/3 is unavailable from the conda build.

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
| a `get` or `post` overload beyond the six arity overloads (slot arity 3 or more) | [Registration structure decision (M3-014)](history/architecture-decisions.md#registration-structure-decision-m3-014) (headroom through slot arity 4, full candidate notes through slot arity 3); the note budget was measured in [Stateful raw handlers in production (M3-007)](history/architecture-decisions.md#stateful-raw-handlers-in-production-m3-007) and [Typed header access decision (M3-012)](history/architecture-decisions.md#typed-header-access-decision-m3-012) |
| a concurrent `App.handle` or a `Copyable` `App` | [Application state decision (M3-001)](history/architecture-decisions.md#application-state-decision-m3-001) (interior mutability in `S`) and [JSON codec decision (M3-008)](history/architecture-decisions.md#json-codec-decision-m3-008) (re-derive the cap) |
| `tests/testclient_headers_api_fail` (a fixture compiles: production `TestClient`'s spelling or ownership changed); `tests/headers_api_fail/request_headers_moved_in.mojo` (compiles: `Request` no longer takes headers by move, the premise the client follows) | [TestClient request headers decision (M3-010)](history/architecture-decisions.md#testclient-request-headers-decision-m3-010) (revisit conditions) and [TestClient request headers in production (M3-011)](history/architecture-decisions.md#testclient-request-headers-in-production-m3-011) (current fixtures and mutations) |
| `tests/header_access_fail` (the toolchain pins: `eleven_candidates_drop_a_note.mojo` loses its text, `generic_slot_does_not_refine.mojo` or `struct_level_assert.mojo` compiles); a registration-structure decision (made: M3-014); header access proposed for typed `get` handlers (decided: M3-016) | [Typed header access decision (M3-012)](history/architecture-decisions.md#typed-header-access-decision-m3-012) |
| `tests/with_headers_api_fail` (a fixture compiles: production `WithHeaders` became a `FromBody`, its body bound relaxed, or a carrier shape registers on `get` or before a route value); generic application code needing every body-slot type under one bound | [Typed header access decision (M3-012)](history/architecture-decisions.md#typed-header-access-decision-m3-012) (revisit conditions, the accepted cost) and [Typed header access in production (M3-013)](history/architecture-decisions.md#typed-header-access-in-production-m3-013) (current fixtures and mutations) |
| another injected kind proposed | [Application state decision (M3-001)](history/architecture-decisions.md#application-state-decision-m3-001) (one injected slot) and [Typed header access decision (M3-012)](history/architecture-decisions.md#typed-header-access-decision-m3-012) (headers kept out of the slot), and [Registration structure decision (M3-014)](history/architecture-decisions.md#registration-structure-decision-m3-014) (it still doubles the stateful family) |
| `tests/registration_fail` (a fixture compiles or loses its text: notes no longer counted per method name, a typed borrowed function value converts to a generic slot, `rebind_var` accepts a different layout, `Origin.equals` works in a `comptime if`, or an exact `StaticString` overload lets `String` through); `tests/registration_known_gaps` (must build: `rebind_var` stops accepting a layout twin, generic `==` starts telling an origin's identity apart, or safe code can no longer erase a local's origin); `header_access_fail/generic_slot_does_not_refine.mojo` or `state_fail/variadic_handler_type.mojo` compiles; documented conformance extensions for standard-library types; slot arity 4 with complete rejected-result diagnostics required, or slot arity 5 (past the cap); `state_known_gaps/registrar_blind_mutation.mojo` stops building (re-measure the builder, C3) | [Registration structure decision (M3-014)](history/architecture-decisions.md#registration-structure-decision-m3-014) |
| `tests/registration_api_fail` (a fixture compiles or loses its text: a typed borrowed `Int` value registers, the rule guard or the rebind helper stops rejecting, or an overload's `where` clause stops rejecting an immutable-origin result) | [Registration on generic-arity slots in production (M3-015)](history/architecture-decisions.md#registration-on-generic-arity-slots-in-production-m3-015) (current fixtures and mutations) and [Registration structure decision (M3-014)](history/architecture-decisions.md#registration-structure-decision-m3-014) (revisit conditions) |
| a toolchain change that lets an overload see how a caller spelled a type; a new slot kind (generic forwarding reaches it too) | [Registration structure amendment: generic forwarding (M3-015)](history/architecture-decisions.md#registration-structure-amendment-generic-forwarding-m3-015) |
| `tests/get_headers_fail` (a fixture compiles or loses its text: the spike's `Headers` rule, its order after the body rule, a typed borrowed `Headers` value converting, or a `post` message for a `Headers` shape); `POST` without a body decided; the R1 transport changed; several route values or another request part beside the fields proposed | [Typed get header access decision (M3-016)](history/architecture-decisions.md#typed-get-header-access-decision-m3-016) |

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
