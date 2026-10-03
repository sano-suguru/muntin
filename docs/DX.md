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

M2 is complete (M2-016). The examples labeled proven or production below make up its contract. Everything this document still calls a target is M3 or later: `docs/SPEC.md`, "M2 completion contract", lists what M2 deliberately leaves out.

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

Typed path parameter (M2-001), proven by `tests/test_app.mojo`, `tests/compile_fail/` (via `./scripts/check.sh`) and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo` (via `./scripts/check_flare.sh`):

```mojo
def get_user(id: Int) -> String:
    return String(id)


var app = App()
app.get["/hello"](hello)              # () -> String and (Int) -> String share one App
app.get["/users/{id}"](get_user)      # same registration syntax
# GET /users/42  -> 200 "42"   (get_user received Int(42))
# GET /users/abc -> 400 "Bad Request"   (get_user not called)
# GET /users     -> 404 "Not Found"
```

Semantics:

- A route literal starts with `/` and is `/`-separated segments. A segment is either static (matched byte for byte) or `{name}`, which matches one non-empty segment; `name` is any non-empty text without braces and is not otherwise validated. A missing leading `/`, `{}`, or braces anywhere else are a compile error (`constraint failed: malformed route literal`). This also applies to `def() -> String` routes: `app.get["hello"](hello)` compiled in M0 and is now rejected.
- Binding is positional. The handler's one `Int` parameter receives the one `{name}` segment; the name is not compared with the handler's parameter name, because Mojo 1.1.0 reflection does not expose function parameter names. `app.get["/users/{user}"](get_user)` is accepted.
- `Int` conversion: an optional `-` followed by one or more ASCII digits, within `Int` range (`-9223372036854775808` to `9223372036854775807`); leading zeros are allowed (`/users/042` -> `Int(42)`). Anything else, including forms Mojo's `Int(String)` accepts (`+42`, ` 42`, `4_2`), returns 400 `Bad Request` without calling the handler.
- The first registered route whose method and path match handles the request: with `/users/me` registered before `/users/{id}`, `GET /users/me` goes to the former. A conversion failure is 400; it does not fall through to later routes.
- Arity is checked at compile time at the registration call: `app.get["/users/{id}"](hello)` fails with `constraint failed: route declares a path parameter but the handler takes none`; `app.get["/users"](get_user)` and `app.get["/users/{id}/posts/{post}"](get_user)` fail with `constraint failed: handler takes one Int parameter; route must declare exactly one path or query parameter` (M2-002 wording; M2-001 said `path parameter; route must declare one`).
- Routes match the path only (M2-002, below): `/users/42?x=1` passes `Int(42)` and `/hello?x=1` is 200. Percent-encoding is not decoded.

Typed query parameter (M2-002), proven by the same tests and fixtures:

```mojo
def list_items(limit: Int) -> String:
    return "items " + String(limit)


app.get["/items?{limit}"](list_items)    # the literal names the query key
# GET /items?limit=10          -> 200 "items 10"
# GET /items?limit=010         -> 200 "items 10"  (list_items received Int(10))
# GET /items?other=z&limit=10  -> 200 "items 10"  (other keys are ignored)
# GET /items, /items?limit=abc, /items?limit=1&limit=2 -> 400 "Bad Request" (list_items not called)
# GET /hello?x=1               -> 200 "hello"     (no-query routes ignore the query)
```

Semantics:

- `Request(method, target, body)` splits the target at its first `?`: `request.path` is the text before it and is all that routes match; `request.query` is the text after it, undecoded (`""` when there is no `?` or nothing follows it). `TestClient.get(target)` and the Flare adapter pass the target as received, so both backends get this one rule. `#` has no meaning (a fragment is not part of an HTTP request target), so `/items?limit=10#x` has value `10#x` and is 400.
- The route literal's query part, after `?`, is `{key}` items separated by `&`. A key is non-empty, visible ASCII (`!` to `~`, the bytes an HTTP request target can carry), and contains none of `{}=&?#`; an empty query part, static text such as `?limit`, `{}`, a space or other non-visible byte (`?{lim it}`, `?{límit}`), or one of those characters is a compile error (`malformed route literal`). Path and query placeholders together must match the handler's arity: `app.get["/items?{limit}"](hello)` fails with `constraint failed: route declares a query parameter but the handler takes none`, and `app.get["/users/{id}?{limit}"](list_items)` with `constraint failed: handler takes one Int parameter; route must declare exactly one path or query parameter` (the same text as `app.get["/users"](get_user)`). One handler cannot take a path and a query value yet.
- The key is written in the route literal because Mojo 1.1.0 cannot reflect a function's parameter names: `reflect[Q].field_names()` returns `limit` for `struct Q` with field `limit`, but `reflect[type_of(list_items)]` has no parameter-name accessor (`'Reflected[def(limit: Int) thin -> String]' value has no attribute 'param_names'`; its `name()` is `std.builtin._stubs.__MLIRType[<unprintable>]`). Binding is positional, as for path parameters: `app.get["/items?{count}"](list_items)` is accepted.
- Parsing the request query: pairs are separated by `&`; a pair's key and value split at its first `=`; a pair without `=` has an empty value; empty pairs are skipped. Keys compare byte for byte, case-sensitively. Nothing is percent-decoded and `+` is not a space, so `lim%69t=1` does not match `limit` and `limit=%31%30` is not `10`.
- The value converts with the path rule (optional `-`, ASCII digits, `Int` range). A missing key, a key that appears more than once (even with equal values), an empty value, or a non-integer value returns 400 `Bad Request` without calling the handler.
- The query takes no part in route selection. With `/items?{limit}` registered before `/items`, `GET /items` matches the first route and is 400; it does not fall through.

