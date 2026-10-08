# Typed handler results (M2-008): a handler returns an application-defined type
# conforming to the public `muntin.ToResponse`, or Muntin's `Response`, on every
# argument shape. The result types live here, in the application module;
# `src/muntin` never names them. Decision:
# docs/history/architecture-decisions.md, "Typed response decision (M2-007)".

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import App, FromBody, Request, Response, ToResponse
from muntin.testing import TestClient

# Handlers are thin functions and cannot capture state, so handler calls and
# conversions are counted in environment variables.
comptime HANDLER_CALLS = "MUNTIN_TEST_RESPONSE_HANDLER_CALLS"
comptime CONVERSIONS = "MUNTIN_TEST_RESPONSE_CONVERSIONS"


def _reset():
    _ = unsetenv(HANDLER_CALLS)
    _ = unsetenv(CONVERSIONS)


def _count(name: StaticString) -> Int:
    var n = getenv(name)
    try:
        return Int(n) if n else 0
    except:
        return -1


def _bump(name: StaticString):
    _ = setenv(name, String(_count(name) + 1))


struct User(ToResponse):
    """A move-only result (not `Copyable`). `deinit self` moves the name out
    of the consumed value; it satisfies the `var self` requirement."""

    var id: Int
    var name: String

    def __init__(out self, id: Int, var name: String):
        self.id = id
        self.name = name^

    def to_response(deinit self) -> Response:
        _bump(CONVERSIONS)
        var name = self.name^
        return Response.text("User(" + String(self.id) + ", " + name + ")")


struct Created(ToResponse):
    """Chooses its own status; conforms with a borrowed `self`."""

    var location: String

    def __init__(out self, location: String):
        self.location = location

    def to_response(self) -> Response:
        _bump(CONVERSIONS)
        return Response.text(self.location, status=201)


struct Token(ToResponse):
    """Conforms with `var self`, the requirement's own convention."""

    var value: String

    def __init__(out self, value: String):
        self.value = value

    def to_response(var self) -> Response:
        _bump(CONVERSIONS)
        return Response.text(self.value^, status=203)


struct NewUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        if body.byte_length() == 0:
            raise Error("empty name")
        return Self(body)


def first_user() -> User:
    _bump(HANDLER_CALLS)
    return User(1, "Ada")


def get_user(id: Int) -> User:
    _bump(HANDLER_CALLS)
    return User(id, "Ada")


def create_user(var body: NewUser) -> User:
    _bump(HANDLER_CALLS)
    return User(7, body.name)


def create_team(body: NewUser) -> Created:
    _bump(HANDLER_CALLS)
    return Created("/teams/" + body.name)


def issue_token(id: Int) -> Token:
    _bump(HANDLER_CALLS)
    return Token("token " + String(id))


def teapot() -> Response:
    _bump(HANDLER_CALLS)
    return Response.text("short and stout", status=418)


def item_status(id: Int) -> Response:
    _bump(HANDLER_CALLS)
    return Response.text("item " + String(id), status=202)


def create_raw(body: NewUser) -> Response:
    _bump(HANDLER_CALLS)
    return Response.text("raw " + body.name, status=201)


def hello() -> String:
    _bump(HANDLER_CALLS)
    return "hello"


def version() -> StaticString:
    _bump(HANDLER_CALLS)
    return "1.0"


def code(id: Int) -> StaticString:
    _bump(HANDLER_CALLS)
    return "code"


def create_static(body: NewUser) -> StaticString:
    _bump(HANDLER_CALLS)
    return "created"


def response_app() -> App:
    var app = App()
    app.get["/hello"](hello)
    app.get["/version"](version)
    app.get["/codes/{id}"](code)
    app.post["/static"](create_static)
    app.get["/first"](first_user)
    app.get["/users/{id}"](get_user)
    app.get["/search?{id}"](get_user)
    app.post["/users"](create_user)
    app.post["/teams"](create_team)
    app.get["/tokens/{id}"](issue_token)
    app.get["/teapot"](teapot)
    app.get["/items/{id}"](item_status)
    app.post["/raw"](create_raw)
    return app^


def _expect(
    app: App, method: String, target: String, status: Int, body: String
) raises:
    var client = TestClient(app)
    var response = client.post(
        target, "Ada"
    ) if method == "POST" else client.get(target)
    assert_equal(response.status, status, method + " " + target)
    assert_equal(response.body, body, method + " " + target)


