"""The benchmark application written against Flare alone: the routes of
`muntin_app.mojo`, which says what they answer, with Flare's `Router`, its
typed body extractor (`Extracted`, `JsonAs`) and the reflection-based JSON
codec Flare ships (`json`), as `bench/compare/users_flare.mojo` uses them.
Not part of Muntin and not run by CI.

`Tracing[Inner]` is the middleware: a handler around another that adds
`X-Trace: 1` to every answer, as Flare's own middleware (`Logger`,
`RequestId`) wraps an inner handler.
"""

from json import Value, deserialize_value, serialize_json
from flare.http import (
    Extracted,
    FromJson,
    Handler,
    JsonAs,
    Request,
    Response,
    Router,
    ok_json,
)


@fieldwise_init
struct Message(Copyable):
    var message: String


@fieldwise_init
struct User(Copyable):
    var id: Int
    var name: String
    var age: Int


@fieldwise_init
struct CreateUser(Copyable, Defaultable, FromJson):
    var name: String
    var age: Int

    def __init__(out self):
        self = Self("", 0)

    def parse_json(mut self, value: Value) raises:
        self = deserialize_value[Self](value)


def plaintext(req: Request) raises -> Response:
    return Response(status=200, body=List(String("Hello, World!").as_bytes()))


def message(req: Request) raises -> Response:
    return ok_json(serialize_json(Message("Hello, World!")))


@fieldwise_init
struct CreateUserHandler(Copyable, Defaultable, Handler):
    var body: JsonAs[CreateUser]

    def __init__(out self):
        self.body = JsonAs[CreateUser]()

    def serve(self, req: Request) raises -> Response:
        ref b = self.body.value
        return ok_json(serialize_json(User(1, b.name, b.age)))


def echo(req: Request) raises -> Response:
    return Response(status=200, body=req.body.copy())


@fieldwise_init
struct Tracing[Inner: Handler & Copyable](Copyable, Handler):
    var inner: Self.Inner

    def serve(self, req: Request) raises -> Response:
        var response = self.inner.serve(req).lower()
        response.headers.append("X-Trace", "1")
        return response^


def router() raises -> Router:
    """The benchmark application's routes, without the middleware."""
    var r = Router()
    r.get("/plaintext", plaintext)
    r.get("/json", message)
    r.post("/json", Extracted[CreateUserHandler]())
    r.post("/echo", echo)
    return r^