Typed request body (M2-006), proven by `tests/test_body.mojo`, `tests/compile_fail/post_*.mojo` and `tests/body_fail/` (via `./scripts/check.sh`) and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`:

```mojo
from muntin import App, FromBody


struct CreateUser(FromBody):              # defined by the application; may be move-only
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:   # the application owns the body format
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("expected name=<text>")
        return Self(String(body[byte=5:]))


def create_user(body: CreateUser) -> String:      # `var body: CreateUser` also works
    return "created " + body.name


app.post["/users"](create_user)
# POST /users  "name=Ada"       -> 200 "created Ada"   (create_user received the converted value)
# POST /users  "Ada" or ""      -> 400 "Bad Request"   (from_body raised; create_user not called)
# GET /users, PUT /users, POST /missing -> 404 "Not Found" (from_body not called)
```

Semantics:

- `FromBody` is a public Muntin trait refining `Deinitable & Movable` with one requirement, `@staticmethod def from_body(body: String) raises -> Self`. The application type conforms to it in its own module; Muntin never names the type. `from_body(body: String)` is the current public body-conversion input contract (the `Request` carries the body as one `String`, with no headers or content type); future body capabilities are added as new APIs without changing it.
- The body-only shape of `app.post[route](handler)` is a handler (non-raising, or raising since M2-011, section 6) with one parameter, the body, on a route literal with no path or query placeholder (the route-value-then-body shape is below, M2-009). It returns `String` (or a type that converts to it implicitly, such as `StaticString`, as for `app.get` since M2-001) or, since M2-008, a type conforming to `ToResponse` (section 5). Parameter names are not consulted.
- Muntin calls `from_body(request.body)` before the handler. The body comes from the request body only, never from the path or query (`POST /users?name=Bob` with body `name=Ada` -> `created Ada`), byte for byte (an empty body or surrounding whitespace reaches `from_body` unchanged; over Flare this holds for UTF-8 bodies, because the adapter replaces invalid UTF-8 with U+FFFD), and the `Request` is borrowed, not consumed. If `from_body` raises, the response is 400 `Bad Request` and the handler is not called. Routes are selected by method and path as for `GET`; no match is 404 and `from_body` is not called.
- Compile-time errors at `app.post`: a type that does not conform, including `String` (`constraint failed: the handler's parameter is the request body; its type must conform to FromBody`); a `Request` body parameter, i.e. `def(req: Request)` with a result other than `Response` or `def(id: Int, req: Request)` (since M2-015, section 9: `constraint failed: Request is the whole request, not a body; a raw handler takes only the Request and returns Response`; other `Request` shapes, such as `mut req` or two `Request`s, match no overload); an `Int` parameter (`constraint failed: Int is a route-value type, never the request body; the body parameter's type must conform to FromBody`); a path or query placeholder (`constraint failed: handler takes only the request body; route must declare no path or query parameter`). Any other shape (no parameter, two bodies) is `no matching method in call to 'post'`, with a note per candidate: `value passed to 'handler' cannot be converted from '<handler type>' to 'def(var B) raises Never thin -> String'` (`raises Never thin` since M2-011: the inferred error type of a non-raising handler), the `ToResponse` candidate's (since M2-008; until then the single candidate gave `invalid call to 'post'`) and, since M2-009, the two `(Int, B)` candidates'. A raw `def(request: Request) -> Response` handler is the raw shape (section 9) since M2-015 (until then it reached the `ToResponse` overload with `Request` as the body type and failed with the `FromBody` message). A body handler passed to `app.get` has no matching overload.
- `TestClient.post(target, body)` sends `Request("POST", target, body)` through `App.handle`, like `TestClient.get`.

Route value then body (M2-009), proven by `tests/test_int_body.mojo`, `tests/compile_fail/{,typed_}post_int_*.mojo` and `tests/body_fail/post_{body_then_int,int_and_two_bodies,int_body_*,owned_int_and_body}.mojo` (via `./scripts/check.sh`) and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`:

```mojo
struct UpdateUser(FromBody):              # as CreateUser above; may be move-only
    ...


def update_user(id: Int, body: UpdateUser) -> String:   # `var body: UpdateUser` also works
    return "user " + String(id) + " " + body.name


app.post["/users/{id}"](update_user)      # route value from a path segment
app.post["/users?{id}"](update_user)      # or from a query item
# POST /users/042     "name=Ada"  -> 200 "user 42 Ada"
# POST /users?id=042  "name=Ada"  -> 200 "user 42 Ada"
# POST /users/abc, /users?id=1&id=2, /users  (any body) -> 400 "Bad Request"  (from_body and update_user not called;
#                                    /users matches the query route's path, so its missing id is 400)
# POST /users/1       "Ada"       -> 400 "Bad Request"  (from_body raised; update_user not called)
# PUT /users/1, POST /users/1/x   -> 404 "Not Found"    (nothing converted)
```

