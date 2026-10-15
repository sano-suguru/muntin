"""The benchmark application written with Muntin; `flare_app.mojo` is the
same application written against Flare alone. Not part of Muntin and not run
by CI; `scripts/bench_overhead.sh` says what is measured.

Routes, the same in both:
- `GET /plaintext`: `Hello, World!`, no `Content-Type`.
- `GET /json`: `{"message":"Hello, World!"}`, `application/json`.
- `POST /json`: reads `{"name": ..., "age": ...}` and answers the user it
  would create, `{"id":1,"name":...,"age":...}`, `application/json`.
- `POST /echo`: the request body, byte for byte, no `Content-Type`.

With `middleware`, one middleware adds `X-Trace: 1` to every answer.
"""

from muntin import (
    App,
    FromJson,
    Json,
    JsonValue,
    JsonWriter,
    Next,
    Request,
    Response,
    ToJson,
)


@fieldwise_init
struct Message(ToJson):
    var message: String

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("message")
        out.string(self.message)
        out.end_object()


@fieldwise_init
struct User(ToJson):
    var id: Int
    var name: String
    var age: Int

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("id")
        out.int(self.id)
        out.name("name")
        out.string(self.name)
        out.name("age")
        out.int(self.age)
        out.end_object()


@fieldwise_init
struct CreateUser(FromJson):
    var name: String
    var age: Int

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string(), value["age"].int())


def plaintext() -> String:
    return "Hello, World!"


def message() -> Json[Message]:
    return Json(Message("Hello, World!"))


def create_user(body: Json[CreateUser]) -> Json[User]:
    return Json(User(1, body.value.name, body.value.age))


def echo(req: Request) -> Response:
    return Response(200, req.body.copy())


def tracing(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    response.headers.add("X-Trace", "1")
    return response^


def build(middleware: Bool) -> App:
    """The benchmark application, with or without the middleware."""
    var app = App()
    if middleware:
        app.use(tracing)
    app.get["/plaintext"](plaintext)
    app.get["/json"](message)
    app.post["/json"](create_user)
    app.post["/echo"](echo)
    return app^
