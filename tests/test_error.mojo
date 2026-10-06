# Raising handlers in production (M2-011): every registration shape accepts
# a non-raising handler, a `raises` handler (error type `Error`) and a
# `raises T` handler (an application-defined `T`), with `String` and
# `ToResponse` results. A request-side failure is 400 and a missing route
# 404, both before the handler; anything the handler raises is a fixed 500
# whose body never carries the error, and the result conversion runs only
# after the handler returns. Decision: docs/history/architecture-decisions.md,
# "Application-error decision (M2-010)".

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_false, TestSuite

from muntin import App, FromBody, Request, Response, ToResponse
from muntin._handler_storage import _Erased
from muntin.app import _Route
from muntin.testing import TestClient

# Handlers are thin functions and cannot capture state, so calls are counted
# in environment variables, and FAIL makes every raising handler raise.
comptime FROM_BODY = "MUNTIN_TEST_ERROR_FROM_BODY"
comptime HANDLER = "MUNTIN_TEST_ERROR_HANDLER"
comptime CONVERSIONS = "MUNTIN_TEST_ERROR_CONVERSIONS"
comptime FAIL = "MUNTIN_TEST_ERROR_FAIL"

comptime SECRET = "database password is hunter2"


def _reset():
    for name in [FROM_BODY, HANDLER, CONVERSIONS, FAIL]:
        _ = unsetenv(name)


def _count(name: StaticString) -> Int:
    var n = getenv(name)
    try:
        return Int(n) if n else 0
    except:
        return -1


def _bump(name: StaticString):
    _ = setenv(name, String(_count(name) + 1))


def _failing() -> Bool:
    return getenv(FAIL) != ""


@fieldwise_init
struct NotFound(Movable, Writable):
    """An application-defined error type (`raises NotFound`), not `Copyable`,
    whose text would identify the failure if it were ever sent."""

    var id: Int

    def write_to(self, mut writer: Some[Writer]):
        writer.write("no user ", self.id, " in table users_pkey")


@fieldwise_init
struct User(Movable, ToResponse):
    """A move-only result."""

    var id: Int

    def to_response(var self) -> Response:
        _bump(CONVERSIONS)
        return Response.text("User(" + String(self.id) + ")")


@fieldwise_init
struct Gone(Movable, ToResponse):
    """Both a result and an error type: returned, it converts (410);
    raised, it is a handler error (500) and is never converted."""

    var id: Int

    def to_response(var self) -> Response:
        _bump(CONVERSIONS)
        return Response.text("gone " + String(self.id), status=410)


struct Name(FromBody):
    """A move-only body; an empty body fails to convert."""

    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(FROM_BODY)
        if body.byte_length() == 0:
            raise Error("empty name")
        return Self(body)


# Non-raising handlers.


def hello() -> String:
    _bump(HANDLER)
    return "hello"


def get_user(id: Int) -> User:
    _bump(HANDLER)
    return User(id)


def create(body: Name) -> String:
    _bump(HANDLER)
    return "created " + body.text


# Raising handlers: `raises` (`Error`) and `raises NotFound`, on every
# argument shape, each with a `String` and a `ToResponse` result. Each
# raises while FAIL is set and returns otherwise.


def _check() raises:
    if _failing():
        raise Error(SECRET)


def none_text() raises -> String:
    _bump(HANDLER)
    _check()
    return "none"


def none_user() raises -> User:
    _bump(HANDLER)
    _check()
    return User(0)


def none_text_t() raises NotFound -> String:
    _bump(HANDLER)
    if _failing():
        raise NotFound(0)
    return "none"


def none_user_t() raises NotFound -> User:
    _bump(HANDLER)
    if _failing():
        raise NotFound(0)
    return User(0)


def int_text(id: Int) raises -> String:
    _bump(HANDLER)
    _check()
    return "int " + String(id)


def int_user(id: Int) raises -> User:
    _bump(HANDLER)
    _check()
    return User(id)


def int_text_t(id: Int) raises NotFound -> String:
    _bump(HANDLER)
    if _failing():
        raise NotFound(id)
    return "int " + String(id)


def int_user_t(id: Int) raises NotFound -> User:
    _bump(HANDLER)
    if _failing():
        raise NotFound(id)
    return User(id)


def body_text(body: Name) raises -> String:
    _bump(HANDLER)
    _check()
    return "body " + body.text


def body_user(var body: Name) raises -> User:
    _bump(HANDLER)
    _check()
    return User(body.text.byte_length())