Semantics:

- The handler takes exactly one `Int` route value, then one body. The route literal declares exactly one route value: one `{name}` path segment or one `{key}` query item, never both. Binding is positional (route value first, body second); parameter names are not consulted (`def update_note(n: Int, var text: Note)` on `/notes/{id}` works). The route value follows the `Int` rules of `app.get` (path and query sections above); the body follows the body-only rules (from the request body only, byte for byte, through `B.from_body`).
- Order: no matching method and path is 404 with nothing converted. Otherwise the route value is gathered and converted first: a non-integer path value, or a missing, duplicated, empty or non-integer query value, is 400 and `from_body` is not called (a missing path segment does not match the path, so it is 404). Then the body: a `from_body` raise is 400 and the handler is not called. Then the handler runs once, and its result is converted once: `String` (or `String`-compatible, such as `StaticString`) to a 200 text response, `R: ToResponse` (an application type or `Response`) by `to_response()`. A matched route that answers 400 never falls through to a later route.
- Compile-time errors at `app.post`, on both result policies: no route value, two path values, or a path and a query value (`constraint failed: handler takes one Int parameter and the request body; route must declare exactly one path or query parameter`); `(Int, Int)` (`constraint failed: Int is a route-value type, never the request body; the body parameter's type must conform to FromBody`); a second parameter that does not conform (`constraint failed: the handler's last parameter is the request body; its type must conform to FromBody`). The body before the route value `(B, Int)`, two bodies after it, a `var id: Int` route value and a result that is neither `String`-compatible nor `ToResponse` match no overload (`no matching method in call to 'post'`; the `(Int, B)` candidates' notes read `cannot be converted from '<handler type>' to 'def(Int, var B) raises Never thin -> String'`, and for the result `argument type 'Int' does not conform to trait 'ToResponse'`).

Current argument shapes are exactly `def()` and `def(Int)` for `app.get`, and `def(B)` and `def(Int, B)` (M2-009) with `B: FromBody` for `app.post`, plus, on both, the raw `def(req: Request) -> Response` (M2-015, section 9; `Response` only, under the same error model). Each may be non-raising or declare `raises` or `raises T` (M2-011, section 6; a `T` declaring `ToErrorResponse` chooses its own response, M2-013), and returns `String` (or a type that converts to it implicitly, such as `StaticString`) or a type conforming to `ToResponse`, including `Response` (M2-008, section 5). Other `get` shapes (more or non-`Int` parameters) and other result types fail overload resolution at the call: `no matching method in call to 'get'`, with one note per candidate, e.g. `cannot be converted from 'def f(id: Int) thin -> Int' to 'def(Int) raises Never thin -> String'` and, for the `ToResponse` candidate, `argument type 'Int' does not conform to trait 'ToResponse'`. Since M3-003, `app.get` also takes a stateful handler with its state as a second argument, `def(State[S])` or `def(State[S], Int)` (section 8); a failing one-argument `get` call lists those four candidates too, each with `missing required argument: 'state'`.

Still targets (not implemented yet; M3 or later, each placed in `docs/SPEC.md` "M3"): `app.run()` (target API; a network backend is proven in M1, but whether Muntin owns a public run/lifecycle API, and its shape, is undecided), more than one route value with a body, `String` or other builtin bodies, optional or multiple bodies, JSON body decoding, `POST` handlers without a body, other methods (`put`, `patch`, `delete`), multiple or non-`Int` path or query parameters, path and query values in one handler, optional/default query values (`limit: Int = 20`), percent-decoding, raising or fallible response conversion, JSON responses, typed header extraction and default response headers, parameter-name checking, middleware, and stateful `post` and raw handlers (decided in M3-001, section 8; stateful `get` is production since M3-003). Request and response headers are production since M3-005 (section 9); typed header extraction and default headers are not.

Mojo facts discovered while proving the above:

- In Mojo 1.1.0, the function type spelled `def() -> String` is a *trait*, not a concrete type, so it cannot be stored in a struct field. The minimal reproduction

  ```mojo
  struct Route:
      var handler: def() -> String
  ```

  fails with `error: struct fields do not support trait types; 'def() -> String' is a trait, use a concrete type or compile-time generic`, and passing `hello` to a parameter of that type fails with `cannot be converted from 'def hello() thin -> String' to 'def() -> String'`. Muntin therefore accepts thin function types internally (`def() thin raises E -> String` since M2-011). Application code is unaffected: an ordinary `def hello() -> String` is passed as-is.
- A `@staticmethod def text(body, status=200) -> Response` and an instance `def text(self) -> String` can coexist on `Response`, so both `Response.text("ok", status=200)` and `response.text()` from this document compile as written.
- `TestClient(app)` borrows without copying via an inferred origin parameter (`struct TestClient[origin: Origin[mut=False]]` holding `Pointer[App, origin]`). The spellings `ImmutOrigin` and `ImmutableOrigin` do not exist in Mojo 1.1.0.
- Overloading `get` on handler shape (`def() thin -> String` vs. `def(Request) thin -> ...`) resolves correctly in a scratch experiment, so the raw-request escape hatch does not require different registration syntax. Not implemented in M0 (decided in M2-014, implemented in M2-015, section 9).

### Handler model (M0.5 spike)

`tests/test_spike_handler_model.mojo` registers `root() -> String`, `get_user(id: Int) -> User`, and `raw(req: Request) -> Response` in one app with `app.get["/users/{id}"](get_user)`-style calls and dispatches all three through `handle(Request) -> Response`. `GET /users/42` returns `User(42, Alice)` and `GET /users/abc` returns 400. `src/muntin` is unchanged.

Result: the registration shape is feasible on Mojo 1.1.0, so this document's syntax stands. The working prototype below is provisional and stays in `tests/`. M2-001 did not adopt it: production `App` stored handlers in a `Variant` of thin function types, which needs no unsafe code for the closed set of shapes it supports (comparison in `docs/ARCHITECTURE.md`, "Routing and handler storage"). Since M2-004 they are stored in a private typed box that erases a pointer to the handler, not the handler's bits (`docs/ARCHITECTURE.md`, "Handler storage decision (M2)"); the public syntax is unchanged. Approaches compared:

| Approach | Result | Evidence |
|---|---|---|
| Capturing closure | does not work as storage | Capture works (`def a(s: String) {var h} -> String`), but every closure has its own type: storing a second closure of the identical signature fails with `cannot be converted from 'Route[def(s: String) -> String]' to 'Route[def(s: String) -> String]'`. The shared function type is a trait, and `struct fields do not support trait types`. A capturing closure cannot become a thin function: `cannot implicitly convert 'def(s: String) -> String' value to 'def(String) thin -> String'`. |
| `rebind` between function types | rejected | `rebind input type ... does not match result type` |
| Function pointer + context, type-erased, with trampoline | works, provisional (unsafe) | The handler's thin function value (8 bytes, the same as `Int`) is stored as `Int` address bits. A trampoline instantiated for the same type restores and calls it. Erase and restore use one type parameter inside one private generic function, guarded by `comptime assert size_of[F]() == size_of[Int]()`. |
| Compile-time generated wrapper / handler as compile-time parameter | works (fallback only) | `app.get["/users/{id}", get_user]()`. No unsafe code, but framework storage concerns leak into the public syntax. Consider only if the runtime-value approach proves unworkable. |

Return conversion: a Muntin-owned conversion from typed return values to `Response` is the direction. The M0.5 prototype below is history; the M2-007 decision (section 5) differs: the requirement is `def to_response(var self) -> Response`, `String` stays on its own overloads instead of conforming through `__extension`, and `Response` conforms in its own module. The M0.5 prototype `trait ToResponse` with `def to_response(self) -> Response` covers all three result types. `User` conforms directly. `String` and `Response` conform through `__extension String(ToResponse)` / `__extension Response(ToResponse)`, which compiles under `--Werror` on 1.1.0. The double-underscore spelling suggests the extension feature is not yet stable, so the trait and this way of conforming stdlib types are provisional; an overload per stdlib type is the fallback. No JSON.

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

Status (M2-001): `app.get["/users/{id}"](get_user)` with `def get_user(id: Int) -> String` is proven, through `TestClient` and a real Flare loopback request; see "Proven vs. target status" for matching and conversion rules. Returning `User` is production since M2-008 (section 5).

Where Mojo makes it practical, route/handler mismatches should be diagnosed at compile time. A route declaring `{id}` should not silently bind to an unrelated handler parameter. If compile-time name matching is not practical, fail as early and clearly as the language permits.

## 3. Query parameters

Desired direction:

```mojo
def search(query: String, limit: Int = 20) -> SearchResults:
    return search_index(query, limit)

app.get["/search"](search)
```

For `GET /search?query=mojo&limit=10`, the handler should receive typed values rather than raw strings. Missing required values and invalid conversions should become clear client errors.

Exact optional/default extraction semantics are M3 work (`docs/SPEC.md` M3, more route values) and must be proven against Mojo's callable/reflection capabilities before they are frozen.

Status (M2-002): one required `Int` query value is proven as `app.get["/items?{limit}"](list_items)` with `def list_items(limit: Int) -> String`; see "Proven vs. target status". The key sits in the route literal because handler parameter names cannot be reflected, so the name-based `app.get["/search"](search)` above is not possible on Mojo 1.1.0. `String` values, several keys, and defaults are not implemented.

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

Status (M2-006, M2-009): the body-only shape and the route-value-then-body shape are **production**: `app.post["/users"](create_user)` and `app.post["/users/{id}"](update_user)` with `from muntin import FromBody` (semantics in "Proven vs. target status"). The extraction contract was decided in M2-005 (`docs/ARCHITECTURE.md`, "Argument extraction decision"); JSON is not implemented:

```mojo
struct CreateUser(FromBody):            # the application type conforms; Muntin never names it
    var name: String

    @staticmethod
    def from_body(body: String) raises -> Self:   # raise -> 400, handler not called
        ...


def create_user(body: CreateUser) -> String:      # `var body: CreateUser` also works; may be move-only
    return body.name


app.post["/users"](create_user)          # production (M2-006): the one parameter is the body
app.post["/users/{id}"](update_user)    # production (M2-009): def update_user(id: Int, body: CreateUser), route value then body
```

- Binding is positional (the decided rule; production implements no route value or exactly one `Int` route value before the body): route values (path segments, then the query key) fill the first parameters, and one more parameter, last, is the body. Route values are Muntin builtins (`Int`), bodies are types that conform to the body trait, and the two never overlap, so a forgotten `{id}` or a misplaced body type is a compile error at `app.post`, not a silent rebinding.
- The application writes `from_body` and chooses the body format. Muntin does not decode JSON yet: a JSON codec will be a separate, later addition that fills `from_body`, so the "no manual decoding" goal above waits for it. Routing and binding do not change when it arrives.
- A body that does not convert is 400 before the handler runs; a raising handler's error is a different outcome (500, section 6).

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

Status (M2-008): **production**. Decided in M2-007 (`docs/ARCHITECTURE.md`, "Typed response decision (M2-007)"); proven by `tests/test_response.mojo`, `tests/storage_fail/{non_conforming_return_handler,raising_to_response}.mojo`, `tests/body_fail/post_non_conforming_return.mojo`, `tests/compile_fail/typed_*.mojo` and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`. An application result type conforms to the public `muntin.ToResponse` in its own module, as body types conform to `FromBody`:

```mojo
from muntin import App, Response, ToResponse


@fieldwise_init
struct User(ToResponse):                  # defined by the application; may be move-only
    var id: Int
    var name: String

    def to_response(deinit self) -> Response:   # the application chooses status and body
        var name = self.name^                    # moved, not copied
        return Response.text(String(self.id) + " " + name)


def get_user(id: Int) -> User:
    return User(id, "Ada")


app.get["/users/{id}"](get_user)          # unchanged registration syntax
app.get["/health"](health)                # def health() -> Response: Response conforms itself
```

- `-> String` handlers, and handlers whose function type converts to `def(...) -> String` such as `-> StaticString`, keep today's behavior: `String` needs no conformance.
- The trait requirement is `def to_response(var self) -> Response`: Muntin hands the result over. An implementation may declare `self`, `var self`, or `deinit self` (to move fields out). It does not raise. Raising handlers (section 6) do not need fallible conversion: the conversion only sees a returned value.
- The same rule applies to every argument shape: `def create_user(body: CreateUser) -> User` and, since M2-009, `def replace_user(id: Int, body: UpdateUser) -> User` on `app.post` convert the same way.
- `-> Response` uses the same trait: `Response` conforms and returns itself by move, so the handler's status and body reach the client unchanged (`GET /teapot` -> 418). There is no separate `Response` overload.
- The conversion runs once, after the handler returns. A 400 (route value or body failed to convert) or 404 calls neither the handler nor the conversion; a handler that raises (section 6) skips the result conversion.
- A result type that is neither `String`-compatible nor conforming fails at the registration call: `no matching method in call to 'get'` with the note `argument type 'Int' does not conform to trait 'ToResponse'`.

## 6. Application errors

Do not freeze a typed-error API until it is validated against the supported Mojo version. Current Mojo's error model and the deprecation of `fn` make idealized typed-error signatures a moving target.

The durable requirement is simpler: domain/application failures must be convertible to HTTP responses centrally without forcing repeated transport-specific error plumbing into every handler.

A future API might resemble an application-level error mapping or result type, but the exact syntax must be derived from executable Mojo code rather than copied from another language.

Status (M2-011): **production**. Decided in M2-010 (`docs/ARCHITECTURE.md`, "Application-error decision (M2-010)"; evidence in `tests/test_spike_error.mojo` and `tests/error_fail/`); proven by `tests/test_error.mojo` and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`. Registration syntax is unchanged:

```mojo
def get_user(id: Int) raises -> User:        # or raises T, an application error type that does not opt in
    if id == 0:
        raise Error("no such user")
    return User(id, "Ada")


app.get["/users/{id}"](get_user)              # unchanged registration
# GET /users/1   -> 200, User converted as today
# GET /users/0   -> 500 "Internal Server Error"   (the error text is not sent)
# GET /users/abc -> 400 "Bad Request"             (get_user not called)
```

- Every argument shape (`def()`, `def(Int)`, `def(B)`, `def(Int, B)`) and both result policies (`String`-compatible, `ToResponse`) accept a non-raising handler, `raises`, or `raises T` for an application-defined `T`. Non-raising `def` handlers keep working unchanged. Mojo infers the handler's error type (`Never`, `Error`, or the application's type); compiler notes print a non-raising candidate type as `def(Int) raises Never thin -> String`.
- Exception, a Mojo 1.1.0 limitation: a handler *value* whose type is spelled without `raises` (`var f: def() thin -> String = hello`, or a helper parameter of that type forwarded to `app.get`) no longer registers: `TODO: function type conversions between closures not supported yet` (`tests/storage_fail/typed_thin_value_handler.mojo`; it compiled before M2-011). Spell the type `def() thin raises Never -> String`, or make the helper generic: `def register[E: Deinitable](mut app: App, h: def() thin raises E -> String)`.
- An error type must be `Deinitable`, because Muntin drops it: a linear error type is rejected at registration (`tests/storage_fail/linear_error_type.mojo`).
- Request failures stay 400 and are decided before the handler: an invalid value in a matched path segment, a missing, duplicated or invalid query value, a body that `from_body` rejects. No route match, including a missing path segment, stays 404. Anything the handler raises, unless its declared error type opts in (below), is a fixed 500 with the body `Internal Server Error`, whatever the error says: the same message raised by the handler and by a failing conversion step gives 500 and 400. The error value is dropped; Muntin has no logging hook yet.
- Returning and raising mean different things. A returned value goes through the response conversion; a raised value is a handler error: 500, even if its type conforms to `ToResponse`, unless its declared type conforms to `ToErrorResponse` (below).

