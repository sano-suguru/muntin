# M2-010 application-error decision spike, application side. Handlers and their
# error types live here; the library side (tests/error_spike.mojo) never names
# them. Decision and evidence: docs/history/architecture-decisions.md,
# "Application-error decision (M2-010)".

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import FromBody, Request, Response, ToResponse
from error_spike import ErrorApp, catch_converting, caught_text

# Handlers are thin functions and cannot capture state, so calls are
# counted in environment variables.
comptime FROM_BODY = "MUNTIN_TEST_SPIKE_ERROR_FROM_BODY"
comptime HANDLER = "MUNTIN_TEST_SPIKE_ERROR_HANDLER"
comptime CONVERSIONS = "MUNTIN_TEST_SPIKE_ERROR_CONVERSIONS"


def _reset():
    for name in [FROM_BODY, HANDLER, CONVERSIONS]:
        _ = unsetenv(name)


def _count(name: StaticString) raises -> Int:
    var n = getenv(name)
    return Int(n) if n else 0


def _bump(name: StaticString):
    var n = 0
    try:
        n = _count(name)
    except:
        pass
    _ = setenv(name, String(n + 1))


@fieldwise_init
struct NotFound(Movable, Writable):
    """An application-defined error type (`raises NotFound`). Not
    `Copyable`; carries data the catch site can read."""

    var id: Int

    def write_to(self, mut writer: Some[Writer]):
        writer.write("no user ", self.id)


@fieldwise_init
struct User(Movable, ToResponse):
    var id: Int

    def to_response(var self) -> Response:
        _bump(CONVERSIONS)
        return Response.text("User(" + String(self.id) + ")")


@fieldwise_init
struct Gone(Movable, ToResponse):
    """An application type that is both a result and an error: returned, it
    converts like any `ToResponse` result; raised, it is a handler error."""

    var id: Int

    def to_response(var self) -> Response:
        _bump(CONVERSIONS)
        return Response.text("gone " + String(self.id), status=410)


struct Name(FromBody):
    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(FROM_BODY)
        if body.byte_length() == 0:
            raise Error("empty name")
        return Self(body)


# Non-raising handlers, as production accepts them today.


def hello() -> String:
    _bump(HANDLER)
    return "hello"


def version() -> StaticString:
    _bump(HANDLER)
    return "1.0"


def get_user(id: Int) -> User:
    _bump(HANDLER)
    return User(id)


def teapot() -> Response:
    _bump(HANDLER)
    return Response.text("tea", status=418)


def create(body: Name) -> String:
    _bump(HANDLER)
    return "created " + body.text


def rename(id: Int, var body: Name) -> User:
    _bump(HANDLER)
    return User(id)


# Raising handlers: `raises` (error type `Error`) and `raises NotFound`, on
# every argument shape, with `String` and `ToResponse` results. Each raises
# for 0 (or an empty-looking body) and succeeds otherwise.


def fail_none() raises -> String:
    _bump(HANDLER)
    raise Error("database password is hunter2")


def fail_none_typed() raises NotFound -> User:
    _bump(HANDLER)
    raise NotFound(0)


def find_name(id: Int) raises -> String:
    _bump(HANDLER)
    if id == 0:
        raise Error("not an integer")  # the same text _parse_int raises
    return "name " + String(id)


def find_user(id: Int) raises NotFound -> User:
    _bump(HANDLER)
    if id == 0:
        raise NotFound(id)
    return User(id)


def store(body: Name) raises -> User:
    _bump(HANDLER)
    if body.text == "boom":
        raise Error("insert failed: duplicate key users_pkey")
    return User(1)


def store_text(body: Name) raises NotFound -> StaticString:
    _bump(HANDLER)
    if body.text == "boom":
        raise NotFound(1)
    return "stored"


def update(id: Int, body: Name) raises -> String:
    _bump(HANDLER)
    if id == 0:
        raise Error("update failed")
    return "updated " + String(id) + " " + body.text


def update_user(id: Int, var body: Name) raises NotFound -> User:
    _bump(HANDLER)
    if id == 0:
        raise NotFound(id)
    return User(id)


