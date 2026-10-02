# One route value then one request body (M2-009): `app.post` with a handler
# `def(Int, B)`, `B` an application-defined `FromBody` type, returning
# `String` or `R: ToResponse`. The route value comes from one path segment or
# one query item; binding is positional (route value first, body second).
# Decision: docs/ARCHITECTURE.md, "Argument extraction decision (M2-005)".

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, TestSuite

from muntin import App, FromBody, Request, Response, ToResponse
from muntin.testing import TestClient

# Handlers are thin functions and cannot capture state, so calls are counted
# in environment variables.
comptime FROM_BODY_CALLS = "MUNTIN_TEST_INT_BODY_FROM_BODY_CALLS"
comptime HANDLER_CALLS = "MUNTIN_TEST_INT_BODY_HANDLER_CALLS"
comptime CONVERSIONS = "MUNTIN_TEST_INT_BODY_CONVERSIONS"


def _reset():
    _ = unsetenv(FROM_BODY_CALLS)
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


struct UpdateUser(FromBody):
    """A move-only request body (not `Copyable`) in `name=<text>` format."""

    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(FROM_BODY_CALLS)
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("expected name=<text>")
        return Self(String(body[byte=5:]))


struct Note(FromBody):
    """Accepts any body unchanged, so a body that is itself an integer, and
    a route value that is itself a valid body, show which source fills which
    parameter."""

    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(FROM_BODY_CALLS)
        return Self(body)


struct User(ToResponse):
    """A move-only result (not `Copyable`)."""

    var id: Int
    var name: String

    def __init__(out self, id: Int, var name: String):
        self.id = id
        self.name = name^

    def to_response(deinit self) -> Response:
        _bump(CONVERSIONS)
        var name = self.name^
        return Response.text("User(" + String(self.id) + ", " + name + ")")


def update_user(id: Int, body: UpdateUser) -> String:
    _bump(HANDLER_CALLS)
    return "user " + String(id) + " " + body.name


def update_note(n: Int, var text: Note) -> String:
    # Parameter names differ from the route's `{id}`: binding is positional.
    # Owned body, moved on.
    _bump(HANDLER_CALLS)
    var notes = List[Note]()
    notes.append(text^)
    return "note " + String(n) + ": " + notes[0].text


def replace_user(id: Int, var body: UpdateUser) -> User:
    _bump(HANDLER_CALLS)
    return User(id, body.name)


def move_user(id: Int, body: UpdateUser) -> Response:
    _bump(HANDLER_CALLS)
    return Response.text("moved " + String(id) + " " + body.name, status=202)


def ack(id: Int, body: UpdateUser) -> StaticString:
    _bump(HANDLER_CALLS)
    return "ack"


def get_user(id: Int) -> String:
    _bump(HANDLER_CALLS)
    return "get " + String(id)


def int_body_app() -> App:
    var app = App()
    app.get["/users/{id}"](get_user)
    app.post["/users/{id}"](update_user)
    app.post["/users?{id}"](update_user)
    app.post["/notes/{id}"](update_note)
    app.post["/notes?{id}"](update_note)
    app.post["/people/{id}"](replace_user)
    app.post["/people?{id}"](replace_user)
    app.post["/moves/{id}"](move_user)
    app.post["/acks/{id}"](ack)
    return app^


def _expect_post(
    app: App, target: String, body: String, status: Int, text: String
) raises:
    var response = TestClient(app).post(target, body)
    assert_equal(response.status, status, target + " " + body)
    assert_equal(response.text(), text, target + " " + body)


def test_body_and_result_types_are_move_only() raises:
    comptime assert not conforms_to(UpdateUser, Copyable)
    comptime assert not conforms_to(Note, Copyable)
    comptime assert not conforms_to(User, Copyable)


def test_path_value_then_body() raises:
    var app = int_body_app()
    _reset()
    # "042" -> "42" and "name=Ada" -> "Ada": both values were converted.
    _expect_post(app, "/users/42", "name=Ada", 200, "user 42 Ada")
    _expect_post(app, "/users/042", "name=Bob", 200, "user 42 Bob")
    _expect_post(app, "/users/-7", "name=Eve", 200, "user -7 Eve")
    _expect_post(app, "/users/5?id=9", "name=Ada", 200, "user 5 Ada")
    assert_equal(_count(FROM_BODY_CALLS), 4)
    assert_equal(_count(HANDLER_CALLS), 4)


def test_query_value_then_body() raises:
    var app = int_body_app()
    _reset()
    _expect_post(app, "/users?id=42", "name=Ada", 200, "user 42 Ada")
    _expect_post(app, "/users?other=z&id=010", "name=Bob", 200, "user 10 Bob")
    assert_equal(_count(FROM_BODY_CALLS), 2)
    assert_equal(_count(HANDLER_CALLS), 2)


