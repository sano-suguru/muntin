# Request-body extraction (M2-006): body-only `app.post` with an
# application-defined `FromBody` type. The body types live here, in the
# application module; `src/muntin` never names them.

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import App, FromBody, Request, Response
from muntin.testing import TestClient

# Handlers are thin functions and cannot capture state, so calls are recorded
# in environment variables.
comptime HANDLER_CALLED = "MUNTIN_TEST_BODY_HANDLER_CALLED"
comptime FROM_BODY_CALLED = "MUNTIN_TEST_FROM_BODY_CALLED"


def _reset():
    _ = unsetenv(HANDLER_CALLED)
    _ = unsetenv(FROM_BODY_CALLED)


def _called(name: StaticString) -> Bool:
    return getenv(name) == "1"


struct CreateUser(FromBody):
    """A move-only request body (not `Copyable`)."""

    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        # The application owns the format; this one is `name=<text>`.
        _ = setenv(FROM_BODY_CALLED, "1")
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("expected name=<text>")
        return Self(String(body[byte=5:]))


struct RenameTeam(FromBody):
    """A second body type with its own format."""

    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        if body.byte_length() == 0:
            raise Error("empty team name")
        return Self(body.upper())


struct RawText(FromBody):
    """Accepts any body, including an empty one, unchanged."""

    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def create_user(body: CreateUser) -> String:
    _ = setenv(HANDLER_CALLED, "1")
    return "created " + body.name


def store_user(var payload: CreateUser) -> String:
    # Owned and moved on: the converted value reaches the handler by move.
    # The parameter is not named `body`; binding never looks at names.
    var users = List[CreateUser]()
    users.append(payload^)
    return "stored " + users[0].name


def rename_team(body: RenameTeam) -> String:
    return "team " + body.name


def echo(body: RawText) -> String:
    return "[" + body.text + "]"


def list_users() -> String:
    return "users"


def get_user(id: Int) -> String:
    return String(id)


def body_app() -> App:
    var app = App()
    app.get["/users"](list_users)
    app.get["/users/{id}"](get_user)
    app.post["/users"](create_user)
    app.post["/stored"](store_user)
    app.post["/teams"](rename_team)
    app.post["/echo"](echo)
    return app^


def test_body_type_is_move_only() raises:
    comptime assert not conforms_to(CreateUser, Copyable)


def test_valid_body_is_converted_before_the_handler() raises:
    _reset()
    var app = body_app()
    var response = TestClient(app).post("/users", "name=Ada")
    assert_equal(response.status, 200)
    # "Ada", not the raw "name=Ada": the handler got the converted value.
    assert_equal(response.text(), "created Ada")
    assert_true(_called(FROM_BODY_CALLED))
    assert_true(_called(HANDLER_CALLED))


def test_invalid_body_is_400_without_calling_the_handler() raises:
    var app = body_app()
    var client = TestClient(app)
    for bad in ["", "Ada", "name=", "Name=Ada"]:
        _reset()
        var response = client.post("/users", bad)
        assert_equal(response.status, 400, bad)
        assert_equal(response.text(), "Bad Request", bad)
        assert_true(_called(FROM_BODY_CALLED), bad)
        assert_false(_called(HANDLER_CALLED), bad)


def test_body_comes_from_the_request_body_only() raises:
    var app = body_app()
    var client = TestClient(app)
    # The query is not the body, and the body is not read for routing.
    assert_equal(
        client.post("/users?name=Bob", "name=Ada").text(), "created Ada"
    )
    assert_equal(client.post("/users?name=Bob", "").status, 400)
    assert_equal(client.post("/users?x=1", "name=Eve").text(), "created Eve")


def test_body_reaches_from_body_byte_for_byte() raises:
    var app = body_app()
    var client = TestClient(app)
    for body in ["", " a=b&c?d \n", "\t", "name=Ada "]:
        assert_equal(client.post("/echo", body).status, 200, body)
        assert_equal(client.post("/echo", body).text(), "[" + body + "]", body)
    assert_equal(client.post("/echo?x=1", "y").text(), "[y]")


def test_unmatched_method_or_path_is_404_without_conversion() raises:
    var app = body_app()
    var client = TestClient(app)
    for method in ["PUT", "PATCH", "DELETE"]:
        _reset()
        var response = app.handle(Request(method, "/users", "name=Ada"))
        assert_equal(response.status, 404, method)
        assert_equal(response.text(), "Not Found", method)
        assert_false(_called(FROM_BODY_CALLED), method)
    for target in ["/missing", "/users/7", "/users/", "/user"]:
        _reset()
        var response = client.post(target, "name=Ada")
        assert_equal(response.status, 404, target)
        assert_equal(response.text(), "Not Found", target)
        assert_false(_called(FROM_BODY_CALLED), target)


def test_get_routes_on_the_same_path_are_unaffected() raises:
    var app = body_app()
    var client = TestClient(app)
    # A GET with a body is routed as before; the body is ignored.
    _reset()
    var response = app.handle(Request("GET", "/users", "name=Ada"))
    assert_equal(response.text(), "users")
    assert_false(_called(FROM_BODY_CALLED))
    assert_equal(client.get("/users/042").text(), "42")
    assert_equal(client.get("/users/abc").status, 400)


def test_owned_parameter_receives_the_moved_body() raises:
    var app = body_app()
    var response = TestClient(app).post("/stored", "name=Grace")
    assert_equal(response.status, 200)
    assert_equal(response.text(), "stored Grace")


def test_each_route_uses_its_own_body_type() raises:
    var app = body_app()
    var client = TestClient(app)
    assert_equal(client.post("/teams", "core").text(), "team CORE")
    assert_equal(client.post("/teams", "").status, 400)
    # "name=Ada" is a valid RenameTeam, and "core" an invalid CreateUser.
    assert_equal(client.post("/teams", "name=Ada").text(), "team NAME=ADA")
    assert_equal(client.post("/users", "core").status, 400)


def test_request_body_is_borrowed_not_consumed() raises:
    var app = body_app()
    var request = Request("POST", "/users", "name=Ada")
    _ = app.handle(request)
    assert_equal(request.body, "name=Ada")
    assert_equal(app.handle(request).text(), "created Ada")


def test_test_client_post_is_the_backend_seam() raises:
    var app = body_app()
    var client = TestClient(app)
    for body in ["name=Ada", "Ada", ""]:
        var direct = app.handle(Request("POST", "/users", body))
        var via_client = client.post("/users", body)
        assert_equal(via_client.status, direct.status, body)
        assert_equal(via_client.text(), direct.text(), body)


def test_app_with_body_routes_moves() raises:
    var app = body_app()
    var moved = app^
    var holder = List[App]()
    holder.append(moved^)
    var last = holder.pop()
    var client = TestClient(last)
    assert_equal(client.post("/users", "name=Lin").text(), "created Lin")
    assert_equal(client.post("/stored", "name=Lin").text(), "stored Lin")
    assert_equal(client.get("/users/5").text(), "5")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