def body_text_t(body: Name) raises NotFound -> String:
    _bump(HANDLER)
    if _failing():
        raise NotFound(0)
    return "body " + body.text


def body_user_t(var body: Name) raises NotFound -> User:
    _bump(HANDLER)
    if _failing():
        raise NotFound(0)
    return User(body.text.byte_length())


def int_body_text(id: Int, body: Name) raises -> String:
    _bump(HANDLER)
    _check()
    return "int " + String(id) + " " + body.text


def int_body_user(id: Int, var body: Name) raises -> User:
    _bump(HANDLER)
    _check()
    return User(id)


def int_body_text_t(id: Int, body: Name) raises NotFound -> String:
    _bump(HANDLER)
    if _failing():
        raise NotFound(id)
    return "int " + String(id) + " " + body.text


def int_body_user_t(id: Int, var body: Name) raises NotFound -> User:
    _bump(HANDLER)
    if _failing():
        raise NotFound(id)
    return User(id)


# String-compatible and `Response` results of raising handlers.


def version() raises -> StaticString:
    _bump(HANDLER)
    _check()
    return "1.0"


def teapot() raises -> Response:
    _bump(HANDLER)
    _check()
    return Response.text("tea", status=418)


# The same message from the handler and from `_parse_int`: only the failing
# step decides the status.


def same_text(id: Int) raises -> String:
    _bump(HANDLER)
    if id == 0:
        raise Error("not an integer")
    return "same " + String(id)


# A `ToResponse` type as the error type: converted when returned, 500 when
# raised.


def find_gone(id: Int) raises Gone -> Gone:
    _bump(HANDLER)
    if id == 0:
        raise Gone(id)
    return Gone(id)


def error_app() -> App:
    var app = App()
    app.get["/hello"](hello)
    app.get["/users/{id}"](get_user)
    app.post["/create"](create)
    app.get["/none"](none_text)
    app.get["/none_user"](none_user)
    app.get["/t/none"](none_text_t)
    app.get["/t/none_user"](none_user_t)
    app.get["/int/{id}"](int_text)
    app.get["/int?{id}"](int_text)
    app.get["/int_user/{id}"](int_user)
    app.get["/t/int/{id}"](int_text_t)
    app.get["/t/int_user?{id}"](int_user_t)
    app.post["/body"](body_text)
    app.post["/body_user"](body_user)
    app.post["/t/body"](body_text_t)
    app.post["/t/body_user"](body_user_t)
    app.post["/ib/{id}"](int_body_text)
    app.post["/ib?{id}"](int_body_text)
    app.post["/ib_user/{id}"](int_body_user)
    app.post["/t/ib/{id}"](int_body_text_t)
    app.post["/t/ib_user?{id}"](int_body_user_t)
    app.get["/version"](version)
    app.get["/teapot"](teapot)
    app.get["/same/{id}"](same_text)
    app.get["/gone/{id}"](find_gone)
    return app^


@fieldwise_init
struct Case(Copyable, Movable):
    """One request to a raising route and its answer when the handler
    returns; `converts` says whether that answer comes from `to_response`,
    `body` whether `from_body` runs."""

    var method: String
    var target: String
    var body: String
    var status: Int
    var text: String
    var converts: Bool
    var reads_body: Bool


def _raising_cases() -> List[Case]:
    return [
        Case("GET", "/none", "", 200, "none", False, False),
        Case("GET", "/none_user", "", 200, "User(0)", True, False),
        Case("GET", "/t/none", "", 200, "none", False, False),
        Case("GET", "/t/none_user", "", 200, "User(0)", True, False),
        Case("GET", "/int/042", "", 200, "int 42", False, False),
        Case("GET", "/int?id=-7", "", 200, "int -7", False, False),
        Case("GET", "/int_user/3", "", 200, "User(3)", True, False),
        Case("GET", "/t/int/5", "", 200, "int 5", False, False),
        Case("GET", "/t/int_user?id=6", "", 200, "User(6)", True, False),
        Case("POST", "/body", "Ada", 200, "body Ada", False, True),
        Case("POST", "/body_user", "Ada", 200, "User(3)", True, True),
        Case("POST", "/t/body", "Bob", 200, "body Bob", False, True),
        Case("POST", "/t/body_user", "Eve", 200, "User(3)", True, True),
        Case("POST", "/ib/1", "Ada", 200, "int 1 Ada", False, True),
        Case("POST", "/ib?id=2", "Ada", 200, "int 2 Ada", False, True),
        Case("POST", "/ib_user/3", "Ada", 200, "User(3)", True, True),
        Case("POST", "/t/ib/4", "Ada", 200, "int 4 Ada", False, True),
        Case("POST", "/t/ib_user?id=5", "Ada", 200, "User(5)", True, True),
        Case("GET", "/version", "", 200, "1.0", False, False),
        Case("GET", "/teapot", "", 418, "tea", False, False),
    ]


