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
src/muntin/__init__.mojo   public exports: App, FromBody, Request, Response
src/muntin/http.mojo       Request(method, target, body) -> path, query, body; Response(status, body)
src/muntin/body.mojo       FromBody: the request-body conversion trait an application type conforms to (M2-006)
src/muntin/app.mojo        App: route table, get[route](handler) for () -> String and (Int) -> String, post[route](handler) for (B: FromBody) -> String, handle(Request) -> Response
src/muntin/_handler_storage.mojo  private: _Erased typed handler box; the only module with unsafe operations (M2-004)
src/muntin/testing.mojo    TestClient: in-memory backend (get, post), imports only muntin modules
```

The backend seam is the single concrete method `App.handle(self, request: Request) -> Response`. A backend converts its input into a Muntin `Request`, calls `handle`, and converts the returned `Response` back. `TestClient` does exactly that without a socket; a future Flare adapter must do the same and must not route on its own. There is deliberately no backend trait yet (A7): one implementation exists, and the trait can be extracted when a second backend arrives.

Requests and responses own their data (`String` fields, copied in). No backend buffer lifetimes appear in the public types. `TestClient` borrows the `App` immutably through an origin parameter, so `App.handle` takes `self` read-only and dispatch cannot mutate routing state.

`scripts/check_boundaries.sh` enforces A2 mechanically: it fails if any module under `src/muntin` imports or mentions Flare or socket modules. `scripts/check_unsafe.sh` confines unsafe pointer/ownership operations to `src/muntin/_handler_storage.mojo` (M2-004, "Production implementation" below). `scripts/check.sh` runs both.

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

`App` stores each route as method, the route literal's path part (plus a query key since M2-002), and the handler: a `Variant[def() thin -> String, def(Int) thin -> String]` until M2-004, now a private typed box ("Production implementation (M2-004)" below). `App.get` is overloaded on those two shapes (each with a `ToResponse` twin since M2-008), so `app.get["/hello"](hello)` and `app.get["/users/{id}"](get_user)` are the same call syntax and both take the handler as a runtime value. `App.handle` scans routes in registration order; the first route whose method and segments match handles the request (later matches are not tried, even if conversion fails). A static segment matches by byte equality; a `{name}` segment matches one non-empty segment. For an `Int` handler, Muntin converts the captured segment (optional `-`, ASCII digits, `Int` range) before calling the handler; anything else returns 400 `Bad Request` and the handler is not called. No match is 404. Routing and extraction run only inside `App.handle`: `TestClient` and the Flare adapter pass the request target through unchanged and have no knowledge of `{name}`. Matching uses `Request.path`, which since M2-002 excludes the query (next section). Percent-encoded segments are not decoded.

Until M2-004, `App.handle` selected the arm with `isa` for each shape and aborted on an unhandled one; since M2-004 each `App.get` overload pairs the handler with its adapter at registration and dispatch is one call, so there is no per-shape branch. `App.get` checks the route literal at compile time with the same segment classifier the runtime matcher uses (`_is_param`): a malformed literal, or a parameter count that differs from the handler's arity (0 or 1), fails to compile at the registration call. Because both use one classifier, an `Int` route always captures exactly one segment at runtime.

Storage choice, compared on Mojo 1.1.0:

| Mechanism | Unsafe | Heterogeneous shapes | Cost |
|---|---|---|---|
| `Variant` of thin function types (M2-001 to M2-003; replaced in M2-004, see "Handler storage decision (M2)") | no | closed set; each shape is one arm, checked with `isa`/`[]` | new handler shapes or return types each need an arm; `-> String` only today |
| Address-bits erasure + trampoline (M0.5 prototype) | yes (`Pointer.unsafe_bitcast` of a function value to `Int`) | open over return types | relies on undocumented function-value representation; not adopted |
| Handler as compile-time parameter | no | open | public syntax becomes `app.get["/users/{id}", get_user]()` |
| Capturing closures, `rebind`, non-`thin` function fields | — | do not compile (diagnostics in `docs/DX.md`) | — |

The `Variant` held plain function values: no heap context, no captured state, no lifetime tied to the `App` beyond the `List` that owns the routes. Moving an `App` moves its route list; copying a route copies its function value; nothing is reinterpreted. The M0.5 unsafe storage therefore did not enter `src/muntin`; it remains only in `tests/test_spike_handler_model.mojo` as the record of the comparison. More Muntin-known parameter or return types grow the closed set; an application-defined type (`-> User`, `body: CreateUser`) cannot be an arm at all. The M2 storage decision below replaced this storage (M2-004) before any new handler shape.

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

Storage reassessment: M2-002 adds **no** `Variant` arm. The handler shape is still `def(Int) thin -> String`; whether the `Int` comes from a path segment or a query key is route data (`query_key`), not part of the shape. So the arm count grows with distinct parameter-type lists and return types, not with parameter sources. The next items would add arms: a `String` query value (DX section 3's `search(query: String)`) is one arm `def(String) thin -> String`; a path and a query value in one handler is `def(Int, Int) thin -> String`; each new Muntin-known return type (`-> Response`) multiplies the existing arms by one. With two parameter types, arity up to two and two return types that would have been 2 x (1 + 2 + 4) = 14 arms, each needing an `isa` branch in `App.handle`. An application-defined return or body type (`-> User`) is not one more factor: a library-side arm set cannot name it (next section).

`App.handle(Request) -> Response` is unchanged and remains the backend seam; streaming or async may change it later.

### Handler storage decision (M2)

Decision: production `App` moves from the closed `Variant` to a private **typed box with pointer erasure** (candidate 3b below), in a separate behavior-preserving PR before any new handler shape. Status: **production implementation** since M2-004, as a smaller move-only box ("Production implementation (M2-004)" at the end of this section). The investigation (M2-003) itself left production storage unchanged.

Why: a `Variant` lists its arm types where it is declared, and dependency direction (A2) means Muntin's library cannot import the application, so a `Variant` declared in the library can never list `User` or `CreateUser`. `tests/spike_fail/variant_app_return_type.mojo` illustrates the consequence (a handler whose type is not an arm fails with `constraint failed: Type does not exist in Variant.`); no fixture can test the import direction itself. The only safe way to name it is `App[User]` (`ParamApp` in the spike), which changes `App()` and grows App's parameters with every application type. So `-> User` (DX section 2/5) and `body: CreateUser` (DX section 4), the next SPEC M2 items, are impossible on `Variant` without a public syntax regression, not merely 14 arms. Every safe alternative was measured as inadequate, and the box meets the bar for contained unsafe code: invariants executable, unsafe surface private and small, no backend detail.

Evidence lives in `tests/handler_storage_spike.mojo` (library side) and `tests/test_spike_handler_storage.mojo` (application side, where `User` is defined, so types cross a module boundary as in a real app), run by `test.sh` and built `--Werror` by `check.sh`, plus `tests/spike_fail/*.mojo` (12 fixtures that must fail with the quoted diagnostic, checked by `check.sh`). All on Mojo 1.1.0 (8189361e). Both prototypes store the six fixture shapes `() -> String`, `(Int) -> String`, `(String) -> String`, `(Int, Int) -> String`, `(Int, String) -> String`, `(Int) -> User` in one route list and dispatch them through one `handle(Request) -> Response`, before and after moving the app. The shapes are fixtures, not supported APIs.

| Candidate | Result on 1.1.0 | Public syntax | Unsafe | Verdict |
|---|---|---|---|---|
| 1. closed `Variant` (production until M2-004) | six shapes in one list work when the arm set is written in the application module | kept | none | safe, but cannot name application types from the library; 14 arms for Muntin-known types alone |
| 1b. `App[R]` generic over application types | compiles (`ParamApp`) | `App()` becomes `App[User]()`, one parameter per application type | none | rejected: syntax regression |
| 2a. trait as field / `List[Trait]` | `struct fields do not support trait types` (`trait_field.mojo`); `'List' parameter 'T' has 'AnyType' type, but value has type 'AnyTrait[Invoke]'` (`list_of_trait.mojo`) | — | — | rejected: no existentials |
| 2b. `Some[Trait]` field | `is not a concrete type` (`some_field.mojo`) | — | — | rejected: `Some` is a hidden type parameter |
| 2c. generic wrapper `Wrap[T]` | one concrete type per `T`: `cannot be converted from 'Wrap[B]' to 'Wrap[A]'` (`generic_wrapper_list.mojo`) | — | — | rejected |
| 2d. capturing closure wrapping the handler | each closure its own type (`closures_one_list.mojo`); not convertible to `thin` (`closure_to_thin.mojo`); non-`thin` function type is a trait (`nonthin_function_field.mojo`); `escaping` removed (`escaping_closure_field.mojo`) | — | — | rejected |
| 3a. M0.5: function value bits stored as `Int` + trampoline | compiles (`tests/test_spike_handler_model.mojo`) | kept | reinterprets a Mojo-ABI function value's bytes | rejected: relies on undocumented function-value representation |
| **3b. typed box + pointer erasure** | six shapes, one list, cross-module `User` (`BoxApp`) | kept | 4 operations and 2 unchecked dereferences, one private section | **chosen** |
| 4. handler as compile-time parameter | compiles (`CompileTimeApp` in the M0.5 spike) | `app.get["/users/{id}", get_user]()` | none | rejected: syntax regression |

Comparison of the two candidates that keep the syntax and store mixed shapes (1 and 3b):

| Criterion | 1. `Variant` | 3b. typed box |
|---|---|---|
| Application-defined types (`-> User`, body) | impossible in the library | yes: return `R: Reply`, parameter `A` conforming to `FromArg`, inferred at the call (`test_box_takes_app_defined_parameter_types`: `(CreateUser) -> String`, `(Int, CreateUser) -> User`) |
| Unsafe operations | none | `OwnedPointer.unsafe_take_allocation` + `Allocation.unsafe_leak`, `Pointer.unsafe_bitcast` (both directions), `OwnedPointer(unsafe_from_opaque_pointer=)`, plus `[]` on the untracked `Pointer[F, MutUntrackedOrigin]` in `_invoke_box` and `_clone_box` |
| Undocumented representation | no | no (only the pointer is cast) |
| Ownership | function values inline in the route | each route owns one heap box; copy clones it, destruction frees it |
| App move/copy | safe | safe (move moves the pointer, the box stays put; tested) |
| Registration code per new shape | alias + arm + overload + dispatch branch | none for new parameter-type combinations; one `elif` in `_from_arg` per new parameter type; overloads = arity x return family (6 for arity ≤ 2 and {`String`, `Reply`}) |
| Dispatch code | one branch per arm | one indirect call |
| Projection at {Int, String}, arity ≤ 2, two return families | 14 arms, 14 overloads, 14 branches | 6 overloads, 6 adapters |
| Missing case | production: run-time `abort`; a `comptime for` over `Ts` + `comptime assert` makes it a compile error (`variant_arm_without_branch.mojo`) | no per-shape dispatch to miss; an unsupported parameter type fails at registration with `constraint failed: unsupported handler parameter type` |
| Diagnostics | overload mismatch lists every arm | overload mismatch lists 6 generic candidates |
| `raises` handlers | arms become `raises` (non-raising `def` converts) | same: the spike's parameters are `raises` function types; a non-raising `def` converts implicitly (`test_box_raising_handler`) |
| Shared extraction model (path, query, body) | per arm | the box stores any `F`; extraction is the adapter's concern. `_from_arg` selects Muntin types (`Int`, `String`) by compile-time type equality, since `Int` cannot take `__extension` (`extension_int.mojo`; `__extension SIMD(...)` can, within the trait's module, see M2-005 below), and application types through `conforms_to(A, FromArg)` + `downcast` (`std/builtin/rebind.mojo`; an MLIR alias with a one-line docstring, so record it with the other relied-on stdlib APIs) |
| Audit surface | none | one ~60-line section |

Candidate 3b, the questions an unsafe design must answer:

- **Erased value:** the pointer to a heap cell holding the handler value `F` (a thin function type today), not the function value. Argument and return types are not erased; they are baked into the trampoline `_invoke_box[call]` and its adapter.
- **Representation:** `MutOpaquePointer[MutUntrackedOrigin]`, i.e. `Pointer[NoneType, MutUntrackedOrigin]`, the stdlib's `void*` equivalent.
- **Size/alignment:** set by `OwnedPointer[F]`'s allocation for `F`; the opaque pointer's own size does not depend on `F`. No size guard is needed, unlike M0.5's `size_of[F]() == size_of[Int]()`.
- **Exact restore:** `_invoke_box[call]`, `_clone_box[F]` and `_drop_box[F]` are instantiated in the one generic `_Erased.__init__[F, call]` that creates the box, and `call: def(F, ...)` shares `F` with the stored value. A trampoline for another type is rejected when the box is made (`box_mismatched_trampoline.mojo`: `cannot be converted from 'def get_id(id: Int) thin -> String' to 'def(String) raises thin -> String'`).
- **Mismatched pairing at run time:** only possible by writing `_box`, `_invoke`, `_clone` or `_drop` outside `__init__`/copy-init. Mojo 1.1.0 has no private fields, so this is enforced by keeping the type in one private module; production does this with `scripts/check_unsafe.sh` (M2-004).
- **Owner and origin:** each `_Erased` owns exactly one box. `MutUntrackedOrigin` means the lifetime checker does not track it, so lifetime is the `_Erased` value's: copy-init clones the box, `__deinit__` rebuilds `OwnedPointer[F]` and lets it deinitialize and free. The pointer never leaves `_Erased`. Oracle: an `ArcPointer` count proves one live value per handler through erase, copy, move, drop and `List` copy/move (`test_box_owns_exactly_one_value_per_erased_handler`).
- **App move/copy:** a move moves the pointer; the box does not move, so nothing dangles. A copy clones. `test_box_handlers_survive_copy_and_move_of_their_owner` and the six-shape checks run after `app^`.
- **Function-value representation:** not relied on. The value is written and read as `F` through typed `OwnedPointer[F]`/`Pointer[F]` access. `unsafe_bitcast`'s contract (`std/memory/pointer.mojo`, "undefined behavior unless the memory it [points to] actually holds a valid `U`") is met because the cell was allocated and initialized as `F`. By contrast the stdlib's own address-to-function conversion (`std/ffi/__init__.mojo`) is used only for `abi("C")` types behind `comptime assert __fn_type_is_cabi[...]`, which is why M0.5's reinterpretation of a Mojo-ABI function value does not transfer.
- **Official conversion:** there is no stdlib type-erased callable or trait object (Mojo roadmap: "Existentials / dynamic traits" not done; closure reference: "Mojo doesn't provide a built-in mechanism for heap-allocated or existential closures"). The box uses `OwnedPointer`'s documented opaque round trip: `unsafe_take_allocation` ("The pointee is handed over still initialized") and `__init__(unsafe_from_opaque_pointer=)` ("must be initialize[d] with a single valid `T` initially allocated with this `OwnedPointer`'s backing allocator"; destruction "will call `T.__deinit__` and `dealloc`").
- **Future return types:** `R` is never erased, so non-register-passable results are returned by value inside the typed adapter; it requires `Reply` (and `Deinitable`).
- **`raises`:** see the table; the trampoline is already `raises`, and a raised error is mapped by `handle` (400 in the spike; the application-error model is later M2 work).

Mutations (planted in copies of the spike, each red): copy-init sharing the box, `_clone_box` returning the same box, dropping twice (each crashes: double free); `__deinit__` not dropping, `_drop_box` not rebuilding the owner (count oracle `3 != 2`); a move constructor that clones the box and never frees the moved-from one (count oracle `4 != 3`); removing a `Variant` dispatch branch (`constraint failed: Variant arm without a dispatch branch`); registering a `(String, String)` handler on the `Variant` model (`no matching method in call to 'get'`). A `(String, String)` handler on `BoxApp` needs no library change; a `Bool` parameter fails with `constraint failed: unsupported handler parameter type`.

Primary sources (Mojo 1.1.0; stdlib at tag `mojo/v1.1.0` of modular/modular, docs at mojolang.org labelled 1.1.0): `std/utils/variant.mojo` (`Variant[*Ts: AnyType]`; `_check` asserts "Type does not exist in Variant."; the stdlib iterates `Self.Ts` with `comptime for`; no visitor or exhaustive match, pattern matching is a concept proposal); `std/memory/pointer.mojo` (`UnsafePointer` deprecated for `Pointer`; `OpaquePointer = Pointer[NoneType, ...]`; `unsafe_bitcast` contract); `std/memory/owned_pointer.mojo` (`unsafe_from_opaque_pointer`, `unsafe_take_allocation`); `std/memory/alloc.mojo` (`Allocation` is explicitly destroyed); `std/origin` (`MutUntrackedOrigin`: "An origin the lifetime checker does not track"); `std/ffi/__init__.mojo` (`__fn_type_is_cabi` guard and the note that `.unsafe_bitcast` only changes the pointee type); `std/builtin/rebind.mojo` (`rebind_var` asserts equal types after elaboration, the use in `_from_arg`); `std/simd.mojo` (`comptime Int = Scalar[DType.int]`); docs: reference/closure-declarations, reference/function-declarations (`thin`), reference/trait-declarations and manual/generics (`Some` is sugar; a `Some` field has no concrete type), roadmap (existentials not done); release notes v1.1.0 (`UnsafePointer` deprecated; `init_pointee_*`/`destroy_pointee` removed for `unsafe_write`/`unsafe_deinit_pointee`). Post-1.1.0 `main` adds no existentials or storable closures. Every compile claim above was checked on the pinned compiler, not taken from these sources.

Reconsideration thresholds:

- Done in M2-004: the migration came before any new handler shape (String query value, second parameter, body, typed return, raw handler), kept every behavior, `tests/compile_fail` fixture and the loopback parity test green, and ported the ownership oracle.
- Revisit the box itself when a `tests/spike_fail` fixture starts compiling after a toolchain change (`check.sh` then fails: existentials, storable closures or field traits may have landed), when `OwnedPointer`'s opaque round trip or its documented contract changes, or when handlers need captured state (closures, application state).

### Production implementation (M2-004)

Public behavior is unchanged: the same two non-raising shapes (`def() -> String`, `def(Int) -> String`), the same `App.get` signatures, route literal checks and diagnostics, and the same matching, extraction and 400/404 rules. Only the stored representation changed.

- **Module:** `src/muntin/_handler_storage.mojo`, struct `_Erased`. Every helper that touches the erased pointer is named `_unsafe_*`, so calling one from anywhere means writing `unsafe`, and `check_unsafe.sh` rejects them in other `src/muntin` modules. It imports only `std.memory` and `.http` (`Response`); other `src/muntin` modules may import only `_Erased` from it (so `_unsafe_erase`, `_unsafe_invoke_box`, `_unsafe_drop_box` and `_Box` stay inside), only `app.mojo` does, and it is not exported from `muntin`; no public signature mentions it.
- **Representation:** `_Erased` has one field, `_header: ThinAllocation[_Header]`, a move-only owning handle (the stdlib's `List` keeps its buffer the same way). The non-generic heap `_Header` holds `_invoke: def(_Box, List[String]) raises thin -> Response`, `_drop: def(_Box) thin` and `_value: MutOpaquePointer[MutUntrackedOrigin]`. The one constructor, `__init__[F: Movable & Deinitable, //, call: _Call[F]](out self, var value: F)`, moves `value` into an `OwnedPointer[F]`, erases only that pointer, and stores it in a new header with `_unsafe_invoke_box[call]` and `_unsafe_drop_box[F]`. The header is read as its own type (`unsafe_ptr()[]`), so no struct layout is assumed. `F` is a thin function type in production; the constructor is generic so that the ownership oracle can box a counted value. Cost: one extra allocation per route, at registration.
- **Unsafe operations retained:** for the value, `OwnedPointer.unsafe_take_allocation` + `Allocation.unsafe_leak` and `Pointer.unsafe_bitcast[NoneType]` (erase), `Pointer.unsafe_bitcast[F]` + one dereference of the untracked pointer (`_unsafe_invoke_box`), `OwnedPointer[F](unsafe_from_opaque_pointer=)` (`_unsafe_drop_box`); for the header, `unsafe_take_allocation` + `Allocation.into_thin` (create), `ThinAllocation.unsafe_ptr` (invoke), `ThinAllocation.unsafe_leak` + `OwnedPointer(unsafe_from_raw_pointer=)` (destroy). Removed from the spike: `_clone`, `_clone_box`, the copy constructor and its second untracked dereference, and the `Copyable` requirement on `F`. `F: Deinitable` stays: without it 1.1.0 rejects `_unsafe_drop_box` (`abandoned without being explicitly destroyed`).
- **Move-only, and why:** nothing in production copies a route or an `App`. `App` is `Movable`; `App.get` appends routes by move; `TestClient` borrows the `App`; `MuntinHandler` takes `var app` and Flare's `serve(handler^)` takes ownership. `_Erased` and `_Route` are therefore `Movable` and not `Copyable`. On 1.1.0, `for route in self._routes` requires a `Copyable` element (`constraint failed: List iteration requires the element to be Copyable.`), so `App.handle` iterates by index and binds `ref route = self._routes[i]`, which does not copy.
- **Adapters:** `_call_none` and `_call_int` in `app.mojo` take exactly the non-raising types `def() thin -> String` and `def(Int) thin -> String`. The invoker is `raises` only because `_call_int` converts its argument with `_parse_int`; a raise means a value failed to convert and becomes 400, as before. The `try` around `invoke` also covers the handler call, which is equivalent while handlers cannot raise; raising handlers would need the application-error model to separate the two. A raising, `String`-parameter, two-parameter or `-> Response` handler still fails at `app.get` with the same diagnostic as before M2-004 (`tests/storage_fail`, checked against both trees). `FromArg`, `Reply` and other spike conversion traits are not in production.
- **Dispatch:** `_match` clears an argument list and appends the captured `{name}` segment; a query route appends `_query_value(request.query, query_key)`; then `route.handler.invoke(args)`. Any raise → 400 `Bad Request`, handler not called (until M2-011: request failures are answered 400 where they occur and a raise out of `invoke` is 500). `_parse_int`, `_query_value`, `_path_params`, `_query_params`, `_is_param`, first-match order and the 404 fallback are unchanged.
- **Owner and lifetime invariant:** each live handler has exactly one owner, the `_Erased` in its `_Route`, which is owned by the `App`'s route list. A move (`deinit move`, synthesized) transfers the handle and does not run `__deinit__` on the source; neither allocation moves, so moving the `App`, the list, or a list reallocation leaves nothing dangling. `__deinit__` drops the value through the header's `_drop`, then frees the header, each once. `MutUntrackedOrigin` means the compiler checks none of this; the obligations are: the value pointer is stored only in the header `_Erased.__init__` made for it; invoke and drop restore it only as that `F`; it outlives every `invoke` because `invoke` borrows the owning `_Erased`; it is freed exactly once because `_Erased` cannot be copied (making it `Copyable` fails: `cannot synthesize copy constructor because field '_header' has non-copyable type`).
- **Pairing:** the invoke trampoline is tied to the boxed type by the compiler (`call: _Call[F]` shares `F` with `value`; `tests/storage_fail/mismatched_trampoline.mojo`: the `Int` adapter for a no-argument handler is rejected). The drop trampoline is tied by construction in the same `__init__`: `_unsafe_drop_box[Int]` there compiles, and the count oracle catches it. After construction, the value pointer and its two functions sit in one header behind one move-only handle, so they cannot be separated by moving, swapping or replacing anything `_Erased` exposes.
- **Downstream application code** (no private fields in Mojo 1.1.0, so an application can import `muntin._handler_storage` and name `app._routes[i].handler._header`): writing `handler._drop`, `._invoke` or `._box` fails (`'_Erased' value has no attribute '_drop'`); copying a handle over another fails (`ThinAllocation[_Header]` `cannot be implicitly copied`); moving one over another fails (`abandoned without being explicitly destroyed`); a handle cannot be moved out of `app._routes[i]` at all; swapping two handles is accepted and keeps each pairing. Pinned by `tests/storage_fail/downstream_{set_drop,alias_header,move_header}.mojo`. What still compiles from such code without an `unsafe_`-named call: `handler._header._ptr = other._header._ptr` (aliasing, then a double free) and `handler._header._ptr[]._drop = _unsafe_drop_box[Int]` (type confusion), both through the stdlib's private `ThinAllocation._ptr`. That is the same reach as the stdlib's own owning types and as the `Variant` storage this replaces, each probed on 1.1.0 from a separate module: `a._inner._ptr = b._inner._ptr` on `OwnedPointer`, `x._inner = y._inner` on `ArcPointer`, `s._len = 1_000_000` on `List`, and on `main`'s `App`, `app._routes._len = 1000` and `app._routes[0].handler._storage.get_discriminant() = 1` (dispatches `/hello` as the `Int` arm). The deprecated public `std.memory.memmove` can also bit-copy one handle (or a whole `_Erased`) over another from such code, with only a warning; it has the same reach over every type. Mojo 1.1.0 cannot seal any owning representation against code that writes underscore fields. What Muntin controls is now closed: its own fields give no such access, and its helpers (`_unsafe_erase`, `_unsafe_invoke_box`, `_unsafe_drop_box`) can be called only by naming `unsafe`. Before this change (three fields on `_Erased`), `handler._drop = _unsafe_drop_box[Int]` and `handler._invoke = other._invoke` compiled and `/hello` ran through the `Int` trampoline.
- **Confinement guard:** `scripts/check_unsafe.sh` (run by `check.sh`) fails if any `src/muntin` file other than the storage module matches `[Uu]nsafe|Untracked|OpaquePointer|OwnedPointer|Allocation|bitcast|\._(header|invoke|drop|value)\b` or names the module on any line other than `from ._handler_storage import _Erased`, if `muntin/__init__.mojo` names the module or `_Erased`, or if the module imports anything but `std.*` and `.http`. It is a confinement guard for this repository, not a safety proof, and cannot see application code; `tests/` is not checked.
- **Tests:** `tests/test_handler_storage.mojo` (run by `test.sh`): an `ArcPointer` count proves one live value per box through erase, move and drop, and through 100 appends (reallocation), a list move, `pop` and drop; arguments and raises pass through `invoke`; one `App` with `/hello`, `/users/{id}`, `/items?{limit}` and 20 more routes (route-list reallocation) dispatches correctly after being returned from a function, moved with `^`, moved into a holder struct, moved into a growing `List[App]`, and popped from it; `app._routes[i].handler` is an `_Erased` (this test does not build against the `Variant`); a partly matched route leaves no argument for the next. `tests/storage_fail/*.mojo` (10, checked by `check.sh`): mismatched adapter, `_Erased.copy()`, five unsupported handler shapes (the four above and a `Request` parameter), and the three downstream writes above.
- **Mutations** (planted against `src/muntin`, reverted), each red: `__deinit__` not dropping, `_unsafe_drop_box[Int]` (count oracle); dropping twice, a move constructor that frees the source (crash); `_unsafe_invoke_box` restoring as `Int`, an `Int` route paired with `_call_none`, `_Erased` made `Copyable` (compile error); a `_drop` field put back on `_Erased` (`downstream_set_drop.mojo` compiles); a route's handle aliased in `App.get`, `OwnedPointer` imported in `app.mojo`, `_unsafe_drop_box` imported in `app.mojo`, `_Erased` exported, the module importing `.testing` (guard); `_call_int` passing the segment length, a query route given a path segment instead of its query value (`test_app`); `_match` not clearing (stale-argument test); the `Int` overload and `_call_int` made `raises` (`raising_handler.mojo` compiles); `main`'s `Variant` `app.mojo` restored (`test_handler_storage` does not build, while `test_app` passes 23/23 on both).
- **Intentionally unsupported:** every shape beyond the two above; captured state and closures; application-defined parameter or return types; handler errors (the next M2 decisions: argument extraction, decided in M2-005 below, response conversion, application errors). A spike's ownership tests that need copy semantics stay in the spike as decision evidence.

### Argument extraction decision (M2-005)

Status: **decision** (M2-005, which left `src/muntin` unchanged). Its body-only case is production since M2-006 ("Body-only POST (M2-006)" below) and its one-route-value-then-body case since M2-009 ("Route value then body in production (M2-009)" below); the rest of this section is the decision and spike evidence. Two questions are decided separately:

```text
route literal + overload  --> source plan   [Path/Query value 0..k-1, Body k]   (route data)
Request at dispatch       --> raw strings   in slot order: path captures, query value, body
per-slot adapter          --> typed values  route value: Muntin builtin conversion; body: T.from_body
typed handler call        (stored in the unchanged _Erased box)
```

**Source binding (which request source fills slot N).** The route literal declares the route values in order (`{name}` path segments, then the `{key}` query item), and handler parameters bind to them by position, as since M2-001/M2-002. A handler with exactly one parameter more than the literal declares takes the request body in that last position. At most one body parameter, always last, always required. Body-taking registrations belong to body-carrying methods (`app.post` first), not `app.get`.

The rule is unambiguous only because of one invariant, which every implementation must keep: **route-value types and body types are disjoint and checked at registration.** A route-value slot accepts only Muntin-known builtins (`Int` today); the body slot accepts only types that conform to the body trait **and are not route-value types**, and application types are not route-value types. The body slot rejects `Int` by compile-time type equality, not by relying on `Int` lacking the conformance: on 1.1.0 `__extension Int(...)` is rejected (`tests/spike_fail/extension_int.mojo`), but `__extension SIMD(FB)` in the module that declares `FB` does satisfy a `[T: FB]` bound for `Int`, while `conforms_to(Int, FB)` stays False (`tests/extraction_fail/extension_invisible_to_conforms_to.mojo`), and the same extension from an application module fails (`does not implement all requirements`, `builtin_body_via_extension.mojo`). Those last two behaviors are undocumented, so nothing relies on them. So every position or arity mistake fails at the registration call instead of silently rebinding: a forgotten `{id}` with a lone `Int` resolves to the `def(Int)` overload and fails its arity check (`int_in_body_slot.mojo`), a forgotten `{b}` in `(a: Int, b: Int)` puts an `Int` in the body slot and is rejected (`two_ints_one_route_value.mojo`), a body type in a route slot is rejected (`app_type_in_route_slot.mojo`), and any other arity has no overload. Handler parameter names are never consulted (renaming them leaves every test green).

**Typed conversion (how a raw value becomes `T`).** Conversion follows the raw input's kind, not its source. Route values, whether from a path segment or a query value, are one scalar text kind and use Muntin's internal builtin conversion (`_parse_int`, selected by overload or compile-time type equality); the source never changes the conversion, as since M2-002. The body is a payload kind and converts through a Muntin-owned trait that the application type conforms to directly, in its own module:

```mojo
trait FromBody(Deinitable, Movable):          # spike name; public name and export decided by the first body slice
    @staticmethod
    def from_body(body: String) raises -> Self: ...
```

A source-neutral trait over one `String` (the M2-003 spike's `FromArg`) was not adopted: it would let `CreateUser` fill a path slot and erase the disjointness that keeps binding unambiguous. Builtins and application types therefore take different internal paths with one public rule: route values are Muntin scalars, bodies are application types that say how to read a body.

Mechanism on 1.1.0: the registration overload is generic over `B: Movable & Deinitable` and asserts `comptime assert conforms_to(B, FromBody), "<Muntin message>"`; the adapter that calls `B.from_body` refines `B` the same way. This is the documented 1.1.0 mechanism (release notes: `trait_downcast()` removed, "Constrain on the trait instead, with `conforms_to(...)` in a `where` clause or a `comptime assert`"; v1.0.0: refinement from `where`/`comptime assert conforms_to` makes downcasting unnecessary). No `downcast`, `rebind_var` or `__extension` is needed, unlike the M2-003 spike. Measured limits: the trait refines `Deinitable` because Muntin may have to drop a converted value and to keep linear types out (calling a borrowed `def(B)` handler with a temporary fails without it: "abandoned without being explicitly destroyed"; the spike's move-in `def(var B)` path happens to compile without it); forwarding a handler with an explicit `inner[B](handler, raw)` to a callee that requires `B: FromBody` fails ("function type conversions between closures not supported yet"; an inferred `B` compiles), so the spike refines in the adapter that calls `from_body`. A trait bound (`[B: FromBody]`) or a `where conforms_to(...)` clause also resolve correctly, but their failure is the compiler's per-candidate note; the `comptime assert` form lets Muntin say which slot is wrong, using the route literal.

**Move-only values.** The spike's `CreateUser` is not `Copyable`. Registration takes `def(var B)`: a handler declaring `body: B` (borrowed) or `var body: B` (owned) converts to it, and the adapter moves the converted value in (`store_user` moves it into a `List`). Offering both `def(B)` and `def(var B)` is ambiguous for a borrowed handler (`borrowed_and_owned_overloads.mojo`). An adapter that swallows a conversion error and still calls the handler does not compile (`use of uninitialized value 'body'`).

Alternatives compared (all on Mojo 1.1.0 (8189361e)):

| Question | Candidate | Result | Verdict |
|---|---|---|---|
| source | A. route values by position, remaining last parameter is the body | `ExtractApp`: `(CreateUser)`, `(Int, CreateUser)`, `(Int, RenameTeam)` | **chosen**, with the disjointness invariant |
| source | B. explicit registration metadata (`app.post["/users", body=True](h)`) | compiles (keyword-only compile-time parameter, scratch probe) | rejected: restates the arity the handler already shows; fallback if disjointness is given up |
| source | C. wrappers `Body[T]` / `Path[T]` / `Query[T]` | compiles, `T` inferred through `Body[T]` (`test_wrapper_alternative_compiles`) | rejected: `body.value.name` puts extraction plumbing in business code; `Path[Int]` contradicts the proven `def get_user(id: Int)`; fallback for an overlapping type |
| source | D. type-directed (the conforming parameter is the body, any position) | same check mechanism as A | rejected: no gain under disjointness; free position multiplies overloads (arity x position) and makes the type carry the source |
| conversion | 1. Muntin trait, payload-specific (`FromBody`) | cross-module, move-only, raising, library never names the type | **chosen** |
| conversion | 1'. source-neutral `FromArg(String)` | compiles (M2-003 spike) | rejected: breaks disjointness |
| conversion | 2. decoder supplied at registration | compiles; handler and decoder boxed as one value in the unchanged `_Erased` (`test_decoder_alternative_fits_the_unchanged_box`) | rejected: a second argument on every body route and one decoder per position |
| conversion | 3. static factory by convention, no trait | `'Deinitable & Movable' value has no attribute 'from_body'` (`convention_without_trait.mojo`) | eliminated by the compiler |
| conversion | 4. reflection-based construction | feasible on 1.1.0 but not cheap: `std.reflection` offers field access, not a constructor (`field_count`, `field_names`, `field_types`, `field_ref`, `field_offset`); the `json` package built as a Flare dependency in this environment (`mojo >=1.1.0`) constructs structs with `deserialize_json[T]`, requiring `T: Defaultable` and using `MaybeUninit`, `field_ref` writes and `downcast` (not reproduced standalone here) | not part of extraction; a codec concern |

**Not JSON.** The extraction contract is the conformance; it chooses no body format (the spike's `CreateUser` reads `name=<text>`). A JSON codec, when it comes, fills `from_body` (a helper the application calls inside it, or a trait refining `FromBody` with a default implementation over reflection, which on 1.1.0 needs `Defaultable` and `downcast`; table row 4) without changing routing or binding. Until then, DX section 4's "no manual decoding" is not met.

**Diagnostics** (Muntin-owned `constraint failed:` texts in the spike): `the handler's parameter is the request body; its type must conform to FromBody` (`body_without_conformance.mojo`), `route declares a path or query parameter; the handler parameter bound to it must be Int`, `Int is a route-value type, never the request body; declare a path or query parameter for every Int parameter` (`two_ints_one_route_value.mojo`), and the production `Int` arity text for a lone `Int` on a route without values. `def(var id: Int)` does not convert to the borrowed `def(Int)` overload and reaches the generic one, which says so: ``an owned (`var`) Int parameter is not supported; declare it borrowed (`id: Int`)``. An order or count with no overload (two bodies, body first) keeps the compiler's `no matching method in call to 'post'` with per-candidate notes.

**Error boundary.** No matching route is 404. A matched route whose value cannot be gathered or converted is 400, decided before the handler runs: gathering (missing or duplicated query key) in `handle`, conversion in the adapter, which answers 400 itself. Anything raised out of `invoke` is then a handler error (500 in the spike, a placeholder for the application-error model). Production today has one `try` around gathering and `invoke` and maps any raise to 400, because `_call_int` raises on conversion; that is equivalent only while handlers cannot raise. The first body adapter should answer its own 400, and when raising handlers arrive `_call_int` moves to the same pattern so `handle`'s `except` belongs to the application-error model. Decided in M2-010 ("Application-error decision (M2-010)" below): request failures are answered 400 where they occur, and a handler error is a fixed 500 decided in the adapter.

**Body ownership.** `Request.body` stays an owned `String`, and `App.handle` borrows the `Request`, so `from_body` borrows `body: String`; consuming it would need an owned `Request` in the backend seam. The body reaches the adapter as one more raw string: one copy per body request, and `_Call[F]`'s `List[String]` input is unchanged. Passing the borrowed `Request` to the trampoline instead is a signature change in `_handler_storage.mojo`, not a representation change; make it when the copy is measured to matter. No streaming, zero-copy or buffer lifetime design.

**Storage stays unchanged.** The spike imports production `_Erased` unmodified and stores every body shape (and the decoder pair) in it: the source plan is route data (`_XRoute.body`, `.query_key`), conversion lives in the per-shape adapter, and no unsafe operation was added or needed; `scripts/check_unsafe.sh` is unchanged.

**Evidence.** `tests/extraction_spike.mojo` (library side: `FromBody`, `ExtractApp`, adapters, production `_Erased` and `_match`/`_parse_int`/`_query_value`) and `tests/test_spike_extraction.mojo` (application side, 9 tests: `CreateUser`, `RenameTeam`, borrowed and owned body handlers, `(Int, B)` from a path and from a query value, 400 versus handler failure, the borrowed `Request` unchanged, an app move). `check.sh` builds the library side with `tests/extraction_lib_only/driver.mojo` from a directory without the application module, which registers a body type the library has never seen; this is needed because 1.1.0 accepts a circular import between two modules on one include path and resolves imports lazily. `tests/extraction_fail/*.mojo` (8) are checked for their diagnostics. Mutations (planted, reverted), each red: route and body slots swapped, body gathered before route values, handler raise mapped to 400 (tests); body never gathered (crash: index out of bounds); conversion error swallowed and handler called (compile error); the route-slot or `Int`-arity assert removed (fixture compiles); the registration conformance assert removed, or the `Int` type-equality guard removed (fixture loses Muntin's message); the library special-casing an application type (isolated build fails). Renaming handler parameters stays green. Sources: Mojo 1.1.0 (8189361e) for every compile claim; modular/modular at tag `mojo/v1.1.0`: `docs/site/releases/v1.1.0.md` and `v1.0.0.md` (`trait_downcast` removal and `conforms_to` refinement), `docs/site/manual/generics.mdx` and `manual/metaprogramming/constraints.mdx` (`comptime if conforms_to`, `where` for user preconditions, `comptime assert` for library-internal checks), `std/builtin/rebind.mojo` (`downcast`, `rebind_var`, no longer needed), `std/reflection/reflect.mojo` (field access, no constructor). No post-1.1.0 behavior was relied on. Candidate B was compiled in scratch probes (also reproduced by the fresh-context review), not retained, since its rejection is not about feasibility.

**Revisit when:**

- an application-defined route-value type (`UserId` from a path segment) or a builtin or raw-text body type (`body: String`) is required: either breaks disjointness, so binding for that case becomes explicit (B or C);
- Mojo reflection exposes function parameter names: name-based binding (DX section 3's `search(query, limit)`) becomes possible;
- `convention_without_trait.mojo` or `borrowed_and_owned_overloads.mojo` starts compiling, or `conforms_to` refinement changes again (it replaced `trait_downcast` between 0.26 and 1.1);
- extensions start working across modules (`builtin_body_via_extension.mojo` then fails with Muntin's message instead) or `conforms_to` starts seeing extension conformances (`extension_invisible_to_conforms_to.mojo` compiles): the type-equality guard must then cover every route-value type, and a Muntin-side extension of a builtin becomes visible to the conformance check;
- optional, multiple or streaming bodies are needed (this decision covers one required body);
- the per-request body copy is measured to matter.

**Next production slice.** `app.post["/users"](create_user)` with `def create_user(body: CreateUser) -> String`: one `post` overload taking `def(var B) -> String` on a route that declares no route value, the body trait exported from `muntin` (public API, so DX updated with it), an adapter that answers its own 400, `TestClient.post(target, body)`, and loopback parity through the Flare adapter (which already passes the body). `(Int, B)` waits for its own slice, as the first two-parameter shape. Done in M2-006, below.

### Body-only POST (M2-006)

Production implements exactly the body-only case of the M2-005 decision: `app.post["/users"](create_user)` with `def create_user(body: CreateUser) -> String`, `CreateUser` an application type conforming to `muntin.FromBody`.

```text
POST /users, body "name=Ada"
  App.handle: method + path match (_match); route.body -> args = [request.body]   (one String copy)
  _Erased.invoke(args)  -> _call_body[CreateUser]: CreateUser.from_body(args[0])
      raises -> 400 Bad Request, handler not called
      ok     -> create_user(body^) -> Response.text(...)
```

- **Public contract:** `FromBody` in `src/muntin/body.mojo`, exported from `muntin`: `trait FromBody(Deinitable, Movable)` with `@staticmethod def from_body(body: String) raises -> Self`. `from_body(body: String)` is the current public body-conversion input contract (the `Request` holds one owned `String` body, no headers or content type); future body capabilities are added as new APIs without changing it. `TestClient.post(target, body)` builds `Request("POST", target, body)` and calls `App.handle`; it converts nothing.
- **Registration:** one overload, `post[B: Movable & Deinitable, //, path: StaticString](mut self, handler: def(var B) thin -> String)`. A handler declaring `body: B` or `var body: B` converts to it. Checks, in order, each a `comptime assert` with a Muntin message: the literal is well formed; it declares no path or query placeholder; `B` is not `Int` (type equality, M2-005); `conforms_to(B, FromBody)`. `String` and `Request` parameters fail the last check. Shapes with another arity, `raises` or a return type that does not convert to `String` (`Response`) do not convert to the one overload (`tests/body_fail`); `-> StaticString` converts implicitly and is accepted, as on `app.get` since M2-001. `App.get` is unchanged and has no body overload.
- **Source and conversion:** whether a route takes the body is route data (`_Route.body`), as the query key is. `App.handle` appends `request.body` as the last raw argument after matching method and path; nothing else reads `Request.body`. `_call_body[B]` in `app.mojo` refines `B` with `comptime assert conforms_to(B, FromBody)` (the documented 1.1.0 mechanism; no `downcast`, `rebind_var` or `__extension`), converts, answers 400 itself on a raise, and moves the value into the handler, so `B` may be move-only. `_call_body` does not raise; `App.handle`'s `try` → 400 still serves `_call_int` and gathering, as before. No route match is 404 before any conversion.
- **Storage unchanged:** `src/muntin/_handler_storage.mojo` is byte-identical to M2-004; the body handler is one more `_Erased.__init__[call=_call_body[B]]` instantiation through the existing `_Call[F]` (`def(F, List[String]) raises thin -> Response`). No unsafe operation was added. `scripts/check_unsafe.sh` now also fails if the storage module names `FromBody`, `from_body`, `Request` or `.body`, so request and body handling stay in `app.mojo`.
- **Package boundary:** the application body type lives in the application module; `mojo precompile src/muntin` (in `check.sh`) builds the package with no application module, and `tests/test_body.mojo` defines `CreateUser` (asserted not `Copyable`) and `RenameTeam` outside it. The M2-005 lib-only driver is not needed for production: the package build is that oracle.
- **Flare:** `adapters/flare/muntin_flare.mojo` is unchanged; it already copied the body into `Request`. The loopback test adds `POST /users` to its typed-route server and sends bodies with Flare's raw-bytes `post` (no `Content-Type`); valid (`name=Ada` -> `created Ada`, also with a query `name=Bob`), invalid (`Ada`, empty), bodies a backend must not touch (an empty and a whitespace-padded body to a type that accepts any body, echoed unchanged), wrong-method (`GET /users`, `POST /users/42`, `POST /hello`) and missing-route (`POST /missing`) results equal `TestClient`.
- **Evidence:** `tests/test_body.mojo` (12: conversion before the handler, the body byte for byte (empty, whitespace, `=&?`), 400 without the handler or with `from_body` recorded through environment variables, body source, 404 without conversion, GET routes on the same path, owned parameter, two body types, borrowed `Request`, `TestClient.post` parity, `App` moves); `tests/compile_fail/post_*.mojo` (6) and `tests/body_fail/*.mojo` (7); adapter contract test `test_adapter_post_body_matches_in_memory_backend`; loopback parity. Mutations (planted, reverted), each red: body never appended (crash), body taken from the query or the path, handler called after a conversion failure (environment-variable oracle; the response stayed 400), conversion failure answered 404 or 200, the route registered as `GET`, `TestClient.post` sending `GET` or dropping the body (`test_body`); the `Int` guard, placeholder check or conformance check removed, an `(Int, B)` overload added (fixtures); the storage module importing `Request` (`check_unsafe.sh`); the adapter rewriting the body or answering an empty `POST` body with 400 itself (adapter contract tests); `App.handle` or `TestClient.post` stripping the body (`test_body`). Whether `_call_body` answers 400 itself or raises into `App.handle`'s `except` is not observable until handlers can raise.
- **Not supported at M2-006:** `(Int, B)` (added later by M2-009) and any other multi-parameter shape, `Int`/`String`/`Request` bodies, body handlers on `GET`, `POST` without a body, other methods, raising handlers, `-> Response` and other return types that do not convert to `String`, raw handlers, JSON, optional or multiple bodies, streaming.

### Typed response decision (M2-007)

Status: **decision** (M2-007), implemented in production by M2-008 ("Typed results in production (M2-008)" below). In M2-007 itself production was unchanged; its only `src/muntin` edit was the wording of `FromBody`'s docstring. This section decides how a handler's result becomes a `Response` so that `def get_user(id: Int) -> User` can be registered with `app.get["/users/{id}"](get_user)` without Muntin naming `User`.

```text
handler result --(overload, selected by the handler's function type)--> return policy
  function type compatible with def(...) thin -> String   (-> String, -> StaticString)   _text: 200 text, as today
  result type R conforming to ToResponse (app type, Response)                            R.to_response(), R moved in
adapter (one per argument shape):  extract args -> call handler -> respond(result)        respond: compile-time parameter
```

**Contract.** A Muntin-owned public trait that the application type conforms to in its own module, the output-side counterpart of `FromBody`:

```mojo
trait ToResponse(Deinitable, Movable):
    def to_response(var self) -> Response: ...
```

The type decides status and body; Muntin never names it. Each existing argument shape gets one generic overload whose result type is bound by the trait (`get[R: ToResponse, //, path](handler: def(Int) thin -> R)`, and so on), beside the existing `String` overload, which keeps its exact signature. The handler is stored in the unchanged `_Erased` box like every other shape.

**`String` and `StaticString`: declared return type versus the registered function type.** The `String` overloads accept a handler whose function type converts to `def(...) thin -> String`. That is a declared `-> String`, and also a declared `-> StaticString` through Mojo 1.1.0's implicit conversion; it is not a property of the declared type alone. Both stay on the `String` overloads and keep today's behavior. `String` does not conform to `ToResponse` and does not need to: a stdlib type could only conform through `__extension`, which the 1.1.0 documentation does not describe. The generic overload binds `R` with a trait bound, so a `String`-compatible result is never a viable candidate for it, and which overload is selected does not depend on how the compiler ranks implicit conversion against parameter inference. With the alternative, a generic `R: Movable & Deinitable` refined by `comptime assert conforms_to(R, ToResponse)` (or a `where` clause), 1.1.0 also selects the `String` overload for `-> StaticString`, but there the generic candidate is viable and the outcome rests on that undocumented ranking. An application type cannot be both `String`-compatible and a `ToResponse` type: `String`'s implicit constructors are stdlib-defined, and a `Writable` type does not convert (`cannot implicitly convert 'W' value to 'String'`).

**`Response`: a direct escape hatch, through the same trait.** `Response` conforms to `ToResponse` in `http.mojo`, the module that declares both (so no import cycle), with `def to_response(var self) -> Response: return self^`: a handler's `Response` is moved through unchanged, no extra overload. DX section 5 requires explicit response construction to stay available, and it is how a handler chooses a status today. Raw `Request` input (DX section 9) is a separate escape hatch and not decided here. A concrete `def() thin -> Response` overload next to this conformance is not ambiguous on 1.1.0 (the concrete overload is selected), so a separate `Response` overload would only duplicate what the conformance gives. Both facts were shown on the unretained scratch copy of the next slice (production `Response` cannot conform to the spike's trait). M2-008's tests retain the first (`-> Response` through the conformance); the second is moot in production, which has no concrete `Response` overload.

**Ownership: by move.** After the call, Muntin owns the result and nothing else needs it, so the requirement takes `var self` and `_converted[R]` passes `result^`. A move-only result works (`User` is not `Copyable`); a conversion can move a field into the `Response` instead of copying it. A `var self` requirement is the most permissive one for implementers: implementations declaring a borrowed `self` (`Created`), `var self`, or `deinit self` (`User`) all satisfy it, while a borrowed `self` requirement rejects a `var self` implementation (`no 'to_response' candidates have type 'def(self: U) thin -> Response'`). On 1.1.0 a `var self` method cannot move one field out of a value that has other fields (`field 'self.name' destroyed out of the middle of a value`); `deinit self` can, so a destructuring implementation declares `deinit self`.

**Errors: the conversion does not raise.** A raising implementation does not conform (`tests/response_fail/raising_conversion.mojo`). A non-raising implementation does satisfy a `raises` requirement (`test_widened_raising_requirement_accepts_existing_conformance`), so on Mojo 1.1.0 a future `raises` requirement would preserve existing conformances. It is not additive for the public API: generic code that calls `to_response()` through a `ToResponse` bound outside a raising context would stop compiling (`cannot call function that may raise in a context that cannot raise`, checked against the spike's `ToResponseRaising`), so the change may be source-breaking for callers and must be reconsidered with the application-error model. The conversion runs after extraction and the handler succeed: a 400 or 404 calls neither (`test_extraction_failure_skips_handler_and_conversion`). Raising handlers stay unsupported for typed results too (`tests/response_fail/raising_handler.mojo`); M2-005's error boundary is unchanged.

**One return policy across GET and POST, independent of extraction.** Each adapter handles one argument shape and is generic over the result type and a compile-time `respond: def(var R) thin -> Response`: `_call_none[R, respond]`, `_call_int[R, respond]`, `_call_body[B, R, respond]`. The `String` overloads instantiate `respond=_text`, the generic ones `respond=_converted[R]`. Extraction never inspects `R` and the policy never sees where the arguments came from: the spike returns one `User` type from a route without values, a path segment, a query value and a request body (`test_one_return_policy_across_get_and_post`). Registration overloads are argument shapes x {`String`, `ToResponse`}: 3 to 6 today; a future shape adds two. The adapter parameters are explicit (no `//`) because they are passed as `call=` to `_Erased.__init__`, where there is no runtime argument to infer them from.

**Storage unchanged.** `_Call[F]` already returns `Response`, and `R` lives inside the typed trampoline; it is never erased. The spike stores mixed `String`, `StaticString`, `User` and `Created` handlers in production's `_Erased`, unmodified, and dispatches them before and after moving the app. No unsafe operation is added.

Alternatives compared (all on Mojo 1.1.0 (8189361e)):

| Candidate | Result | Verdict |
|---|---|---|
| 1. Muntin-owned trait on application types (`ToResponse`) | cross-module, move-only, mixed with `String` handlers in one `_Erased` list, GET and POST | **chosen** |
| 2. explicit converter at registration (`app.get["/users/{id}"](get_user, user_json)`) | compiles; handler and converter boxed as one value in the unchanged `_Erased` (`test_explicit_converter_alternative_fits_the_unchanged_box`), as M2-005's decoder | rejected: changes the registration syntax of every typed route and restates what the return type already says; fallback if one type ever needs different representations per route |
| 3. convention without a trait (`result.to_response()` on an unbounded `R`) | `value has no attribute 'to_response'` (`tests/response_fail/convention_without_trait.mojo`) | eliminated by the compiler |
| 4. direct `Response` special case (concrete `-> Response` overloads) | compiles; not ambiguous next to a `Response` conformance (concrete selected; scratch copy, not retained) | rejected as a mechanism: covers no application type, and duplicates the `Response` conformance |
| `__extension String(ToResponse)`, one overload per shape | compiles (M0.5 spike) | not relied on: undocumented on 1.1.0 |

**Diagnostics.** A result type that is neither `String`-compatible nor conforming fails at the registration call with `no matching method in call to 'get'` and a note naming the trait: `argument type 'Int' does not conform to trait 'ToResponse'` (`tests/response_fail/non_conforming_return.mojo`). Costs, measured on a scratch copy of the next slice: the candidate list doubles; for a raising `String` handler the generic candidate's note says `argument type 'String' does not conform to trait 'ToResponse'` next to the `String` candidate's real `raises` mismatch; `app.post`'s single-candidate `invalid call to 'post'` becomes `no matching method in call to 'post'`; and a raw `def(req: Request) -> Response` passed to `app.post` reaches the generic overload with `B = Request` and fails with Muntin's own `FromBody` constraint message.

**Evidence.** `tests/response_spike.mojo` (library side: `ToResponse`, `ResponseApp` with production's `App.handle`, adapters generic over `respond`, production `_Erased`, `FromBody`, `_match`, `_parse_int`, `_query_value`) and `tests/test_spike_response.mojo` (application side, 8 tests: `String`/`StaticString` handlers still on the `String` overloads with the generic ones present, `User` and `Created` converting themselves, move-only result converted once, one policy for four argument sources, 400/404 without handler or conversion, app moves, the widened `raises` requirement, candidate 2). `tests/response_lib_only/driver.mojo`, built by `check.sh` from a directory without the application module, registers result types the library has never seen and aborts on a wrong response. `tests/response_fail/*.mojo` (4). Not retained: a scratch copy of `src/muntin` with exactly the next slice applied (trait in `http.mojo`, `Response` conformance, generic adapters, three generic overloads) precompiles with `--Werror`, passes `test_app` 23/23, `test_body` 12/12 and `test_handler_storage` 6/6 unchanged, and serves `-> User`, `-> Response` (status 204, 418, 201) and `-> StaticString` routes through `TestClient`; the fixture changes it causes are listed under the next slice. Sources: Mojo 1.1.0 (8189361e) for every compile claim; no post-1.1.0 behavior relied on.

**Revisit when:**

- `test_string_compatible_handlers_keep_the_string_overload` or `non_conforming_return.mojo` changes result after a toolchain change (overload resolution or trait-bound checking changed);
- `__extension` becomes documented: `String` could conform, collapsing each shape to one overload;
- the application-error model needs a fallible conversion: reconsider a `raises` requirement with it (existing conformances would be preserved, shown above, but callers may break) and decide what a raise means;
- a type needs different representations per route (content negotiation): candidate 2 becomes the fallback;
- the stdlib gives `String` an implicit constructor from a trait that application types can conform to (a type could then be both `String`-compatible and `ToResponse`);
- raw `def(Request) -> Response` handlers (DX section 9) arrive: with a concrete `post(def(Request) thin -> Response)` overload next to both body overloads, 1.1.0 selects it for `def raw(req: Request) -> Response`, but `def raw(var req: Request) -> Response` matches only the generic `def(var B) thin -> R` (`B = Request`, unbounded in the signature) and then fails on the `FromBody` assert; that slice decides whether to accept this or bound `B`;
- a JSON codec arrives: it fills `to_response` (as it fills `from_body`), without changing registration.

**Next production slice.** `def get_user(id: Int) -> User` on `app.get` and `def create_user(body: CreateUser) -> User` on `app.post`, plus `-> Response`:

- `src/muntin/http.mojo`: `trait ToResponse(Deinitable, Movable)` with `def to_response(var self) -> Response`; `Response` conforms with `return self^`; `muntin` exports `ToResponse`.
- `src/muntin/app.mojo`: `_call_none`, `_call_int`, `_call_body` generic over `R` and `respond`, with `_text` and `_converted[R]`; the three existing overloads keep their public signatures and checks and instantiate `respond=_text`; three new overloads, `get[R: ToResponse, //, path](def() thin -> R)`, `get[R: ToResponse, //, path](def(Int) thin -> R)`, `post[B: Movable & Deinitable, R: ToResponse, //, path](def(var B) thin -> R)`, each with the same route-literal and body checks as its `String` twin.
- `_handler_storage.mojo` byte-identical; no unsafe operation; the Flare adapter unchanged.
- Fixtures (verified on the scratch copy): `storage_fail/response_return_handler.mojo` and `body_fail/post_response_return.mojo` start compiling and retire into positive tests; `body_fail/post_{no_param,int_and_body,two_bodies,raising_handler}.mojo` now fail with `no matching method in call to 'post'` (M2-008's fixtures keep checking the `String` candidate's note); `body_fail/post_raw_handler.mojo` expects the `FromBody` constraint message; `storage_fail/{copy_erased,downstream_move_header,mismatched_trampoline}.mojo` spell the adapters with their new parameters. Every `compile_fail` fixture and the other `storage_fail`/`body_fail` fixtures keep their diagnostics.
- Docs: DX's "Proven vs. target status" sentences that list `-> Response` as `invalid call to 'post'` and the current handler shapes change with the slice.
- Tests: `-> User` from a route without values, a path segment, a query value and a body; `-> Response` choosing its status; `-> StaticString` still on the `String` overload; a move-only result; no conversion on 400/404; `TestClient` and loopback parity through Flare for one `-> User` and one `-> Response` route.
- Still out at M2-007: raising handlers or conversions, `(Int, B)` (implemented later in M2-009), JSON, headers, raw `Request` handlers.

Done in M2-008, below.

### Typed results in production (M2-008)

Production implements exactly the slice above. A handler returns `String` (or a `String`-compatible type such as `StaticString`) or a type conforming to the public `muntin.ToResponse`, on every existing argument shape:

```text
registration (6 overloads)                          adapter instantiation stored in _Erased
get[path](def() thin -> String)                     _call_none[String, _text]
get[R: ToResponse, //, path](def() thin -> R)       _call_none[R, _converted[R]]
get[path](def(Int) thin -> String)                  _call_int[String, _text]
get[R: ToResponse, //, path](def(Int) thin -> R)    _call_int[R, _converted[R]]
post[B, //, path](def(var B) thin -> String)        _call_body[B, String, _text]
post[B, R: ToResponse, //, path](def(var B) thin -> R)   _call_body[B, R, _converted[R]]
```

- **Trait and `Response`:** `trait ToResponse(Deinitable, Movable)` with `def to_response(var self) -> Response` is declared in `http.mojo` next to `Response`, which conforms with `return self^`, and exported from `muntin`. `-> Response` therefore resolves to the generic overloads with `R = Response`; no `Response`-specific overload exists.
- **Overloads:** the three `String` overloads keep their exact signatures, checks and messages, and now instantiate `respond=_text`. Each generic twin repeats its twin's `comptime assert`s word for word (route literal, arity, `B` not `Int`, `conforms_to(B, FromBody)`), so a route or body mistake gives the same message whichever return policy the handler uses (`tests/compile_fail/typed_*.mojo`). The bound `R: ToResponse` keeps `String`-compatible results off the generic overloads: `-> StaticString` still resolves through implicit conversion to the `String` overloads, and `String`/`StaticString` do not conform (`test_result_types_are_application_defined`).
- **Adapters:** `_call_none[R, respond]`, `_call_int[R, respond]`, `_call_body[B, R, respond]` keep their extraction code; only the last step changed, from `Response.text(handler(...))` to `respond(handler(...))`. `_call_body` still answers 400 itself before the handler on a `from_body` raise, and `_call_int` still raises (→ 400 in `App.handle`) before the handler on a bad value, so neither the handler nor the conversion runs on 400; a 404 never reaches an adapter.
- **Storage and backends unchanged:** `_handler_storage.mojo` is byte-identical; `R` lives only in the typed trampoline instantiation, never erased. No unsafe operation was added (`check_unsafe.sh`). The Flare adapter is unchanged: `App.handle` returns the converted `Response` and the adapter carries it as before.
- **Diagnostics changed by the extra candidates:** `app.post` shapes that match no overload (no parameter, `(Int, B)` until M2-009, two bodies, `raises` until M2-011) now report `no matching method in call to 'post'` with one note per candidate instead of `invalid call to 'post'`; the `String` candidate's note is unchanged and still checked (`tests/body_fail`). A raw `def(request: Request) -> Response` passed to `app.post` reaches the generic overload with `B = Request` and fails on the `FromBody` assert (`body_fail/post_raw_handler.mojo`), as recorded in the revisit conditions above; not addressed here. `app.get` notes gain the generic candidates (`argument type 'String' does not conform to trait 'ToResponse'` for a mismatched `String` handler); the `String` notes the fixtures check are unchanged. A non-conforming result (`-> Int`) fails at registration with `argument type 'Int' does not conform to trait 'ToResponse'` (`storage_fail/non_conforming_return_handler.mojo`, `body_fail/post_non_conforming_return.mojo`). A raising typed handler matched no overload until M2-011 (`storage_fail/raising_typed_handler.mojo`, retired then); a raising `to_response` does not conform (`storage_fail/raising_to_response.mojo`).
- **Evidence:** `tests/test_response.mojo` (application-defined move-only `User` on no-argument, path, query and body routes, `Created` choosing 201 with a borrowed `self`, `Token` with `var self`, `-> Response` with 418/202/201 on GET and POST, `-> StaticString` on GET and POST, handler and conversion counts, 400/404 with neither, mixed handlers after `App` moves); the earlier fixtures `storage_fail/response_return_handler.mojo` (M2-004) and `body_fail/post_response_return.mojo` (M2-006) now compile and were retired in favor of those tests. Loopback through Flare: `GET /people/{id}` and `POST /people` (`-> Person`, defined in the test) and `GET /teapot` (`-> Response`, 418) equal `TestClient`. The M2-007 spike (`tests/response_spike.mojo` and its fixtures) is kept as decision evidence: it covers the rejected candidates and the widened `raises` requirement, which production tests do not.

### Route value then body in production (M2-009)

Production implements the M2-005 `(Int, B)` case with the M2-008 return policies, and nothing more: `app.post["/users/{id}"](update_user)` and `app.post["/users?{id}"](update_user)` with `def update_user(id: Int, body: UpdateUser) -> String` or `-> R`, `R: ToResponse`.

```text
registration (2 overloads added, 8 in all)                    adapter instantiation stored in _Erased
post[B, //, path](def(Int, var B) thin -> String)             _call_int_body[B, String, _text]
post[B, R: ToResponse, //, path](def(Int, var B) thin -> R)   _call_int_body[B, R, _converted[R]]

POST /users/042 (or /users?id=042), body "name=Ada"
  App.handle: method + path match; args = [path capture | query value, request.body]
      query key missing/duplicated -> raise -> 400   (before any conversion)
  _Erased.invoke(args) -> _call_int_body:
      _parse_int(args[0])          raises -> 400 in App.handle; from_body and handler not called
      B.from_body(args[1])         raises -> 400 answered here; handler not called
      respond(handler(id, body^))  handler once, then _text or _converted[R] once
```

- **Binding and source:** positional, as decided in M2-005: slot 0 is the one route value, slot 1 the body. Where the route value comes from (path segment or query item) is route data (`_Route.path`, `_Route.query_key`), and the body flag is `_Route.body`; `App.handle` already appended the route value before the body, so dispatch did not change. Parameter names are never consulted.
- **Registration checks**, the same four on both overloads, word for word: the literal is well formed; it declares exactly one route value (`_path_params + _query_params == 1`, so no value, two path values, or a path and a query value are rejected with one message: `handler takes one Int parameter and the request body; route must declare exactly one path or query parameter`); `B` is not `Int` by type equality (the body-only overload's message, reused because it names the rule, not the route); `conforms_to(B, FromBody)` (`the handler's last parameter is the request body; ...`, distinct from the body-only `the handler's parameter ...`). Disjointness is kept as M2-005 requires: the route slot is the concrete `Int` of the function type, the body slot rejects `Int` and requires `FromBody`.
- **Adapter:** one new adapter, `_call_int_body[B, R, respond]`, built from the existing pieces in the existing order: `_call_int`'s step (`_parse_int`, raising into `App.handle`'s 400), then `_call_body`'s step (`from_body` in a `try`, answering 400 itself), then the response policy. `B` is refined in the adapter with `comptime assert conforms_to(B, FromBody)`, as in `_call_body`. The body is moved into the handler, so `B` may be move-only; a move-only `R` is moved into its conversion. `_call_none`, `_call_int`, `_call_body` are unchanged. Raising for the route value and answering 400 for the body are indistinguishable today (handlers cannot raise); the split follows the existing adapters and is to be revisited with the application-error model, as recorded in M2-005's "Error boundary". (Since M2-011 both answer 400 in the adapter.)
- **Overload resolution:** the new function types differ in arity from every existing one, so no existing handler changes overload. Existing `app.post` diagnostics keep their checked notes and gain two candidate notes; `body_fail/post_int_and_body.mojo` (M2-006) now compiles and was retired in favor of `tests/test_int_body.mojo`. Shapes that stay closed: `(B, Int)`, `(Int, B, B)`, `(var Int, B)`, a raising handler (accepted since M2-011, its two fixtures retired) and a result that is neither `String`-compatible nor `ToResponse` (no overload; `tests/body_fail/post_{body_then_int,int_and_two_bodies,owned_int_and_body,int_body_non_conforming_return}.mojo`, and `int_body_raising_handler`/`int_body_raising_typed_handler` until M2-011), and the Muntin-message cases above (`tests/compile_fail/{,typed_}post_int_*.mojo`). The raw `Request` handler issue recorded in M2-007 is unchanged.
- **Storage and backends unchanged:** `_handler_storage.mojo` and `adapters/flare/muntin_flare.mojo` are byte-identical to M2-008; no unsafe operation was added (`check_unsafe.sh` unchanged).
- **Evidence:** `tests/test_int_body.mojo` (13: path and query sources; a body that is itself an integer and a route value that is itself a valid body, so only `[route value, body]` binding gives the expected text; invalid path values and invalid, missing, duplicated and empty query values with valid and invalid bodies → 400 with `from_body`, the handler and the conversion each counted 0; invalid bodies → 400 with `from_body` counted once and the handler 0; 404 with nothing counted; a matched query route whose key is missing answers 400 without falling through to a later route on the same path; `-> String`, `-> StaticString`, `-> Response` (202) and move-only `-> User` converted once; move-only bodies borrowed and owned; `TestClient.post` equal to `App.handle`; `App` moves). Loopback through Flare: `POST /accounts/{id}`, `/accounts?{id}` (`-> String`) and `/profiles/{id}` (`-> Person`) with valid path and query values, invalid values, a missing query value, invalid bodies and a typed result, equal to `TestClient`. Mutations (planted, reverted), each red: body converted before the route value, body parsed as the `Int`, route value passed to `from_body`, the handler called after a route-value or body failure, `App.handle` appending the body before the query value, the response policy skipped, `App.handle` falling through to the next route after a 400, the route registered without the body flag (crash) or as `GET`; each of the arity, `Int` and `FromBody` asserts removed from either overload (fixture compiles or loses Muntin's message); the `R: ToResponse` bound dropped (fixture loses the trait note); the `String` `(Int, B)` overload removed (tests stop compiling); a reversed `(B, Int)` overload added (`post_body_then_int.mojo` compiles); an unsafe import in `app.mojo` or request names in the storage module (`check_unsafe.sh`); the storage module edited (diff against `main`).
- **Not supported:** more than one route value, a path and a query value together, two or optional bodies, `String`/builtin bodies, raising handlers (added by M2-011) or conversions, raw `Request` handlers, JSON, headers, other methods, middleware, state.

### Application-error decision (M2-010)

Status: **decision** (M2-010, merged as PR #18); production implements it since M2-011 ("Raising handlers in production (M2-011)", below). This section decides how a handler such as `def get_user(id: Int) raises -> User` registers with the existing `app.get["/users/{id}"](get_user)` syntax, where request failures stop and handler failures begin, and what a handler failure becomes on the wire, while `App.handle(Request) -> Response` stays the backend seam.

```text
route match            no match                            -> 404   (App.handle)
query gathering        _query_value raises                 -> 400   (App.handle, its own try)
route value            _parse_int raises                   -> 400   (adapter, its own try)
body                   B.from_body raises                  -> 400   (adapter, its own try)
handler call           handler raises E                    -> 500   (adapter, the only step in its try: _handler_error[E])
result                 respond(result^)  non-raising       -> the handler's response
invoke raises          (no adapter does)                   -> 500   (App.handle; never 400)
```

**Contract.** A handler may be non-raising (as today), declare `raises` (error type `Error`), or declare `raises T` for an application-defined `T`, on every existing argument shape and with either return policy. Registration syntax and the eight overloads stay as they are; each overload's function type gains one inferred error type, `E: Deinitable`:

```mojo
def get[E: Deinitable, //, path: StaticString](mut self, handler: def(Int) thin raises E -> String)
def get[E: Deinitable, R: ToResponse, //, path: StaticString](mut self, handler: def(Int) thin raises E -> R)
# likewise def(), def(var B) and def(Int, var B) on post
```

**Function type: parametric raises.** Mojo 1.1.0 documents this mechanism ("Parametric raises" in the errors chapter of the manual): a function-type parameter declared `thin raises E` infers `E` from the argument, and a non-raising argument infers `Never`, which the manual defines as equivalent to omitting `raises`. Measured: in one overload set, `E` is `Never` for a non-raising handler, `Error` for `raises`, and the application's type for `raises NotFound`. `-> StaticString` still converts to the `String` overloads, a borrowed `body: B` still converts to `var B`, and `B`, `E` and `R` are inferred together on the body shapes (`test_spike_error`, all eight overloads). Because `E` is inferred in every overload, it never decides between overloads. Shape still decides through arity and parameter types, and the `R: ToResponse` bound still decides the return policy, as since M2-008. No overload ranking is involved.
- `E: Deinitable`, not `AnyType`: the adapter catches the error and drops it, and a caught value bounded only by `AnyType` fails with `'e' abandoned without being explicitly destroyed` (`tests/error_fail/catch_unbounded_error_type.mojo`). `Never` and `Error` satisfy the bound. A linear error type (`Deinitable where False`) is rejected at registration (`does not conform to trait 'Deinitable'`), as is a handler declared `-> Never` (no result type to convert); both are unsupported, not ambiguous (fresh-context review probes, not retained).
- Spelling: `thin raises E`, the manual's order. `raises E thin` compiles, but `mojo format` on 1.1.0 cannot parse it (`Cannot parse`). Compiler notes print the type as `raises Never thin` (`tests/error_fail/wrong_arity_note.mojo`).

**Candidates for raising handlers** (all on Mojo 1.1.0 (8189361e)):

| Candidate | Result | Verdict |
|---|---|---|
| 1. widen each function type to a bare `raises` | non-raising and `raises` handlers convert (`test_widened_candidate_takes_error_and_non_raising_handlers`); a `raises NotFound` handler does not: `error type of the first type is 'NotFound' but the second type is 'Error'` (`typed_error_to_widened_type.mojo`) | rejected: blocks typed errors, the only channel that carries an application type to the catch (below); accepting them later would need a second signature change. With `E` fixed to `Error`, extraction and the handler call could also share one `try` unnoticed. |
| 2. a raising twin beside each non-raising overload | a non-raising handler converts to both: `ambiguous call to 'get'` (`raising_twin_overloads.mojo`); a raising handler selects the twin | eliminated by the compiler: no ranking prefers the exact match |
| 3. keep the shapes and infer the error type (parametric raises) | non-raising, `raises` and `raises T` on all eight overloads, mixed in one `_Erased` list, after `App` moves | **chosen** |

**Request failures versus handler failures.** One rule: a request-side failure is answered 400 by the step that fails, before the handler runs, and only the handler call sits in the adapter's handler `try`, whose error becomes 500. Query gathering keeps its place in `App.handle`, in its own `try`. `_call_int` and `_call_int_body` answer a `_parse_int` failure with 400 themselves, as `_call_body` already does for `from_body`, instead of raising into `App.handle`'s broad `except`. `respond` runs after the `try`, so the catch covers exactly the handler. Three compiler facts support the split:
- a `try` block has one error type, so an adapter cannot put `_parse_int` (raises `Error`) and the handler call (raises `E`) in one `try`: `cannot call function that may raise 'E' in context that supports an error type of 'Error'` (`extraction_and_handler_in_one_try.mojo`; the generic body is checked, so this holds for every `E`);
- a typed error cannot reach `App.handle`: `_Call[F]` raises `Error`, and an adapter that lets `E` escape does not convert to it (`typed_error_escaping_the_adapter.mojo`), so the adapter, the only code that knows `E`, chooses the response;
- 500 depends on which step raised, not on the error: a handler raising `Error("not an integer")`, `_parse_int`'s own text, is 500, while a bad value on the same route is 400 (`test_500_depends_on_the_step_not_the_message`).

`App.handle` keeps one `except` around `invoke`, mapped to 500: no adapter raises any more, so a raise there means a broken adapter, a server fault, never a client error. `_Call[F]` stays `raises` (a non-raising adapter converts to it), so `_handler_storage.mojo` does not change.

**Wire.** An unhandled handler error is `500` with the fixed text body `Internal Server Error`, like the fixed `Bad Request` and `Not Found` bodies. The error value is dropped unread. An `Error`'s message is arbitrary handler text: the spike's handlers raise `database password is hunter2` and `insert failed: duplicate key users_pkey`, both readable at the catch (`caught_text`) and absent from the response (`test_handler_error_text_never_reaches_the_client`). Muntin has no logging or observability hook, and printing to stderr from the library would be a policy decided with observability (M3), so the error is currently lost. An application that needs a specific response catches inside its handler and returns a `Response`.

**What Mojo exposes at the catch.** The adapter's `except e:` binds a value of the handler's error type, inferred:
- `raises` gives `Error`: a message (`Writable`, `String(e)`) and an optional stack trace (`get_stack_trace()`, collected only with `MODULAR_DEBUG=stack-trace-on-error`). It carries no application type: a typed error that passes through a bare-`raises` function arrives as `Error` (the manual's "type erasure"), and `Error` is a stdlib type an application cannot conform to a Muntin trait (`__extension` is undocumented).
- `raises T` gives `e: T`, statically typed, with its fields. The documented `comptime if conforms_to(E, ToResponse)` refinement lets code at the catch call `e^.to_response()`: the evidence helper `catch_converting` answers a `raises Gone` handler (`Gone: ToResponse`) with 410 (`test_typed_error_reaches_the_catch_boundary_with_its_type`). `ErrorApp` does not do this.
- A function declares at most one error type. Several failure kinds in one handler need one enumerated struct or a `Variant`, and an `Error`-raising call inside a `raises T` function must be caught and wrapped (manual: errors chapter).

**Application-defined error conversion: deferred.** The fixed 500 is the first error model. Conversion works mechanically for typed errors (above) but is not adopted:
- it would cover only `raises T` handlers. Mojo's recommended default, a bare `raises`, gives `Error`, which carries only text, so conversion would split handlers into two error models, or map errors by message;
- DX section 6 asks for central conversion. Whether that is per error type (the type conforms, as results do with `ToResponse`) or an application-level mapping, and how a handler with several failure kinds reads under one-error-type-per-function, is a DX decision with its own evidence;
- the fixed 500 is needed in any design, for `Error` and for error types that do not convert.

**A raised value is a handler error, whatever its type.** The rule is decided by control flow: a value the handler returns goes through the response policy, and a value it raises is a fixed 500. The error type's traits do not matter: a type that conforms to `ToResponse` converts when returned (`Gone` → 410) and is 500 when raised, with its `to_response` never run (`test_raised_to_response_value_is_a_handler_error`). The slice does not reject such error types. That would narrow what applications may raise for the sake of a conversion design that is not chosen yet. The later conversion stays additive without it, provided it is an explicit opt-in (its own trait, or an application-level mapping the application registers) rather than implied by `ToResponse`: a handler that raises a `ToResponse` type keeps its 500 until the application opts in.

**`ToResponse` stays non-raising.** Raising handlers do not require fallible conversion: the handler's error is caught before `respond` runs, and the conversion only sees a returned value. A fallible `to_response` remains the separate M2-007 revisit condition.

**Storage and backends.** `E` exists only in the adapter instantiation (`_call_int[E, R, respond]`) and in the stored function type `F`. `_Erased`, `_Call[F]` and the unsafe surface are unchanged, and the spike stores every kind in production's `_Erased`. `TestClient` and the Flare adapter still receive only the final `Response`; status 500 is chosen in Muntin, not in an adapter. `adapters/flare/muntin_flare.mojo` needs no change: on a scratch copy of `src/muntin` with the slice below applied, `check_flare.sh` passes unchanged (adapter 8/8, loopback 2/2).

**Evidence.** `tests/error_spike.mojo` is the library side: production `_Erased`, `FromBody`, `ToResponse`, `_text`/`_converted`, `_match`, `_parse_int` and `_query_value`, plus `ErrorApp` with the eight widened overloads, the adapters, the split `handle`, candidate 1 (`get_widened`) and the catch-boundary helpers. `tests/test_spike_error.mojo` is the application side (10 tests): non-raising handlers unchanged (including `-> StaticString`, `-> Response` 418 and `(Int, B)`); raising `Error` and `NotFound` handlers succeeding and failing on every shape, with `String` and `ToResponse` results; a fixed 500 with the result conversion never run; message independence; no leak; every request failure 400 with the handler count at 0; 404; app moves; candidate 1; a `ToResponse` type converted when returned and 500 when raised; the typed catch. `check.sh` builds `tests/error_lib_only/driver.mojo` without the application module, so its error type `Missing` is unknown to the library. `tests/error_fail/*.mojo` (6) are checked for their diagnostics. Mutations, planted and reverted, each red: handler error answered 400 (5 tests), 500 answered as 200 (6 tests), query gathering answered 500 (1 test), `_parse_int` moved into the handler's `try` (compile error, above), `_handler_error` converting a raised `ToResponse` value (1 test). Not retained: a scratch copy of `src/muntin` with exactly the slice below applied precompiles with `--Werror`; it passes `test_app` 23/23, `test_body` 12/12, `test_int_body` 13/13, `test_response` 8/8, every spike and `check_flare.sh` unchanged. It fails only the fixtures and the one storage test listed under the slice. Sources: Mojo 1.1.0 (8189361e) for every compile claim; modular/modular at tag `mojo/v1.1.0`: `docs/site/manual/errors.mdx` (typed errors, `Never`, parametric raises, type erasure through bare `raises`, one error type per `try`, `get_stack_trace`) and `docs/site/releases/v0.26.1.md`/`v0.26.2.md` (typed errors introduced).

**Revisit when:**

- inference of the error type changes: `test_non_raising_handlers_are_unchanged` or `wrong_arity_note.mojo` changes result, or `raising_twin_overloads.mojo` starts compiling (twins would then rest on ranking; one overload per shape is still preferred);
- `typed_error_to_widened_type.mojo` compiles (typed errors convert to `Error`), or `typed_error_escaping_the_adapter.mojo` compiles (a typed error could reach `App.handle`);
- `extraction_and_handler_in_one_try.mojo` compiles: the compiler no longer keeps the two catches apart, and only tests do;
- application-defined error responses are needed: decide per-type conversion versus an application-level mapping, as an explicit opt-in so that today's 500 for a raised `ToResponse` type does not change silently;
- an observability or logging hook arrives: decide where a dropped handler error goes;
- `Error` gains structured payloads, or `except` gains type matching;
- `mojo format` accepts `raises E thin` (spelling only);
- `tests/storage_fail/typed_thin_value_handler.mojo` compiles: a value typed `def() thin -> String` converts to `def() thin raises E -> String` again, and the M2-011 source-compatibility exception can be dropped.

**Next production slice.** Raising handlers with a fixed 500, nothing more:

- `src/muntin/app.mojo`: each of the eight overloads gains `E: Deinitable` (inferred, before `//`) and its function type becomes `thin raises E`; route and body `comptime assert`s and messages are unchanged. `_call_none`, `_call_int`, `_call_body` and `_call_int_body` gain `E` as their first non-body parameter. `_call_int` and `_call_int_body` answer a `_parse_int` failure with 400 themselves. Each adapter calls the handler alone in a `try` whose `except` returns `_handler_error[E]` (fixed 500, whatever `E` is), then `respond(result^)`. `App.handle` gathers the query value in its own `try` → 400 and maps a raise from `invoke` to 500. Docstrings that say handlers do not raise change with it.
- Unchanged: `_handler_storage.mojo` code (one docstring sentence changes: `_Call`'s "Raising means an argument failed to convert" becomes false, since no adapter raises; a raise out of `invoke` is a server fault), `http.mojo` (`ToResponse` non-raising), `body.mojo`, `testing.mojo`, `adapters/flare/muntin_flare.mojo`, the unsafe surface, and every `compile_fail` fixture.
- Fixtures, verified on the scratch copy:
  - start compiling and retire into positive tests: `storage_fail/raising_handler.mojo`, `storage_fail/raising_typed_handler.mojo`, `body_fail/post_raising_handler.mojo`, `body_fail/post_int_body_raising_handler.mojo`, `body_fail/post_int_body_raising_typed_handler.mojo`;
  - notes gain `raises Never` (for example `'def(Int) raises Never thin -> String'`): `storage_fail/{request_param_handler,string_param_handler,two_param_handler,mismatched_trampoline}.mojo` and `body_fail/{get_body_handler,post_body_then_int,post_int_and_two_bodies,post_int_body_non_conforming_return,post_no_param,post_owned_int_and_body,post_two_bodies}.mojo`;
  - `storage_fail/{copy_erased,downstream_move_header,mismatched_trampoline}.mojo` spell the adapters `[Never, String, _text]`;
  - `test_handler_storage.test_app_routes_hold_erased_handlers` expects a returned 400 for `4_2` instead of a raise.
- Tests: `raises` and `raises T` handlers on every shape with `String` and `ToResponse` results → 500 `Internal Server Error`, conversion not run, no error text in the body; every existing 400 and 404 case with the handler not called; 500 independent of the message; a raised error type that conforms to `ToResponse` is 500 and its `to_response` does not run; `TestClient` and loopback through Flare agree for one raising route (500) next to the existing routes.
- Docs: DX section 6 and "Proven vs. target status" list raising handlers and the 500; the DX status lines that call every handler shape non-raising, list `raises` among the shapes `get` rejects, and quote the note `'def(Int) thin -> String'` (now `raises Never thin`) change with it.
- Not in the slice: application-defined error conversion, logging, fallible `ToResponse`, raw `Request` handlers, JSON, headers, new methods, middleware, state.

### Raising handlers in production (M2-011)

Production implements the M2-010 slice above ("Next production slice"), and nothing more. Registration shapes and syntax are unchanged; each overload's function type gains the inferred error type:

```text
registration (8 overloads)                                      adapter instantiation stored in _Erased
get[E, //, path](def() thin raises E -> String)                 _call_none[E, String, _text]
get[E, R: ToResponse, //, path](def() thin raises E -> R)       _call_none[E, R, _converted[R]]
get[E, //, path](def(Int) thin raises E -> String)              _call_int[E, String, _text]
get[E, R: ToResponse, //, path](def(Int) thin raises E -> R)    _call_int[E, R, _converted[R]]
post[B, E, //, path](def(var B) thin raises E -> String)        _call_body[B, E, String, _text]
post[B, E, R: ToResponse, //, path](def(var B) thin raises E -> R)        _call_body[B, E, R, _converted[R]]
post[B, E, //, path](def(Int, var B) thin raises E -> String)             _call_int_body[B, E, String, _text]
post[B, E, R: ToResponse, //, path](def(Int, var B) thin raises E -> R)   _call_int_body[B, E, R, _converted[R]]
(E: Deinitable, B: Movable & Deinitable, both inferred)
```

- **Inference:** `E` is `Never` for a non-raising handler, `Error` for `raises`, the application's type for `raises T`. Non-raising `def` handlers are source-compatible: `test_app`, `test_body`, `test_int_body`, `test_response` and every `compile_fail` fixture pass unchanged, and the compiler's candidate notes now print the inferred `Never` (`'def(Int) raises Never thin -> String'`). `-> StaticString` still converts to the `String` overloads and a borrowed `body: B` to `var B`, raising or not. Explicit `raises Error`/`raises Never`, `Copyable` and non-`Movable` error types and parametric handlers also resolve (fresh-context review probes, not retained).
- **Measured exception to source compatibility (Mojo 1.1.0):** a handler *value* already typed without `raises`, such as `var f: def() thin -> String = hello` or a helper parameter of that type forwarded to `app.get`/`app.post`, compiled on M2-010 `main` and now fails: `TODO: function type conversions between closures not supported yet` (`tests/storage_fail/typed_thin_value_handler.mojo`). It is the same compiler TODO as forwarding with an explicit `B` (M2-005). M2-010 measured only `def` declarations, which convert. Workarounds: spell the value's type `def() thin raises Never -> String`, or make the helper generic over `E: Deinitable`. No fix within the decided design: raising twins beside the overloads are ambiguous (`error_fail/raising_twin_overloads.mojo`), and anything else is an overload redesign. A linear error type is rejected at registration (`does not conform to trait 'Deinitable'`, `tests/storage_fail/linear_error_type.mojo`).
- **Boundary**, as the M2-010 table: no match → 404 in `App.handle`; query gathering in `App.handle`, in its own `try` → 400; `_call_int` and `_call_int_body` answer a `_parse_int` failure with 400 themselves, as `_call_body` already did for `from_body`; each adapter then calls the handler alone in a `try` whose `except e` returns `_handler_error(e^)`, the fixed 500 `Internal Server Error` whatever `E` is; `respond(result^)` runs after that `try`, so the response policy runs only on a returned value. No adapter raises; `App.handle` maps a raise out of `invoke` to 500 (`_internal_error()`), never 400.
- **Raised `ToResponse` values:** a raised value is 500 whatever its type; `_handler_error` drops it unread, so its `to_response` never runs. A returned value of the same type converts (`Gone`: 410 returned, 500 raised).
- **Unchanged:** `_handler_storage.mojo` code (only `_Call`'s docstring sentence, now: no adapter raises, so a raise out of `invoke` is a server fault), `_Erased`, `_Call[F]` (still `raises`), the unsafe surface and `check_unsafe.sh`, `http.mojo` (`ToResponse` non-raising), `body.mojo`, `testing.mojo`, `adapters/flare/muntin_flare.mojo`.
- **Fixtures:** added `storage_fail/{typed_thin_value_handler,linear_error_type}.mojo` (above). Retired into `tests/test_error.mojo` (they now compile): `storage_fail/{raising_handler,raising_typed_handler}.mojo`, `body_fail/{post_raising_handler,post_int_body_raising_handler,post_int_body_raising_typed_handler}.mojo`. Notes gain `raises Never`: `storage_fail/{request_param_handler,string_param_handler,two_param_handler,mismatched_trampoline}.mojo`, `body_fail/{get_body_handler,post_body_then_int,post_int_and_two_bodies,post_int_body_non_conforming_return,post_no_param,post_owned_int_and_body,post_two_bodies}.mojo`. `storage_fail/{copy_erased,downstream_move_header,mismatched_trampoline}.mojo` spell the adapters `[Never, String, _text]`. `test_handler_storage.test_app_routes_hold_erased_handlers` expects a returned 400 for `4_2` instead of a raise. Every other fixture, the M2-010 spike and `tests/error_fail` are unchanged; this list is exactly the one M2-010 measured on its scratch copy.
- **Evidence:** `tests/test_error.mojo` (11): sixteen raising handlers (`raises` and `raises NotFound` on `def()`, `def(Int)` from a path and a query value, `def(B)`, `def(Int, B)`, each with a `String` and a `ToResponse` result) plus raising `-> StaticString` and `-> Response`, in one `App` with non-raising handlers; each answers normally when it returns (handler and conversion once) and the fixed 500 when it raises (conversion 0, body exactly `Internal Server Error`, neither the `Error` message nor the `NotFound` text in it); every route-value, query and body failure 400 with the handler not called, raising or not; 404 (including a missing path segment) with nothing called; a handler raising `_parse_int`'s own message is 500 while a bad value on the same route is 400; `Gone` returned 410, raised 500 unconverted; a deliberately raising adapter planted in `App._routes` gives 500, not 400; `TestClient` equal to `App.handle`; `App` moves. Loopback through Flare: `GET /orders/{id}` (`raises -> String`) and `POST /orders` (`raises Rejected -> Person`) answer 500, 200 and 400 equal to `TestClient`.
- **Mutations** (planted, reverted), each red: handler error answered 400 or 200; a bad route value or body answered 500 by the adapter; query gathering answered 500; a raise out of `invoke` answered 400; a `Writable` error's text written into the 500; a raised `ToResponse` value converted; `_parse_int` moved into the handler's `try` (compile error: `cannot call function that may raise 'E' in context that supports an error type of 'Error'`); the `except` falling through to the conversion (compile error: `use of uninitialized value 'result'`); the handler error re-raised out of the adapter (compile error); the response policy skipped on success; `OwnedPointer` in `app.mojo` and `Request` in the storage module (`check_unsafe.sh`); `_Call` made non-raising (the broken-adapter test stops compiling); the Flare adapter rewriting 500 as 502 (`check_flare.sh`). Equivalent, survives by design: `respond` moved inside the handler's `try` (it does not raise, so placement is unobservable; `ToResponse` stays non-raising, `storage_fail/raising_to_response.mojo`).
- **Not in the slice:** application-defined error conversion, logging, fallible `ToResponse`, raw `Request` handlers, JSON, headers, new methods or argument shapes, middleware, state.

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
