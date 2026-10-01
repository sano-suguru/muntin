# Muntin architecture

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
| later: extraction / middleware|
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

Transport independence is not a diagram claim. M0 must include an in-memory/reference path that exercises the same application-dispatch seam intended for transport adapters.

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

## M0 core model

M0 needs only enough concepts to prove a real dispatch:

- `App` or equivalent application registry/dispatcher;
- Muntin-owned `Request`;
- Muntin-owned `Response`;
- minimal HTTP method/status/body representations;
- route registration for at least one static `GET` route;
- a backend/application dispatch entry point;
- an in-memory driver/test client.

Do not design the final middleware, schema, DI, async, or streaming system during M0.

### Implemented M0 layout (Mojo 1.1.0)

```text
src/muntin/__init__.mojo   public exports: App, Request, Response
src/muntin/http.mojo       Request(method, target, body) -> path, query, body; Response(status, body)
src/muntin/app.mojo        App: route table, get[route](handler) for () -> String and (Int) -> String, handle(Request) -> Response
src/muntin/testing.mojo    TestClient: in-memory backend, imports only muntin modules
```

The backend seam is the single concrete method `App.handle(self, request: Request) -> Response`. A backend converts its input into a Muntin `Request`, calls `handle`, and converts the returned `Response` back. `TestClient` does exactly that without a socket; a future Flare adapter must do the same and must not route on its own. There is deliberately no backend trait yet (A7): one implementation exists, and the trait can be extracted when a second backend arrives.

Requests and responses own their data (`String` fields, copied in). No backend buffer lifetimes appear in the public types. `TestClient` borrows the `App` immutably through an origin parameter, so `App.handle` takes `self` read-only and dispatch cannot mutate routing state.

`scripts/check_boundaries.sh` enforces A2 mechanically: it fails if any module under `src/muntin` imports or mentions Flare or socket modules. `scripts/check.sh` runs it.

The Flare adapter (M1-002) lives outside the boundary-checked core path, in `adapters/flare/muntin_flare.mojo`, and imports only Flare and Muntin's public `App`/`Request`/`Response`; nothing under `src/` imports it.

Flare (M1-001) is a dependency of the separate `flare` pixi environment only (`[feature.flare]` in `pixi.toml`, pinned to the released tag `v0.11.0`; `pixi.lock` records commit `59bda50f`). The default environment, which `check.sh` and `test.sh` use to build and test `src/muntin`, does not have Flare on its module path. `compat/flare/flare_smoke.mojo` is a Flare-only compatibility fixture (no Muntin import); `scripts/check_flare.sh` builds and runs it in the `flare` environment and fails if the same fixture builds in the default environment.

### Flare adapter (M1-002)

```text
flare.http.Request -> to_muntin_request -> muntin.Request
  -> App.handle -> muntin.Response -> to_flare_response -> flare.http.Response
```