def _send(app: App, c: Case) -> Response:
    return app.handle(Request(c.method, c.target, c.body))


def _expect(app: App, c: Case, status: Int, text: String) raises -> Response:
    var response = _send(app, c)
    assert_equal(response.status, status, c.method + " " + c.target)
    assert_equal(response.text(), text, c.method + " " + c.target)
    return response^


def test_non_raising_handlers_are_unchanged() raises:
    var app = error_app()
    var client = TestClient(app)
    _reset()
    assert_equal(client.get("/hello").text(), "hello")
    assert_equal(client.get("/users/42").text(), "User(42)")
    assert_equal(client.post("/create", "Ada").text(), "created Ada")
    assert_equal(client.get("/users/x").status, 400)
    assert_equal(client.post("/create", "").status, 400)
    assert_equal(_count(HANDLER), 3)
    assert_equal(_count(CONVERSIONS), 1)


def test_raising_handlers_that_return_answer_normally() raises:
    var app = error_app()
    for c in _raising_cases():
        _reset()
        _ = _expect(app, c, c.status, c.text)
        var label = c.method + " " + c.target
        assert_equal(_count(HANDLER), 1, label)
        assert_equal(_count(CONVERSIONS), 1 if c.converts else 0, label)
        assert_equal(_count(FROM_BODY), 1 if c.reads_body else 0, label)


def test_raising_handlers_that_raise_answer_a_fixed_500() raises:
    var app = error_app()
    for c in _raising_cases():
        _reset()
        _ = setenv(FAIL, "1")
        var response = _expect(app, c, 500, "Internal Server Error")
        var label = c.method + " " + c.target
        assert_equal(_count(HANDLER), 1, label)
        assert_equal(_count(CONVERSIONS), 0, label)
        assert_equal(_count(FROM_BODY), 1 if c.reads_body else 0, label)
        assert_false(SECRET in response.text(), label)
        assert_false("no user" in response.text(), label)


def test_request_failures_are_400_before_a_raising_handler() raises:
    var app = error_app()
    var cases = [
        Case("GET", "/int/x", "", 0, "", False, False),
        Case("GET", "/int/+4", "", 0, "", False, False),
        Case("GET", "/int?id=", "", 0, "", False, False),
        Case("GET", "/int", "", 0, "", False, False),
        Case("GET", "/int?id=1&id=2", "", 0, "", False, False),
        Case("GET", "/int_user/4_2", "", 0, "", False, False),
        Case("GET", "/t/int/x", "", 0, "", False, False),
        Case("GET", "/t/int_user?other=1", "", 0, "", False, False),
        Case("POST", "/ib/x", "Ada", 0, "", False, False),
        Case("POST", "/ib?id=x", "Ada", 0, "", False, False),
        Case("POST", "/ib_user/x", "Ada", 0, "", False, False),
        Case("POST", "/t/ib/x", "Ada", 0, "", False, False),
        Case("POST", "/t/ib_user", "Ada", 0, "", False, False),
        Case("GET", "/same/x", "", 0, "", False, False),
        Case("GET", "/gone/x", "", 0, "", False, False),
    ]
    for fail in [False, True]:
        for c in cases:
            _reset()
            if fail:
                _ = setenv(FAIL, "1")
            _ = _expect(app, c, 400, "Bad Request")
            assert_equal(_count(FROM_BODY), 0, c.target)
            assert_equal(_count(HANDLER), 0, c.target)
            assert_equal(_count(CONVERSIONS), 0, c.target)


def test_body_failures_are_400_before_a_raising_handler() raises:
    var app = error_app()
    var targets = [
        "/body",
        "/body_user",
        "/t/body",
        "/t/body_user",
        "/ib/1",
        "/ib?id=1",
        "/ib_user/1",
        "/t/ib/1",
        "/t/ib_user?id=1",
    ]
    for fail in [False, True]:
        for target in targets:
            _reset()
            if fail:
                _ = setenv(FAIL, "1")
            var response = app.handle(Request("POST", target, ""))
            assert_equal(response.status, 400, target)
            assert_equal(response.text(), "Bad Request", target)
            assert_equal(_count(FROM_BODY), 1, target)
            assert_equal(_count(HANDLER), 0, target)
            assert_equal(_count(CONVERSIONS), 0, target)