Application-defined error responses, status (M2-013): **production**. Decided in M2-012 (`docs/ARCHITECTURE.md`, "Error-response decision (M2-012)"; evidence in `tests/test_spike_error_response.mojo` and `tests/error_response_fail/`); proven by `tests/test_error_response.mojo`, `tests/storage_fail/{error_type_is_not_a_result,raising_error_conversion}.mojo` and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo` ("Application-defined error responses in production (M2-013)"). An error type opts in by declaring the public `muntin.ToErrorResponse`, separate from `ToResponse`; registration does not change:

```mojo
from muntin import App, Response, ToErrorResponse


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):     # the opt-in, in the type's own declaration
    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("no user " + String(self.id), status=404)


def get_user(id: Int) raises NotFound -> User:
    ...


app.get["/users/{id}"](get_user)
# GET /users/0   -> 404 "no user 0"          (NotFound.to_error_response; User not converted)
# GET /users/abc -> 400 "Bad Request"        (get_user not called)
```

- Only the handler's declared error type decides: `raises T` converts if `T` declares `ToErrorResponse` in its own declaration (directly, through a refining trait, or as a conditional conformance, `struct Missing[T: AnyType](ToErrorResponse where conforms_to(T, Writable))`). Bare `raises` (`Error`) has no opt-in and stays the fixed 500; Muntin never maps by message, and an opted-in type raised inside a bare-`raises` handler arrives as `Error` (500). A type that conforms only to `ToResponse` (including `raise Response.text(...)`), merely has a `to_error_response` method, or is a `Variant` of opted-in types stays 500 when raised. The undocumented `__extension` is not a supported way to opt in.
- A type may conform to both traits: returned, it converts with `to_response`; raised, with `to_error_response`. A type conforming only to `ToErrorResponse` cannot be returned (`argument type 'NotFound' does not conform to trait 'ToResponse'`).
- One central place: an application that wants one mapping uses one error type with several kinds (a Mojo function declares one error type), or a trait of its own that refines `ToErrorResponse`.
- The conversion runs once, after the handler raised, and consumes the error (`self`, `var self` or `deinit self`); the result conversion does not run. Move-only types work. It cannot raise: a raising `to_error_response` does not conform (`'NotFound' does not implement all requirements for 'ToErrorResponse'`). 400 and 404 run neither conversion.

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

Status: not implemented; M3 (`docs/SPEC.md`). `app.use` does not exist.

## 8. Application state

Long-lived state should have explicit ownership and predictable lifetime behavior.

Production for `get` since M3-003 (decided in M3-001, `docs/ARCHITECTURE.md` "Application state decision (M3-001)"), proven by `tests/test_state.mojo` (this example included), `tests/state_get_fail`, `tests/compile_fail/state_*.mojo` and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`:

```mojo
from muntin import App, State


struct Users(Movable):
    var names: List[String]

    def get(self, id: Int) raises NotFound -> String:
        ...


def get_user(users: State[Users], id: Int) raises NotFound -> User:
    return User(id, users[].get(id))       # read-only access to the shared value


def main():
    var users = State(Users(load_names()))   # the application builds the value once
    var app = App()                          # App stays non-generic
    app.get["/hello"](hello)                 # stateless handlers: unchanged
    app.get["/users/{id}"](get_user, users)  # the state is the registration's second argument
# GET /users/0  -> get_user(users, 0) -> User(0, "ada").to_response()
# GET /users/9  -> NotFound(9).to_error_response()   (as section 6)
# GET /users/x  -> 400 "Bad Request"                 (get_user not called)
```

Rules:

- **Which parameter is injected:** a handler takes application state exactly when its registration passes a second argument, a `State[S]`. Its first parameter is then `State[S]` (the same `S`), and the rest is one of the M2 shapes, bound as before: route values in the literal's order, then the body. So `def(State[Users], Int, CreateUser)` on `post` is state, route value, body. The state is never a route value or a body, and parameter names are never read.
- **Ownership:** `State(value)` takes the value. `State` is a shared handle: the application keeps its own, each registration keeps a copy, and the value is destroyed when the last handle goes. A request borrows the route's handle, so it copies nothing and allocates nothing. `users[]` is read-only through every handle (the handle's internal pointer is reachable by name, since Mojo 1.1.0 has no private fields; it is not API). A value that must change while the application serves keeps that mutability in its own fields, and its rules are the application's. A reference from `users[]` lives no longer than the handle it came from: using it after `users` is reassigned or moved is a compile error (`use of invalidated interior reference`).
- **Several values:** one `State` per handler. Several values are the fields of one state type, and different routes may take different state types (`State[Users]` on some routes, `State[Config]` on others).
- **Unchanged:** every M2 handler and registration, `App()`, `App.handle(Request) -> Response`, `TestClient(app)` and the backends. There are no globals and no hidden lookup: the state reaches the handler only through the registration that passed it.

