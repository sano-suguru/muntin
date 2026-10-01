# Muntin developer experience

This document defines the intended user-facing experience of Muntin.

The examples are **design constraints**, not merely tutorials. They describe the API shape Muntin should converge toward. They are not permission to invent unsupported Mojo syntax.

If an example cannot be implemented exactly as written with the current stable Mojo toolchain:

1. reproduce the limitation in the smallest possible program;
2. record the compiler/toolchain version and relevant diagnostic;
3. choose the closest type-safe, composable alternative;
4. keep backend-specific details out of application code;
5. update this document only after the alternative is proven in executable code.

Muntin should feel like a native Mojo framework rather than a mechanical translation of a Python framework.

## Proven vs. target status

Verified on **Mojo 1.1.0 (8189361e)** by `tests/test_app.mojo` and `main.mojo` (run via `./scripts/test.sh` / `./scripts/check.sh`).

Proven (compiles and is exercised by executable tests):

```mojo
from muntin import App, Request, Response
from muntin.testing import TestClient


def hello() -> String:
    return "hello"


def main() raises:
    var app = App()
    app.get["/hello"](hello)          # compile-time route literal, runtime handler value

    var client = TestClient(app)      # borrows the app; no socket
    var response = client.get("/hello")
    # response.status == 200, response.text() == "hello"

    var direct = app.handle(Request("GET", "/hello"))  # backend seam
    var custom = Response.text("ok", status=201)
```

Unmatched method/path pairs return status 404.

Still targets (not implemented yet): `app.run()` (target API; a network backend is proven in M1, but whether Muntin owns a public run/lifecycle API, and its shape, is undecided), raising handlers, `def(Request) -> Response` raw handlers, `app.post`, path/query/body extraction, typed response conversion beyond `String`, middleware, state, and compile-time route validation (the route literal is currently only stored as a `String`).

Mojo facts discovered while proving the above:

- In Mojo 1.1.0, the function type spelled `def() -> String` is a *trait*, not a concrete type, so it cannot be stored in a struct field. The minimal reproduction

  ```mojo
  struct Route:
      var handler: def() -> String
  ```

  fails with `error: struct fields do not support trait types; 'def() -> String' is a trait, use a concrete type or compile-time generic`, and passing `hello` to a parameter of that type fails with `cannot be converted from 'def hello() thin -> String' to 'def() -> String'`. Muntin therefore accepts `def() thin -> String` internally. Application code is unaffected: an ordinary `def hello() -> String` is passed as-is.
- A `@staticmethod def text(body, status=200) -> Response` and an instance `def text(self) -> String` can coexist on `Response`, so both `Response.text("ok", status=200)` and `response.text()` from this document compile as written.
- `TestClient(app)` borrows without copying via an inferred origin parameter (`struct TestClient[origin: Origin[mut=False]]` holding `Pointer[App, origin]`). The spellings `ImmutOrigin` and `ImmutableOrigin` do not exist in Mojo 1.1.0.
- Overloading `get` on handler shape (`def() thin -> String` vs. `def(Request) thin -> ...`) resolves correctly in a scratch experiment, so the raw-request escape hatch does not require different registration syntax. Not implemented in M0.

### Handler model (M0.5 spike)

`tests/test_spike_handler_model.mojo` registers `root() -> String`, `get_user(id: Int) -> User`, and `raw(req: Request) -> Response` in one app with `app.get["/users/{id}"](get_user)`-style calls and dispatches all three through `handle(Request) -> Response`. `GET /users/42` returns `User(42, Alice)` and `GET /users/abc` returns 400. `src/muntin` is unchanged.

Result: the registration shape is feasible on Mojo 1.1.0, so this document's syntax stands. No storage implementation is adopted; the working prototype below is provisional and stays in `tests/` until M2 designs the real router. Approaches compared:

| Approach | Result | Evidence |
|---|---|---|
| Capturing closure | does not work as storage | Capture works (`def a(s: String) {var h} -> String`), but every closure has its own type: storing a second closure of the identical signature fails with `cannot be converted from 'Route[def(s: String) -> String]' to 'Route[def(s: String) -> String]'`. The shared function type is a trait, and `struct fields do not support trait types`. A capturing closure cannot become a thin function: `cannot implicitly convert 'def(s: String) -> String' value to 'def(String) thin -> String'`. |
| `rebind` between function types | rejected | `rebind input type ... does not match result type` |
| Function pointer + context, type-erased, with trampoline | works, provisional (unsafe) | The handler's thin function value (8 bytes, the same as `Int`) is stored as `Int` address bits. A trampoline instantiated for the same type restores and calls it. Erase and restore use one type parameter inside one private generic function, guarded by `comptime assert size_of[F]() == size_of[Int]()`. |
| Compile-time generated wrapper / handler as compile-time parameter | works (fallback only) | `app.get["/users/{id}", get_user]()`. No unsafe code, but framework storage concerns leak into the public syntax. Consider only if the runtime-value approach proves unworkable. |

Return conversion: a Muntin-owned conversion from typed return values to `Response` is the direction; the specific mechanism is decided in M2. The prototype `trait ToResponse` with `def to_response(self) -> Response` covers all three result types. `User` conforms directly. `String` and `Response` conform through `__extension String(ToResponse)` / `__extension Response(ToResponse)`, which compiles under `--Werror` on 1.1.0. The double-underscore spelling suggests the extension feature is not yet stable, so the trait and this way of conforming stdlib types are provisional; an overload per stdlib type is the fallback. No JSON.

Other facts measured on Mojo 1.1.0:

- Handler types are inferred from a runtime argument: `def get[R: ToResponse](handler: def(Int) thin -> R)` binds `R` from `get_user`.
- Generic return types used by value need `Deinitable` (otherwise `abandoned without being explicitly destroyed ... consider adding trait conformance to Deinitable`). `ToResponse` refines `Deinitable`.
- The route literal is a compile-time `StaticString`, so a plain `def` can count `{` inside `comptime assert`. `app.get["/users/{id}"](root)` fails to compile; the notes point at that call and end with `constraint failed: route declares path parameters but the handler takes none`. A handler of the wrong shape fails overload resolution, for example `cannot be converted from 'def root() thin -> String' to 'def(Request) thin -> Response'`.
- Reflection (`std.reflection`, `reflect[T]()`) covers struct fields only, not function parameter names, so path parameters bind by position. The `{id}`-to-`id` name check in section 16 is not possible yet.

Limitations of the provisional prototype: handlers must be thin functions that do not raise, and only `Int` path parameters are prototyped. Equal `size_of` does not prove that storing a function value as `Int` bits is defined behavior (ABI, provenance, optimizer, future function representation), so this storage is not adopted; the spike test only detects breakage on Mojo upgrades.

## Design principles

The public API should optimize for minimal boilerplate, strong static typing, useful compile-time validation, explicit escape hatches, predictable ownership, transport independence, composability, helpful diagnostics, and tests that do not require a real network socket.

Prefer compile-time work when it materially improves correctness, runtime cost, or diagnostics. Do not use metaprogramming merely because Mojo supports it.

Avoid hidden global state. Application code should not need to understand Flare or any other networking backend.

## 1. Hello World

Target shape:

```mojo
from muntin import App


def hello() -> String:
    return "Hello, Mojo!"


def main():
    var app = App()
    app.get["/"](hello)
    app.run()
```

A basic endpoint should not require users to manually construct a `Request`, `Response`, router entry, handler adapter, transport, executor, or allocator simply to return text.

Returning a `String` should be convertible to a successful text response by Muntin.

The parameterized `app.get["/"](...)` syntax is a target because route literals known at compile time may enable better validation. It becomes canonical only after it compiles cleanly on the supported Mojo version.

Status: `app.get["/"](hello)` compiles and dispatches on Mojo 1.1.0 (see "Proven vs. target status"). `app.run()` remains a target: M1 proved a real network backend (Flare, M1-003) without adding it, and public run/lifecycle ownership is undecided.

## 2. Typed path parameters

Desired direction:

```mojo
@fieldwise_init
struct User:
    var id: Int
    var name: String


def get_user(id: Int) -> User:
    return users.get(id)


app.get["/users/{id}"](get_user)
```

