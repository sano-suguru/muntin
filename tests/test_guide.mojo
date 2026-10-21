# docs/GUIDE.md's examples, each on its own `App`, through `TestClient` and
# `App.handle`: the success and the failure answers each section states. The
# text between `# example: <id>` and `# example: end` is what the guide shows
# (scripts/check_doc_examples.py compares them); `# fmt: off` keeps its
# layout. The guide's serving example is examples/hello_server.mojo, which
# scripts/check_flare.sh builds.

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


# A first application; README.md shows it too. The guide's `main` is
# `first_application` here.


# fmt: off
# example: first-application
from muntin import App
from muntin.testing import TestClient


def get_user(id: Int) -> String:
    return "user " + String(id)


def make_app() -> App:
    var app = App()
    app.get["/users/{id}"](get_user)
    return app^


def first_application() raises:
    var app = make_app()
    var client = TestClient(app)        # in memory, no socket
    print(client.get("/users/42").text())   # user 42
# example: end
# fmt: on


# Routes and route values.


# example: routes
def list_items(limit: Optional[Int]) -> String:
    return "items " + String(limit.or_else(20))


def search(q: String, sort: Optional[String]) -> String:
    return "results for " + q + " by " + sort.or_else("relevance")


# example: end


# Request bodies.


# fmt: off
# example: request-bodies
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
        out.field("id", self.id)
        out.field("name", self.name)
        out.end_object()


def create_user(body: Json[CreateUser]) -> Json[User]:    # borrow and read body.value
    return Json(User(1, body.value.name))
# example: end
# fmt: on


# Results and errors.


# fmt: off
# example: results-and-errors
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
# example: end
# fmt: on


def fails() raises -> String:
    raise Error("database password is hunter2")


# Header fields.


# fmt: off
# example: header-fields
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
# example: end
# fmt: on


# Application state.


# fmt: off
# example: application-state
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
# example: end
# fmt: on


# Guarded routes.


# fmt: off
# example: guarded-routes
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
# example: end
# fmt: on


# Middleware.


# example: middleware
from muntin import App, Next, Request, Response


def tracing(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    response.headers.add("X-Trace", "1")
    return response^


# example: end


# Raw handlers.


# fmt: off
# example: raw-handlers
def webhook(req: Request) -> Response:       # `var req: Request` also works
    if Span(req.body) != "signed".as_bytes():  # application code decides
        return Response.text("unsigned", status=401)
    return Response.text("ok")
# example: end
# fmt: on


def _json() raises -> Headers:
    var headers = Headers()
    headers.add("Content-Type", "application/json")
    return headers^


def test_first_application() raises:
    first_application()
    var app = make_app()
    var client = TestClient(app)
    var r = client.get("/users/42")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "user 42")
    assert_equal(client.get("/users/abc").status, 400)
    assert_equal(client.get("/users").status, 404)


def test_routes_and_route_values() raises:
    var app = App()
    # example: routes
    app.get["/items?{limit}"](list_items)
    app.get["/search?{q}&{sort}"](search)
    # GET /items                   -> 200 "items 20"
    # GET /search?q=mojo           -> 200 "results for mojo by relevance"
    # GET /search?sort=date        -> 400 "Bad Request"  (q is required)
    # example: end
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
    # example: request-bodies
    app.post["/users"](create_user)
    # POST /users  Content-Type: application/json  {"name":"Ada","age":36}
    #   -> 200, Content-Type: application/json, {"id":1,"name":"Ada"}
    # Content-Type missing -> 415; a body over 1 MiB -> 413; malformed JSON -> 400
    # example: end
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
    # fmt: off
    # example: results-and-errors
    app.get["/users/{id}"](find_user)
    # GET /users/1   -> 200 {"id":1,"name":"Ada"}
    # GET /users/0   -> 404 "no user 0"
    # GET /users/abc -> 400 "Bad Request"        (find_user not called)
    # example: end
    # fmt: on
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
    # example: header-fields
    app.get["/me"](me)
    # GET /me  Authorization: t1  -> 200 "me t1"
    # GET /me                     -> 401 "Unauthorized"
    # example: end
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
    var app = App()
    # fmt: off
    # example: application-state
    var names: List[String] = ["ada", "bo"]
    var users = State(Users(names^))          # the application builds the value once
    app.get["/users/{id}"](show_user, users)  # the state is the registration's second argument
    # GET /users/1 -> 200 {"id":1,"name":"bo"}
    # GET /users/5 -> 404 "no user 5"
    # example: end
    # fmt: on
    var client = TestClient(app)
    var r = client.get("/users/1")
    assert_equal(r.status, 200)
    assert_equal(r.text(), '{"id":1,"name":"bo"}')
    r = client.get("/users/5")
    assert_equal(r.status, 404)
    assert_equal(r.text(), "no user 5")


