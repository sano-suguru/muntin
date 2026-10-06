# M2-007 typed-response decision spike, application side. The return types
# live here, in the application module; the library side
# (tests/response_spike.mojo) never names them. Decision and evidence:
# docs/history/architecture-decisions.md, "Typed response decision (M2-007)".

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import FromBody, Request, Response
from response_spike import ResponseApp, ToResponse, ToResponseRaising

# Handlers are thin functions and cannot capture state, so conversions are
# counted in an environment variable.
comptime CONVERSIONS = "MUNTIN_TEST_SPIKE_RESPONSE_CONVERSIONS"


def _reset():
    _ = unsetenv(CONVERSIONS)


def _conversions() raises -> Int:
    var n = getenv(CONVERSIONS)
    return Int(n) if n else 0


def _count_conversion():
    var n = 0
    try:
        n = _conversions()
    except:
        pass
    _ = setenv(CONVERSIONS, String(n + 1))


struct User(ToResponse, ToResponseRaising):
    """A move-only result (not `Copyable`). Its `to_response` takes
    `deinit self` to move a field out (on 1.1.0 a `var self` method cannot
    move one field out of a value with others left); that satisfies the
    `var self` requirement. One non-raising `to_response` satisfies today's
    requirement and the widened `raises` one."""

    var id: Int
    var name: String

    def __init__(out self, id: Int, var name: String):
        self.id = id
        self.name = name^

    def to_response(deinit self) -> Response:
        _count_conversion()
        var name = self.name^  # moved out of the consumed value, not copied
        return Response.text("User(" + String(self.id) + ", " + name + ")")


struct Created(ToResponse):
    """Chooses its own status, and conforms with a borrowed `self`."""

    var location: String

    def __init__(out self, location: String):
        self.location = location

    def to_response(self) -> Response:
        _count_conversion()
        return Response.text(self.location, status=201)


struct NewUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        if body.byte_length() == 0:
            raise Error("empty name")
        return Self(body)


def hello() -> String:
    return "hello"


def version() -> StaticString:
    return "1.0"


def get_name(id: Int) -> String:
    return "name " + String(id)


def get_code(id: Int) -> StaticString:
    return "code"


def get_user(id: Int) -> User:
    return User(id, "Ada")


def first_user() -> User:
    return User(1, "Ada")


def create_user(var body: NewUser) -> User:
    return User(7, body.name)


def create_user_text(body: NewUser) -> String:
    return "created " + body.name


def create_user_static(body: NewUser) -> StaticString:
    return "created"


def create_team(body: NewUser) -> Created:
    return Created("/teams/" + body.name)


def mixed_app() -> ResponseApp:
    var app = ResponseApp()
    app.get["/hello"](hello)
    app.get["/version"](version)
    app.get["/names/{id}"](get_name)
    app.get["/codes/{id}"](get_code)
    app.get["/users/{id}"](get_user)
    app.get["/search?{id}"](get_user)
    app.get["/first"](first_user)
    app.post["/users"](create_user)
    app.post["/users/text"](create_user_text)
    app.post["/users/static"](create_user_static)
    app.post["/teams"](create_team)
    return app^


def _expect(
    app: ResponseApp, method: String, target: String, status: Int, body: String
) raises:
    var request = Request(method, target, "Ada" if method == "POST" else "")
    var response = app.handle(request)
    assert_equal(response.status, status, method + " " + target)
    assert_equal(response.body, body, method + " " + target)


def test_string_compatible_handlers_keep_the_string_overload() raises:
    # Each of these resolves to a `String` overload although a generic
    # `ToResponse` overload for the same shape is present: `StaticString`
    # through Mojo's implicit conversion to the function type
    # `def(...) thin -> String`, not because it conforms to anything.
    var app = mixed_app()
    _reset()
    _expect(app, "GET", "/hello", 200, "hello")
    _expect(app, "GET", "/version", 200, "1.0")
    _expect(app, "GET", "/names/3", 200, "name 3")
    _expect(app, "GET", "/codes/3", 200, "code")
    _expect(app, "POST", "/users/text", 200, "created Ada")
    _expect(app, "POST", "/users/static", 200, "created")
    assert_equal(_conversions(), 0)


def test_app_defined_return_type_converts_itself() raises:
    var app = mixed_app()
    _reset()
    _expect(app, "GET", "/users/42", 200, "User(42, Ada)")
    _expect(app, "POST", "/teams", 201, "/teams/Ada")
    assert_equal(_conversions(), 2)


def test_return_value_is_moved_into_conversion_once() raises:
    assert_false(conforms_to(User, Copyable))
    var app = mixed_app()
    _reset()
    _expect(app, "GET", "/users/5", 200, "User(5, Ada)")
    assert_equal(_conversions(), 1)


def test_one_return_policy_across_get_and_post() raises:
    # The same type from every argument shape and source: no route value,
    # a path segment, a query value, and the request body.
    var app = mixed_app()
    _reset()
    _expect(app, "GET", "/first", 200, "User(1, Ada)")
    _expect(app, "GET", "/users/1", 200, "User(1, Ada)")
    _expect(app, "GET", "/search?id=1", 200, "User(1, Ada)")
    _expect(app, "POST", "/users", 200, "User(7, Ada)")
    assert_equal(_conversions(), 4)


def test_extraction_failure_skips_handler_and_conversion() raises:
    var app = mixed_app()
    _reset()
    _expect(app, "GET", "/users/abc", 400, "Bad Request")
    _expect(app, "GET", "/search", 400, "Bad Request")
    var empty = app.handle(Request("POST", "/users", ""))
    assert_equal(empty.status, 400)
    _expect(app, "GET", "/missing", 404, "Not Found")
    assert_equal(_conversions(), 0)


def test_mixed_handlers_survive_app_moves() raises:
    var app = mixed_app()
    var moved = app^
    var apps = List[ResponseApp]()
    apps.append(moved^)
    var last = apps.pop()
    _expect(last, "GET", "/hello", 200, "hello")
    _expect(last, "GET", "/users/9", 200, "User(9, Ada)")
    _expect(last, "POST", "/teams", 201, "/teams/Ada")


def _convert_raising[R: ToResponseRaising](var result: R) raises -> Response:
    return result^.to_response()


def test_widened_raising_requirement_accepts_existing_conformance() raises:
    comptime assert conforms_to(User, ToResponse)
    comptime assert conforms_to(User, ToResponseRaising)
    assert_equal(_convert_raising(User(3, "Bo")).body, "User(3, Bo)")


def user_json(var user: User) -> Response:
    return Response.text('{"id":' + String(user.id) + "}")


def test_explicit_converter_alternative_fits_the_unchanged_box() raises:
    # Candidate 2 compiles and runs; rejected for its registration syntax.
    var app = ResponseApp()
    app.get_converted["/users/{id}"](get_user, user_json)
    _expect(app, "GET", "/users/4", 200, '{"id":4}')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