def test_unmatched_routes_are_404_before_a_raising_handler() raises:
    var app = error_app()
    _reset()
    _ = setenv(FAIL, "1")
    var cases = [
        Case("GET", "/int/", "", 0, "", False, False),  # missing segment
        Case("GET", "/int_user", "", 0, "", False, False),
        Case("GET", "/t/int/1/2", "", 0, "", False, False),
        Case("POST", "/none", "", 0, "", False, False),
        Case("GET", "/body", "Ada", 0, "", False, False),
        Case("POST", "/ib/", "Ada", 0, "", False, False),  # missing segment
        Case("PUT", "/ib/1", "Ada", 0, "", False, False),
        Case("GET", "/missing", "", 0, "", False, False),
    ]
    for c in cases:
        _ = _expect(app, c, 404, "Not Found")
    assert_equal(_count(FROM_BODY), 0)
    assert_equal(_count(HANDLER), 0)
    assert_equal(_count(CONVERSIONS), 0)


def test_500_depends_on_the_step_not_the_message() raises:
    # The handler raises `_parse_int`'s own text; a bad value on the same
    # route is 400.
    var client = TestClient(error_app())
    _reset()
    var handler_error = client.get("/same/0")
    assert_equal(handler_error.status, 500)
    assert_equal(handler_error.text(), "Internal Server Error")
    assert_equal(_count(HANDLER), 1)
    var bad_value = client.get("/same/x")
    assert_equal(bad_value.status, 400)
    assert_equal(bad_value.text(), "Bad Request")
    assert_equal(_count(HANDLER), 1)
    assert_equal(client.get("/same/7").text(), "same 7")


def test_returned_to_response_converts_raised_is_500() raises:
    var client = TestClient(error_app())
    _reset()
    var returned = client.get("/gone/4")
    assert_equal(returned.status, 410)
    assert_equal(returned.text(), "gone 4")
    assert_equal(_count(CONVERSIONS), 1)
    _reset()
    var raised = client.get("/gone/0")
    assert_equal(raised.status, 500)
    assert_equal(raised.text(), "Internal Server Error")
    assert_equal(_count(HANDLER), 1)
    assert_equal(_count(CONVERSIONS), 0)


def test_test_client_is_the_backend_seam() raises:
    var app = error_app()
    var client = TestClient(app)
    for fail in [False, True]:
        for c in _raising_cases():
            _reset()
            if fail:
                _ = setenv(FAIL, "1")
            var direct = _send(app, c)
            var via_client: Response
            if c.method == "GET":
                via_client = client.get(c.target)
            else:
                via_client = client.post(c.target, c.body)
            assert_equal(via_client.status, direct.status, c.target)
            assert_equal(via_client.text(), direct.text(), c.target)
    _reset()


def test_app_with_raising_routes_moves() raises:
    var app = error_app()
    var holder = List[App]()
    holder.append(app^)
    var last = holder.pop()
    var client = TestClient(last)
    _reset()
    assert_equal(client.get("/t/int/9").text(), "int 9")
    assert_equal(client.post("/ib_user/9", "Ada").text(), "User(9)")
    _ = setenv(FAIL, "1")
    assert_equal(client.get("/t/int/9").status, 500)
    assert_equal(client.post("/ib_user/9", "Ada").status, 500)
    assert_equal(client.get("/hello").text(), "hello")
    _reset()


def _broken_adapter(
    handler: def() thin -> String, args: List[String]
) raises -> Response:
    """An adapter that breaks the rule that adapters do not raise, with a
    request-like message."""
    raise Error("Bad Request")


def test_raise_out_of_invoke_is_500_never_400() raises:
    # No production adapter raises, so a raise out of `invoke` is a server
    # fault: `App.handle` answers 500, not 400.
    var app = App()
    var broken: def() thin -> String = hello
    app._routes.append(
        _Route("GET", "/broken", _Erased.__init__[call=_broken_adapter](broken))
    )
    _reset()
    var response = app.handle(Request("GET", "/broken"))
    assert_equal(response.status, 500)
    assert_equal(response.text(), "Internal Server Error")
    assert_equal(_count(HANDLER), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