def test_guarded_routes() raises:
    var app = App()
    # fmt: off
    # example: guarded-routes
    var names: List[String] = ["ada", "bo"]
    var users = State(Users(names^))
    var signed_in = Group(authenticate, users)       # one guard, with start-up values
    signed_in.get["/whoami"](whoami)
    signed_in.get["/users/{id}"](show_user, users)  # guarded, without the caller
    app.mount(signed_in^)
    # GET /whoami  Authorization: t1  -> 200 "you are ada"
    # GET /whoami, GET /users/x      -> 401 "Unauthorized"  (before the 400)
    # example: end
    # fmt: on
    var client = TestClient(app)
    var headers = Headers()
    headers.add("Authorization", "t1")
    var r = client.get("/whoami", headers=headers.copy())
    assert_equal(r.status, 200)
    assert_equal(r.text(), "you are ada")
    r = client.get("/users/1", headers=headers.copy())
    assert_equal(r.text(), '{"id":1,"name":"bo"}')
    assert_equal(client.get("/users/x", headers=headers^).status, 400)
    for path in ["/whoami", "/users/x"]:
        r = client.get(path)
        assert_equal(r.status, 401)
        assert_equal(r.text(), "Unauthorized")


def test_middleware() raises:
    var app = App()
    # example: middleware
    app.use(tracing)
    app.get["/users/{id}"](get_user)  # the first application's handler
    # GET /users/1, GET /missing -> each answer with X-Trace: 1 added, the 404 included
    # example: end
    var client = TestClient(app)
    var r = client.get("/users/1")
    assert_equal(r.status, 200)
    assert_equal(r.headers.get("x-trace").value(), "1")
    r = client.get("/missing")
    assert_equal(r.status, 404)
    assert_equal(r.headers.get("x-trace").value(), "1")


def test_raw_handlers() raises:
    var app = App()
    # example: raw-handlers
    app.post["/webhook"](webhook)
    # POST /webhook  "signed"  -> 200 "ok"
    # POST /webhook  "forged"  -> 401 "unsigned"
    # example: end
    var client = TestClient(app)
    var r = client.post("/webhook", "signed")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "ok")
    r = client.post("/webhook", "forged")
    assert_equal(r.status, 401)
    assert_equal(r.text(), "unsigned")


def test_testing() raises:
    var app = App()
    # The example's requests run here; the asserts below send them again.
    # fmt: off
    # example: testing
    app.post["/users"](create_user)  # the JSON handler above
    var client = TestClient(app)
    var headers = Headers()
    headers.add("Content-Type", "application/json")
    _ = client.post("/users", '{"name":"Ada","age":36}', headers=headers^)  # 200
    _ = client.post("/users", '{"name":"Ada","age":36}')                    # 415: no field sent
    # example: end
    # fmt: on
    var body = '{"name":"Ada","age":36}'
    assert_equal(client.post("/users", body, headers=_json()).status, 200)
    var r = client.post("/users", body)
    assert_equal(r.status, 415)
    assert_false(r.failure())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