`MuntinHandler` owns an `App` and implements Flare's `Handler` trait, so its `serve(Request) -> Response` is the call Flare's server makes; it does no routing of its own. Conversion is by copy: method and the request target (`url`, path plus query, undecoded) verbatim into `Request(method, target, body)`, which splits it in core (M2-002), so routing and query extraction match the in-memory backend; body bytes decoded into a `String` as lossy UTF-8; headers, version and peer dropped. The response copies status and body bytes, leaves the reason unset (Flare's default applies), and sets no headers. The policy is listed in the module docstring. `adapters/flare/test_muntin_flare.mojo` tests it without a socket; `check_flare.sh` builds it with `--Werror`, runs it, and checks that the adapter does not build in the default environment. `adapters/flare/serve_probe.mojo` type-checks `HttpServer.bind(...).serve(handler^)` with an owned `MuntinHandler` and exits before binding, so the ownership shape is accepted by Flare's single-worker server without opening a socket. CI runs `check_flare.sh` on Ubuntu and macOS from a cold `pixi install --locked -e flare`.

### Real localhost round trip (M1-003)

```text
HttpClient --TCP 127.0.0.1:<ephemeral>--> HttpServer.serve -> MuntinHandler.serve
  -> App.handle -> registered route -> Response -> Flare response -> wire
```

`adapters/flare/test_localhost_roundtrip.mojo` is the proof. Its server lifecycle is test fixture code, not a Muntin API: `HttpServer.serve` owns its thread, so the test binds in the parent (`bind` already listens, so readiness is `bind` returning), forks a child that serves `MuntinHandler`, drives Flare's `HttpClient` with connect/read timeouts, and SIGKILLs and reaps the child in `finally`; the child also arms a 30-second `alarm(2)`. No `app.run()`, runtime, or shutdown API was added to Muntin, and the adapter itself is unchanged.

### Routing and handler storage (M2-001)

`App` stores each route as method, the route literal's path part (plus a query key since M2-002), and a `Variant[def() thin -> String, def(Int) thin -> String]`. `App.get` is overloaded on those two shapes, so `app.get["/hello"](hello)` and `app.get["/users/{id}"](get_user)` are the same call syntax and both take the handler as a runtime value. `App.handle` scans routes in registration order; the first route whose method and segments match handles the request (later matches are not tried, even if conversion fails). A static segment matches by byte equality; a `{name}` segment matches one non-empty segment. For the `Int` arm, Muntin converts the captured segment (optional `-`, ASCII digits, `Int` range) before calling the handler; anything else returns 400 `Bad Request` and the handler is not called. No match is 404. Routing and extraction run only inside `App.handle`: `TestClient` and the Flare adapter pass the request target through unchanged and have no knowledge of `{name}`. Matching uses `Request.path`, which since M2-002 excludes the query (next section). Percent-encoded segments are not decoded.

`App.handle` selects the arm with `isa` for each shape and aborts on an unhandled one, so a new arm cannot silently fall into another's call path. `App.get` checks the route literal at compile time with the same segment classifier the runtime matcher uses (`_is_param`): a malformed literal, or a parameter count that differs from the handler's arity (0 or 1), fails to compile at the registration call. Because both use one classifier, an `Int` route always captures exactly one segment at runtime.

Storage choice, compared on Mojo 1.1.0:

| Mechanism | Unsafe | Heterogeneous shapes | Cost |
|---|---|---|---|
| `Variant` of thin function types (chosen for M2-001; to be replaced, see "Handler storage decision (M2)") | no | closed set; each shape is one arm, checked with `isa`/`[]` | new handler shapes or return types each need an arm; `-> String` only today |
| Address-bits erasure + trampoline (M0.5 prototype) | yes (`Pointer.unsafe_bitcast` of a function value to `Int`) | open over return types | relies on undocumented function-value representation; not adopted |
| Handler as compile-time parameter | no | open | public syntax becomes `app.get["/users/{id}", get_user]()` |
| Capturing closures, `rebind`, non-`thin` function fields | — | do not compile (diagnostics in `docs/DX.md`) | — |

The `Variant` holds plain function values: no heap context, no captured state, no lifetime tied to the `App` beyond the `List` that owns the routes. Moving an `App` moves its route list; copying a route copies its function value; nothing is reinterpreted. The M0.5 unsafe storage therefore did not enter `src/muntin`; it remains only in `tests/test_spike_handler_model.mojo` as the record of the comparison. More Muntin-known parameter or return types grow the closed set; an application-defined type (`-> User`, `body: CreateUser`) cannot be an arm at all. The M2 storage decision below replaces this storage before any new handler shape.

### Request target boundary and query extraction (M2-002)

```text
raw request target ("/users/42?x=1")       TestClient.get(target) | Flare url, verbatim
        |
Request(method, target, body)               muntin/http.mojo: split at the first '?'
        |-- path  "/users/42"   -> route matching (App.handle)
        '-- query "x=1"         -> query extraction for a route's {key} (App.handle)
```

The split is owned by `Request.__init__`, the one constructor every backend already calls with the raw target, so the in-memory and Flare backends cannot diverge: neither splits, parses nor decodes the query. The Flare adapter's code is unchanged; it does not use Flare's own query helpers. `query` is stored raw (no `?`, `""` when absent); `#` is not special. Requests own `path` and `query` as separate `String`s, copied once at construction.

A route literal is split the same way at registration: `_Route` stores the path part (matched as in M2-001) and the key of its `{key}` query item, if any. `App.get` checks both parts at compile time (`_path_params`, `_query_params`) and requires their placeholder total to equal the handler's arity. At dispatch, the query never affects which route is selected; for an `Int` route with a query key, `_query_value` finds the key in `Request.query` (pairs split on `&`, key/value on the first `=`, byte-equal keys, no decoding) and the value goes through the same `_parse_int` as a path segment. A missing or duplicated key or a failed conversion is 400 `Bad Request` and the handler is not called.

Storage reassessment: M2-002 adds **no** `Variant` arm. The handler shape is still `def(Int) thin -> String`; whether the `Int` comes from a path segment or a query key is route data (`query_key`), not part of the shape. So the arm count grows with distinct parameter-type lists and return types, not with parameter sources. The next items would add arms: a `String` query value (DX section 3's `search(query: String)`) is one arm `def(String) thin -> String`; a path and a query value in one handler is `def(Int, Int) thin -> String`; each new Muntin-known return type (`-> Response`) multiplies the existing arms by one. With two parameter types, arity up to two and two return types that is already 2 x (1 + 2 + 4) = 14 arms, each needing an `isa` branch in `App.handle`. An application-defined return or body type (`-> User`) is not one more factor: a library-side arm set cannot name it (next section).

`App.handle(Request) -> Response` is unchanged and remains the backend seam; streaming or async may change it later.

### Handler storage decision (M2)

Decision: production `App` moves from the closed `Variant` to a private **typed box with pointer erasure** (candidate 3b below), in a separate behavior-preserving PR before any new handler shape. Production storage is unchanged by the investigation; `src/muntin/app.mojo` still holds `Variant[def() thin -> String, def(Int) thin -> String]`.

Why: a `Variant` arm set declared in Muntin's library cannot name a type the application defines. `def get[R](handler: def(Int) thin -> R)` storing into a library `Variant` fails with `constraint failed: Type does not exist in Variant.` (`tests/spike_fail/variant_app_return_type.mojo`). The only safe way to name it is `App[User]` (`ParamApp` in the spike), which changes `App()` and grows App's parameters with every application type. So `-> User` (DX section 2/5) and `body: CreateUser` (DX section 4), the next SPEC M2 items, are impossible on `Variant` without a public syntax regression, not merely 14 arms. Every safe alternative was measured as inadequate, and the box meets the bar for contained unsafe code: invariants executable, unsafe surface private and small, no backend detail.

Evidence lives in `tests/handler_storage_spike.mojo` (library side) and `tests/test_spike_handler_storage.mojo` (application side, where `User` is defined, so types cross a module boundary as in a real app), run by `test.sh` and built `--Werror` by `check.sh`, plus `tests/spike_fail/*.mojo` (12 fixtures that must fail with the quoted diagnostic, checked by `check.sh`). All on Mojo 1.1.0 (8189361e). Both prototypes store the six fixture shapes `() -> String`, `(Int) -> String`, `(String) -> String`, `(Int, Int) -> String`, `(Int, String) -> String`, `(Int) -> User` in one route list and dispatch them through one `handle(Request) -> Response`, before and after moving the app. The shapes are fixtures, not supported APIs.

| Candidate | Result on 1.1.0 | Public syntax | Unsafe | Verdict |
|---|---|---|---|---|
| 1. closed `Variant` (production) | six shapes in one list work when the arm set is written in the application module | kept | none | safe, but cannot name application types from the library; 14 arms for Muntin-known types alone |
| 1b. `App[R]` generic over application types | compiles (`ParamApp`) | `App()` becomes `App[User]()`, one parameter per application type | none | rejected: syntax regression |
| 2a. trait as field / `List[Trait]` | `struct fields do not support trait types` (`trait_field.mojo`); `'List' parameter 'T' has 'AnyType' type, but value has type 'AnyTrait[Invoke]'` (`list_of_trait.mojo`) | — | — | rejected: no existentials |
| 2b. `Some[Trait]` field | `is not a concrete type` (`some_field.mojo`) | — | — | rejected: `Some` is a hidden type parameter |
| 2c. generic wrapper `Wrap[T]` | one concrete type per `T`: `cannot be converted from 'Wrap[B]' to 'Wrap[A]'` (`generic_wrapper_list.mojo`) | — | — | rejected |
| 2d. capturing closure wrapping the handler | each closure its own type (`closures_one_list.mojo`); not convertible to `thin` (`closure_to_thin.mojo`); non-`thin` function type is a trait (`nonthin_function_field.mojo`); `escaping` removed (`escaping_closure_field.mojo`) | — | — | rejected |
| 3a. M0.5: function value bits stored as `Int` + trampoline | compiles (`tests/test_spike_handler_model.mojo`) | kept | reinterprets a Mojo-ABI function value's bytes | rejected: relies on undocumented function-value representation |
| **3b. typed box + pointer erasure** | six shapes, one list, cross-module `User` (`BoxApp`) | kept | 4 operations, one private section | **chosen** |
| 4. handler as compile-time parameter | compiles (`CompileTimeApp` in the M0.5 spike) | `app.get["/users/{id}", get_user]()` | none | rejected: syntax regression |

Comparison of the two candidates that keep the syntax and store mixed shapes (1 and 3b):

| Criterion | 1. `Variant` | 3b. typed box |
|---|---|---|
| Application-defined types (`-> User`, body) | impossible in the library | yes: generic `R: Reply`, inferred at the call |
| Unsafe operations | none | `OwnedPointer.unsafe_take_allocation` + `Allocation.unsafe_leak`, `Pointer.unsafe_bitcast` (both directions), `OwnedPointer(unsafe_from_opaque_pointer=)` |
| Undocumented representation | no | no (only the pointer is cast) |
| Ownership | function values inline in the route | each route owns one heap box; copy clones it, destruction frees it |
| App move/copy | safe | safe (move moves the pointer, the box stays put; tested) |
| Registration code per new shape | alias + arm + overload + dispatch branch | none for new parameter-type combinations; one `elif` in `_from_arg` per new parameter type; overloads = arity x return family (6 for arity ≤ 2 and {`String`, `Reply`}) |
| Dispatch code | one branch per arm | one indirect call |
| Projection at {Int, String}, arity ≤ 2, two return families | 14 arms, 14 overloads, 14 branches | 6 overloads, 6 adapters |
| Missing case | production: run-time `abort`; a `comptime for` over `Ts` + `comptime assert` makes it a compile error (`variant_arm_without_branch.mojo`) | no per-shape dispatch to miss; an unsupported parameter type fails at registration with `constraint failed: unsupported handler parameter type` |
| Diagnostics | overload mismatch lists every arm | overload mismatch lists 6 generic candidates |
| `raises` handlers | arms become `raises` (non-raising `def` converts) | same: the spike's parameters are `raises` function types; a non-raising `def` converts implicitly (`test_box_raising_handler`) |
| Shared extraction model (path, query, body) | per arm | the box stores any `F`; extraction is the adapter's concern. Application-defined parameter types (bodies) will need a trait-bounded adapter, since `_from_arg`'s compile-time type equality only covers Muntin types and `Int` cannot take `__extension` (`extension_int.mojo`) |
| Audit surface | none | one ~60-line section |

Candidate 3b, the questions an unsafe design must answer:

- **Erased value:** the pointer to a heap cell holding the handler value `F` (a thin function type today), not the function value. Argument and return types are not erased; they are baked into the trampoline `_invoke_box[call]` and its adapter.
- **Representation:** `MutOpaquePointer[MutUntrackedOrigin]`, i.e. `Pointer[NoneType, MutUntrackedOrigin]`, the stdlib's `void*` equivalent.
- **Size/alignment:** set by `OwnedPointer[F]`'s allocation for `F`; the opaque pointer's own size does not depend on `F`. No size guard is needed, unlike M0.5's `size_of[F]() == size_of[Int]()`.
- **Exact restore:** `_invoke_box[call]`, `_clone_box[F]` and `_drop_box[F]` are instantiated in the one generic `_Erased.__init__[F, call]` that creates the box, and `call: def(F, ...)` shares `F` with the stored value. A trampoline for another type is rejected when the box is made (`box_mismatched_trampoline.mojo`: `cannot be converted from 'def get_id(id: Int) thin -> String' to 'def(String) raises thin -> String'`).
- **Mismatched pairing at run time:** only possible by writing `_box`, `_invoke`, `_clone` or `_drop` outside `__init__`/copy-init. Mojo 1.1.0 has no private fields, so this is enforced by keeping the type in one private module; the migration PR should add a `check.sh` rule that `unsafe_` appears only in that module.
- **Owner and origin:** each `_Erased` owns exactly one box. `MutUntrackedOrigin` means the lifetime checker does not track it, so lifetime is the `_Erased` value's: copy-init clones the box, `__deinit__` rebuilds `OwnedPointer[F]` and lets it deinitialize and free. The pointer never leaves `_Erased`. Oracle: an `ArcPointer` count proves one live value per handler through erase, copy, move, drop and `List` copy/move (`test_box_owns_exactly_one_value_per_erased_handler`).
- **App move/copy:** a move moves the pointer; the box does not move, so nothing dangles. A copy clones. `test_box_handlers_survive_copy_and_move_of_their_owner` and the six-shape checks run after `app^`.
- **Function-value representation:** not relied on. The value is written and read as `F` through typed `OwnedPointer[F]`/`Pointer[F]` access. `unsafe_bitcast`'s contract (`std/memory/pointer.mojo`, "undefined behavior unless the memory it [points to] actually holds a valid `U`") is met because the cell was allocated and initialized as `F`. By contrast the stdlib's own address-to-function conversion (`std/ffi/__init__.mojo`) is used only for `abi("C")` types behind `comptime assert __fn_type_is_cabi[...]`, which is why M0.5's reinterpretation of a Mojo-ABI function value does not transfer.
- **Official conversion:** there is no stdlib type-erased callable or trait object (Mojo roadmap: "Existentials / dynamic traits" not done; closure reference: "Mojo doesn't provide a built-in mechanism for heap-allocated or existential closures"). The box uses `OwnedPointer`'s documented opaque round trip: `unsafe_take_allocation` ("The pointee is handed over still initialized") and `__init__(unsafe_from_opaque_pointer=)` ("must be initialize[d] with a single valid `T` initially allocated with this `OwnedPointer`'s backing allocator"; destruction "will call `T.__deinit__` and `dealloc`").
- **Future return types:** `R` is never erased, so non-register-passable results are returned by value inside the typed adapter; it requires `Reply` (and `Deinitable`).
- **`raises`:** see the table; the trampoline is already `raises`, and a raised error is mapped by `handle` (400 in the spike; the application-error model is later M2 work).

Mutations (planted in copies of the spike, each red): copy-init sharing the box, `_clone_box` returning the same box, dropping twice (each crashes: double free); `__deinit__` not dropping, `_drop_box` not rebuilding the owner (count oracle `3 != 2`); removing a `Variant` dispatch branch (`constraint failed: Variant arm without a dispatch branch`); registering a `(String, String)` handler on the `Variant` model (`no matching method in call to 'get'`). A `(String, String)` handler on `BoxApp` needs no library change; a `Bool` parameter fails with `constraint failed: unsupported handler parameter type`.

Primary sources (Mojo 1.1.0; stdlib at tag `mojo/v1.1.0` of modular/modular, docs at mojolang.org labelled 1.1.0): `std/utils/variant.mojo` (`Variant[*Ts: AnyType]`; `_check` asserts "Type does not exist in Variant."; the stdlib iterates `Self.Ts` with `comptime for`; no visitor or exhaustive match, pattern matching is a concept proposal); `std/memory/pointer.mojo` (`UnsafePointer` deprecated for `Pointer`; `OpaquePointer = Pointer[NoneType, ...]`; `unsafe_bitcast` contract); `std/memory/owned_pointer.mojo` (`unsafe_from_opaque_pointer`, `unsafe_take_allocation`); `std/memory/alloc.mojo` (`Allocation` is explicitly destroyed); `std/origin` (`MutUntrackedOrigin`: "An origin the lifetime checker does not track"); `std/ffi/__init__.mojo` (`__fn_type_is_cabi` guard and the note that `.unsafe_bitcast` only changes the pointee type); `std/builtin/rebind.mojo` (`rebind_var` asserts equal types after elaboration, the use in `_from_arg`); `std/simd.mojo` (`comptime Int = Scalar[DType.int]`); docs: reference/closure-declarations, reference/function-declarations (`thin`), reference/trait-declarations and manual/generics (`Some` is sugar; a `Some` field has no concrete type), roadmap (existentials not done); release notes v1.1.0 (`UnsafePointer` deprecated; `init_pointee_*`/`destroy_pointee` removed for `unsafe_write`/`unsafe_deinit_pointee`). Post-1.1.0 `main` adds no existentials or storable closures. Every compile claim above was checked on the pinned compiler, not taken from these sources.

Reconsideration thresholds:

- Production `Variant` stays at exactly its two arms. The migration PR comes before any new handler shape (String query value, second parameter, body, typed return, raw handler), and must keep every current behavior, `tests/compile_fail` fixture and the loopback parity test green, and port the ownership oracle.
- Revisit the box itself when a `tests/spike_fail` fixture starts compiling after a toolchain change (`check.sh` then fails: existentials, storable closures or field traits may have landed), when `OwnedPointer`'s opaque round trip or its documented contract changes, or when handlers need captured state (closures, application state).

## Request/Response ownership

M0 should choose the simplest ownership model that compiles cleanly and supports deterministic tests. Do not prematurely optimize around zero-copy wire buffers if that leaks backend lifetimes into Muntin's durable API.

Before changing the ownership model later, measure the cost and document the concrete requirement that justifies additional lifetime complexity.

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
4. once M1 exists, a real localhost request traverses Flare -> adapter -> Muntin app -> adapter -> Flare;
5. the same application handler can be exercised by both in-memory and Flare paths without changing its public signature.

## Architecture decision threshold

Create an ADR or update this document before:

- exposing any third-party type publicly;
- introducing a custom runtime/executor/task model;
- making a transport mandatory;
- adding unsafe memory/lifetime machinery to a public contract;
- changing request/response ownership semantics;
- changing the backend seam in a way that breaks adapters;
- making a provisional DX example a frozen compatibility promise.
