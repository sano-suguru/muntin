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

Everything below is for **Mojo 1.1.0 (8189361e)**. Each numbered section from 1 on opens with the design target (a constraint on where the API should go, not a claim that it compiles) and then gives its status: what is production now, with the tests that prove it, and what is still a target. Which capabilities are shipped and which remain is `docs/SPEC.md`. Production behavior that crosses the backend seam is also exercised over a real loopback connection through Flare (`adapters/flare/test_localhost_roundtrip.mojo`, `./scripts/check_flare.sh`).

Proven baseline, verified by `tests/test_app.mojo` and `main.mojo` (run via `./scripts/test.sh` / `./scripts/check.sh`):

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

A request whose path no route matches returns status 404; one whose path a route matches, when no route on that path has its method, returns 405 with `Allow` ("405 `Method Not Allowed`", below). These, and every status and field this document gives for a request, are Muntin's own answers: what `App.handle` returns when no middleware changes them. Middleware may answer instead or change any answer, Muntin's 404 and 405 included (section 7).

Typed path parameter, proven by `tests/test_app.mojo`, `tests/compile_fail/` (via `./scripts/check.sh`) and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo` (via `./scripts/check_flare.sh`):

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
- Arity is checked at compile time at the registration call: `app.get["/users/{id}"](hello)` fails with `constraint failed: route declares a path parameter but the handler takes none`; `app.get["/users"](get_user)` and `app.get["/users/{id}/posts/{post}"](get_user)` fail with `constraint failed: handler takes one Int parameter; route must declare exactly one path or query parameter`.
- Routes match the path only (below): `/users/42?x=1` passes `Int(42)` and `/hello?x=1` is 200. Matching uses the raw path; the matched value is then percent-decoded before conversion ("`String` route values and decoding", below), so `/users/%34%32` passes `Int(42)`.

Typed query parameter, proven by the same tests and fixtures:

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

- `Request(method, target, body)` splits the target at its first `?`: `request.path` is the text before it and is all that routes match; `request.query` is the text after it, undecoded (`""` when there is no `?` or nothing follows it). `TestClient.get(target)` and the Flare adapter pass the target as received, so both backends get this one rule. Through Flare, a request whose method or target is not well-formed UTF-8 (which Flare passes on over cleartext HTTP/2; over HTTP/1.1 it answers any byte outside `!`..`~` 400 itself, well-formed UTF-8 included) is answered 400 `Bad Request` by the adapter before `App.handle`: no middleware, route scan or handler runs, so it is 400 on any path, and the `Server` keeps serving. A method or target that is UTF-8 is answered as before, non-ASCII, U+FFFD and percent-encoded bytes included (`%FF` stays route-value decoding's 400, below), and so is a method that is not an HTTP token, such as `é` or an empty one (over h2c 405 or 404; over HTTP/1.1 Flare answers it 400 first) ([Request target and method bytes decision (M3-039)](history/architecture-decisions.md#request-target-and-method-bytes-decision-m3-039)). `#` has no meaning (a fragment is not part of an HTTP request target), so `/items?limit=10#x` has value `10#x` and is 400.
- The route literal's query part, after `?`, is `{key}` items separated by `&`. A key is non-empty, visible ASCII (`!` to `~`, the bytes an HTTP request target can carry), and contains none of `{}=&?#`; an empty query part, static text such as `?limit`, `{}`, a space or other non-visible byte (`?{lim it}`, `?{límit}`), or one of those characters is a compile error (`malformed route literal`). Path and query placeholders together must match the handler's arity: `app.get["/items?{limit}"](hello)` fails with `constraint failed: route declares a query parameter but the handler takes none`, and `app.get["/users/{id}?{limit}"](list_items)` with `constraint failed: handler takes one Int parameter; route must declare exactly one path or query parameter` (the same text as `app.get["/users"](get_user)`). A handler with two route values takes a path and a query value together, or two of either ("Two route values", below).
- The key is written in the route literal because Mojo 1.1.0 cannot reflect a function's parameter names: `reflect[Q].field_names()` returns `limit` for `struct Q` with field `limit`, but `reflect[type_of(list_items)]` has no parameter-name accessor (`'Reflected[def(limit: Int) thin -> String]' value has no attribute 'param_names'`; its `name()` is `std.builtin._stubs.__MLIRType[<unprintable>]`). Binding is positional, as for path parameters: `app.get["/items?{count}"](list_items)` is accepted.
- Parsing the request query: pairs are separated by `&`; a pair's key and value split at its first `=`; a pair without `=` has an empty value; empty pairs are skipped. Keys compare byte for byte, case-sensitively, and are never decoded, so `lim%69t=1` does not match `limit`. The value is decoded before conversion (below), so `limit=%31%30` is `10`.
- The decoded value converts with the path rule (optional `-`, ASCII digits, `Int` range). A missing key, a key that appears more than once (even with equal values), an empty value, a value that does not decode, or a non-integer value returns 400 `Bad Request` without calling the handler. An `Optional[Int]` gets `None` for a missing key or an empty value instead ("Optional query values", below).
- The query takes no part in route selection. With `/items?{limit}` registered before `/items`, `GET /items` matches the first route and is 400; it does not fall through.

`String` route values and decoding, proven by `tests/test_string_route_values.mojo` (with this example as written), `tests/test_app.mojo`, `tests/string_route_api_fail/` (via `./scripts/check.sh`) and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`:

```mojo
def profile(name: String) -> String:
    return "profile " + name


def search(q: String) -> String:
    return "results for " + q


var app = App()                       # its own App: in the one above, /users/{id} answers first
app.get["/users/{name}"](profile)
# GET /users/alice        -> 200 "profile alice"
# GET /users/J%C3%B6rg    -> 200 "profile Jörg"
# GET /users/a+b          -> 200 "profile a+b"     (`+` is literal in a path)
# GET /users/%zz, /users/%FF -> 400 "Bad Request"  (bad escape; not UTF-8)
app.get["/search?{q}"](search)
# GET /search?q=mojo+lang -> 200 "results for mojo lang"
# GET /search?q=a%2Bb     -> 200 "results for a+b"
# GET /search, /search?q=, /search?q=1&q=2 -> 400 "Bad Request"
app.get["/items?{limit}"](list_items)  # list_items as above
# GET /items?limit=%31%30 -> 200 "items 10"
```

Semantics:

- A route value is percent-decoded once, when it is captured, and then converted; the decoding belongs to the capture, not to the type, so an `Int` and a `String` handler on one route receive the same decoded text. Route matching runs first, on the raw path.
- Path value: the matched segment, percent-decoded: each `%` followed by two hex digits (either case) becomes that byte, every other byte is kept, and `+` is literal. `%2F` decodes to `/` inside the one value and never splits a segment (`/users/a%2Fb` is `"a/b"`; `/users/a/b` does not match). Nothing is normalized: `..` and `%2E%2E` are the value `".."`.
- Query value: the value found by its key (above), then `+` becomes a space, then the same percent-decoding (`?q=a+b%2B` is `"a b+"`). Keys are matched undecoded, byte for byte.
- Exactly once: `/users/%2541` gives a `String` handler `"%41"`, and `%2534` is 400 for an `Int`.
- A placeholder binds one non-empty value, whatever its type: an empty path segment does not match (404), and an empty query value (`?q=` or `?q`) is 400 for a `String` as for an `Int` (an optional value is `None` instead: "Optional query values", below).
- The invalid values are exactly: an empty value, a `%` not followed by two hex digits (`%zz`, `%4`, a trailing `%`), and decoded bytes that are not UTF-8 (`%FF`, `%C3`). Each is 400 `Bad Request` before the handler. Anything else that decodes to valid UTF-8 is a value, NUL and other control characters included (`%00`, `%0A`, `%09`). Decoding validates the encoding, not the application's safety: a handler that passes a route value to a filesystem, a C API, a database or another interpreter validates the characters that destination requires.
- An `Int` parses the decoded text with the rule above: `%34%32` is 42, `%2D7` and `-%37` are -7, and `?limit=%31%30` is 10. Decoded text outside the rule is still 400: `+1`, `%2B1`, `%20`, `%2D%2D7`, an out-of-range number. A value written without escapes means what it meant before.
- Muntin's decoding is not a form parser. Only the `+` rule comes from the `application/x-www-form-urlencoded` format, which is how `URLSearchParams` and HTML forms send a space. The WHATWG URL Standard's parser for that format keeps a `%` not followed by two hex digits (`?q=%zz` is `%zz` there, 400 here), replaces bytes that are not UTF-8 with U+FFFD (`?q=%FF` is `"�"` there, 400 here), and decodes names (`?%71=x` has the name `q` there; here it does not match `{q}`). Its binding differs too: `URLSearchParams` gives `""` for `?q=` and keeps duplicates, where Muntin answers 400.
- Order: 404 or 405; a missing or duplicated query value, then an empty value, a bad escape or text that is not UTF-8, 400; an `Int` that does not parse, 400; then the body or `Headers` steps (sections 4 and 9); then the handler.
- Shapes: a `String` parameter goes wherever an `Int` route value goes, once: `app.get` `def(String)` and `def(String, Headers)`; `app.post` `def(String, B)` with `B` a `FromBody`, a `Json[T]` or a `WithHeaders[B2]`; each also after a leading `State[S]` (section 8). The route literal declares exactly one `{name}` segment or `{key}` item for it; binding is positional. The handler may declare `name: String` or `var name: String` (each request gets a fresh value); `mut name: String` matches no overload. An explicitly typed function value spells it `var String` (`def(String) thin raises Never -> String` fails with `TODO: function type conversions between closures not supported yet`), and a generic helper forwards a `String` handler as it does an `Int` one. A `String` is also either of two route values ("Two route values", below).
- Only `String` itself is a route value (exact type equality): `StaticString`, `StringSlice` and application types are not, and `def(StaticString)` on `app.get` is `constraint failed: a get handler's parameter is an Int or String route value, an Optional of one, the request Headers or, for a raw handler, the Request`. A `String` is never the request body: `def(String)` on `app.post` keeps the body messages of section 4.
- Compile-time errors for a `String` shape, where the `Int` text would be false: `constraint failed: handler takes one String parameter; route must declare exactly one path or query parameter` on `app.get`, `constraint failed: handler takes one String parameter and the request body; route must declare exactly one path or query parameter` on `app.post`, and, for two route values, one message whatever their types ("Two route values", below).
- Raw handlers and `Request` are never decoded: `req.path` and `req.query` stay the text received, and an application that must tell `%2F` from `/` uses a raw handler (section 9).

