# Muntin guide

How to write a Muntin application today, on Mojo 1.1.0 (8189361e). Each section shows the common case and links to the [reference](#reference) for every rule, status and error message. Setup is in the [README](../README.md#try-it).

Muntin is pre-alpha: the API still changes, and the Flare adapter's `Server` is not production-ready. Read [Before you deploy](#before-you-deploy) first.

## A first application

```mojo
from muntin import App
from muntin.testing import TestClient


def get_user(id: Int) -> String:
    return "user " + String(id)


def main() raises:
    var app = App()
    app.get["/users/{id}"](get_user)

    var client = TestClient(app)        # in memory, no socket
    print(client.get("/users/42").text())   # user 42
```

- `app.get["/users/{id}"](get_user)` registers a handler for a compile-time route literal. A route whose placeholders do not fit the handler does not compile: `app.get["/users/{id}"](hello)` with `def hello() -> String` fails with `route declares a path parameter but the handler takes none`.
- `GET /users/42` calls `get_user(42)`; `GET /users/abc` is 400 and `get_user` is never called; `GET /users` is 404.
- The same `App` is served over HTTP by the Flare adapter (below) without changing the handler.

## Routes and route values

Handlers take route values by position: path placeholders left to right, then query placeholders.

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

- A route value is an `Int`, a `String` (percent-decoded once), an `Optional` of either (query only; `None` when missing or empty), or an application type conforming to `FromRouteValue`.
- A handler takes up to two bare values. **Two bare values of one type declared in the wrong order compile and receive each other's values**; declare them as `Param["uid", Int]` to have the names checked at compile time. Three or more values are one `RouteValues` record, whose field names are checked.
- Overlapping routes of one method must be registered most specific first (`/users/me` before `/users/{id}`), or registration aborts.
- `app.post`, `app.put`, `app.patch` and `app.delete` register the other methods; a `get` route also answers `HEAD`; a path that only other methods match is 405 with `Allow`.

Reference: [routing](reference/routing.md), [route values](reference/route-values.md).

## Request bodies

A `post`, `put` or `patch` handler takes one body, last. For JSON, wrap an application type in `Json[T]`:

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


app.post["/users"](create_user)
# POST /users  Content-Type: application/json  {"name":"Ada","age":36}
#   -> 200, Content-Type: application/json, {"id":1,"name":"Ada"}
# Content-Type missing -> 415; a body over 1 MiB -> 413; malformed JSON -> 400
```

- Fields are mapped by hand in `from_json` and `write_json`; there is no derived codec.
- Other bodies: a `FromBody` type parses text itself; a `FromBytes` type receives the bytes and must declare `comptime max_bytes`, its size limit (a longer body is 413).
- A handler that also needs header fields takes `WithHeaders[B]` instead of `B`. **Muntin gives header fields no meaning**: a missing field is `None`, and the handler decides the status.
- A handler with only route values on `post`, `put` or `patch` is bodyless: the body is not read.

Reference: [bodies](reference/bodies.md).

## Results and errors

A handler returns `String` (a 200 text response with no fields), `Json[T]`, or any type conforming to `ToResponse`, `Response` included. `Json(value, status=201)` chooses another status.

**Anything a handler raises is a fixed 500 `Internal Server Error`, and the error's text is never sent**, unless the handler's declared error type conforms to `ToErrorResponse`:

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
# GET /users/0   -> 404 "no user 0"
# GET /users/abc -> 400 "Bad Request"        (get_user not called)
```

- Bare `raises` never maps by message: it is always the fixed 500.
- The fixed 500 carries a report of the dropped error (`response.failure()`) for middleware to log. **Its message is not safe log text**: it may hold secrets and client input.

Reference: [responses](reference/responses.md), [errors](reference/errors.md).

## Header fields

A `get` or `delete` handler (or a bodyless one) takes `Headers` as its last parameter:

```mojo
def me(headers: Headers) raises Unauthorized -> String:
    var token = headers.get("authorization")  # Optional[String]
    if not token:
        raise Unauthorized()  # ToErrorResponse: 401
    return "me " + token.value()


app.get["/me"](me)
```

`get` returns the first value matched case-insensitively, `get_all` every value in order. Reference: [headers](reference/headers.md).

## Application state

Long-lived data reaches a handler only as `State[S]`, passed at registration; there are no globals:

```mojo
def get_user(users: State[Users], id: Int) raises NotFound -> User:
    return User(id, users[].get(id))       # read-only access to the shared value


var users = State(Users(load_names()))   # the application builds the value once
app.get["/users/{id}"](get_user, users)  # the state is the registration's second argument
```

- `State` is a shared, read-only handle; a request copies nothing. A value that must change keeps that mutability in its own fields.
- The state's type must own its data: a type that may borrow (its name shows an origin) does not compile.
- With workers, each worker has its own `App` and its own `State` values.

Reference: [state](reference/state.md).

## Middleware

Middleware is a function that may answer, or run the rest with `next^.run(request^)` and change the response:

```mojo
from muntin import App, Next, Request, Response


def tracing(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    response.headers.add("X-Trace", "1")
    return response^


app.use(tracing)
```

- It runs on every request `App.handle` receives, 404 and 405 included, in registration order, outermost first.
- Configuration is compile-time only (`app.use(tagged["v1"])`); runtime-configured middleware, per-route middleware and request-scoped context are not supported.
- A middleware registered first can log the reports of dropped errors; the reference has a complete logger that escapes what it writes.

Reference: [middleware](reference/middleware.md).

## Raw handlers

When a typed shape does not fit, a raw handler takes the whole `Request` and returns a `Response`; Muntin extracts nothing and answers no 400:

```mojo
def webhook(req: Request) -> Response:       # `var req: Request` also works
    if Span(req.body) != "signed".as_bytes():  # application code decides
        return Response.text("unsigned", status=401)
    return Response.text("ok")


app.post["/webhook"](webhook)
```

Bodies are bytes (`List[UInt8]`) both ways; `req.text()` raises when they are not UTF-8. Reference: [raw handlers](reference/raw.md).

## Testing

`TestClient` drives an `App` in memory through `App.handle`, the same entry a network backend calls:

```mojo
var client = TestClient(app)
var headers = Headers()
headers.add("Content-Type", "application/json")
_ = client.post("/users", '{"name":"Ada","age":36}', headers=headers^)  # 200
_ = client.post("/users", '{"name":"Ada","age":36}')                    # 415: no field sent
```

The client sends exactly the fields given in `headers=` and nothing else. Reference: [testing](reference/testing.md).

## Serving

The Flare adapter's `Server` serves an `App` over HTTP/1.1 and h2c, or HTTPS with `tls=Tls(cert_file=..., key_file=...)`:

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

- **One request at a time per worker.** While a handler runs, its worker answers nothing else, and requests waiting on that worker's connections can be dropped when the handler outlasts `idle_timeout_ms`. Keep handlers short, bound waits on other services, and size `workers` above the number of handlers that may block at once.
- **A stop ends the process if a handler outlasts it.** SIGTERM or SIGINT refuses new connections and serves the open ones for `shutdown_grace_ms`; if the server has not stopped one second later, the whole process ends without cleanup. Make changes atomic and retries safe.
- **Workers are not isolated.** One worker's failure stops every worker; run under a supervisor.
- **Limits are per `Server`.** `max_body_bytes` bounds one request body, not memory overall; nothing caps the number of idle connections.
- **Client input stays untrusted.** Route values are decoded but not sanitized, header fields are client input, and dropped-error messages may hold secrets.

## Reference

- [Routing and registration](reference/routing.md): route literals, methods, `HEAD`, 405, conflicts, accepted shapes, order of checks, compile errors.
- [Route values](reference/route-values.md): `Int`, `String`, decoding, query values, `Param`, `Optional`, `FromRouteValue`, `RouteValues`.
- [Request bodies](reference/bodies.md): `FromBody`, `Json[T]`, `WithHeaders[B]`, `FromBytes` and `max_bytes`.
- [Responses](reference/responses.md) and [errors](reference/errors.md): results, JSON status, `ToErrorResponse`, reports of dropped errors.
- [Headers](reference/headers.md), [raw handlers](reference/raw.md), [middleware](reference/middleware.md), [state](reference/state.md).
- [Testing and the backend seam](reference/testing.md).
- [Serving](reference/serving.md): `Server`, settings, workers, HTTPS, stopping.

What is not supported yet: [`docs/SPEC.md`](SPEC.md), "Remaining candidates".