A scoped registrar, `app.with_state(users).get[...](h)`, was measured too. It states the state once and leaves `App`'s compiler messages unchanged, but it is rejected on Mojo 1.1.0: the compiler does not track mutation through the registrar's stored pointer. With the decided form, every registration is an ordinary `mut` call on `App`, which the compiler tracks.

DX's earlier sketch put the state last (`def get_user(id: Int, state: State[AppState])`) and read it as `state.users`. A state-last family compiles on Mojo 1.1.0, but it is not the decided shape. State goes first so the body stays the last parameter (M2-005). Access is `state[]` because a struct cannot forward field access to the value it holds.

Status (M3-003): production for `get`. `app.get[route](handler, state)` takes `def(State[S])` or `def(State[S], Int)`, each non-raising or raising (`raises`, `raises T`, section 6) and returning `String` (or `String`-compatible) or `R: ToResponse` (section 5). Request handling is the stateless twin's: the same route checks and messages, the `Int` from a `{name}` segment or a `{key}` query item, 400 before the handler for an invalid, missing or duplicated value, `ToErrorResponse` or the fixed 500 for a raise, 404 without a match, and the first registration wins.

- Compile-time errors at `app.get`: a state of another type (`value passed to 'state' cannot be converted from 'State[Cache]' to 'State[Db]'`), the value instead of a handle (`cannot be converted from 'Db' to 'State[Db]'`), a stateful handler without its state (`missing required argument: 'state'`), a state for a stateless handler, the state after the route value or `var db: State[Db]` (each `cannot be converted from '<handler type>' to 'def(State[S]) raises Never thin -> String'` or `'def(State[S], Int) ...'`), mutation through `db[]` (`expression must be mutable ...`), using a `ref r = db[]` after `db` is reassigned (`use of invalidated interior reference`), a second handle replacing or mutating the value (`'_Shared[Db]' is not subscriptable`, `invalid use of mutating method`), and a placeholder count that does not fit the shape (the stateless twin's `constraint failed: ...`; the state is not a route value).
- Each registration copies the handle once, so the reference count rises by one per route and falls when the `App` is dropped. A request changes it by nothing. Moving the `App` moves the routes' handles, and the value is destroyed once, after the last handle. `TestClient(app)` serves a stateful `App` repeatedly, also after `var moved = app^` (a new client on `moved`).

Stateful `post` shapes and stateful raw handlers come in a later slice. Until then, a stateful handler registered on `post` fails to compile: with its state, `app.post[...](h, users)`, as `no matching method in call to 'post'`; without it, `app.post[...](h)`, with the `FromBody` message.

## 9. Raw Request/Response escape hatch

Raw request handling is first-class (M2-015), proven by `tests/test_raw.mojo` (which registers this handler, verbatim, and checks the responses below), the raw fixtures in `tests/compile_fail`, `tests/storage_fail` and `tests/body_fail` (via `./scripts/check.sh`) and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`:

```mojo
from muntin import App, Request, Response


def webhook(req: Request) -> Response:       # `var req: Request` also works
    if req.body != "signed":                 # application code decides
        return Response.text("unsigned", status=401)
    return Response.text("ok")


app.post["/webhook"](webhook)                # same syntax as typed handlers; app.get too
# POST /webhook          "signed"  -> 200 "ok"
# POST /webhook?id=abc   "forged"  -> 401 "unsigned"   (no 400 from Muntin: nothing is extracted)
# GET /webhook, POST /webhook/x    -> 404 "Not Found"  (webhook not called)
```

The escape hatch is meant for webhooks, streaming, custom content types, unusual authentication, protocol integrations, and performance-sensitive endpoints. Today it covers what can be decided from the method, path, query and body, as in the example above. Header-based authentication and custom content types use headers, production since M3-005 (below); streaming still needs a `Request`/`Response` capability that does not exist yet (M3). The example above is kept as the body-only form.

Headers (M3-005, production; decided in M3-002, `docs/ARCHITECTURE.md` "Headers decision (M3-002)"), proven by `tests/test_headers.mojo` (which registers this handler as `dx_webhook` and checks the responses below), `tests/headers_api_fail`, `adapters/flare/test_muntin_flare.mojo` and, over real loopback connections through Flare (HTTP/1.1 and cleartext HTTP/2), `adapters/flare/test_localhost_roundtrip.mojo`:

```mojo
from muntin import App, Headers, Request, Response


def webhook(req: Request) raises -> Response:
    var signature = req.headers.get("x-signature")      # Optional[String]
    if not signature or signature.value() != "sha256=valid":
        return Response.text("unsigned", status=401)
    var resp = Response.text("ok")
    resp.headers.add("X-Request-Id", "42")               # raises if invalid
    return resp^


app.post["/webhook"](webhook)
# POST /webhook  X-Signature: sha256=valid  -> 200 "ok", X-Request-Id: 42
# POST /webhook  (no X-Signature)           -> 401 "unsigned"
```

- `muntin.Headers` is the header fields in order. Each keeps its name's casing, and a repeated name (`Set-Cookie`) is several fields. `get(name)` returns the first value as `Optional[String]` (an absent field and an empty value differ), `get_all(name)` every value, and `len`, `name(i)`, `value(i)` walk them. Names compare ASCII case-insensitively.
- `add(name, value)` appends; `set(name, value)` removes every field with that name, then appends. Both raise on a name that is not an RFC 9110 token, or on a value with a control byte (other than HTAB) or SP/HTAB at either end. In a raising handler that error is the fixed 500, or its `ToErrorResponse`. Code that must not raise, such as `to_response`, wraps `add` in `try`.
- `Request` has `headers` (as the backend received them); `Request(method, target, body, headers^)` builds one, and existing calls without headers are unchanged. `Response` has `headers`, empty from `Response(status, body)` and `Response.text`: Muntin adds no `Content-Type` or other default field.
- Raw handlers read `req.headers` (a `var req` handler owns a copy it may change) and set fields on the `Response` they return. Typed handlers read no headers; a typed result sets fields through the `Response` its `to_response` builds. `String` results set none.
- `TestClient` sends no headers; a test builds `Request(..., headers^)` and calls `app.handle`, the same seam.
- Through Flare, a request field Muntin cannot represent is answered 400 before the handler: over HTTP/2 Flare admits a `:` inside a name or a control byte in a value. Fields the backend owns or that are connection-specific (`Content-Length`, `Transfer-Encoding`, `Connection`, `Keep-Alive`, `Proxy-Connection`, `Upgrade`, `TE`, `Trailer`), and any field a `Connection` value names, are not written to the wire; they stay in the in-memory `Response`. Over HTTP/2, names go out lowercase. Header values are text: Flare answers 400 to an HTTP/1.1 header byte ≥ 0x80 itself.

Semantics (decided in M2-014, `docs/ARCHITECTURE.md` "Raw Request decision (M2-014)"; production facts in "Raw Request handlers in production (M2-015)"):

- Same registration syntax on `app.get` and `app.post`: each has one overload taking `def(var Request) thin raises E -> Response`. On `post` a raw handler also fits the generic body overload (`B = Request`); Mojo's documented resolution rule "shorter parameter list" selects the raw overload, and typed handlers never fit it, so they resolve as before.
- The handler may declare `req: Request` (canonical) or `var req: Request` (it owns a fresh copy of the request and can move `req.body` out). It returns `Response` only.
- It may be non-raising, `raises` or `raises T`, under the error model of section 6: a `T` declaring `ToErrorResponse` answers its own response, anything else is the fixed 500 without the error text.
- The route is selected by method and path as usual (404 otherwise, without calling the handler; first registration wins across raw and typed routes, and a typed route's 400 does not fall through to a later one). The route literal declares no path or query parameter (`def()`'s rule and messages: `route declares a path parameter but the handler takes none`, `... query parameter ...`, `malformed route literal`).
- The handler reads `req.method`, `req.path`, `req.query` and `req.body` exactly as the backend built them (the query undecoded, an empty body included). Muntin runs no typed extraction on a raw route, so it generates no 400 before the handler; the handler's `Response` (or its error's `to_error_response()`) may use any status, 400 included.
- A raw-shaped handler that fits no raw overload on `post` (`def(req: Request) -> String` or `-> User`, `def(id: Int, req: Request)`) reports `constraint failed: Request is the whole request, not a body; a raw handler takes only the Request and returns Response` instead of the `FromBody` message. On `get` it is `no matching method in call to 'get'`, with the raw candidate's note `cannot be converted from 'def h(req: Request) thin -> String' to 'def(var Request) raises Never thin -> Response'`; an extra parameter gets the same note on `post`.
- An explicitly typed function value must be spelled `def(var Request) thin raises Never -> Response` on Mojo 1.1.0; `def(Request) thin raises Never -> Response` or a type without `raises` fails with `TODO: function type conversions between closures not supported yet` (as for typed values since M2-011).

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

Status: proven on Mojo 1.1.0 with `from muntin.testing import TestClient`; `TestClient.get(target)` and `TestClient.post(target, body)` build a Muntin `Request` and call `App.handle`, the same entry point network adapters use.

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

Status: not part of M2. M2-016 moved schema/OpenAPI foundations to M3: `FromBody` and `ToResponse` leave the body format to the application, so there is no type-level schema source until a codec defines the mapping.

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

Status after M2 (M2-016): the handler model of this example is production: `get_user(id: Int) -> User` with `app.get["/users/{id}"]` and `create_user(body: CreateUser) -> User` with `app.post["/users"]`, through `TestClient` and the Flare adapter. Some parts are still later work:

- `CreateUser` must conform to `FromBody` and parse its own body, because there is no JSON codec;
- `User` must conform to `ToResponse`. The stdlib `List[User]` does not conform, so a list result needs an application type that does;
- `users` is not a global: on Mojo 1.1.0 module-level variables do not compile (`global variables are not supported`) and handlers cannot capture. Since M3-003 a `get` handler reaches it as `State` (section 8): `def get_user(users: State[Users], id: Int) -> User` registered as `app.get["/users/{id}"](get_user, users)`. A stateful `post` (`create_user`) is not production yet;
- there is no `app.run()`.

The first three are M3 items (codec, stateful `post`); `app.run()` is lifecycle work (M3, ownership undecided). The closest runnable form today is section 4's `CreateUser` and section 5's `User`, driven through `TestClient`.

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