Muntin should perform the conceptual flow:

```text
/users/42
   |
route match
   |
"42"
   |
Int(42)
   |
get_user(id=42)
```

Application code should not manually parse common path types.

Where Mojo makes it practical, route/handler mismatches should be diagnosed at compile time. A route declaring `{id}` should not silently bind to an unrelated handler parameter. If compile-time name matching is not practical, fail as early and clearly as the language permits.

## 3. Query parameters

Desired direction:

```mojo
def search(query: String, limit: Int = 20) -> SearchResults:
    return search_index(query, limit)

app.get["/search"](search)
```

For `GET /search?query=mojo&limit=10`, the handler should receive typed values rather than raw strings. Missing required values and invalid conversions should become clear client errors.

Exact optional/default extraction semantics are M2 work and must be proven against Mojo's callable/reflection capabilities before they are frozen.

## 4. Typed request bodies

Ordinary JSON APIs should not require application code to manually decode JSON.

```mojo
@fieldwise_init
struct CreateUser:
    var name: String
    var age: Int


def create_user(body: CreateUser) -> User:
    return users.create(body)

app.post["/users"](create_user)
```

Conceptually:

```text
HTTP body -> decode -> validate -> CreateUser -> handler
```

Muntin should use Mojo's type system and reflection capabilities where they genuinely reduce duplication. Do not introduce opaque runtime reflection when compile-time information is available.

## 5. Typed responses

High-level handlers should be able to return common values directly:

```mojo
def hello() -> String:
    return "hello"
```

and structured serializable values:

```mojo
def get_user(id: Int) -> User:
    return users.get(id)
```

Explicit response construction must remain available:

```mojo
def health() -> Response:
    return Response.text("ok", status=200)
```

Convenience must not eliminate low-level control.

## 6. Application errors

Do not freeze a typed-error API until it is validated against the supported Mojo version. Current Mojo's error model and the deprecation of `fn` make idealized typed-error signatures a moving target.

The durable requirement is simpler: domain/application failures must be convertible to HTTP responses centrally without forcing repeated transport-specific error plumbing into every handler.

A future API might resemble an application-level error mapping or result type, but the exact syntax must be derived from executable Mojo code rather than copied from another language.

## 7. Middleware

The intended experience is explicit and composable:

```mojo
var app = App()
app.use(Tracing())
app.use(Cors())
app.use(Authentication())
app.get["/users/{id}"](get_user)
```

Middleware should be able to inspect a request, short-circuit, call the next layer, inspect/modify a response, and attach request-scoped typed context. The public middleware contract must be Muntin-owned even if an adapter internally translates to a backend-specific mechanism.

## 8. Application state

Long-lived state should have explicit ownership and predictable lifetime behavior.

Conceptual direction:

```mojo
@fieldwise_init
struct AppState:
    var users: UserRepository
    var metrics: Metrics


def get_user(id: Int, state: State[AppState]) -> User:
    return state.users.get(id)
```

The exact state/extractor syntax is not frozen. Requirements are explicit ownership, no hidden globals, testability, and no unnecessary per-request allocation.

## 9. Raw Request/Response escape hatch

Raw request handling is first-class:

```mojo
def webhook(req: Request) -> Response:
    var signature = req.headers.get("x-signature")
    # verify and process...
    return Response.text("ok")

app.post["/webhook"](webhook)
```

The escape hatch matters for webhooks, streaming, custom content types, unusual authentication, protocol integrations, and performance-sensitive endpoints.

## 10. Testing without networking

Application behavior must be testable without opening a TCP socket.

Conceptual direction:

```mojo
def test_hello():
    var app = App()
    app.get["/"](hello)

    var client = TestClient(app)
    var response = client.get("/")

    assert_equal(response.status, 200)
    assert_equal(response.text(), "Hello, Mojo!")
```

The in-memory path must execute the same Muntin application dispatch seam used by real transports. This is an architecture proof, not merely test convenience.

Status: proven on Mojo 1.1.0 with `from muntin.testing import TestClient`; `TestClient.get` builds a Muntin `Request` and calls `App.handle`, the same entry point network adapters will use.

