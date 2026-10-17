# docs/GUIDE.md's examples, as written there, each on its own `App`, through
# `TestClient` and `App.handle`: the success and the failure answers each
# section states. The guide's serving example is examples/hello_server.mojo,
# which scripts/check_flare.sh builds.

from std.collections import Optional
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import (
    App,
    FromJson,
    Headers,
    Json,
    JsonValue,
    JsonWriter,
    Next,
    Request,
    Response,
    State,
    ToErrorResponse,
    ToJson,
)
from muntin.testing import TestClient


# A first application.


def get_user(id: Int) -> String:
    return "user " + String(id)


# Routes and route values.


def list_items(limit: Optional[Int]) -> String:
    return "items " + String(limit.or_else(20))


def search(q: String, sort: Optional[String]) -> String:
    return "results for " + q + " by " + sort.or_else("relevance")


# Request bodies.


@fieldwise_init
struct CreateUser(FromJson):
    var name: String
    var age: Int
    var nickname: Optional[String]

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        var nick = Optional[String]()
        var n = value.get("nickname")
        if n and not n.value().is_null():
            nick = n.value().string()
        return Self(value["name"].string(), value["age"].int(), nick^)


@fieldwise_init
struct User(ToJson):
    var id: Int
    var name: String

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("id")
        out.int(self.id)
        out.name("name")
        out.string(self.name)
        out.end_object()


def create_user(body: Json[CreateUser]) -> Json[User]:
    return Json(User(1, body.value.name))


# Results and errors.


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):
    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("no user " + String(self.id), status=404)


def find_user(id: Int) raises NotFound -> Json[User]:
    if id == 0:
        raise NotFound(id)
    return Json(User(id, "Ada"))


def fails() raises -> String:
    raise Error("database password is hunter2")


# Header fields.


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(deinit self) -> Response:
        return Response.text("Unauthorized", status=401)


def me(headers: Headers) raises Unauthorized -> String:
    var token = headers.get("authorization")
    if not token:
        raise Unauthorized()
    return "me " + token.value()


# Application state.


struct Users(Movable):
    var names: List[String]

    def __init__(out self, var names: List[String]):
        self.names = names^

    def get(self, id: Int) raises NotFound -> String:
        if id < 0 or id >= len(self.names):
            raise NotFound(id)
        return self.names[id]


def show_user(users: State[Users], id: Int) raises NotFound -> Json[User]:
    return Json(User(id, users[].get(id)))


# Middleware.


def tracing(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    response.headers.add("X-Trace", "1")
    return response^


# Raw handlers.


def webhook(req: Request) -> Response:
    if Span(req.body) != "signed".as_bytes():
        return Response.text("unsigned", status=401)
    return Response.text("ok")


def _json() raises -> Headers:
    var headers = Headers()
    headers.add("Content-Type", "application/json")
    return headers^


def test_first_application() raises:
    var app = App()
    app.get["/users/{id}"](get_user)
    var client = TestClient(app)
    var r = client.get("/users/42")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "user 42")
    assert_equal(client.get("/users/abc").status, 400)
    assert_equal(client.get("/users").status, 404)


def test_routes_and_route_values() raises:
    var app = App()
    app.get["/items?{limit}"](list_items)
    app.get["/search?{q}&{sort}"](search)
    var client = TestClient(app)
    assert_equal(client.get("/items").text(), "items 20")
    assert_equal(client.get("/items?limit=5").text(), "items 5")
    var r = client.get("/search?q=mojo")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "results for mojo by relevance")
    r = client.get("/search?sort=date")
    assert_equal(r.status, 400)
    assert_equal(r.text(), "Bad Request")


def test_request_bodies() raises:
    var app = App()
    app.post["/users"](create_user)
    var r = app.handle(
        Request("POST", "/users", '{"name":"Ada","age":36}', _json())
    )
    assert_equal(r.status, 200)
    assert_equal(r.text(), '{"id":1,"name":"Ada"}')
    assert_equal(r.headers.get("content-type").value(), "application/json")
    var missing = app.handle(Request("POST", "/users", '{"name":"Ada"}'))
    assert_equal(missing.status, 415)
    var ok = '{"name":"Ada","age":36}'
    var big = ok + String(" ") * (1_048_576 - ok.byte_length() + 1)
    var too_large = app.handle(Request("POST", "/users", big, _json()))
    assert_equal(too_large.status, 413)
    var bad = app.handle(Request("POST", "/users", '{"name":', _json()))
    assert_equal(bad.status, 400)


def test_results_and_errors() raises:
    var app = App()
    app.get["/users/{id}"](find_user)
    app.get["/fails"](fails)
    var client = TestClient(app)
    var r = client.get("/users/1")
    assert_equal(r.status, 200)
    assert_equal(r.text(), '{"id":1,"name":"Ada"}')
    r = client.get("/users/0")
    assert_equal(r.status, 404)
    assert_equal(r.text(), "no user 0")
    r = client.get("/users/abc")
    assert_equal(r.status, 400)
    assert_equal(r.text(), "Bad Request")
    r = client.get("/fails")
    assert_equal(r.status, 500)
    assert_equal(r.text(), "Internal Server Error")
    assert_true(r.failure(), "no report")
    assert_equal(r.failure().value().message, "database password is hunter2")


def test_header_fields() raises:
    var app = App()
    app.get["/me"](me)
    var client = TestClient(app)
    var headers = Headers()
    headers.add("Authorization", "t1")
    var r = client.get("/me", headers=headers^)
    assert_equal(r.status, 200)
    assert_equal(r.text(), "me t1")
    r = client.get("/me")
    assert_equal(r.status, 401)
    assert_equal(r.text(), "Unauthorized")


def test_application_state() raises:
    var names: List[String] = ["ada", "bo"]
    var users = State(Users(names^))
    var app = App()
    app.get["/users/{id}"](show_user, users)
    var client = TestClient(app)
    var r = client.get("/users/1")
    assert_equal(r.status, 200)
    assert_equal(r.text(), '{"id":1,"name":"bo"}')
    r = client.get("/users/5")
    assert_equal(r.status, 404)
    assert_equal(r.text(), "no user 5")


def test_middleware() raises:
    var app = App()
    app.use(tracing)
    app.get["/users/{id}"](get_user)
    var client = TestClient(app)
    var r = client.get("/users/1")
    assert_equal(r.status, 200)
    assert_equal(r.headers.get("x-trace").value(), "1")
    r = client.get("/missing")
    assert_equal(r.status, 404)
    assert_equal(r.headers.get("x-trace").value(), "1")


def test_raw_handlers() raises:
    var app = App()
    app.post["/webhook"](webhook)
    var client = TestClient(app)
    var r = client.post("/webhook", "signed")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "ok")
    r = client.post("/webhook", "forged")
    assert_equal(r.status, 401)
    assert_equal(r.text(), "unsigned")


def test_testing() raises:
    var app = App()
    app.post["/users"](create_user)
    var client = TestClient(app)
    var headers = Headers()
    headers.add("Content-Type", "application/json")
    var r = client.post("/users", '{"name":"Ada","age":36}', headers=headers^)
    assert_equal(r.status, 200)
    r = client.post("/users", '{"name":"Ada","age":36}')
    assert_equal(r.status, 415)
    assert_false(r.failure())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