def make_app() -> ErrorApp:
    var app = ErrorApp()
    app.get["/hello"](hello)
    app.get["/version"](version)
    app.get["/users/{id}"](get_user)
    app.get["/teapot"](teapot)
    app.post["/create"](create)
    app.post["/rename/{id}"](rename)
    app.get["/fail"](fail_none)
    app.get["/fail_typed"](fail_none_typed)
    app.get["/names/{id}"](find_name)
    app.get["/found/{id}"](find_user)
    app.get["/found?{id}"](find_user)
    app.post["/store"](store)
    app.post["/store_text"](store_text)
    app.post["/update/{id}"](update)
    app.post["/update_user/{id}"](update_user)
    return app^


def _expect(
    app: ErrorApp,
    method: String,
    target: String,
    status: Int,
    body: String,
    request_body: String = "Ada",
) raises:
    var response = app.handle(Request(method, target, request_body))
    assert_equal(response.status, status, method + " " + target)
    assert_equal(response.body, body, method + " " + target)


def _expect_counts(from_body: Int, handler: Int, conversions: Int) raises:
    assert_equal(_count(FROM_BODY), from_body, "from_body calls")
    assert_equal(_count(HANDLER), handler, "handler calls")
    assert_equal(_count(CONVERSIONS), conversions, "conversions")


def test_non_raising_handlers_are_unchanged() raises:
    # Non-raising handlers infer `E = Never` and keep today's results,
    # including `-> StaticString` on the `String` overloads.
    var app = make_app()
    _reset()
    _expect(app, "GET", "/hello", 200, "hello")
    _expect(app, "GET", "/version", 200, "1.0")
    _expect(app, "GET", "/users/4", 200, "User(4)")
    _expect(app, "GET", "/teapot", 418, "tea")
    _expect(app, "POST", "/create", 200, "created Ada")
    _expect(app, "POST", "/rename/2", 200, "User(2)")
    _expect_counts(from_body=2, handler=6, conversions=2)


def test_raising_handlers_succeed_like_non_raising_ones() raises:
    var app = make_app()
    _reset()
    _expect(app, "GET", "/names/3", 200, "name 3")
    _expect(app, "GET", "/found/3", 200, "User(3)")
    _expect(app, "GET", "/found?id=3", 200, "User(3)")
    _expect(app, "POST", "/store", 200, "User(1)")
    _expect(app, "POST", "/store_text", 200, "stored")
    _expect(app, "POST", "/update/5", 200, "updated 5 Ada")
    _expect(app, "POST", "/update_user/5", 200, "User(5)")
    _expect_counts(from_body=4, handler=7, conversions=4)


def test_handler_error_is_a_fixed_500_on_every_shape() raises:
    # `Error` and `NotFound`, `String` and `ToResponse` results, no route
    # value, a path value, a query value, a body, a route value and a body.
    # The handler runs once; the result conversion never does.
    var app = make_app()
    _reset()
    _expect(app, "GET", "/fail", 500, "Internal Server Error")
    _expect(app, "GET", "/fail_typed", 500, "Internal Server Error")
    _expect(app, "GET", "/names/0", 500, "Internal Server Error")
    _expect(app, "GET", "/found/0", 500, "Internal Server Error")
    _expect(app, "GET", "/found?id=0", 500, "Internal Server Error")
    _expect(app, "POST", "/store", 500, "Internal Server Error", "boom")
    _expect(app, "POST", "/store_text", 500, "Internal Server Error", "boom")
    _expect(app, "POST", "/update/0", 500, "Internal Server Error")
    _expect(app, "POST", "/update_user/0", 500, "Internal Server Error")
    _expect_counts(from_body=4, handler=9, conversions=0)


def test_handler_error_text_never_reaches_the_client() raises:
    # The message is readable at the catch boundary...
    assert_equal(caught_text(fail_none), "database password is hunter2")
    # ...and absent from the response.
    var app = make_app()
    var response = app.handle(Request("GET", "/fail"))
    assert_equal(response.status, 500)
    assert_false("hunter2" in response.body)
    response = app.handle(Request("POST", "/store", "boom"))
    assert_false("users_pkey" in response.body)