def test_result_types_are_application_defined() raises:
    comptime assert not conforms_to(User, Copyable)
    comptime assert conforms_to(User, ToResponse)
    comptime assert conforms_to(Created, ToResponse)
    comptime assert conforms_to(Token, ToResponse)
    comptime assert conforms_to(Response, ToResponse)
    # `String`-compatible results need no conformance; they stay on the
    # `String` overloads (below), never on the generic one.
    comptime assert not conforms_to(String, ToResponse)
    comptime assert not conforms_to(StaticString, ToResponse)


def test_user_result_converts_once_on_every_argument_shape() raises:
    # No route value, a path segment, a query value and the request body.
    var app = response_app()
    _reset()
    _expect(app, "GET", "/first", 200, "User(1, Ada)")
    _expect(app, "GET", "/users/42", 200, "User(42, Ada)")
    _expect(app, "GET", "/search?id=5", 200, "User(5, Ada)")
    _expect(app, "POST", "/users", 200, "User(7, Ada)")
    assert_equal(_count(HANDLER_CALLS), 4)
    assert_equal(_count(CONVERSIONS), 4)


def test_result_chooses_its_status() raises:
    var app = response_app()
    _reset()
    _expect(app, "POST", "/teams", 201, "/teams/Ada")
    _expect(app, "GET", "/tokens/4", 203, "token 4")
    assert_equal(_count(CONVERSIONS), 2)


def test_response_result_keeps_its_status_and_body() raises:
    var app = response_app()
    _reset()
    _expect(app, "GET", "/teapot", 418, "short and stout")
    _expect(app, "GET", "/items/3", 202, "item 3")
    _expect(app, "POST", "/raw", 201, "raw Ada")
    assert_equal(_count(HANDLER_CALLS), 3)
    assert_equal(_count(CONVERSIONS), 0)


def test_string_compatible_results_keep_string_behavior() raises:
    var app = response_app()
    _reset()
    _expect(app, "GET", "/hello", 200, "hello")
    _expect(app, "GET", "/version", 200, "1.0")
    _expect(app, "GET", "/codes/3", 200, "code")
    _expect(app, "POST", "/static", 200, "created")
    assert_equal(_count(HANDLER_CALLS), 4)
    assert_equal(_count(CONVERSIONS), 0)


def test_rejected_requests_run_neither_handler_nor_conversion() raises:
    var app = response_app()
    _reset()
    _expect(app, "GET", "/users/abc", 400, "Bad Request")
    _expect(app, "GET", "/items/x", 400, "Bad Request")
    _expect(app, "GET", "/search", 400, "Bad Request")
    _expect(app, "GET", "/search?id=1&id=2", 400, "Bad Request")
    var empty = TestClient(app).post("/users", "")
    assert_equal(empty.status, 400)
    assert_equal(empty.body, "Bad Request")
    _expect(app, "GET", "/missing", 404, "Not Found")
    _expect(app, "POST", "/first", 405, "Method Not Allowed")
    _expect(app, "GET", "/teams", 405, "Method Not Allowed")
    var allow_first = (
        TestClient(app).post("/first", "Ada").headers.get_all("Allow")
    )
    assert_equal(len(allow_first), 1)
    assert_equal(allow_first[0], "GET, HEAD")
    var allow_teams = TestClient(app).get("/teams").headers.get_all("Allow")
    assert_equal(len(allow_teams), 1)
    assert_equal(allow_teams[0], "POST")
    assert_equal(_count(HANDLER_CALLS), 0)
    assert_equal(_count(CONVERSIONS), 0)


def test_mixed_results_survive_app_moves() raises:
    var app = response_app()
    var moved = app^
    var apps = List[App]()
    apps.append(moved^)
    var last = apps.pop()
    _reset()
    _expect(last, "GET", "/hello", 200, "hello")
    _expect(last, "GET", "/version", 200, "1.0")
    _expect(last, "GET", "/users/9", 200, "User(9, Ada)")
    _expect(last, "POST", "/teams", 201, "/teams/Ada")
    _expect(last, "GET", "/teapot", 418, "short and stout")
    assert_equal(_count(CONVERSIONS), 2)


def test_backend_seam_converts_the_same_way() raises:
    var app = response_app()
    var response = app.handle(Request("GET", "/users/8"))
    assert_equal(response.status, 200)
    assert_equal(response.body, "User(8, Ada)")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