Typed request body, proven by `tests/test_body.mojo`, `tests/compile_fail/post_*.mojo` and `tests/body_fail/` (via `./scripts/check.sh`), `adapters/flare/test_muntin_flare.mojo` and, over real loopback connections through Flare (HTTP/1.1 and cleartext HTTP/2), `adapters/flare/test_localhost_roundtrip.mojo`:

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
# GET /users, PUT /users      -> 405 "Method Not Allowed", Allow: POST (from_body not called)
# POST /missing                -> 404 "Not Found" (from_body not called)
```

Semantics:

- `FromBody` is a public Muntin trait refining `Deinitable & Movable` with one requirement, `@staticmethod def from_body(body: String) raises -> Self`. The application type conforms to it in its own module; Muntin never names the type. `from_body(body: String)` is the current public body-conversion input contract (`from_body` receives the body as one `String` and sees no header fields or content type, although `Request` carries headers); future body capabilities are added as new APIs without changing it.
- The body-only shape of `app.post[route](handler)` is a handler (non-raising or raising, section 6) with one parameter, the body, on a route literal with no path or query placeholder (the route-value-then-body shape is below). It returns `String` or `StaticString` (a string-literal result is text too) or a type conforming to `ToResponse` (section 5). Parameter names are not consulted.
- Muntin reads the request body's bytes as UTF-8 and calls `from_body` with that text before the handler. The body comes from the request body only, never from the path or query (`POST /users?name=Bob` with body `name=Ada` -> `created Ada`), byte for byte (an empty body, surrounding whitespace, NUL and a U+FFFD the client sent reach `from_body` unchanged), and the `Request` is borrowed, not consumed. If the bytes are not well-formed UTF-8, or `from_body` raises, the response is 400 `Bad Request` and the handler is not called. Routes are selected by method and path as for `GET`; a path no route matches is 404, a path only routes of other methods match is 405 with `Allow`, and `from_body` is not called.
- `Request.body` is the body's bytes (`List[UInt8]`), exactly as the backend received them, and a typed text body (`FromBody`) is text read from them strictly: bytes that are not well-formed UTF-8 (`0x80`, `0xFF`, a truncated or overlong sequence, a surrogate, a PNG signature) are 400 before `from_body`, after routing and through middleware, and are never replaced by U+FFFD, so `from_body` never sees a U+FFFD the client did not send. Through Flare every body reaches `App.handle` byte for byte, over HTTP/1.1 and cleartext HTTP/2 (Flare's own refusals come first and are unchanged; among them, a body over its `max_body_size`, 10 MiB by default, and a request its HTTP/1.1 parser or HTTP/2 layer rejects never reach the adapter). A body that is not text is a `FromBytes` body, which receives the bytes with no UTF-8 step (section 4, "Typed binary bodies"), or a raw handler's (section 9).
- Compile-time errors at `app.post`: a parameter type that is neither a `FromBody` body, a `FromBytes` body nor a `WithHeaders[B]` carrier (section 4), including `String` and `List[UInt8]` (`constraint failed: the handler's parameter is the request body; its type must conform to FromBody or FromBytes`; the message does not name the carrier); a `Request` body parameter, i.e. `def(req: Request)` with a result other than `Response` or `def(id: Int, req: Request)` (section 9: `constraint failed: Request is the whole request, not a body; a raw handler takes only the Request and returns Response`; two `Request`s are `constraint failed: a raw post handler takes only the Request and returns Response`, and `mut req` matches no overload); an `Int` parameter (`constraint failed: Int is a route-value type, never the request body; the body parameter's type must conform to FromBody or FromBytes`); a path or query placeholder (`constraint failed: handler takes only the request body; route must declare no path or query parameter`). No parameter is `constraint failed: a post handler takes the request body as its last parameter`, and two bodies `constraint failed: a post handler takes one request body, as its last parameter`. A raw `def(request: Request) -> Response` handler is the raw shape (section 9). A body handler passed to `app.get` is `constraint failed: a get handler takes no request body`.
- `TestClient.post(target, body)` sends `Request("POST", target, body)` through `App.handle`, like `TestClient.get`.

Route value then body, proven by `tests/test_int_body.mojo`, `tests/compile_fail/{,typed_}post_int_*.mojo` and `tests/body_fail/post_{body_then_int,int_and_two_bodies,int_body_*}.mojo` (via `./scripts/check.sh`), `tests/test_registration.mojo` (an owned route value) and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`:

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
# PUT /users/1                    -> 405 "Method Not Allowed", Allow: GET, HEAD, POST  (nothing converted)
# POST /users/1/x                 -> 404 "Not Found"    (nothing converted)
```

Semantics:

- The handler takes exactly one route value, an `Int` or a `String` (above) or an `Optional` of either ("Optional query values", below), then one body. The route literal declares exactly one route value: one `{name}` path segment or one `{key}` query item. Two route values before the body are below ("Two route values"). Binding is positional (route value first, body second); parameter names are not consulted (`def update_note(n: Int, var text: Note)` on `/notes/{id}` works). The route value may be owned (`var id: Int`). The route value follows the rules of `app.get` (path, query and `String` sections above); the body follows the body-only rules (from the request body only, byte for byte, through `B.from_body`).
- Order: no matching method and path is 404, or 405 with `Allow` when a route of another method matches the path, with nothing converted. Otherwise the route value is gathered, decoded and converted first: an invalid path value, or a missing, duplicated, empty or invalid query value, is 400 and `from_body` is not called (for an optional value, a missing or empty one is `None`: "Optional query values", below; a missing path segment does not match the path, so it is 404). Then the body: bytes that are not UTF-8, or a `from_body` raise, are 400 and the handler is not called. Then the handler runs once, and its result is converted once: `String` (or `String`-compatible, such as `StaticString`) to a 200 text response, `R: ToResponse` (an application type or `Response`) by `to_response()`. A matched route that answers 400 never falls through to a later route.
- Compile-time errors at `app.post`, on both result policies: no route value, two path values, or a path and a query value (`constraint failed: handler takes one Int parameter and the request body; route must declare exactly one path or query parameter`, or `... one String parameter and ...` for a `String`); `(Int, Int)` (`constraint failed: Int is a route-value type, never the request body; the body parameter's type must conform to FromBody or FromBytes`); a second parameter that does not conform (`constraint failed: the handler's last parameter is the request body; its type must conform to FromBody or FromBytes`). The body before the route value `(B, Int)`, and two bodies after it `(Int, B, B)`, are `constraint failed: a post handler takes one request body, as its last parameter`. Four parameters match no overload (`no matching method in call to 'post'`, with a note per candidate), and so does a result that is neither `String`, `StaticString` nor `ToResponse` (the candidate's note is `violated constraint`, then the `where` clause, which contains `identical(R, StringSpan[ImmStaticOrigin])`).

PUT, PATCH and DELETE, proven by `tests/test_methods.mojo` (which runs this example as written), `tests/methods_api_fail/` (via `./scripts/check.sh`) and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`. `app.put` and `app.patch` take exactly `app.post`'s shapes, `app.delete` exactly `app.get`'s:

```mojo
from muntin import App, FromJson, Headers, Json, JsonValue, Request, Response, State


@fieldwise_init
struct Rename(FromJson):
    var name: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string())


@fieldwise_init
struct Directory(Movable):
    var domain: String


def replace_user(id: Int, body: UserForm) -> String:  # `post`'s shapes; UserForm as CreateUser above
    return String("replaced ", id, " ", body.name)


def rename_user(
    users: State[Directory], id: Int, body: Json[Rename]
) -> Json[User]:                                          # User as in section 4
    return Json(User(id, body.value.name + "@" + users[].domain))


def remove_user(id: Int, headers: Headers) raises Unauthorized -> String:
    if not headers.get("authorization"):  # `get`'s shapes; Unauthorized as in section 9
        raise Unauthorized()
    return String("removed ", id)


def purge(req: Request) raises -> Response:  # raw: reads a DELETE body as text
    return Response.text("purged " + req.path + " [" + req.text() + "]")


var app = App()                       # its own App: the ones above register POST /users/{id}
app.put["/users/{id}"](replace_user)
app.patch["/users/{id}"](rename_user, State(Directory("example.com")))
app.delete["/users/{id}"](remove_user)
app.delete["/cache"](purge)
# PUT /users/7  "name=Ada"                  -> 200 "replaced 7 Ada"
# PUT /users/7  "Ada" or ""                 -> 400 "Bad Request"  (from_body raised; replace_user not called)
# PATCH /users/7  Content-Type: application/json  {"name":"bo"}
#   -> 200, Content-Type: application/json, {"id":7,"name":"bo@example.com"}
# PATCH /users/7  (no Content-Type)         -> 415 "Unsupported Media Type"
# DELETE /users/7  Authorization: t1        -> 200 "removed 7"
# DELETE /users/7  (no Authorization)       -> 401 "Unauthorized"
# DELETE /users/abc                         -> 400 "Bad Request"  (remove_user not called)
# DELETE /cache  "all"                      -> 200 "purged /cache [all]"
# POST /users/7, HEAD /users/7 (no get route here), OPTIONS /users/7, delete /users/7
#   -> 405 "Method Not Allowed", Allow: PUT, PATCH, DELETE
# GET /cache                                -> 405 "Method Not Allowed", Allow: DELETE

var client = TestClient(app)
_ = client.put("/users/7", "name=Ada")
var h = Headers()
h.add("Content-Type", "application/json")
_ = client.patch("/users/7", '{"name":"bo"}', headers=h^)
_ = client.delete("/users/7")                       # 401: no field sent
_ = app.handle(Request("DELETE", "/cache", "all"))  # a DELETE body: build the Request
```

Semantics:

- Shape families: `put` and `patch` accept every shape `post` accepts and no other (a required body last: a `FromBody`, a `Json[T]` or a `WithHeaders[B]`; at most two route values (`Int`, `String` or an `Optional` of either) before it; the raw handler; each after a leading `State[S]`). `delete` accepts every shape `get` accepts and no other (no body; at most two route values; a `Headers` parameter last; the raw handler; each after a leading `State[S]`). Route values, their decoding and 400s, the body steps (415 then 413 for `Json[T]`, then 400 for bytes that are not UTF-8 or a `from_body` raise), result policies and errors are those of the family, in the same order. Everything this document says about `post`'s shapes holds for `put` and `patch`, and about `get`'s for `delete`.
- A typed `put` or `patch` handler takes a body; one without a body is a compile error (`a put handler takes the request body as its last parameter`). A request with an empty body is not a bodyless handler: the body rules apply to `""` (415 first for a `Json[T]` body without its `Content-Type`, then 400 if `from_body("")` raises).
- A typed `delete` handler takes no body: a body parameter is `constraint failed: a delete handler takes no request body`, and a body sent to a typed `delete` route is not read. A raw `delete` handler receives the whole request, `req.body` included.
- Matching: a route matches a request whose method is its own (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`) byte for byte, and a `get` route also matches `HEAD` (below). Routes are tried in registration order across methods, and the first whose method and path match handles the request and never falls through. A path that only routes of other methods match is 405 with `Allow`, and a path no route matches is 404 ("405 `Method Not Allowed`", below). `HEAD` on a path no `get` route matches, `OPTIONS` and every other method get the same answer.
- Diagnostics name the method: each message that names `get` or `post` above names `delete`, `put` or `patch` on those methods (`a stateful raw delete handler takes State first, then only the Request, and returns Response`, `State is injected application state, not the request body; a stateful put handler takes State first and the body last, and the state is the registration's second argument`, `a patch handler takes one request body, as its last parameter`); messages that name no method are the same. A call no overload takes is `no matching method in call to 'put'` (or `'patch'`, `'delete'`), with that method's eight candidate notes.
- `TestClient.put(target, body)`, `.patch(target, body)` and `.delete(target)` send `PUT`, `PATCH` and `DELETE` through `App.handle` (section 10); `delete` sends an empty body.
- Through Flare, a method with a lowercase letter (`delete`) is 400 from Flare before `App.handle`, which would answer 405 or 404 as for any method no route has (`docs/ARCHITECTURE.md`, "Other current limits").

`HEAD`, proven by `tests/test_head.mojo` (which runs this example as written), `tests/test_testclient_head.mojo` (`TestClient.head`), `adapters/flare/test_muntin_flare.mojo` and, over real loopback connections through Flare (HTTP/1.1 and cleartext HTTP/2), `adapters/flare/test_localhost_roundtrip.mojo` and `compat/flare/head/head_probe.mojo` (via `./scripts/check_flare.sh`). A `get` route answers `HEAD`; there is no `app.head`:

```mojo
from muntin import App, Request, Response
from muntin.testing import TestClient


def show_user(id: Int) -> String:
    return String("user ", id)


def report(req: Request) -> Response:  # raw: req.method is "GET" or "HEAD"
    return Response.text("report")     # the GET body for both


def drop(id: Int) -> String:
    return String("dropped ", id)


var app = App()                        # its own App
app.get["/users/{id}"](show_user)
app.get["/report"](report)
app.delete["/cache/{id}"](drop)
# HEAD /users/7   -> 200 "user 7" from App.handle, as GET /users/7; through Flare: 200, Content-Length: 6, no content
# HEAD /users/abc -> 400 "Bad Request" (show_user not called); through Flare: 400, Content-Length: 11, no content
# HEAD /report    -> report receives req.method == "HEAD": 200 "report"; through Flare: Content-Length: 6, no content
# HEAD /cache/1   -> 405 "Method Not Allowed", Allow: DELETE; through Flare: Content-Length: 18, no content
# head /users/7, OPTIONS /users/7 -> 405 "Method Not Allowed", Allow: GET, HEAD
# HEAD /missing   -> 404 "Not Found"

var head = TestClient(app).head("/users/7")  # = app.handle(Request("HEAD", "/users/7"))
# head.status == 200, head.text() == "user 7": the in-memory response keeps the body
```

- A `HEAD` request is answered by the first route, in registration order, whose method is `GET` and whose path matches: route values, the `Headers` parameter, `State`, the handler, the result or error conversion and the 400/404/500 order all run as for `GET`. A typed handler gets the `GET`'s arguments, so `App.handle` returns the `GET`'s status, fields and body; a raw handler receives the `HEAD` request (below). A route of another method on the path is skipped, as for any method. Only the exact token `HEAD` maps: `head` and `Head` are answered as any method no route has, 405 on a path some route matches (through Flare they are 400 before `App.handle`, as `delete` is). `HEAD` on a path no `get` route matches is 405 with `Allow` when a route of another method matches it, and 404 otherwise.
- The backend keeps the content off the wire. A network backend sends the response's status and fields with no content and declares a `Content-Length` equal to the byte length of the body it would send for the `GET` (the one `App.handle` returned, or the backend's own answer), or none for a status that never carries content (1xx, 204, 205, 304). The Flare adapter applies this to every answer it sends for `HEAD`, its own 400 and 500 included, over HTTP/1.1 and cleartext HTTP/2; over HTTP/1.1 Flare itself still frames a 205 or 304 with `Content-Length: 0`. A handler's own `Content-Length` is dropped, as for every method. Why: [HEAD decision (M3-026)](history/architecture-decisions.md#head-decision-m3-026).
- A typed handler cannot tell `HEAD` from `GET`: it receives the same arguments. A raw `get` handler receives the request as sent, `req.method == "HEAD"`, and must answer it with the body it would give `GET`: the backend declares the length of the body the handler returned, so a shorter body for `HEAD` (to skip work) sends a wrong `Content-Length`. Muntin cannot check this.
- Testing: `TestClient(app).head(target)` sends `HEAD` and returns `app.handle(Request("HEAD", target))` unchanged, its body included: the in-memory response, not what a network backend sends (section 10). Its body is the `GET`'s only when the route and every middleware answer `HEAD` as `GET`; when a raw handler or middleware answers `HEAD` with another body, `head` returns that body: for a status that carries content, the body whose length a network backend declares.
- Cost: every `HEAD` computes and converts the whole `GET` body for the backend to drop.

405 `Method Not Allowed`, proven by `tests/test_method_not_allowed.mojo` (which runs this example as written), `adapters/flare/test_muntin_flare.mojo` and, over real loopback connections through Flare (HTTP/1.1 and cleartext HTTP/2), `adapters/flare/test_localhost_roundtrip.mojo`. A request whose path a route matches, when no route on that path has its method, is Muntin's own 405 with an `Allow` field:

```mojo
var app = App()                          # its own App
app.get["/users/me"](me)                 # def me() -> String
app.delete["/users/{id}"](delete_user)   # def delete_user(id: Int) -> String
app.get["/users/{id}"](get_user)         # def get_user(id: Int) -> String
app.put["/users/{id}"](update_user)      # def update_user(id: Int, body: Note) -> String
app.post["/hooks"](hook)                 # raw: def hook(req: Request) -> Response
# POST /users/7, OPTIONS /users/7, FOO /users/7 -> 405 "Method Not Allowed", Allow: DELETE, GET, HEAD, PUT
# POST /users/me  -> 405, Allow: GET, HEAD, DELETE, PUT  (/users/me and /users/{id} both match the path)
# POST /users/abc -> 405, Allow: DELETE, GET, HEAD, PUT  (nothing is decoded or converted to decide it)
# PUT /users/me   -> 400 "Bad Request"  (PUT selects /users/{id}; "me" is no Int)
# GET /hooks, HEAD /hooks -> 405, Allow: POST; through Flare, HEAD /hooks: Content-Length: 18, no content
# POST /users/7/x, POST /missing -> 404 "Not Found"
```

- When no route matches a request's method and path, `App.handle` checks each route's path with the test selection uses (equal static segments, one non-empty segment per placeholder, the query ignored, on the raw path). If some route's path matches, Muntin's answer is `Response.text("Method Not Allowed", status=405)` with one `Allow` field and no `Content-Type`; if none does, it is 404 `Not Found`. Neither decodes or converts anything or runs a handler. A request some route matches by method and path keeps its answer, a 400 included.
- `Allow` lists the methods of the routes whose path matches, each once, in the order their first such route was registered, with `HEAD` right after `GET` (a `get` route answers `HEAD`), joined by `, `. Raw and typed routes, stateless and stateful, count alike. A method in `Allow`, sent to the same target, selects a route, which may still answer 400 for its route value or body (`PUT /users/me`); a method not in it gets 405. Reordering registrations reorders `Allow`.
- Every method is answered alike: `OPTIONS`, an unknown method (`FOO`) and a lowercase one (`get`, `head`) are 405 on a path some route matches and 404 elsewhere. Muntin does not answer `OPTIONS` itself or a CORS preflight, and does not answer 501 for a method it does not implement (why: [Method not allowed decision (M3-030)](history/architecture-decisions.md#method-not-allowed-decision-m3-030)). Through Flare, a method with a lowercase letter is still 400 before `App.handle`.
- Muntin's body is fixed. An application answers a 405 or a 404 itself with middleware (section 7), which may replace either answer or change it; a 405 the middleware builds or changes carries whatever `Allow` the middleware leaves on it, which is the application's responsibility (`tests/test_middleware.mojo`). Through Flare the 405 goes out with the fields `App.handle` returned, Muntin's `Allow` included; a `HEAD` 405 has no content and `Content-Length: 18`, by the `HEAD` rule above.

Two route values, proven by `tests/test_route_values.mojo` (which runs this example as written), `tests/route_values_api_fail/` (via `./scripts/check.sh`) and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`. A handler takes up to two route values, on every method:

```mojo
from muntin import App, FromJson, Headers, Json, JsonValue, JsonWriter, ToJson


@fieldwise_init
struct Edit(FromJson):
    var title: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["title"].string())


@fieldwise_init
struct Post(ToJson):
    var uid: Int
    var pid: Int
    var title: String

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("uid")
        out.int(self.uid)
        out.name("pid")
        out.int(self.pid)
        out.name("title")
        out.string(self.title)
        out.end_object()


def post_of(uid: Int, pid: Int) -> String:
    return String("post ", pid, " of user ", uid)


def user_fields(id: Int, fields: String) -> String:
    return String("user ", id, ": ", fields)


def search(q: String, limit: Int) -> String:
    return String(limit, " results for ", q)


def edit_post(uid: Int, pid: Int, body: Json[Edit]) -> Json[Post]:
    return Json(Post(uid, pid, body.value.title))


def remove_post(
    uid: Int, pid: Int, headers: Headers
) raises Unauthorized -> String:      # Unauthorized as in section 9
    if not headers.get("authorization"):
        raise Unauthorized()
    return String("removed post ", pid, " of user ", uid)


var app = App()                       # its own App: the ones above register /users/{id} and /search?{q}
app.get["/users/{uid}/posts/{pid}"](post_of)
app.get["/users/{id}?{fields}"](user_fields)
app.get["/search?{q}&{limit}"](search)
app.patch["/users/{uid}/posts/{pid}"](edit_post)
app.delete["/users/{uid}/posts/{pid}"](remove_post)
# GET /users/1/posts/2            -> 200 "post 2 of user 1"
# GET /users/1?fields=name+email  -> 200 "user 1: name email"
# GET /search?limit=5&q=mojo      -> 200 "5 results for mojo"   (the literal's order, not the request's)
# GET /users/1/posts/x, /search?q=mojo, /search?q=a&q=b&limit=5 -> 400 "Bad Request"  (handler not called)
# PATCH /users/1/posts/2  Content-Type: application/json  {"title":"Hi"}
#   -> 200, Content-Type: application/json, {"uid":1,"pid":2,"title":"Hi"}
# PATCH /users/1/posts/x  (no Content-Type)   -> 400 "Bad Request"  (the value answers before the body's 415)
# DELETE /users/1/posts/2  Authorization: t1  -> 200 "removed post 2 of user 1"
# DELETE /users/1/posts/2  (no Authorization) -> 401 "Unauthorized"
```

Semantics:

- Shapes: `get` and `delete` take `def(V, V)` and `def(V, V, Headers)`; `post`, `put` and `patch` take `def(V, V, B)` with `B` a `FromBody`, a `Json[T]` or a `WithHeaders[B2]`; each also after a leading `State[S]` (section 8). `V` is an `Int` or a `String`, or an `Optional` of either ("Optional query values", below), in any combination. The route literal declares exactly two placeholders: two `{name}` segments, two `{key}` items, or one of each. Every zero- and one-value shape is unchanged.
- Binding is by position: the path placeholders left to right, then the query placeholders left to right, fill the route-value parameters in order; then the body or the `Headers`. The request's query order does not matter (`/search?limit=5&q=mojo` gives `search("mojo", 5)`). Names are never compared with the handler's parameters, because Mojo 1.1.0 cannot reflect them.
- The swap caveat: two values of one type that the handler declares in the other order compile and receive each other's values. `def post_of(pid: Int, uid: Int)` on `/users/{uid}/posts/{pid}` gets `pid == 1` for `/users/1/posts/2`. A swapped `Int` and `String` fails only at request time, when the text is not an `Int` (400). For two values of one type, section 2's "a route declaring `{id}` should not silently bind to an unrelated handler parameter" is not met; the parameter order is the application's to keep ([why](history/architecture-decisions.md#several-route-values-decision-m3-022)).
- Query keys in one literal must differ: `app.put["/x?{a}&{a}"](h)` is `constraint failed: route declares a query parameter twice`, because both parameters would read the one key. Path names are not checked: `/x/{a}/{a}` and `/x/{a}?{a}` register, and each parameter gets its own value by position.
- Each value follows the one-value rules (sections above): captured and percent-decoded once in `App.handle`, non-empty (for an optional value, a missing or empty one is `None`: "Optional query values", below), the same invalid set, query keys matched undecoded. The values convert in order, so the first invalid one answers 400 and nothing later is converted. Order: 404 or 405; a duplicated query value, a missing or empty required value, a bad escape or text that is not UTF-8, 400; an `Int` that does not parse, 400; then the body steps (415 and 413 for `Json[T]`, then the UTF-8 read, then `from_body`) or the `Headers` rebuild; then the handler. A 400 calls neither `from_body` nor the handler, and there is no new status.
- Compile-time errors: two values with another placeholder count are `constraint failed: handler takes two route values; route must declare exactly two path or query parameters` on `get` and `delete`, and `constraint failed: handler takes two route values and the request body; route must declare exactly two path or query parameters` on `post`, `put` and `patch`, whatever the values' types. Three route values are `constraint failed: a get handler takes at most two route values` (or `delete`), whatever the literal declares. A handler with four request parameters matches no overload (`no matching method in call to 'get'`, or the other method).

Optional query values, proven by `tests/test_optional_values.mojo` (which runs this example as written), `tests/optional_values_api_fail/` (via `./scripts/check.sh`) and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`. An `Optional[Int]` or `Optional[String]` parameter is a route value that may be absent; the handler supplies any default:

```mojo
def list_items(limit: Optional[Int]) -> String:
    return "items " + String(limit.or_else(20))


def search(q: String, sort: Optional[String]) -> String:
    return "results for " + q + " by " + sort.or_else("relevance")


def posts(uid: Int, limit: Optional[Int], headers: Headers) -> String:
    return String("user ", uid, ": ", limit.or_else(20), " posts")


def tag_user(tag: Optional[String], body: CreateUser) -> String:   # CreateUser as above
    return "created " + body.name + " tagged " + tag.or_else("none")


var app = App()                       # its own App: the ones above register /items?{limit} and /search?{q}
app.get["/items?{limit}"](list_items)
app.get["/search?{q}&{sort}"](search)
app.get["/users/{uid}/posts?{limit}"](posts)
app.post["/users?{tag}"](tag_user)
# GET /items, /items?limit=, /items?limit    -> 200 "items 20"   (limit is None)
# GET /items?limit=5, /items?limit=%35       -> 200 "items 5"
# GET /items?limit=x, /items?limit=1&limit=2 -> 400 "Bad Request" (list_items not called)
# GET /search?q=mojo                         -> 200 "results for mojo by relevance"
# GET /search?sort=date&q=mojo               -> 200 "results for mojo by date"
# GET /search?sort=date                      -> 400 "Bad Request"  (q is required)
# GET /users/1/posts, /users/1/posts?limit=5 -> 200 "user 1: 20 posts", "user 1: 5 posts"
# POST /users  "name=Ada"                    -> 200 "created Ada tagged none"
# POST /users?tag=a+b  "name=Ada"            -> 200 "created Ada tagged a b"
```

Semantics:

- Shapes: an optional value is a route value wherever an `Int` or `String` is (`V` in every shape above, on every method, stateless or stateful), in any combination with them, at most two per handler. It binds a `{key}` query placeholder only: a path segment is never absent, because a request without it has another path. Binding is unchanged (path placeholders, then query placeholders, by position), so an optional value at a path position is a compile error, and so is a lone optional value on a literal with a path placeholder or with other than one query placeholder.
- Absent and empty are one case: a key that does not appear, a pair with an empty value (`limit=`) and a pair without `=` (`limit`) all give `None`. A value that decodes to a space (`limit=+`, `limit=%20`) is present. Muntin never passes `Some("")`, so an application cannot tell `?q=` from no `q`; a route that must (an update that leaves a field unchanged when its key is absent) uses a raw handler (section 9).
- A present value keeps every rule of a required one: decoded once, then converted; a bad escape, text that is not UTF-8 or an `Int` that does not parse is 400 before the handler, not `None`. A repeated key is 400 whatever its values (`?limit=1&limit=2`, `?limit&limit`). Keys are matched undecoded, so `?%6Cimit=5` leaves `limit` absent. Order: 404 or 405; a duplicated key, a required value missing or empty, a bad escape or text that is not UTF-8, 400; an `Int` that does not parse, 400; then the body or `Headers` steps; then the handler. A required value beside an optional one is still 400 when absent or empty.
- Defaults are the handler's (`limit.or_else(20)`), which also covers a filter that is not applied when absent and a default computed from `State`. Section 3's `limit: Int = 20` is not expressible: on Mojo 1.1.0 the default does not travel with the function value, so `def list_items(limit: Int = 20)` on `/items?{limit}` registers as a required `Int` and `/items` is 400 without a diagnostic ([why](history/architecture-decisions.md#optional-query-values-decision-m3-024)).
- Only `Optional[Int]` and `Optional[String]` are optional values (exact type equality): `Optional[Optional[Int]]` on `app.get` is `constraint failed: a get handler's parameter is an Int or String route value, an Optional of one, the request Headers or, for a raw handler, the Request`, and `Optional[Float64]` before the body on `app.post` is `constraint failed: a post handler's parameter before the body is a route value: an Int, a String or an Optional of either`. An `Optional` is never the body: `def(Optional[Int])` on `app.post` keeps the body message `the handler's parameter is the request body; its type must conform to FromBody or FromBytes`.
- Compile-time errors: one optional value on a literal with a path placeholder or with other than one query placeholder is `constraint failed: handler takes one Optional route value; route must declare exactly one query parameter and no path parameter` on `get` and `delete`, and `constraint failed: handler takes one Optional route value and the request body; route must declare exactly one query parameter and no path parameter` on `post`, `put` and `patch`. Two values whose count matches, one of them optional at a path position (`def(Optional[Int], Int)` on `/users/{uid}?{limit}`, which would bind `uid`'s segment to the optional parameter), are `constraint failed: an Optional route value binds a query parameter; route values bind the path parameters first, then the query parameters` on every method.
- An explicitly typed function value spells it `var Optional[Int]` (`def(var Optional[Int]) thin raises Never -> String`), and a generic helper forwards an optional-value handler as it does any other.

Current argument shapes are exactly `def()`, `def(V)`, `def(Headers)`, `def(V, Headers)`, `def(V, V)` and `def(V, V, Headers)` for `app.get` (section 9), and `def(B)`, `def(V, B)` and `def(V, V, B)` with `B: FromBody` (or a `WithHeaders[B]` around one, section 4) for `app.post`, where `V` is an `Int` or `String` route value or an `Optional` of either (a query value only), plus, on both, the raw `def(req: Request) -> Response` (section 9); `app.delete` takes `app.get`'s shapes and `app.put` and `app.patch` take `app.post`'s (above). Each may be non-raising or declare `raises` or `raises T` (section 6), and returns `String`, `StaticString` (or a string literal) or a type conforming to `ToResponse`, including `Response` (section 5). With a state as the registration's second argument, each shape also takes a leading `State[S]` (section 8). `Json[T]` (sections 4 and 5) is a body or a result type on these shapes, not a new shape.

Registration rules, proven by `tests/test_registration.mojo`, `tests/registration_api_fail/` and every test and fixture above. `app.get`, `app.post`, `app.put`, `app.patch` and `app.delete` each have one overload per number of request parameters (0 to 3), stateless and stateful; the kind of each parameter (`Int`, `String`, `Optional[Int]` or `Optional[String]` route value, body, `Request`, `Headers`) is decided from its type, and the result type through a `where` clause on each overload.

- An owned route value registers: `def get_user(var id: Int)` on `get`, `def update(var id: Int, body: Note)` on `post`.
- A rejected shape that has an accepted parameter count reports the rule it breaks: `constraint failed: <rule>`, after `function instantiation failed` at the enclosing function and the registration call in the next note. Besides the messages above: `a get handler takes no request body`, `a get handler takes at most two route values`, `a get handler's parameter is an Int or String route value, an Optional of one, the request Headers or, for a raw handler, the Request` (a `Float64` or `StaticString` parameter, for example), `a get handler takes one Headers, as its last parameter`, `a raw get handler takes only the Request and returns Response`, `a post handler takes the request body as its last parameter`, `a post handler takes one request body, as its last parameter`, `a raw post handler takes only the Request and returns Response`, and the stateful and `State` variants in section 8.
- A call that no overload takes gets `no matching method in call to 'get'` (or `'post'`, `'put'`, `'patch'`, `'delete'`) with one note per candidate, eight candidates per method: more parameters than three (after a leading `State`), a `State` parameter that is `var`, `mut`, a plain value or not first, and a result that is not `String`, `StaticString` or a `ToResponse` (`candidate not viable: violated constraint`, then the `where` clause, e.g. `... Bool(identical(R, StringSpan[ImmStaticOrigin])) or conforms_to(R, ToResponse)`). When the call does not let the compiler decide the clause, the error is `invalid call to '<method>': lacking evidence to prove correctness` instead: for a result with a local's immutable origin (`origin_text[ImmOrigin(origin_of(s))]`), and for a forwarding helper's generic result whose own `where` is neither one branch of the clause nor the whole clause (no `where`, or a partial disjunction such as `where (R == String or R == StaticString)`). Candidate notes name the generic slots: `cannot be converted from 'def h(id: Int, db: State[Db], body: Note) thin -> String' to 'def(State[S], var A, var B) raises Never thin -> String'`.
- An explicitly typed function value or helper parameter spells each request parameter `var`: `def(var Int) thin raises Never -> String` registers, and `def(Int) thin raises Never -> String` fails with `TODO: function type conversions between closures not supported yet`. A leading `State[S]` keeps its spelling; bodies, `Headers` and `Request`s are `var` too. Plain `def` handlers are unaffected. A typed `def() thin raises Never -> StaticString` value, and a generic helper parameter `h: def() thin raises E -> StaticString` forwarded to `app.get`, register as text.
- Generic forwarding: a helper generic over a request parameter (for example `h: def(var A) thin raises Never -> String`, `def(State[S], var A, var B)`, or `def(var A) -> Response` filled by `Request`) or over the handler's result forwards to `app.get`/`app.post` (and `app.put`, `app.patch`, `app.delete`) and registers as the plain handler would. A generic result needs its own `where` clause that is one branch of the registration's (`where R == String`, `where R == StaticString`, `where conforms_to(R, ToResponse)`) or the whole clause (also with its branches reordered); with none, or with a partial disjunction, the call is `invalid call ...: lacking evidence to prove correctness` even for an accepted type. The rules apply to the instantiated types as usual.

Sections below mark what is still a target; the list of shipped and remaining capabilities is `docs/SPEC.md`. Default response fields are decided, not a target: `String` results and `Response.text` add none, and only `Json[T]` results add `Content-Type: application/json`.

## Design principles

The public API should optimize for minimal boilerplate, strong static typing, useful compile-time validation, explicit escape hatches, predictable ownership, transport independence, composability, helpful diagnostics, and tests that do not require a real network socket.

Prefer compile-time work when it materially improves correctness, runtime cost, or diagnostics. Do not use metaprogramming merely because Mojo supports it.

Avoid hidden global state. Application code should not need to understand Flare or any other networking backend.

## 1. Hello World

Target shape (`examples/hello_server.mojo`):

```mojo
from muntin import App
from muntin_flare import Server


def hello() -> String:
    return "Hello, Mojo!"


def main() raises:
    var app = App()
    app.get["/"](hello)
    var server = Server.bind("127.0.0.1", 8080)
    print("listening on http://127.0.0.1:" + String(server.port()))
    server.serve(app)
```

From a clone it runs as `pixi run -e flare mojo run -I src -I adapters/flare examples/hello_server.mojo`.

A basic endpoint should not require users to manually construct a `Request`, `Response`, router entry, handler adapter, transport, executor, or allocator simply to return text.

Returning a `String` should be convertible to a successful text response by Muntin.

The parameterized `app.get["/"](...)` syntax is a target because route literals known at compile time may enable better validation. It becomes canonical only after it compiles cleanly on the supported Mojo version.

Status: the program above runs on the shipped, supported serving API; it is a runnable example, not a production-ready deployment (the limits are below). `app.get["/"](hello)` compiles and dispatches (see "Proven vs. target status"), and `Server` in the Flare adapter module serves it ([Serving entrypoint decision (M3-032)](history/architecture-decisions.md#serving-entrypoint-decision-m3-032); `adapters/flare/test_server.mojo`, and every loopback case in `adapters/flare/test_localhost_roundtrip.mojo` runs through `Server`). Muntin core has no `app.run()`: the backend is chosen by the one import of `muntin_flare`, which builds only in the `flare` pixi environment with `-I src -I adapters/flare` (Muntin is not published as a package). `./scripts/check_flare.sh` builds the example and does not run it (it binds port 8080).

- `Server.bind(host: String, port: Int) raises -> Server` binds and listens before it returns, so a client may connect as soon as it returns. There are no defaults. `host` is an IPv4 or IPv6 literal (`"127.0.0.1"`, `"0.0.0.0"`, `"::1"`), never a name: `"localhost"` raises. `port` is 0 to 65535, and 0 lets the system choose; outside that range it raises `port out of range: <port>` before anything is bound. An address in use or another OS error raises too; the text of those errors is Flare's, not part of the contract. Dropping the `Server` closes its listener, so the port can be bound again. `Server.bind` is the one spelling: `Server("127.0.0.1", 0)` and `Server(host="127.0.0.1", port=0)` do not build (`no matching function in initialization`); the initializer's `_host` and `_port` keywords are not API.
- `server.port() -> Int` is the bound port, the system's choice for 0.
- `server.serve(app) raises` borrows `app`, as `TestClient(app)` does, so a raise leaves it usable. It serves on the calling thread with one reactor (`App.handle` is never called concurrently) and does not return while serving. Each request that reaches Muntin is answered as `App.handle` answers it, with the adapter's 400 for a request method, target or field it cannot represent (one that is not UTF-8: the target bullet of "Proven vs. target status" and section 9; a body is never refused there, whatever its bytes, section 4), its 500 for an invalid outgoing field, and the `HEAD` rule ("Proven vs. target status", `HEAD`). Flare answers some requests first: over HTTP/1.1 a method that is empty, has a lowercase letter or a byte that is not a token character, or a target byte outside `!`..`~` (400), and a body over its 10 MiB `max_body_size` (413 over HTTP/1.1; over h2c such a stream is reset).
- Protocols: cleartext HTTP/1.1, and HTTP/2 with prior knowledge on the same listener. No TLS, no HTTP/3, and no backend configuration: Flare's `ServerConfig` defaults apply (among them the body size, keep-alive and timeouts). Flare reads an opt-in `FLARE_BUFRING_HANDLER=1` (Linux, HTTP/1.1 only) from the environment; answers on that path are not covered by Muntin's tests.
- Stopping: there is no stop call, graceful shutdown or signal handling; neither Muntin nor Flare installs a signal handler. SIGINT (Ctrl-C) and SIGTERM end the process (on Mojo 1.1.0 the runtime's own handler for them re-raises the signal under the disposition the process inherited), unless the process inherited them ignored (a background job of a non-interactive shell inherits SIGINT ignored): in-flight requests are cut, nothing is drained, and no destructor runs.
- When Flare's `serve` raises, the raise propagates; when it returns, `serve` returns. Nothing Muntin exposes stops Flare, so on Flare v0.12.0 a return means Flare's reactor stopped (a failed poll), and `serve` returning does not distinguish that from a stop. Muntin adds no exit or error policy for it: a `main` that does nothing after `serve`, as above, can then end with status 0.

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

Status: `app.get["/users/{id}"](get_user)` with an `Int` parameter is production, and so is a `String` parameter (`app.get["/users/{name}"](profile)`, the value percent-decoded); see "Proven vs. target status" for matching and conversion rules, and section 5 for returning `User`. Two route values are production too (`app.get["/users/{uid}/posts/{pid}"](post_of)`), bound by position in the literal's order; two values of one type declared in the other order compile and receive each other's values, so for them the name rule above is not met ("Two route values" in "Proven vs. target status").

Where Mojo makes it practical, route/handler mismatches should be diagnosed at compile time. A route declaring `{id}` should not silently bind to an unrelated handler parameter. If compile-time name matching is not practical, fail as early and clearly as the language permits.

## 3. Query parameters

Desired direction:

```mojo
def search(query: String, limit: Int = 20) -> SearchResults:
    return search_index(query, limit)

app.get["/search"](search)
```

For `GET /search?query=mojo&limit=10`, the handler should receive typed values rather than raw strings. Missing required values and invalid conversions should become clear client errors.

A default written as a parameter default (`limit: Int = 20`) is not expressible on Mojo 1.1.0: the default does not travel with the function value, so the closest type-safe form is an `Optional` parameter whose handler supplies the default ([why](history/architecture-decisions.md#optional-query-values-decision-m3-024)).

Status: one required `Int` query value is proven as `app.get["/items?{limit}"](list_items)` with `def list_items(limit: Int) -> String`; see "Proven vs. target status". The key sits in the route literal because handler parameter names cannot be reflected, so the name-based `app.get["/search"](search)` above is not possible on Mojo 1.1.0. A `String` value is production too (`app.get["/search?{q}"](search)`, `+` a space and the value percent-decoded). Two keys work (`app.get["/search?{q}&{limit}"](search)` with `def search(q: String, limit: Int)`), bound in the literal's order whatever the request's order ("Two route values" in "Proven vs. target status"). An optional value is `Optional[Int]` or `Optional[String]`, `None` when its key is absent or its value empty, with the default in the handler: `def list_items(limit: Optional[Int])` and `limit.or_else(20)` ("Optional query values" in "Proven vs. target status"). `def search(query: String, limit: Int = 20)` registers on `/search?{query}&{limit}`, but its `limit` is required: a request without it is 400.

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

Status: the body-only shape and the route-value-then-body shape are **production**: `app.post["/users"](create_user)` and `app.post["/users/{id}"](update_user)` with `from muntin import FromBody` (semantics in "Proven vs. target status"). An application `FromBody` type chooses its own format; JSON is Muntin's `Json[T]` (below):

```mojo
struct CreateUser(FromBody):            # the application type conforms; Muntin never names it
    var name: String

    @staticmethod
    def from_body(body: String) raises -> Self:   # raise -> 400, handler not called
        ...


def create_user(body: CreateUser) -> String:      # `var body: CreateUser` also works; may be move-only
    return body.name


app.post["/users"](create_user)          # the one parameter is the body
app.post["/users/{id}"](update_user)    # def update_user(id: Int, body: CreateUser), route value then body
```

- Binding is positional (no route value, or one or two route values before the body: an `Int`, a `String` or an `Optional` of either): route values (path segments, then the query keys) fill the first parameters, and one more parameter, last, is the body. Route values are Muntin builtins (`Int`, `String` and their `Optional`s), bodies are types that conform to the body trait, and the two never overlap, so a forgotten `{id}` or a misplaced body type is a compile error at `app.post`, not a silent rebinding.
- The application writes `from_body` and chooses the body format. For JSON, Muntin's `Json[T]` wrapper fills `from_body` with Muntin's codec (below); routing and binding are the same.
- A body that does not convert is 400 before the handler runs; a raising handler's error is a different outcome (500, section 6).

JSON, status: **production**; proven by `tests/test_json.mojo`, `tests/test_json_dx.mojo` (this section's example and section 5's), `tests/json_api_fail/` (via `./scripts/check.sh`) and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`. The application declares `FromJson`/`ToJson` on its own types and wraps them in Muntin's `Json[T]`, which is a body and a result through the existing traits, so registration is unchanged and no new handler shape exists:

```mojo
from muntin import App, FromJson, Json, JsonValue, JsonWriter, ToJson


@fieldwise_init
struct CreateUser(FromJson):
    var name: String
    var age: Int
    var nickname: Optional[String]

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:   # raise -> 400, handler not called
        var nick = Optional[String]()
        var n = value.get("nickname")                  # None when absent
        if n and not n.value().is_null():
            nick = n.value().string()
        return Self(value["name"].string(), value["age"].int(), nick^)


@fieldwise_init
struct User(ToJson):
    var id: Int
    var name: String

    def write_json(self, mut out: JsonWriter) raises:  # raise -> fixed 500, not the handler's error
        out.begin_object()
        out.name("id")
        out.int(self.id)
        out.name("name")
        out.string(self.name)
        out.end_object()


def create_user(body: Json[CreateUser]) -> Json[User]:    # borrow and read body.value
    return Json(User(1, body.value.name))


def replace_user(id: Int, var body: Json[CreateUser]) -> Json[User]:
    var c = body^.take()                                  # own: the whole value, moved out
    return Json(User(id, c.name))


app.post["/users"](create_user)          # body only
app.post["/users/{id}"](replace_user)    # route value, then body
# POST /users  Content-Type: application/json  {"name":"Ada","age":36}
#   -> 200, Content-Type: application/json, {"id":1,"name":"Ada"}
# Content-Type missing, text/plain, two fields, or application/problem+json
#   -> 415 "Unsupported Media Type" (before parsing and the handler)
# a body over 1 MiB -> 413 "Content Too Large" (after the 415 check, before parsing)
# application/json; charset=utf-8 -> accepted (parameters are not interpreted)
# malformed JSON, a missing member, a wrong kind -> 400 "Bad Request"
```

- `def create_user(body: CreateUser) -> User`, with no wrapper, is not the JSON form: a `FromJson` type is not a body by itself (`tests/json_api_fail/from_json_alone_is_not_a_body.mojo`: `the handler's parameter is the request body; its type must conform to FromBody or FromBytes`). The alternatives that would make it one were rejected ([JSON codec decision (M3-008)](history/architecture-decisions.md#json-codec-decision-m3-008)). Fields are mapped by hand: Mojo 1.1.0 reflection has no constructor, so a derived `from_json` would need a dummy `Defaultable` initializer in every type.
- `body.value^` does not compile (`field 'body.value...' destroyed out of the middle of a value`); `body^.take()` on a `var body` moves the whole value out (a move-only `T` works). As for any Mojo 1.1.0 struct, moving one field out of that value needs a `deinit` method on the type; otherwise copy the field.
- `Json[T]` requires `T: FromJson` as a body and `T: ToJson` as a result; otherwise the registration fails (`its type must conform to FromBody or FromBytes`; for the result, `no matching method` with the `where` clause's `violated constraint`).
- The RFC 8259 grammar, strictly, with Muntin's limits: comments, trailing commas, leading zeros, `NaN`, duplicate member names, a byte order mark, lone surrogates and nesting deeper than 64 are 400. Extra members are ignored. `int()` takes integer literals that fit `Int`, exactly. `float()` goes through Mojo 1.1.0's `atof`: long literals (`100000000000000000000000`) raise (400), and some values come back 1 ulp off (`-2.7546748226290886e+20`, `123456789012345678`); `String(Float64)` in the writer likewise does not always print text that reads back to the same double. Known toolchain gaps, pinned in `tests/test_json.mojo`; read exact values with `int()`.
- Order on a JSON body route, each step before the next runs: no matching route 404 or 405; a missing, duplicated or invalid query value 400; an invalid path value 400; the `Content-Type` 415; the size 413; a body that is not UTF-8 400; malformed JSON or a `from_json` raise 400; then the handler. Every shape that takes a `FromBody` body takes `Json[T]` (body only or `Int` then body, stateless or stateful, either result policy). Other body types keep their rules: no `Content-Type` required and no Muntin cap.
- A body that is not well-formed UTF-8 is 400 before parsing (section 4), so the codec parses only the bytes the client sent: a U+FFFD the client sent in a string is a character, and a byte that is not UTF-8 is never parsed as one.
- JSON bodies are capped at 1 MiB (fixed; 413 above it, and `Json[T].from_body` raises on a larger body in a raw handler). Parsing is linear apart from a sort of each object's member names (duplicates); member lookup (`get`, `value[name]`) scans the object's members, so reading k fields of an m-member object costs O(k·m). At the cap parsing adds at most about 29 MB of memory (measured: 1 MiB of `[0,0,...]`; 1 MiB of typical records adds about 5 MB). Other body types have no Muntin cap.
- A test reaches a JSON body route through `TestClient` by sending the field (section 10):

  ```mojo
  from muntin import Headers
  from muntin.testing import TestClient

  var client = TestClient(app)
  var headers = Headers()
  headers.add("Content-Type", "application/json")
  _ = client.post("/users", '{"name":"Ada","age":36}', headers=headers^)  # 200, {"id":1,"name":"Ada"}
  _ = client.post("/users", '{"name":"Ada","age":36}')                    # 415: no field sent
  ```

  The client adds no field itself, so `client.post(target, body)` stays 415, and its answer equals `app.handle(Request("POST", target, body, h^))` for a separate `Headers` value `h` with the same fields (`headers` itself is moved into the client's request).

Typed header access on `post`, status: **production**; proven by `tests/test_with_headers.mojo` (which runs this example as written), `tests/with_headers_api_fail/` (via `./scripts/check.sh`) and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`. A `post` handler that needs request header fields takes `WithHeaders[B]` where it would take the body `B`; registration is unchanged:

```mojo
from muntin import App, Json, Response, State, ToErrorResponse, WithHeaders


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(deinit self) -> Response:
        return Response.text("Unauthorized", status=401)


def create_user(
    users: State[Users], input: WithHeaders[Json[CreateUser]]
) raises Unauthorized -> Json[User]:
    var token = input.headers.get("authorization")    # Optional[String]
    if not token or not users[].allows(token.value()):    # a read-only Users method
        raise Unauthorized()                          # ToErrorResponse: 401
    return Json(User(1, input.body.value.name))


def update_note(id: Int, var input: WithHeaders[Note]) -> String:   # Note: an application FromBody
    var traces = input.headers.get_all("x-trace")     # every value, in order
    var note = input^.take_body()                     # the body, moved out
    return String(id, " ", note.text, " traces=", len(traces))


app.post["/users"](create_user, users)                # stateful, body only
app.post["/notes/{id}"](update_note)                  # route value, then body
# POST /users  Content-Type: application/json  Authorization: <allowed token>  {"name":"Ada","age":36}
#   -> 200, {"id":1,"name":"Ada"}
# Authorization missing or not allowed -> 401 "Unauthorized" (the handler's error type)
# Content-Type missing -> 415, before the handler (the JSON rules above, unchanged)
# POST /notes/3  X-Trace: a  x-trace: b  "hi" -> 200 "3 hi traces=2"
```

- `input.headers` is the request's `Headers` (section 9): every field in order, with its casing, repeated names as separate fields and empty values as values; `get` returns the first value matched ASCII case-insensitively, or `None`, and `get_all` every value. Muntin chooses no status for the fields `input.headers` exposes and gives them no meaning: a missing field is `None`, and there is no pre-handler 400 for a field. Two existing checks still answer before the handler: a `Json[T]` body's `Content-Type` verdict (415), and the rebuild of a field an in-memory `Headers` holds invalidly (the fixed 500). The handler answers a missing or malformed field through its error type, because the right status depends on the field (401 for a credential, 412 or 428 for a precondition, 400 for a malformed value).
- `input.body` is converted by `B.from_body` exactly as a bare body, and a raise is 400 before the handler. `WithHeaders[Json[T]]` keeps the JSON steps, in the same order: 404 or 405, query value 400, route value 400, 415, 413, the field rebuild 500 (the `_fields` gap only), a body that is not UTF-8 400, JSON 400, handler. A handler may borrow the carrier (`input: WithHeaders[B]`) or own it (`var input`) and move the body out with `input^.take_body()`; `input.body^` does not compile (`... destroyed out of the middle of a value`, naming the moved field, as `field 'input.body.text'` for a `Note` body).
- Every shape that takes a body takes the carrier as that body: `def(B)`, `def(V, B)` and `def(V, V, B)` with `V` a route value (`Int`, `String` or an `Optional` of either), stateless or with `State` first, either result policy. It adds no overload and no registration spelling. It is not a `get` handler: `get` takes no body, so `app.get[...]` with a carrier handler is `constraint failed: a get handler takes no request body`, and a `get` handler that needs fields takes a `Headers` parameter (section 9). Like any body, it is the last parameter (`def(WithHeaders[B], Int)` is `constraint failed: a post handler takes one request body, as its last parameter`).
- `WithHeaders` is accepted as a body without being a `FromBody`. It has no `from_body`, so a body alone cannot produce one with the fields silently missing, and generic application code bounded by `B: FromBody` does not accept it: an accepted cost. Building one by hand takes an explicit `Headers`: `WithHeaders(body^, headers^)`. Its `B` must be a `FromBody`: `WithHeaders[Int]`, a carrier inside a carrier and `WithHeaders[Json[T]]` without `T: FromJson` are rejected where the handler is declared (`'WithHeaders' parameter 'B' has 'FromBody' type ...`).
- Cost: a carrier route copies each field name and value twice per request and validates each field again, as raw routes do; every other route is unchanged. Through the Flare adapter a field Muntin cannot represent is still 400 before `App.handle` (section 9).

Typed binary bodies, status: **production** (M3-041); proven by `tests/test_bytes_body.mojo` (which registers this example verbatim and checks the answers below), `tests/from_bytes_api_fail/` (via `./scripts/check.sh`) and, over real loopback connections through Flare (HTTP/1.1 with `Content-Length` and chunked, cleartext HTTP/2 in one and two DATA frames), `adapters/flare/test_localhost_roundtrip.mojo`. A body that is not text is an application type conforming to `FromBytes`, which receives the body's bytes, whatever they are; registration is unchanged:

```mojo
from muntin import App, FromBytes


struct Image(FromBytes):
    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        if len(body) < 8 or body[0] != 0x89 or body[1] != 0x50:
            raise Error("not a PNG")  # 400, upload not called
        return Self(body.copy())  # the bytes are borrowed: keep a copy


def upload(image: Image) -> String:  # `var image: Image` also works
    return String(len(image.data), " bytes")


app.post["/upload"](upload)
# POST /upload  89 50 4E 47 0D 0A 1A 0A 00 FF 80 -> 200 "11 bytes"  (from_bytes received the 11 bytes)
# POST /upload  "GIF89a"                         -> 400 "Bad Request"  (from_bytes raised; upload not called)
# GET /upload                                    -> 405 "Method Not Allowed", Allow: POST  (from_bytes not called)
```

- `FromBytes` is a public Muntin trait refining `Deinitable & Movable` with one requirement, `@staticmethod def from_bytes(body: List[UInt8]) raises -> Self`; a non-raising `from_bytes` conforms too. The application type conforms in its own module, as for `FromBody`, and may be move-only.
- `from_bytes` receives `Request.body` itself (the same buffer, `tests/test_bytes_body.mojo` checks its address), borrowed and read-only: the request's bytes exactly as the backend received them, or as middleware replaced them (section 7), with no UTF-8 check, no text conversion and no copy by Muntin. A type that keeps them copies them (`body.copy()`); keeping them without the copy (`cannot be implicitly copied`), changing them (`invalid use of mutating method on rvalue`), or declaring them `var` or as a `String` (`does not implement all requirements for 'FromBytes'`) does not compile.
- Every shape that takes a `FromBody` body takes a `FromBytes` body, with the same order: on `app.post`, `app.put` and `app.patch`, `def(B)`, `def(V, B)` and `def(V, V, B)` with `V` a route value, stateless or with `State` first, either result policy. 404 or 405 first, then each route value (a bad one is 400 and `from_bytes` is not called), then `from_bytes` (a raise is 400 and the handler is not called), then the handler. There is no `Content-Type` rule and no Muntin size cap (Flare's own 10 MiB default still applies over the wire).
- A type conforms to one of `FromBody` and `FromBytes`: one conforming to both is rejected at registration, alone or inside `WithHeaders` (`constraint failed: the request body's type conforms to both FromBody and FromBytes; a body type conforms to one of them`, which for a carrier means the carried type), and is still a body for the other rules (on `app.get`, `a get handler takes no request body`). A `FromBytes` body on `app.get` or `app.delete` is `a get handler takes no request body` (`a delete handler ...`), and before a route value or beside another body `a post handler takes one request body, as its last parameter`. `List[UInt8]` itself is not a body (`its type must conform to FromBody or FromBytes`): the application names its own type.
- Not supported: a `FromBytes` body with the request's header fields. `WithHeaders[B]` takes a `FromBody` (`WithHeaders[Image]` is `'WithHeaders' parameter 'B' has 'FromBody' type, but value has type 'AnyStruct[Image]'`), so a handler that needs both reads `req.body` and `req.headers` as a raw handler (section 9). Text bodies, `Json[T]` and raw handlers answer exactly as before.
- A test sends bytes with `TestClient`'s bytes overloads (section 10): `client.post("/upload", png^)`.

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

Status: **production**; proven by `tests/test_response.mojo`, `tests/storage_fail/{non_conforming_return_handler,raising_to_response}.mojo`, `tests/body_fail/post_non_conforming_return.mojo`, `tests/compile_fail/typed_*.mojo` and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`. An application result type conforms to the public `muntin.ToResponse` in its own module, as body types conform to `FromBody`:

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

- `-> String`, `-> StaticString` and string-literal results are 200 text responses: neither needs a conformance. The result type is generic, and each overload accepts it through `where (R == String or R == StaticString or conforms_to(R, ToResponse))`, which the compiler checks by identity, so other immutable-origin string slices (`StringSlice[ImmutAnyOrigin]`) are rejected.
- The trait requirement is `def to_response(var self) -> Response`: Muntin hands the result over. An implementation may declare `self`, `var self`, or `deinit self` (to move fields out). It does not raise. Raising handlers (section 6) do not need fallible conversion: the conversion only sees a returned value.
- The same rule applies to every argument shape: `def create_user(body: CreateUser) -> User` and `def replace_user(id: Int, body: UpdateUser) -> User` on `app.post` convert the same way.
- `-> Response` uses the same trait: `Response` conforms and returns itself by move, so the handler's status and body reach the client unchanged (`GET /teapot` -> 418). There is no separate `Response` overload.
- The conversion runs once, after the handler returns. A 400 (route value or body failed to convert), 404 or 405 calls neither the handler nor the conversion; a handler that raises (section 6) skips the result conversion.
- A result type that is neither `String`, `StaticString` nor conforming fails at the registration call: `no matching method in call to 'get'`, whose candidate note is `violated constraint` followed by the `where` clause (`... identical(R, StringSpan[ImmStaticOrigin]) ...`). When the call does not let the compiler decide the clause (a local's immutable origin, or a forwarding helper whose generic result is not pinned down by its own `where`), the error is `invalid call to '<method>': lacking evidence to prove correctness` instead.

JSON results: a handler returns `Json[T]` with `T: ToJson` (section 4). The response has exactly one field, `Content-Type: application/json`, and status 200; `String` results and `Response.text` still add no field. `Json(value, status=201)` chooses another status, with the same body and field; `Json(value)` is still 200:

```mojo
def register(var body: Json[CreateUser]) -> Json[User]:
    var c = body^.take()
    return Json(User(2, c.name), status=201)


app.post["/accounts"](register)
# POST /accounts  Content-Type: application/json  {"name":"Bo","age":1}
#   -> 201, Content-Type: application/json, {"id":2,"name":"Bo"}
```

- `status` is keyword-only: `Json(value, 201)` does not compile, and the compiler quotes `def __init__(out self, var value: Self.T, *, status: Int = 200)` under its candidate note (`tests/json_api_fail/positional_status.mojo`). It takes any `Int`; Muntin does not validate it, as it does not validate `Response`'s.
- A body (`body: Json[T]`) has no public status; the status belongs to the result, and the request steps (415, 413, 400) are unchanged.

Another media type is an explicit edit of the converted response:

```mojo
def create() raises -> Response:
    var r = Json(User(7, "Ada"), status=201).to_response()
    r.headers.set("Content-Type", "application/problem+json")   # a set after the conversion wins
    return r^
```

If `write_json` raises (including NaN or infinity, which JSON cannot represent) or leaves the writer unbalanced, the answer is the fixed 500 without a `Content-Type`, whatever status was chosen; the handler's `ToErrorResponse` is not called, because the handler did not fail. An edit after `to_response()` applies to that 500 too: on a failure, the example above sends the 500 with `Content-Type: application/problem+json`, and a status set there (`r.status = 201`) would turn the failure into a success status with the body `Internal Server Error`; choose the status with `status=` instead. Why: [JSON response status decision (M3-028)](history/architecture-decisions.md#json-response-status-decision-m3-028).

## 6. Application errors

Do not freeze a typed-error API until it is validated against the supported Mojo version. Current Mojo's error model and the deprecation of `fn` make idealized typed-error signatures a moving target.

The durable requirement is simpler: domain/application failures must be convertible to HTTP responses centrally without forcing repeated transport-specific error plumbing into every handler.

A future API might resemble an application-level error mapping or result type, but the exact syntax must be derived from executable Mojo code rather than copied from another language.

Status: **production**; proven by `tests/test_error.mojo` and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`. Registration syntax is unchanged:

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

- Every argument shape (`def()`, `def(Int)`, `def(B)`, `def(Int, B)`) and both result policies (`String` or `StaticString` text, `ToResponse`) accept a non-raising handler, `raises`, or `raises T` for an application-defined `T`. Non-raising `def` handlers keep working unchanged. Mojo infers the handler's error type (`Never`, `Error`, or the application's type); compiler notes print a non-raising candidate type as `def(var A) raises Never thin -> String`.
- Exception, a Mojo 1.1.0 limitation: a handler *value* whose type is spelled without `raises` (`var f: def() thin -> String = hello`, or a helper parameter of that type forwarded to `app.get`) does not register: `TODO: function type conversions between closures not supported yet` (`tests/storage_fail/typed_thin_value_handler.mojo`). Spell the type `def() thin raises Never -> String`, or make the helper generic: `def register[E: Deinitable](mut app: App, h: def() thin raises E -> String)`. Such a type also spells each request parameter `var`: `def(var Int) thin raises Never -> String`; `def(Int) thin raises Never -> String` fails with the same `TODO` error (`tests/registration_api_fail/typed_borrowed_int_value.mojo`). A leading `State[S]` keeps its spelling, and `-> StaticString` may be the result type.
- An error type must be `Deinitable`, because Muntin drops it: a linear error type is rejected at registration (`tests/storage_fail/linear_error_type.mojo`).
- Request failures stay 400 and are decided before the handler: an invalid value in a matched path segment, a missing, duplicated or invalid query value, a body that `from_body` rejects. A path no route matches, including a missing path segment, stays 404; a path only routes of other methods match is 405 with `Allow`. Anything the handler raises, unless its declared error type opts in (below), is a fixed 500 with the body `Internal Server Error`, whatever the error says: the same message raised by the handler and by a failing conversion step gives 500 and 400. The error value is dropped; Muntin has no logging hook yet.
- Returning and raising mean different things. A returned value goes through the response conversion; a raised value is a handler error: 500, even if its type conforms to `ToResponse`, unless its declared type conforms to `ToErrorResponse` (below).

Application-defined error responses, status: **production**; proven by `tests/test_error_response.mojo`, `tests/storage_fail/{error_type_is_not_a_result,raising_error_conversion}.mojo` and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`. An error type opts in by declaring the public `muntin.ToErrorResponse`, separate from `ToResponse`; registration does not change:

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
- A type may conform to both traits: returned, it converts with `to_response`; raised, with `to_error_response`. A type conforming only to `ToErrorResponse` cannot be returned (`no matching method`, the `where` clause's `violated constraint`).
- One central place: an application that wants one mapping uses one error type with several kinds (a Mojo function declares one error type), or a trait of its own that refines `ToErrorResponse`.
- The conversion runs once, after the handler raised, and consumes the error (`self`, `var self` or `deinit self`); the result conversion does not run. Move-only types work. It cannot raise: a raising `to_error_response` does not conform (`'NotFound' does not implement all requirements for 'ToErrorResponse'`). 400, 404 and 405 run neither conversion.

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

Status: production, proven by `tests/test_middleware.mojo` (through `TestClient`, `HEAD` through `TestClient.head`; it runs the example below as written), `tests/test_testclient_head.mojo` (`HEAD` through middleware: seen as `HEAD`, a field added, a short circuit, a replaced 404), `tests/middleware_api_fail/` (via `./scripts/check.sh`) and, over real loopback connections through Flare's `Server` (HTTP/1.1 and cleartext HTTP/2), `adapters/flare/test_localhost_roundtrip.mojo`. Middleware is a function (why: [Middleware decision (M3-034)](history/architecture-decisions.md#middleware-decision-m3-034)):

```mojo
from muntin import App, Next, Request, Response


def tracing(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    response.headers.add("X-Trace", "1")
    return response^


def hello() -> String:
    return "hello"


def main() raises:
    var app = App()
    app.use(tracing)
    app.get["/hello"](hello)
# GET /hello    -> 200 "hello"; X-Trace: 1
# GET /missing  -> 404 "Not Found"; X-Trace: 1
# POST /hello   -> 405 "Method Not Allowed"; Allow: GET, HEAD; X-Trace: 1
```

- `app.use(f)` takes a function `def(var request: Request, var next: Next) raises -> Response`; one that borrows the request (`request: Request`) or does not raise converts too. Its type is public as `Middleware`. A middleware may change the request, answer without running the rest (short-circuit), or run the rest with `next^.run(request^)` and change or replace the response that comes back.
- `next^.run(request^)` consumes `next`, so the rest runs at most once per middleware call: a second direct use of `next`, or one inside a loop, does not compile (`use of uninitialized value 'next'`), and `Next` has no plain call (`next(request^)` does not compile) and no copy (`next.copy()` does not compile; `Next` is not `Copyable`). The once rule holds by type for `next` itself: a `Next` moved into a container (`var o = Optional(next^)`) and taken twice runs the rest once and then aborts the process at the second `take()`, an abort, not a 500. A `Next` cannot outlive the call that received it (a middleware written for a `Next` of a fixed origin does not register), and no public spelling constructs one. Code that names `_`-prefixed members, or applies the standard library's unsafe pointer operations (`unsafe_*`, `UnsafePointer`) or an origin rebind (`rebind_var`) to a `Next`, is outside these guarantees.
- Scope and order: every request `App.handle` receives, 404, 405, the route values' 400, a handler's 500 and `HEAD` included, in registration order, outermost first, whether `use` comes before or after the routes: two middleware `a` then `b` see the request as `a`, `b` and the response as `b`, `a`. `HEAD` arrives as `HEAD`, and the backend drops the content of whatever response comes out and declares its length by the `HEAD` rule, so a middleware must answer `HEAD` with the body it would give the `GET` (as a raw `get` handler must, "`HEAD`" in "Proven vs. target status"); Muntin cannot check this. Requests a backend refuses before `App.handle` (Flare's own 400s and its 413 over `max_body_size`, and the adapter's 400s for a request method, target or field it cannot represent) never reach middleware; for a method or target that is not UTF-8 this is tested (`adapters/flare/test_muntin_flare.mojo`, `adapters/flare/test_localhost_roundtrip.mojo`), and otherwise it describes where `App.handle` sits. A body is never refused before `App.handle` (M3-040): middleware receives every body's bytes, ones that are not UTF-8 included, so a middleware that reads `request.text()` must handle its raise (tested in the same files and `tests/test_binary_body.mojo`).
- Muntin's answers: middleware that does not touch a response passes it through unchanged, fields included. A middleware may replace or change any answer, Muntin's 404 and 405 included; on a 405 it builds or changes, `Allow` is the application's responsibility.
- Errors: a raise out of a middleware is the fixed 500 `Internal Server Error` at that middleware's call, with no error text; the middleware outside it receives that 500 from its `next` as an ordinary response and continues. A raise before `next^.run` leaves the rest, the handler included, uncalled. Middleware has no error type of its own.
- Configuration is compile-time only, through the function's own parameters (`app.use(tagged["v1"])` for `def tagged[value: StaticString](var request: Request, var next: Next) raises -> Response`). A closure that captures a runtime value does not convert (`cannot be converted from ... to 'Middleware'`), nor does a function without `next` or a plain value. Not supported: runtime-configured middleware (the `Tracing()` values above, or a value read at start-up), request-scoped typed context, per-route or per-group middleware, middleware error types, async.
- An identity is not passed in header fields: middleware can allow or deny a request, but request header fields are client input (a client can send the same name itself), so a field middleware writes for a handler to trust is not a way to hand it an authenticated identity, and an application must not use one as such.
- Cost: an `App` with no middleware dispatches as before, plus a length check. With middleware, `App.handle` copies the borrowed request once per request (method, path, query, header fields and body), and each middleware is one call and one `Next`. Over Flare the body in that copy is bounded by Flare's `max_body_size` (10 MiB by default); `TestClient` and other in-memory callers have no such bound. Each middleware also adds one level of nested calls (`App.handle` to the middleware, to `next^.run`, to the next one), so the stack grows with the number registered. Neither the copy nor the stack is measured.

## 8. Application state

Long-lived state should have explicit ownership and predictable lifetime behavior.

Production on `get`, `post` and raw handlers, proven by `tests/test_state.mojo` (this example included), `tests/test_state_post.mojo` (the `post` example below), `tests/test_state_raw.mojo` (the raw example below), `tests/state_get_fail`, `tests/state_post_fail`, `tests/state_raw_fail`, `tests/compile_fail/state_*.mojo`, `tests/compile_fail/post_*state_as_body.mojo` and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`:

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

- **Which parameter is injected:** a handler takes application state exactly when its registration passes a second argument, a `State[S]`. Its first parameter is then `State[S]` (the same `S`), and the rest is one of the stateless shapes, bound as before: route values in the literal's order, then the body. So `def(State[Users], Int, CreateUser)` on `post` is state, route value, body. The state is never a route value or a body, and parameter names are never read.
- **Ownership:** `State(value)` takes the value. `State` is a shared handle: the application keeps its own, each registration keeps a copy, and the value is destroyed when the last handle goes. A request borrows the route's handle, so it copies nothing and allocates nothing. `users[]` is read-only through every handle (the handle's internal pointer is reachable by name, since Mojo 1.1.0 has no private fields; it is not API). A value that must change while the application serves keeps that mutability in its own fields, and its rules are the application's. A reference from `users[]` lives no longer than the handle it came from: using it after `users` is reassigned or moved is a compile error (`use of invalidated interior reference`).
- **Several values:** one `State` per handler. Several values are the fields of one state type, and different routes may take different state types (`State[Users]` on some routes, `State[Config]` on others).
- **Unchanged:** every stateless handler and registration, `App()`, `App.handle(Request) -> Response`, `TestClient(app)` and the backends. There are no globals and no hidden lookup: the state reaches the handler only through the registration that passed it.

State goes first so the body stays the last parameter. Access is `state[]` because a struct cannot forward field access to the value it holds.

On `get`, `app.get[route](handler, state)` takes `def(State[S])`, `def(State[S], V)`, `def(State[S], Headers)`, `def(State[S], V, Headers)`, `def(State[S], V, V)` or `def(State[S], V, V, Headers)` with `V` a route value (`Int`, `String` or an `Optional` of either) (section 9), each non-raising or raising (`raises`, `raises T`, section 6) and returning `String` (or `String`-compatible) or `R: ToResponse` (section 5). Request handling is the stateless twin's: the same route checks and messages, each route value from a `{name}` segment or a `{key}` query item, decoded, 400 before the handler for an invalid or duplicated value or a missing or empty required one (an optional one is `None`: "Optional query values" in "Proven vs. target status"), `ToErrorResponse` or the fixed 500 for a raise, 404 or 405 without a match, and the first registration wins.

- Compile-time errors at `app.get`: a state of another type (`value passed to 'state' cannot be converted from 'State[Cache]' to 'State[Db]'`), the value instead of a handle (`cannot be converted from 'Db' to 'State[Db]'`), a stateful handler without its state (`constraint failed: State is injected application state; a stateful get handler takes State first, and the state is the registration's second argument`), a state for a stateless handler, the state after the route value or `var db: State[Db]` (each `no matching method`, with notes such as `cannot be converted from '<handler type>' to 'def(State[S]) raises Never thin -> String'` or `'def(State[S], var A) ...'`), mutation through `db[]` (`expression must be mutable ...`), using a `ref r = db[]` after `db` is reassigned (`use of invalidated interior reference`), a second handle replacing or mutating the value (`'_Shared[Db]' is not subscriptable`, `invalid use of mutating method`), and a placeholder count that does not fit the shape (the stateless twin's `constraint failed: ...`; the state is not a route value).
- Each registration copies the handle once, so the reference count rises by one per route and falls when the `App` is dropped. A request changes it by nothing. Moving the `App` moves the routes' handles, and the value is destroyed once, after the last handle. `TestClient(app)` serves a stateful `App` repeatedly, also after `var moved = app^` (a new client on `moved`).

On `post`, `app.post[route](handler, state)` takes `def(State[S], B)`, `def(State[S], V, B)` or `def(State[S], V, V, B)` with `V` a route value (`Int`, `String` or an `Optional` of either) and `B: FromBody` (or a `WithHeaders[B]` carrier, section 4), each non-raising or raising and returning `String` (or `String`-compatible) or `R: ToResponse`. The state comes first, the route values (if any) next, the body last:

```mojo
def update_user(users: State[Users], id: Int, body: CreateUser) raises NotFound -> User:
    return User(id, users[].get(id) + " as " + body.name)


app.post["/users/{id}"](update_user, users)  # state, route value, body
# POST /users/1 "name=bo" -> update_user(users, 1, CreateUser("bo")) -> User(1, "bob as bo")
# POST /users/9 "name=bo" -> NotFound(9).to_error_response()
# POST /users/x "name=bo" -> 400 "Bad Request"   (from_body and update_user not called)
```

Request handling is the stateless twin's (section 4): the route value is converted first (400 without calling `from_body`), then the body (`from_body` raising is 400 without calling the handler), then the handler runs once and its result is converted once; `ToErrorResponse` or the fixed 500 for a raise, 404 or 405 without a match, and the first registration wins. Registration copies the handle once and a request borrows it, as for `get`. Request headers take no part unless the body is a `WithHeaders[B]` carrier (section 4), which composes with the state unchanged.

- Compile-time errors at `app.post` with a state: the stateless twin's placeholder-count, malformed-route, `Int`-as-body and `FromBody` messages (`constraint failed: ...`; the state is not a route value); a second `State` as the body (`constraint failed: a handler takes at most one State, as its first parameter`); a `def(State[S])` handler without a body (`constraint failed: a post handler takes the request body as its last parameter`); a state of another type, the value instead of a handle, a stateless handler given a state, the state after the body or the route value, `var db: State[Db]` or `mut db: State[Db]`, and a plain `db: Db` parameter (`no matching method in call to 'post'`, with notes such as `cannot be converted from '<handler type>' to 'def(State[S], var A) raises Never thin -> String'` or `'def(State[S], var A, var B) ...'`).
- Without a state, `app.post[...](h)`: a handler such as `def(State[Db], B)`, `def(State[Db])`, `def(Int, State[Db])` (on a route with one placeholder) or `def(State[Db], Int, B)` is `constraint failed: State is injected application state, not the request body; a stateful post handler takes State first and the body last, and the state is the registration's second argument`.

Raw handlers: `app.get[route](handler, state)` and `app.post[route](handler, state)` take `def(State[S], req: Request) -> Response` (`var req: Request` also works), the raw shape of section 9 with the state first. The handler reads the state and the whole request in the same call:

```mojo
@fieldwise_init
struct WebhookKeys(Movable):
    var secret: String


def webhook(keys: State[WebhookKeys], req: Request) raises -> Response:
    var signature = req.headers.get("x-signature")
    if not signature or signature.value() != keys[].secret:
        return Response.text("unsigned", status=401)
    var resp = Response.text("ok")
    resp.headers.add("X-Request-Id", "42")
    return resp^


var keys = State(WebhookKeys("sha256=valid"))
app.post["/webhook"](webhook, keys)          # app.get too
# POST /webhook  X-Signature: sha256=valid  -> 200 "ok", X-Request-Id: 42
# POST /webhook  (no X-Signature)           -> 401 "unsigned"
```

Request handling is the raw twin's (section 9): the route literal declares no path or query parameter, the handler receives the method, path, query, body and header fields as the backend built them, Muntin runs no typed extraction and answers no 400 after the match, and the `Response` (status, body and fields) is the answer, unconverted. A raise is `ToErrorResponse` or the fixed 500; 404 or 405 without a match; the first registration wins across raw, stateful raw and typed routes. Registration copies the handle once and a request borrows it, as for `get`.

- Compile-time errors with a state: the raw twin's placeholder and malformed-route messages (`constraint failed: ...`); a state of another type or the value instead of a handle (`no matching method`, with the note `value passed to 'state' cannot be converted from 'State[Cache]' to 'State[Db]'` or `from 'Db' to 'State[Db]'`); a stateless raw handler given a state, a plain `db: Db` parameter, the state after the `Request`, `var db: State[Db]` or `mut db: State[Db]` (`no matching method`, with the note `cannot be converted from '<handler type>' to 'def(State[S], var A) raises Never thin -> Response'`). On `get`, an extra parameter, a non-`Response` result or an `Int` before the `Request` is `constraint failed: a stateful raw get handler takes State first, then only the Request, and returns Response`. On `post`, an extra parameter is `constraint failed: a stateful raw post handler takes State first, then only the Request, and returns Response`, and a non-`Response` result or an `Int` before the `Request` keeps `constraint failed: Request is the whole request, not a body; a stateful raw handler takes State first, then only the Request, and returns Response`.
- Without a state, a stateful raw handler reports the `State` rule: on `get`, `constraint failed: State is injected application state; a stateful get handler takes State first, and the state is the registration's second argument`; on `post`, the `post` text above.
- An explicitly typed function value must be spelled `def(State[S], var Request) thin raises Never -> Response` on Mojo 1.1.0; `def(State[S], Request) thin raises Never -> Response` or a type without `raises` fails with `TODO: function type conversions between closures not supported yet`, as in section 9.

## 9. Raw Request/Response escape hatch

Raw request handling is first-class, proven by `tests/test_raw.mojo` (which registers this handler, verbatim, and checks the responses below), the raw fixtures in `tests/compile_fail`, `tests/storage_fail` and `tests/body_fail` (via `./scripts/check.sh`) and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`:

```mojo
from muntin import App, Request, Response


def webhook(req: Request) -> Response:       # `var req: Request` also works
    if Span(req.body) != "signed".as_bytes():  # application code decides
        return Response.text("unsigned", status=401)
    return Response.text("ok")


app.post["/webhook"](webhook)                # same syntax as typed handlers; app.get too
# POST /webhook          "signed"  -> 200 "ok"
# POST /webhook?id=abc   "forged"  -> 401 "unsigned"   (no 400 from Muntin: nothing is extracted)
# GET /webhook                    -> 405 "Method Not Allowed", Allow: POST  (webhook not called)
# POST /webhook/x                 -> 404 "Not Found"  (webhook not called)
```

The escape hatch is meant for webhooks, streaming, custom content types, unusual authentication, protocol integrations, and performance-sensitive endpoints. Header-based authentication and custom content types use headers (below); streaming still needs a `Request`/`Response` capability that does not exist yet.

Headers, proven by `tests/test_headers.mojo` (which registers this handler as `dx_webhook` and checks the responses below), `tests/headers_api_fail`, `adapters/flare/test_muntin_flare.mojo` and, over real loopback connections through Flare (HTTP/1.1 and cleartext HTTP/2), `adapters/flare/test_localhost_roundtrip.mojo`:

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
- Raw handlers read `req.headers` (a `var req` handler owns a copy it may change) and set fields on the `Response` they return. Typed `post`, `put` and `patch` handlers read them through a `WithHeaders[B]` body (section 4), typed `get` and `delete` handlers through a `Headers` parameter (below). A typed result sets fields through the `Response` its `to_response` builds. `String` results set none.
- `TestClient.get`, `.head`, `.post`, `.put`, `.patch` and `.delete` send the fields passed as `headers=` and none otherwise (section 10); a test may also build `Request(..., headers^)` and call `app.handle`, the same seam.
- Through Flare, a request field Muntin cannot represent is answered 400 before the handler: over HTTP/2 Flare admits a name that is not a token (`x-user/admin`), a control byte in a value and a value that is not UTF-8. Fields the backend owns or that are connection-specific (`Content-Length`, `Transfer-Encoding`, `Connection`, `Keep-Alive`, `Proxy-Connection`, `Upgrade`, `TE`, `Trailer`), and any field a `Connection` value names, are not written to the wire; they stay in the in-memory `Response`. Over HTTP/2, names go out lowercase. Header values are text: Flare answers 400 to an HTTP/1.1 header byte ≥ 0x80 itself.

Semantics:

- Same registration syntax on `app.get`, `app.post`, `app.put`, `app.patch` and `app.delete`: `Request` is a kind of request parameter, so a raw handler registers through the one-parameter overload like any one-parameter handler, and the raw rule requires `Response` as the result.
- The handler may declare `req: Request` (canonical) or `var req: Request` (it owns a fresh copy of the request and can move `req.body` out). It returns `Response` only.
- It may be non-raising, `raises` or `raises T`, under the error model of section 6: a `T` declaring `ToErrorResponse` answers its own response, anything else is the fixed 500 without the error text.
- The route is selected by method and path as usual (405 with `Allow` when only routes of other methods match the path, 404 otherwise, without calling the handler; first registration wins across raw and typed routes, and a typed route's 400 does not fall through to a later one). The route literal declares no path or query parameter (`def()`'s rule and messages: `route declares a path parameter but the handler takes none`, `... query parameter ...`, `malformed route literal`).
- The handler reads `req.method`, `req.path`, `req.query` and `req.body` exactly as the backend built them (the query undecoded, an empty body included). `req.body` is the body's bytes, whatever they are (below); a method or target that is not UTF-8 never reaches a raw handler (the target bullet of "Proven vs. target status"). A raw `get` handler also answers `HEAD`, with `req.method == "HEAD"`, and returns the body it would return for `GET` ("`HEAD`" in "Proven vs. target status"). Muntin runs no typed extraction on a raw route, so it generates no 400 before the handler; the handler's `Response` (or its error's `to_error_response()`) may use any status, 400 included.
- A raw-shaped handler that breaks the raw rule on `post` (`def(req: Request) -> String` or `-> User`, `def(id: Int, req: Request)`) reports `constraint failed: Request is the whole request, not a body; a raw handler takes only the Request and returns Response` instead of the `FromBody` message, and one with an extra parameter after the `Request` `constraint failed: a raw post handler takes only the Request and returns Response`. On `get` each is `constraint failed: a raw get handler takes only the Request and returns Response`.
- An explicitly typed function value must be spelled `def(var Request) thin raises Never -> Response` on Mojo 1.1.0; `def(Request) thin raises Never -> Response` or a type without `raises` fails with `TODO: function type conversions between closures not supported yet` (as for typed values, section 6).

Binary bodies, status: **production** (M3-040); proven by `tests/test_binary_body.mojo` (which registers these handlers, verbatim, and checks the answers below), `tests/body_bytes_api_fail` (via `./scripts/check.sh`: a `List[UInt8]` typed body, text assigned to `Request.body`, `response.text()` in non-raising code and the bytes passed to `from_body` do not compile), `adapters/flare/test_muntin_flare.mojo` and, over real loopback connections through Flare (HTTP/1.1 with `Content-Length` and chunked, cleartext HTTP/2 in one and two DATA frames), `adapters/flare/test_localhost_roundtrip.mojo`. A raw handler receives any request body and returns any response body, byte for byte:

```mojo
from muntin import App, Request, Response
from muntin.testing import TestClient


def upload(req: Request) raises -> Response:
    # Any bytes, as received, sent back byte for byte; Muntin adds no
    # Content-Type, so the handler sets its own.
    var r = Response(200, req.body.copy())
    r.headers.add("Content-Type", "application/octet-stream")
    return r^


def note(req: Request) raises -> Response:
    # `text()` raises if the body is not UTF-8.
    return Response.text("note: " + req.text())


var app = App()
app.post["/upload"](upload)
app.post["/note"](note)
var png: List[UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
var r = TestClient(app).post("/upload", png^)
# POST /upload  89 50 4E 47 0D 0A 1A 0A -> 200, the same 8 bytes, Content-Type: application/octet-stream
# POST /note    "hé"                    -> 200 "note: hé"
# POST /note    FF                      -> 500 "Internal Server Error"  (note's raise; it may catch it and answer 400)
```

- `Request.body` and `Response.body` are `List[UInt8]`, the one representation of a body: no step replaces, drops or adds a byte, and nothing converts it to text unless code asks. `Response(status, bytes^)` and `Request(method, target, bytes^, headers^)` take bytes by move; `Response(status, text)`, `Response.text(text)` and `Request(method, target, text)` store the text's UTF-8 bytes, as before. Muntin adds, guesses or rewrites no `Content-Type`; a handler sets one if it wants one.
- `req.text()` and `response.text()` return a copy of the bytes as text when they are well-formed UTF-8 and raise otherwise (a U+FFFD the client sent is a character; nothing is replaced). In a raw handler the raise is a handler error, so the fixed 500 unless the error type converts; a handler that must answer 400 catches it, or compares bytes without reading text (`Span(req.body) == "signed".as_bytes()`, as `webhook` above).
- Middleware sees the request's bytes and may replace them (`request.body = new_bytes^`); the routes receive exactly what it passes on.
- Through Flare the bytes go out as given; for `HEAD` the adapter sends no content and declares their byte count as `Content-Length` ("`HEAD`" in "Proven vs. target status").
- A typed handler takes binary bodies too, as a `FromBytes` type (section 4, "Typed binary bodies"); a raw handler is for what typed shapes do not cover (the header fields beside a binary body, any status before a conversion). Not supported: streaming and multipart bodies.
- Migration from text bodies (M3-040): a text read of `req.body` is `req.text()` in a raising handler (catch its raise to answer 400: over Flare M3-038's adapter answered a body that is not UTF-8 400 before the handler, and an uncaught raise is now the fixed 500); `response.body` compared with text is `response.text()`; `request.body = "x"` is `request.body = List("x".as_bytes())`; `response.text()` now raises.

Typed header access on `get`, status: **production**; proven by `tests/test_get_headers.mojo` (which runs this example as written), `tests/get_headers_api_fail/` (via `./scripts/check.sh`) and, over a real loopback connection through Flare, `adapters/flare/test_localhost_roundtrip.mojo`. A `get` handler that needs request header fields takes `Headers` as its last parameter; registration is unchanged:

```mojo
from muntin import App, Headers, Response, State, ToErrorResponse


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(deinit self) -> Response:
        return Response.text("Unauthorized", status=401)


def me(headers: Headers) raises Unauthorized -> String:
    var token = headers.get("authorization")  # Optional[String]
    if not token:
        raise Unauthorized()  # ToErrorResponse: 401
    return "me " + token.value()


def note(id: Int, headers: Headers) -> String:  # route value, then the fields
    var traces = headers.get_all("x-trace")  # every value, in order
    return String(id, " traces=", len(traces))


def private_note(
    users: State[Users], id: Int, headers: Headers
) raises Unauthorized -> String:  # State first, as always
    var token = headers.get("authorization")
    if not token or not users[].allows(token.value()):    # a read-only Users method
        raise Unauthorized()
    return String("private ", id)


app.get["/me"](me)
app.get["/notes/{id}"](note)
app.get["/private/{id}"](private_note, users)
# GET /me  Authorization: t1             -> 200 "me t1"
# GET /me  (no Authorization)            -> 401 "Unauthorized" (the handler's error type)
# GET /notes/3  X-Trace: a  x-trace: b   -> 200 "3 traces=2"
# GET /notes/x                           -> 400 "Bad Request"  (note not called)
# GET /private/3  Authorization: <allowed token> -> 200 "private 3"; otherwise 401
```

- `headers` holds the request's fields with the semantics above: every field in order, with its casing, repeated names as separate fields and empty values as values. It is a fresh value rebuilt for the handler, which may borrow it (`headers: Headers`) or own it (`var headers: Headers`); changing an owned one changes no `Request`. `mut headers: Headers` matches no overload. Muntin chooses no status for a field and gives it no meaning: a missing field is `None`, and the handler answers it through its error type, as with `input.headers` (section 4).
- Shapes: `def(Headers)` on a route with no placeholder, `def(Int, Headers)` or `def(String, Headers)` on a route with exactly one, and `def(V, V, Headers)` on a route with exactly two ("Two route values" in "Proven vs. target status"), each also with `State[S]` first (section 8), either result policy, non-raising or raising. `Headers` is the last parameter, once: `def(Headers, Int)` and two `Headers` are `constraint failed: a get handler takes one Headers, as its last parameter`. The other rules keep their messages: a body beside it is `a get handler takes no request body`, a `Request` beside it `a raw get handler takes only the Request and returns Response`, and a placeholder count that does not fit is the `def()`, `def(Int)`, `def(String)` or two-value message (`route declares a path parameter but the handler takes none`, `handler takes one Int parameter; route must declare exactly one path or query parameter`, `handler takes one String parameter; ...`, `handler takes two route values; ...`).
- Order: 404 or 405; query value 400; route value 400 (each value in order); the field rebuild, whose only failure is a field an in-memory `Headers` holds invalidly (the fixed 500); then the handler. There is no new 400, 413 or 415.
- `post` takes no `Headers` parameter: its last position is the body, so a `post` handler reads fields through `WithHeaders[B]` (section 4). The same holds for `put` and `patch`, and `delete` takes `Headers` as `get` does ("PUT, PATCH and DELETE" in "Proven vs. target status"). `Headers` shapes on `post` keep the messages they had: `def(Headers)` is `the handler's parameter is the request body; its type must conform to FromBody or FromBytes`, `def(Headers, B)` is `a post handler's parameter before the body is a route value: an Int, a String or an Optional of either`, `def(B, Headers)` is `a post handler takes one request body, as its last parameter`, and `def(Int, Headers)` is `the handler's last parameter is the request body; its type must conform to FromBody or FromBytes`.
- An explicitly typed function value spells the parameter `var Headers` (`def(var Headers) thin raises Never -> String`); `def(Headers) thin raises Never -> String` fails with `TODO: function type conversions between closures not supported yet`, as for `Int` (section 6). A generic helper (`h: def(var A) thin raises Never -> String`, `def(var A, var B)`, `def(State[S], var A)`) forwards a `Headers` handler to `app.get` and registers as the plain handler would.
- Cost: a `Headers` route copies each field name and value twice per request and validates each field again, as carrier and raw routes do; every other route is unchanged.

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

Status: proven on Mojo 1.1.0 with `from muntin.testing import TestClient`; `TestClient.get(target)`, `TestClient.head(target)`, `TestClient.post(target, body)`, `TestClient.put(target, body)`, `TestClient.patch(target, body)` and `TestClient.delete(target)` build a Muntin `Request` and call `App.handle` (`body` is text, or bytes as a `List[UInt8]` passed by move, M3-040: `client.post("/upload", png^)`), the same entry point network adapters use (`head` and `delete` with an empty body; a test that sends a `HEAD` or `DELETE` body builds the `Request` and calls `app.handle`). Each takes the request's header fields as a keyword-only, defaulted argument, moved into the `Request` as `Request`'s initializer takes them (proven by `tests/test_testclient_headers.mojo`, `tests/test_methods.mojo`, `tests/test_testclient_head.mojo`, `tests/testclient_headers_api_fail/` and `tests/methods_api_fail/`, via `./scripts/check.sh`):

```mojo
var headers = Headers()
headers.add("X-Request-Id", "42")
_ = client.get("/echo", headers=headers.copy())    # headers stays usable
_ = client.post("/echo", "body", headers=headers^)  # moved
_ = client.get("/echo")                             # no fields
```

- The client builds `Request(method, target, body, headers^)` and nothing else: it adds, removes, inspects or merges no field, so its answer equals `app.handle(Request(...))` built from the same method, target and body and a `Headers` value with the same fields. Fields keep their order, casing and repeats, and an empty value is sent as a value.
- `headers=` is keyword-only: a positional `Headers` after the target or the body is `invalid call to 'get'` (or `'head'`, `'delete'`): `unexpected argument`; on `post`, `put` and `patch`, which have a text and a bytes overload, it is `no matching method in call to 'post'` (or `'put'`, `'patch'`) with `candidate not viable: unexpected argument` for each. A plain variable is `cannot be implicitly copied` (pass `headers^` or `headers.copy()`), and using it after `^` is `use of uninitialized value`. Each call without `headers=` sends none; the client keeps no per-client fields.
- Building `Headers` raises (`add` validates), so a test that sends fields runs in a raising context.
- `TestClient.head(target)` sends `HEAD`: a raw `get` handler sees `req.method == "HEAD"`, middleware `request.method == "HEAD"`. It returns `App.handle`'s answer unchanged, as every method does: the status, every field and the body, which is the `GET`'s when the route and every middleware answer `HEAD` as `GET`, and otherwise whatever they returned. It applies no wire rule: it removes no body and declares no `Content-Length`, for 204, 205 and 304 too, and keeps a `Content-Length` a handler set. On the wire a network backend sends the status and fields without content and declares the length itself ("`HEAD`" in "Proven vs. target status"); a test of that goes through the backend (`adapters/flare`). Why: [TestClient HEAD decision (M3-036)](history/architecture-decisions.md#testclient-head-decision-m3-036).

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

Status: target. `FromBody` and `ToResponse` leave the body format to the application, and `FromJson`/`ToJson` map fields by hand, so there is no type-level schema source until a derived codec exists.

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

Status: a handler whose parameter count its registration method (`get`, `post`, `put`, `patch` or `delete`) accepts but whose shape breaks a registration rule gets that rule as `constraint failed: <rule>` (under `function instantiation failed` at the enclosing function, with the registration call in the next note) instead of up to ten candidate notes (section 3, "Registration rules"). A call no overload takes (a wrong number of parameters, a misdeclared `State`, an unaccepted result type) still gets the compiler's candidate notes. Names are not compared: the route literal and the handler bind by position.

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
from muntin_flare import Server


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


def main() raises:
    var app = App()
    app.get["/users"](list_users)
    app.get["/users/{id}"](get_user)
    app.post["/users"](create_user)
    var server = Server.bind("127.0.0.1", 8080)
    server.serve(app)
```

The spellings of what this example still lacks (below) are provisional; the shipped ones it uses, such as `App`, `app.get`, `app.post` and `Server.bind`/`serve`, are the current API (section 1). The durable properties are a small application surface, typed handlers, typed extraction, automatic conversion where safe, useful compile-time validation, low-level escape hatches, and backend independence.

Status: the handler model of this example is production: `get_user(id: Int) -> User` with `app.get["/users/{id}"]` and `create_user(body: CreateUser) -> User` with `app.post["/users"]`, through `TestClient` and the Flare adapter. What still differs from the example:

- JSON needs the wrapper (section 4): `def create_user(body: Json[CreateUser]) -> Json[User]`, with `CreateUser: FromJson` and `User: ToJson` mapping their fields by hand. The bare `body: CreateUser` form needs `CreateUser` to conform to `FromBody` and parse its own body; a JSON-capable type is not a body by itself, and there is no derived codec;
- the stdlib `List[User]` conforms to neither `ToResponse` nor `ToJson`, and top-level list results are not supported, so a list result needs an application type that conforms;
- `users` is not a global: on Mojo 1.1.0 module-level variables do not compile (`global variables are not supported`) and handlers cannot capture. A handler reaches it as `State` (section 8): `def get_user(users: State[Users], id: Int) -> User` registered as `app.get["/users/{id}"](get_user, users)`, and on `post`: `def create_user(users: State[Users], body: CreateUser) -> User` registered as `app.post["/users"](create_user, users)`;
- `Server` is the Flare adapter module's (`muntin_flare`, section 1), with section 1's serving limits.

Derived codecs and list results are remaining candidates (`docs/SPEC.md`); serving is section 1's. The closest runnable form today is section 4's JSON example (`Json[CreateUser]` in, `Json[User]` out) with section 8's `State`: JSON request bodies through `TestClient.post(target, body, headers=headers^)` or `App.handle` with the `Content-Type` field set (without it, 415), JSON results through either. A handler that also needs a request field, such as a credential, takes `WithHeaders[Json[CreateUser]]` (section 4).

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
