# Muntin guide

How to write a Muntin application today, on Mojo 1.1.0 (8189361e). Each section shows the common case and links to the [reference](#reference) for every rule, status and error message. Setup is in the [README](../README.md#try-it).

The examples build on each other: `User` and `CreateUser` come from "Request bodies", `NotFound` from "Results and errors", `Unauthorized` from "Header fields", `Users` and `show_user` from "Application state". `tests/test_guide.mojo` registers every example as written (each example is that file's text, which `scripts/check_doc_examples.py` compares), each on its own `App` with only the routes its comments rely on, and checks those answers; the serving example is `examples/hello_server.mojo`, which CI builds.

Muntin is pre-alpha: the API still changes, and the Flare adapter's `Server` is not production-ready. Read [Before you deploy](#before-you-deploy) first.

## A first application

<!-- example: tests/test_guide.mojo#first-application first_application=main -->
```mojo
from muntin import App
from muntin.testing import TestClient


def get_user(id: Int) -> String:
    return "user " + String(id)


def make_app() -> App:
    var app = App()
    app.get["/users/{id}"](get_user)
    return app^


def main() raises:
    var app = make_app()
    var client = TestClient(app)        # in memory, no socket
    print(client.get("/users/42").text())   # user 42
```

- `app.get["/users/{id}"](get_user)` registers a handler for a compile-time route literal. A route whose placeholders do not fit the handler does not compile: `app.get["/users/{id}"](hello)` with `def hello() -> String` fails with `route declares a path parameter but the handler takes none`.
- `GET /users/42` calls `get_user(42)`; `GET /users/abc` is 400 and `get_user` is never called; `GET /users` is 404.
- The same `App` is served over HTTP by the Flare adapter (below) without changing the handler.

## Routes and route values

Handlers take route values by position: path placeholders left to right, then query placeholders.

<!-- example: tests/test_guide.mojo#routes -->
```mojo
def list_items(limit: Optional[Int]) -> String:
    return "items " + String(limit.or_else(20))


def search(q: String, sort: Optional[String]) -> String:
    return "results for " + q + " by " + sort.or_else("relevance")


app.get["/items?{limit}"](list_items)
app.get["/search?{q}&{sort}"](search)
# GET /items                   -> 200 "items 20"
# GET /search?q=mojo           -> 200 "results for mojo by relevance"
# GET /search?sort=date        -> 400 "Bad Request"  (q is required)
```

- A route value is an `Int`, a `String`, an `Optional` of either (query only; `None` when missing or empty), or an application type conforming to `FromRouteValue`. Every route value is percent-decoded once before it is converted.
- A handler takes up to two bare values. **Two bare values of one type declared in the wrong order compile and receive each other's values**; declare them as `Param["uid", Int]` to have the names checked at compile time. Three or more values are one `RouteValues` record, whose field names are checked.
- Overlapping routes of one method must be registered most specific first (`/users/me` before `/users/{id}`). Registration aborts otherwise, and also for a repeated path or two overlapping routes where neither is more specific, in any order.
- `app.post`, `app.put`, `app.patch` and `app.delete` register the other methods; a `get` route also answers `HEAD`; a path that only other methods match is 405 with `Allow`.

Reference: [routing](reference/routing.md), [route values](reference/route-values.md).

## Request bodies

A `post`, `put` or `patch` handler takes one body, last. For JSON, wrap an application type in `Json[T]`:

<!-- example: tests/test_guide.mojo#request-bodies -->
```mojo
from muntin import App, Json, JsonFields


@fieldwise_init
struct CreateUser(JsonFields):     # a JSON object, one member per field, named after it
    var name: String
    var age: Int
    var nickname: Optional[String]  # may be absent or null; the other members are required


@fieldwise_init
struct User(JsonFields):
    var id: Int
    var name: String


def create_user(body: Json[CreateUser]) -> Json[User]:    # borrow and read body.value
    return Json(User(1, body.value.name))


app.post["/users"](create_user)
# POST /users  Content-Type: application/json  {"name":"Ada","age":36}
#   -> 200, Content-Type: application/json, {"id":1,"name":"Ada"}
# Content-Type missing -> 415; a body over 1 MiB -> 413
# malformed JSON, a missing member, a wrong kind -> 400 (create_user not called)
```

- A `JsonFields` struct's codec is derived from its fields: `Int`, `Float64`, `Bool`, `String`, another `JsonFields` struct, or a `List` or `Optional` of one (and a hand-written `FromJson` or `ToJson` type); a field the codec cannot read or write is refused at the registration, naming it. `Json[List[User]]` is a body or result too. **Muntin builds the struct without running its initializers**, so it is for a DTO that any combination of field values leaves valid; build a type with an invariant from the checked DTO with its own constructor, or read it with a hand-written `from_json`. For another representation, write `FromJson` and `ToJson` by hand ([bodies](reference/bodies.md#json-jsont)).
- Other bodies: a `FromBody` type parses text itself; a `FromBytes` type receives the bytes. **Every body has a size limit**, and a longer one is 413: a type's `comptime max_bytes` (1 MiB when a `FromBody` type declares none, required on a `FromBytes` type unless a refining trait gives a default) or `Json[T, limit=n]` (1 MiB by default) ([body size limits](reference/body-limits.md)).
- A handler that also needs header fields takes `WithHeaders[B]` instead of `B`. **Muntin gives header fields no meaning**: a missing field is `None`, and the handler decides the status. Only a `Json[T]` body's `Content-Type` (415) is checked before the handler.
- A handler with only route values, and at most one `Headers` last, on `post`, `put` or `patch` is bodyless: the body is not read.

Reference: [bodies](reference/bodies.md).

## Results and errors

A handler returns `String` or `StaticString` (a 200 text response with no fields), `Json[T]`, or any type conforming to `ToResponse`, `Response` included. `Json(value, status=201)` chooses another status.

**Anything a handler raises is a fixed 500 `Internal Server Error`, and the error's text is never sent**, unless the handler's declared error type conforms to `ToErrorResponse`:

<!-- example: tests/test_guide.mojo#results-and-errors -->
```mojo
from muntin import App, Json, Response, ToErrorResponse


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):     # the opt-in, in the type's own declaration
    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("no user " + String(self.id), status=404)


def find_user(id: Int) raises NotFound -> Json[User]:
    if id == 0:
        raise NotFound(id)
    return Json(User(id, "Ada"))


app.get["/users/{id}"](find_user)
# GET /users/1   -> 200 {"id":1,"name":"Ada"}
# GET /users/0   -> 404 "no user 0"
# GET /users/abc -> 400 "Bad Request"        (find_user not called)
```

`User` conforms only to `JsonFields`, so the handler returns it as `Json[User]`; returning a bare `User` needs `User` to conform to `ToResponse` ([responses](reference/responses.md)).

- Bare `raises` never maps by message: it is always the fixed 500.
- The fixed 500 carries a report of the dropped error (`response.failure()`) for middleware to log. **Its message is not safe log text**: it may hold secrets and client input.
- Muntin's 400 carries a report of why (`response.rejection()`): the step, the route value and the message, such as `from_json: age: JSON member is missing` for a body without `age` ([errors](reference/errors.md#reports-of-rejected-requests)).

Reference: [responses](reference/responses.md), [errors](reference/errors.md).

## Header fields

A `get` or `delete` handler (or a bodyless one) takes `Headers` as its last parameter:

<!-- example: tests/test_guide.mojo#header-fields -->
```mojo
from muntin import Headers


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(deinit self) -> Response:
        return Response.text("Unauthorized", status=401)


def me(headers: Headers) raises Unauthorized -> String:
    var token = headers.get("authorization")  # Optional[String]
    if not token:
        raise Unauthorized()
    return "me " + token.value()


app.get["/me"](me)
# GET /me  Authorization: t1  -> 200 "me t1"
# GET /me                     -> 401 "Unauthorized"
```

`get` returns the first value matched case-insensitively, `get_all` every value in order. Reference: [headers](reference/headers.md).

## Application state

Long-lived data reaches a handler only as `State[S]`, passed at registration; there are no globals:

<!-- example: tests/test_guide.mojo#application-state -->
```mojo
from muntin import State


struct Users(Movable):
    var names: List[String]

    def __init__(out self, var names: List[String]):
        self.names = names^

    def get(self, id: Int) raises NotFound -> String:
        if id < 0 or id >= len(self.names):
            raise NotFound(id)
        return self.names[id]


def show_user(users: State[Users], id: Int) raises NotFound -> Json[User]:
    return Json(User(id, users[].get(id)))  # read-only access to the shared value


var names: List[String] = ["ada", "bo"]
var users = State(Users(names^))          # the application builds the value once
app.get["/users/{id}"](show_user, users)  # the state is the registration's second argument
# GET /users/1 -> 200 {"id":1,"name":"bo"}
# GET /users/5 -> 404 "no user 5"
```

- `State` is a shared, read-only handle; a request copies nothing. A value that must change keeps that mutability in its own fields.
- The state's type must own its data: a type that may borrow (its name shows an origin) does not compile.
- With the Flare adapter's workers, each worker has its own `App` and its own `State` values ([state](reference/state.md#rules)).

Reference: [state](reference/state.md).

## Guarded routes

A `Group` puts routes behind one guard, which reads start-up values, can refuse the request and hands each handler a typed value, such as the caller:

<!-- example: tests/test_guide.mojo#guarded-routes -->
```mojo
from muntin import Group


@fieldwise_init
struct Caller(Movable):                    # what the guard hands a handler; owns its data
    var name: String


def authenticate(users: State[Users], headers: Headers) raises Unauthorized -> Caller:
    var token = headers.get("authorization")
    if not token or token.value() != "t1":    # application code decides
        raise Unauthorized()
    return Caller(users[].names[0])


def whoami(caller: Caller) -> String:       # first: the guard's value
    return "you are " + caller.name


var names: List[String] = ["ada", "bo"]
var users = State(Users(names^))
var signed_in = Group(authenticate, users)       # one guard, with start-up values
signed_in.get["/whoami"](whoami)
signed_in.get["/users/{id}"](show_user, users)  # guarded, without the caller
app.mount(signed_in^)
# GET /whoami  Authorization: t1  -> 200 "you are ada"
# GET /whoami, GET /users/x      -> 401 "Unauthorized"  (before the 400)
```

- The guard sees the header fields only. It runs after 404 and 405, before any conversion or the body; a raise answers as a handler's would.
- A handler receives the value as its first request parameter (after `State`); one without it is still guarded.
- A group takes no middleware and does not nest; middleware on the `App` wraps its routes.

Reference: [guarded groups](reference/groups.md).

## Middleware

Middleware is a function that may answer, or run the rest with `next^.run(request^)` and change the response:

<!-- example: tests/test_guide.mojo#middleware -->
```mojo
from muntin import App, Next, Request, Response


def tracing(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    response.headers.add("X-Trace", "1")
    return response^


app.use(tracing)
app.get["/users/{id}"](get_user)  # the first application's handler
# GET /users/1, GET /missing -> each answer with X-Trace: 1 added, the 404 included
```

- It runs on every request `App.handle` receives, 404 and 405 included, in registration order, outermost first.
- Configuration is compile-time only (`app.use(tagged["v1"])`); runtime-configured and per-route middleware are not supported. For start-up values and a typed value per request, use a guarded group (above).
- A middleware registered first can log the reports of dropped errors; the reference has a complete logger that escapes what it writes.

Reference: [middleware](reference/middleware.md).

## Raw handlers

When a typed shape does not fit, a raw handler takes the whole `Request` and returns a `Response`; Muntin extracts nothing and answers no 400:

<!-- example: tests/test_guide.mojo#raw-handlers -->
```mojo
def webhook(req: Request) -> Response:       # `var req: Request` also works
    if Span(req.body) != "signed".as_bytes():  # application code decides
        return Response.text("unsigned", status=401)
    return Response.text("ok")


app.post["/webhook"](webhook)
# POST /webhook  "signed"  -> 200 "ok"
# POST /webhook  "forged"  -> 401 "unsigned"
```

Bodies are bytes (`List[UInt8]`) both ways; `req.text()` raises when they are not UTF-8. Reference: [raw handlers](reference/raw.md).

## Testing

`TestClient` drives an `App` in memory through `App.handle`, the same entry a network backend calls:

<!-- example: tests/test_guide.mojo#testing -->
```mojo
app.post["/users"](create_user)  # the JSON handler above
var client = TestClient(app)
var headers = Headers()
headers.add("Content-Type", "application/json")
_ = client.post("/users", '{"name":"Ada","age":36}', headers=headers^)  # 200
_ = client.post("/users", '{"name":"Ada","age":36}')                    # 415: no field sent
```

The client sends exactly the fields given in `headers=` and nothing else. Reference: [testing](reference/testing.md).

## Serving

The Flare adapter's `Server` serves an `App` over HTTP/1.1 and h2c, or HTTPS with `tls=Tls(cert_file=..., key_file=...)`:

<!-- example: examples/hello_server.mojo -->
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

- `Server.bind` takes an IP literal (not a host name), a port, and keyword-only settings: `max_body_bytes` (10 MiB), `idle_timeout_ms` (500), `max_header_fields` (100), `shutdown_grace_ms` (5,000) and `tls`.
- `server.serve[make_app](workers=4)` serves with 4 threads, each building its own `App` with `make_app`.

Reference: [serving](reference/serving.md).

## Before you deploy

- **One request at a time per worker.** While a handler runs, its worker answers nothing else, and requests waiting on that worker's keep-alive and h2c connections can be closed unanswered once it returns, when a connection's idle time before the handler plus the handler's run time exceeds `idle_timeout_ms` (500 ms unless set). Keep handlers short, set `idle_timeout_ms` above the longest handler run plus your clients' idle time, and size `workers` above the number of handlers that may block at once ([serving](reference/serving.md#one-request-at-a-time)).
- **A stop ends the process if a handler outlasts it.** SIGTERM or SIGINT refuses new connections and serves the open ones for `shutdown_grace_ms`; if the server has not stopped one second later, the whole process ends without cleanup. Make changes atomic and retries safe.
- **Workers are not isolated.** If `make_app` raises on a worker, or a worker's reactor raises or returns, before a stop signal, every worker stops and `serve` raises; run under a supervisor ([workers](reference/serving.md#workers)).
- **Limits are per `Server`.** `max_body_bytes` bounds one request body, not memory overall; nothing caps the number of idle connections.
- **Client input stays untrusted.** Route values are decoded but not sanitized, header fields are client input, and dropped-error messages may hold secrets.

## Reference

- [Routing and registration](reference/routing.md): route literals, methods, `HEAD`, 405, conflicts, accepted shapes, order of checks, compile errors.
- [Route values](reference/route-values.md): `Int`, `String`, decoding, query values, `Param`, `Optional`, `FromRouteValue`, `RouteValues`.
- [Request bodies](reference/bodies.md): `FromBody`, `Json[T]`, `WithHeaders[B]`, `FromBytes`; [body size limits](reference/body-limits.md): `max_bytes`, `Json[T, limit=n]`.
- [Responses](reference/responses.md) and [errors](reference/errors.md): results, JSON status, `ToErrorResponse`, reports of dropped errors.
- [Headers](reference/headers.md), [raw handlers](reference/raw.md), [middleware](reference/middleware.md), [state](reference/state.md), [guarded groups](reference/groups.md).
- [Testing and the backend seam](reference/testing.md).
- [Serving](reference/serving.md): `Server`, settings, workers, HTTPS, stopping.

What is not supported yet: [`docs/SPEC.md`](SPEC.md), "Remaining candidates".