## 11. Transport independence

Normal application code may import:

```mojo
from muntin import App, Request, Response
```

Normal application code must not need:

```mojo
from flare.http import Request, Response, Router
```

The conceptual dependency graph is:

```text
application
    |
Muntin public API
    |
Muntin core
    |
backend boundary
   / \
in-memory  Flare
```

Flare is an implementation backend, not part of Muntin's durable application contract.

## 12. Compile-time route information

Where supported cleanly by Mojo, prefer preserving route literals at compile time:

```mojo
app.get["/users/{id}"](get_user)
```

Potential checks include malformed route syntax, duplicate parameter names, route/handler mismatches, incompatible extractors, and some duplicate routes.

Compile-time machinery must earn its complexity through simpler application code, earlier diagnostics, or measurable runtime savings.

## 13. Serialization and schemas

The same type information used for request parsing and response serialization should eventually feed API schema generation. Application authors should not maintain a second copy of their data model solely for OpenAPI.

Schema generation is not an M0 requirement.

## 14. Async and streaming

Do not commit Muntin's public API to a custom executor, `Future`, `Task`, `Waker`, reactor, or scheduler merely to anticipate future Mojo runtime features.

Streaming should eventually be possible. The public model should remain adaptable to the language/runtime direction that actually ships.

## 15. Allocation and ownership

Muntin is a systems-language framework, so allocation and lifetime behavior should be intentional. Normal application handlers should nevertheless avoid framework-internal memory plumbing.

Prefer:

```mojo
def get_user(id: Int) -> User:
    return users.get(id)
```

over requiring every ordinary handler to accept allocators, connection contexts, or backend lifecycle objects.

Low-level APIs may expose more control when an endpoint genuinely needs it.

## 16. Error messages are part of the API

A framework diagnostic should state what is wrong, where it is wrong, what Muntin expected, and the likely fix.

Prefer a diagnostic conceptually like:

```text
route "/users/{id}" declares parameter "id",
but handler "get_user" has no compatible input for it
```

over an opaque generic type-mismatch message when Muntin can provide context.

## 17. Boilerplate budget

A normal route should converge toward roughly:

```mojo
def hello() -> String:
    return "hello"

app.get["/"](hello)
```

Adding an ordinary route should not require application authors to define a handler adapter, implement a backend trait, manually register serializers, construct a context object, or touch the networking transport.

## 18. Public API stability

Treat every public abstraction as expensive. Before exposing one, ask whether it is genuinely necessary for application developers, whether it can remain internal, whether Mojo already provides the right idiom, whether it leaks a backend detail, and whether users would reasonably depend on it for years.

Prefer a small composable API over many convenience types.

## 19. Canonical application

The target feel is approximately:

```mojo
from muntin import App


@fieldwise_init
struct CreateUser:
    var name: String
    var age: Int


@fieldwise_init
struct User:
    var id: Int
    var name: String
    var age: Int


def list_users() -> List[User]:
    return users.all()


def get_user(id: Int) -> User:
    return users.get(id)


def create_user(body: CreateUser) -> User:
    return users.create(body)


def main():
    var app = App()
    app.get["/users"](list_users)
    app.get["/users/{id}"](get_user)
    app.post["/users"](create_user)
    app.run()
```

The exact spellings are provisional. The durable properties are a small application surface, typed handlers, typed extraction, automatic conversion where safe, useful compile-time validation, low-level escape hatches, and backend independence.

## 20. Non-goals

Muntin should not initially become a custom TCP stack, TLS implementation, HTTP/2 or HTTP/3 implementation, QUIC implementation, general-purpose async runtime, thin Flare re-export, FastAPI syntax clone, or Rails/Django-scale full-stack framework.

The leverage belongs at the application-development layer.

## Decision rule

When choosing between competing designs, prefer the design that makes this kind of application code simpler:

```mojo
def get_user(id: Int) -> User:
    return users.get(id)

app.get["/users/{id}"](get_user)
```

without sacrificing correctness, type safety, explicit escape hatches, transport independence, or maintainable implementation boundaries.