def test_500_depends_on_the_step_not_the_message() raises:
    # `find_name` raises `Error("not an integer")`, the text `_parse_int`
    # raises: 500, because the handler raised. A bad value with the same
    # route is 400, because extraction failed.
    var app = make_app()
    _reset()
    _expect(app, "GET", "/names/0", 500, "Internal Server Error")
    _expect(app, "GET", "/names/x", 400, "Bad Request")
    _expect_counts(from_body=0, handler=1, conversions=0)


def test_request_failures_stay_400_before_the_handler() raises:
    var app = make_app()
    _reset()
    # Path value, query value (missing, duplicated, invalid), body, and a
    # route value before a body: each 400, no handler call.
    _expect(app, "GET", "/found/abc", 400, "Bad Request")
    _expect(app, "GET", "/found", 400, "Bad Request")
    _expect(app, "GET", "/found?id=1&id=2", 400, "Bad Request")
    _expect(app, "GET", "/found?id=x", 400, "Bad Request")
    _expect(app, "POST", "/store", 400, "Bad Request", "")
    _expect(app, "POST", "/update_user/abc", 400, "Bad Request")
    _expect_counts(from_body=1, handler=0, conversions=0)
    _expect(app, "POST", "/update_user/1", 400, "Bad Request", "")
    _expect_counts(from_body=2, handler=0, conversions=0)
    # No route: 404, nothing converted or called.
    _expect(app, "GET", "/missing", 404, "Not Found")
    _expect(app, "PUT", "/store", 404, "Not Found")
    _expect_counts(from_body=2, handler=0, conversions=0)


def test_raising_handlers_survive_app_moves() raises:
    var app = make_app()
    var moved = app^
    var apps = List[ErrorApp]()
    apps.append(moved^)
    var last = apps.pop()
    _expect(last, "GET", "/hello", 200, "hello")
    _expect(last, "GET", "/found/0", 500, "Internal Server Error")
    _expect(last, "GET", "/found/x", 400, "Bad Request")


def plain(id: Int) -> String:
    return "plain"


def test_widened_candidate_takes_error_and_non_raising_handlers() raises:
    # Candidate 1 compiles for these two kinds; `raises NotFound` does not
    # (tests/error_fail/typed_error_to_widened_type.mojo).
    var app = ErrorApp()
    app.get_widened["/plain/{id}"](plain)
    app.get_widened["/names/{id}"](find_name)
    _expect(app, "GET", "/plain/1", 200, "plain")
    _expect(app, "GET", "/names/0", 500, "Internal Server Error")


def fail_gone() raises Gone -> User:
    _bump(HANDLER)
    raise Gone(9)


def show_gone(id: Int) -> Gone:
    _bump(HANDLER)
    return Gone(id)


def test_raised_to_response_value_is_a_handler_error() raises:
    # Control flow decides: `Gone` returned converts itself (410); `Gone`
    # raised is a fixed 500 and its `to_response` never runs, although the
    # type conforms to `ToResponse`.
    var app = ErrorApp()
    app.get["/gone/{id}"](show_gone)
    app.get["/fail_gone"](fail_gone)
    _reset()
    _expect(app, "GET", "/gone/9", 410, "gone 9")
    _expect_counts(from_body=0, handler=1, conversions=1)
    _expect(app, "GET", "/fail_gone", 500, "Internal Server Error")
    _expect_counts(from_body=0, handler=2, conversions=1)


def test_typed_error_reaches_the_catch_boundary_with_its_type() raises:
    # Evidence for the deferred candidate 4: at an `except`, a `raises Gone`
    # handler's error is a `Gone` value, which code can convert; an `Error`
    # is only its message. `ErrorApp` does not do this (test above).
    comptime assert conforms_to(Gone, ToResponse)
    comptime assert not conforms_to(NotFound, ToResponse)
    assert_false(conforms_to(NotFound, Copyable))
    var gone = catch_converting(fail_gone)
    assert_equal(gone.status, 410)
    assert_equal(gone.body, "gone 9")
    var plain = catch_converting(fail_none_typed)
    assert_equal(plain.status, 500)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