def test_each_source_fills_its_own_parameter() raises:
    # The body "7" is a valid integer and the route value "5" a valid Note:
    # only positional binding of [route value, body] says "note 5: 7".
    var app = int_body_app()
    _expect_post(app, "/notes/5", "7", 200, "note 5: 7")
    _expect_post(app, "/notes?id=5", "7", 200, "note 5: 7")
    _expect_post(app, "/notes/5", "", 200, "note 5: ")
    _expect_post(
        app, "/notes?id=5", " a=b&id=9 \n", 200, "note 5:  a=b&id=9 \n"
    )


def test_bad_route_value_is_400_before_body_conversion() raises:
    var app = int_body_app()
    var targets = [
        "/users/abc",
        "/users/+4",
        "/users/4_2",
        "/users?id=abc",
        "/users?id=",
        "/users",
        "/users?other=1",
        "/users?id=1&id=2",
        "/notes/x",
        "/notes",
        "/people/x",
        "/people?id=1&id=2",
        "/moves/x",
        "/acks/x",
    ]
    for target in targets:
        for body in ["name=Ada", "Ada"]:
            _reset()
            _expect_post(app, target, body, 400, "Bad Request")
            assert_equal(_count(FROM_BODY_CALLS), 0, target + " " + body)
            assert_equal(_count(HANDLER_CALLS), 0, target + " " + body)
            assert_equal(_count(CONVERSIONS), 0, target + " " + body)


def test_bad_body_is_400_without_the_handler() raises:
    var app = int_body_app()
    var targets = [
        "/users/1",
        "/users?id=1",
        "/people/1",
        "/people?id=1",
        "/moves/1",
        "/acks/1",
    ]
    for target in targets:
        for body in ["", "Ada", "name=", "Name=Ada"]:
            _reset()
            _expect_post(app, target, body, 400, "Bad Request")
            assert_equal(_count(FROM_BODY_CALLS), 1, target + " " + body)
            assert_equal(_count(HANDLER_CALLS), 0, target + " " + body)
            assert_equal(_count(CONVERSIONS), 0, target + " " + body)


def test_unmatched_method_or_path_is_404_without_extraction() raises:
    var app = int_body_app()
    for method in ["PUT", "PATCH", "DELETE"]:
        _reset()
        var response = app.handle(Request(method, "/users/1", "name=Ada"))
        assert_equal(response.status, 404, method)
        assert_equal(response.text(), "Not Found", method)
    for target in ["/users/1/x", "/users/", "/missing/1", "/people/1/2"]:
        _reset()
        _expect_post(app, target, "name=Ada", 404, "Not Found")
    assert_equal(_count(FROM_BODY_CALLS), 0)
    assert_equal(_count(HANDLER_CALLS), 0)
    assert_equal(_count(CONVERSIONS), 0)


def test_get_route_on_the_same_path_is_unaffected() raises:
    var app = int_body_app()
    _reset()
    var response = app.handle(Request("GET", "/users/042", "name=Ada"))
    assert_equal(response.text(), "get 42")
    assert_equal(_count(FROM_BODY_CALLS), 0)
    assert_equal(TestClient(app).get("/users/abc").status, 400)


def test_typed_result_converts_once_after_the_handler() raises:
    var app = int_body_app()
    _reset()
    _expect_post(app, "/people/4", "name=Ada", 200, "User(4, Ada)")
    _expect_post(app, "/people?id=04", "name=Bob", 200, "User(4, Bob)")
    assert_equal(_count(HANDLER_CALLS), 2)
    assert_equal(_count(CONVERSIONS), 2)


def test_response_and_string_compatible_results() raises:
    var app = int_body_app()
    _reset()
    _expect_post(app, "/moves/3", "name=Ada", 202, "moved 3 Ada")
    _expect_post(app, "/acks/3", "name=Ada", 200, "ack")
    assert_equal(_count(HANDLER_CALLS), 2)
    assert_equal(_count(CONVERSIONS), 0)


def test_test_client_post_is_the_backend_seam() raises:
    var app = int_body_app()
    var client = TestClient(app)
    var cases = [
        ("/users/1", "name=Ada"),
        ("/users?id=1", "name=Ada"),
        ("/users/x", "name=Ada"),
        ("/users/1", "Ada"),
        ("/people/2", "name=Ada"),
        ("/missing/1", "name=Ada"),
    ]
    for c in cases:
        var target = String(c[0])
        var body = String(c[1])
        var direct = app.handle(Request("POST", target, body))
        var via_client = client.post(target, body)
        assert_equal(via_client.status, direct.status, target)
        assert_equal(via_client.text(), direct.text(), target)


def test_app_with_int_body_routes_moves() raises:
    var app = int_body_app()
    var moved = app^
    var holder = List[App]()
    holder.append(moved^)
    var last = holder.pop()
    _expect_post(last, "/users/8", "name=Lin", 200, "user 8 Lin")
    _expect_post(last, "/notes?id=8", "Lin", 200, "note 8: Lin")
    _expect_post(last, "/people/8", "name=Lin", 200, "User(8, Lin)")
    assert_equal(TestClient(last).get("/users/8").text(), "get 8")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
