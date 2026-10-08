# Application-defined error responses in production (M2-013): a handler declared
# `raises T`, where `T` declares `ToErrorResponse` (directly, through a refining
# trait, or conditionally), is answered with `T.to_error_response()` when it
# raises, on every argument shape and with `String` and `ToResponse` results.
# Every other error type, bare `raises` (`Error`) and a raised `ToResponse`-only
# value stay the fixed 500. The error converts once and the result conversion
# does not run; 400, 404 and 405 run neither. Decision:
# docs/history/architecture-decisions.md, "Error-response decision (M2-012)".

from std.os import getenv, setenv, unsetenv
from std.utils import Variant
from std.testing import assert_equal, assert_false, TestSuite

from muntin import App, FromBody, Request, Response, ToErrorResponse
from muntin import ToResponse
from muntin.testing import TestClient

# Handlers are thin functions and cannot capture state, so calls are counted
# in environment variables, and FAIL makes every handler that can raise
# raise.
comptime FROM_BODY = "MUNTIN_TEST_ERROR_RESPONSE_FROM_BODY"
comptime HANDLER = "MUNTIN_TEST_ERROR_RESPONSE_HANDLER"
comptime CONVERSIONS = "MUNTIN_TEST_ERROR_RESPONSE_CONVERSIONS"
comptime ERROR_CONVERSIONS = "MUNTIN_TEST_ERROR_RESPONSE_ERRORS"
comptime DROPS = "MUNTIN_TEST_ERROR_RESPONSE_DROPS"
comptime FAIL = "MUNTIN_TEST_ERROR_RESPONSE_FAIL"

comptime SECRET = "database password is hunter2"


def _reset():
    for name in [FROM_BODY, HANDLER, CONVERSIONS, ERROR_CONVERSIONS, DROPS]:
        _ = unsetenv(name)
    _ = unsetenv(FAIL)


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


# Results and bodies.


@fieldwise_init
struct User(Movable, ToResponse):
    """A move-only result."""

    var id: Int

    def to_response(var self) -> Response:
        _bump(CONVERSIONS)
        return Response.text("User(" + String(self.id) + ")")


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


# Error types that opt in. Each declares `ToErrorResponse` in its own
# struct declaration; the destructor counts drops, so a lost, copied or
# twice-dropped error shows.


struct NotFound(ToErrorResponse):
    """Move-only (not `Copyable`), `var self`: the destructor runs once,
    after the conversion."""

    var id: Int

    def __init__(out self, id: Int):
        self.id = id

    def __deinit__(deinit self):
        _bump(DROPS)

    def to_error_response(var self) -> Response:
        _bump(ERROR_CONVERSIONS)
        return Response.text("no user " + String(self.id), status=404)


@fieldwise_init
struct Conflict(Copyable, ToErrorResponse):
    """`Copyable`, with a borrowed `self` implementation."""

    var id: Int

    def __deinit__(deinit self):
        _bump(DROPS)

    def to_error_response(self) -> Response:
        _bump(ERROR_CONVERSIONS)
        return Response.text("conflict " + String(self.id), status=409)


trait ApiFailure(ToErrorResponse):
    """An application's own refinement: conforming to it is conforming to
    `ToErrorResponse`."""

    pass


struct ApiError(ApiFailure):
    """One error type with several kinds, converted in one place. `deinit
    self` moves a field out, and the destructor does not run."""

    var kind: Int
    var message: String

    def __init__(out self, kind: Int, var message: String):
        self.kind = kind
        self.message = message^

    def __deinit__(deinit self):
        _bump(DROPS)

    def to_error_response(deinit self) -> Response:
        _bump(ERROR_CONVERSIONS)
        var status = 409 if self.kind == 1 else 422
        return Response.text(self.message^, status=status)


struct Missing[T: AnyType](ToErrorResponse where conforms_to(T, Writable)):
    """Conditional conformance: `Missing[Int]` opts in, `Missing[Plain]`
    does not."""

    var id: Int

    def __init__(out self, id: Int):
        self.id = id

    def to_error_response(var self) -> Response:
        _bump(ERROR_CONVERSIONS)
        return Response.text("missing " + String(self.id), status=404)


struct Plain:
    pass


@fieldwise_init
struct Stale(Movable, ToErrorResponse, ToResponse):
    """A result and an error type at once: each channel has its own
    method."""

    var id: Int

    def to_response(var self) -> Response:
        _bump(CONVERSIONS)
        return Response.text("current " + String(self.id))

    def to_error_response(var self) -> Response:
        _bump(ERROR_CONVERSIONS)
        return Response.text("stale " + String(self.id), status=409)


@fieldwise_init
struct Erasable(Movable, ToErrorResponse, Writable):
    """Opted in and `Writable`: raised inside a bare-`raises` handler it
    propagates as `Error` (Mojo 1.1.0 type erasure)."""

    var id: Int

    def write_to(self, mut writer: Some[Writer]):
        writer.write(SECRET)

    def to_error_response(var self) -> Response:
        _bump(ERROR_CONVERSIONS)
        return Response.text("erasable", status=404)


# Error types that do not opt in.


struct Rejected(Movable):
    """No error-response conformance: the fixed 500, dropped once."""

    var id: Int

    def __init__(out self, id: Int):
        self.id = id

    def __deinit__(deinit self):
        _bump(DROPS)


@fieldwise_init
struct Gone(Movable, ToResponse):
    """`ToResponse` only: converted when returned, 500 when raised."""

    var id: Int

    def to_response(var self) -> Response:
        _bump(CONVERSIONS)
        return Response.text("gone " + String(self.id), status=410)


@fieldwise_init
struct Lookalike(Movable):
    """A method named `to_error_response` without the conformance."""

    var id: Int

    def to_error_response(var self) -> Response:
        _bump(ERROR_CONVERSIONS)
        return Response.text("lookalike", status=404)


# Opted-in `raises NotFound` on every argument shape, each with a `String`
# and a `ToResponse` result. Each raises while FAIL is set and returns
# otherwise.


def none_text() raises NotFound -> String:
    _bump(HANDLER)
    if _failing():
        raise NotFound(0)
    return "none"


def none_user() raises NotFound -> User:
    _bump(HANDLER)
    if _failing():
        raise NotFound(0)
    return User(0)


def int_text(id: Int) raises NotFound -> String:
    _bump(HANDLER)
    if _failing():
        raise NotFound(id)
    return "int " + String(id)


def int_user(id: Int) raises NotFound -> User:
    _bump(HANDLER)
    if _failing():
        raise NotFound(id)
    return User(id)


def body_text(body: Name) raises NotFound -> String:
    _bump(HANDLER)
    if _failing():
        raise NotFound(body.text.byte_length())
    return "body " + body.text


def body_user(var body: Name) raises NotFound -> User:
    _bump(HANDLER)
    if _failing():
        raise NotFound(body.text.byte_length())
    return User(body.text.byte_length())


def int_body_text(id: Int, body: Name) raises NotFound -> String:
    _bump(HANDLER)
    if _failing():
        raise NotFound(id)
    return "int " + String(id) + " " + body.text


def int_body_user(id: Int, var body: Name) raises NotFound -> User:
    _bump(HANDLER)
    if _failing():
        raise NotFound(id)
    return User(id)


# Other opted-in kinds, one shape each.


def find_conflict(id: Int) raises Conflict -> String:
    _bump(HANDLER)
    if _failing():
        raise Conflict(id)
    return "free " + String(id)


def save(id: Int, body: Name) raises ApiError -> User:
    _bump(HANDLER)
    if id == 1:
        raise ApiError(1, "duplicate " + body.text)
    if id == 2:
        raise ApiError(2, "invalid " + body.text)
    return User(id)


def find_missing(id: Int) raises Missing[Int] -> String:
    _bump(HANDLER)
    if _failing():
        raise Missing[Int](id)
    return "found " + String(id)


def find_missing_plain(id: Int) raises Missing[Plain] -> String:
    _bump(HANDLER)
    if _failing():
        raise Missing[Plain](id)
    return "found " + String(id)


def find_stale(id: Int) raises Stale -> Stale:
    _bump(HANDLER)
    if _failing():
        raise Stale(id)
    return Stale(id)


# Fixed-500 kinds.


def rejected(id: Int) raises Rejected -> String:
    _bump(HANDLER)
    if _failing():
        raise Rejected(id)
    return "accepted " + String(id)


def bare(id: Int) raises -> String:
    _bump(HANDLER)
    if _failing():
        raise Error(SECRET)
    return "bare " + String(id)


def erased(id: Int) raises -> String:
    _bump(HANDLER)
    if _failing():
        raise Erasable(id)
    return "erased " + String(id)


def find_gone(id: Int) raises Gone -> Gone:
    _bump(HANDLER)
    if _failing():
        raise Gone(id)
    return Gone(id)


def raise_response(id: Int) raises Response -> String:
    _bump(HANDLER)
    if _failing():
        raise Response.text("raised", status=404)
    return "response " + String(id)


def raise_variant(id: Int) raises Variant[Conflict, Stale] -> String:
    _bump(HANDLER)
    if _failing():
        raise Variant[Conflict, Stale](Conflict(id))
    return "variant " + String(id)


def lookalike(id: Int) raises Lookalike -> String:
    _bump(HANDLER)
    if _failing():
        raise Lookalike(id)
    return "lookalike " + String(id)


def error_response_app() -> App:
    var app = App()
    app.get["/none"](none_text)
    app.get["/none_user"](none_user)
    app.get["/int/{id}"](int_text)
    app.get["/int?{id}"](int_text)
    app.get["/int_user/{id}"](int_user)
    app.get["/int_user?{id}"](int_user)
    app.post["/body"](body_text)
    app.post["/body_user"](body_user)
    app.post["/ib/{id}"](int_body_text)
    app.post["/ib?{id}"](int_body_text)
    app.post["/ib_user/{id}"](int_body_user)
    app.post["/ib_user?{id}"](int_body_user)
    app.get["/conflict/{id}"](find_conflict)
    app.post["/save/{id}"](save)
    app.get["/missing/{id}"](find_missing)
    app.get["/missing_plain/{id}"](find_missing_plain)
    app.get["/stale/{id}"](find_stale)
    app.get["/rejected/{id}"](rejected)
    app.get["/bare/{id}"](bare)
    app.get["/erased/{id}"](erased)
    app.get["/gone/{id}"](find_gone)
    app.get["/lookalike/{id}"](lookalike)
    app.get["/response/{id}"](raise_response)
    app.get["/variant/{id}"](raise_variant)
    return app^


@fieldwise_init
struct Case(Copyable, Movable):
    """One request to an opted-in `raises NotFound` route: its answer when
    the handler returns (`ok_*`, `converts` if that comes from
    `to_response`) and when it raises (`error_text`, status 404);
    `reads_body` whether `from_body` runs."""

    var method: String
    var target: String
    var body: String
    var ok_text: String
    var converts: Bool
    var reads_body: Bool
    var error_text: String


def _shape_cases() -> List[Case]:
    return [
        Case("GET", "/none", "", "none", False, False, "no user 0"),
        Case("GET", "/none_user", "", "User(0)", True, False, "no user 0"),
        Case("GET", "/int/042", "", "int 42", False, False, "no user 42"),
        Case("GET", "/int?id=-7", "", "int -7", False, False, "no user -7"),
        Case("GET", "/int_user/3", "", "User(3)", True, False, "no user 3"),
        Case("GET", "/int_user?id=6", "", "User(6)", True, False, "no user 6"),
        Case("POST", "/body", "Ada", "body Ada", False, True, "no user 3"),
        Case("POST", "/body_user", "Eve", "User(3)", True, True, "no user 3"),
        Case("POST", "/ib/1", "Ada", "int 1 Ada", False, True, "no user 1"),
        Case("POST", "/ib?id=2", "Ada", "int 2 Ada", False, True, "no user 2"),
        Case("POST", "/ib_user/3", "Ada", "User(3)", True, True, "no user 3"),
        Case(
            "POST", "/ib_user?id=5", "Ada", "User(5)", True, True, "no user 5"
        ),
    ]


def _send(app: App, c: Case) -> Response:
    return app.handle(Request(c.method, c.target, c.body))


def _expect(
    app: App,
    method: String,
    target: String,
    body: String,
    status: Int,
    text: String,
) raises:
    var label = method + " " + target
    var response = app.handle(Request(method, target, body))
    assert_equal(response.status, status, label)
    assert_equal(response.text(), text, label)


def test_opted_in_handlers_that_return_answer_normally() raises:
    var app = error_response_app()
    for c in _shape_cases():
        _reset()
        var label = c.method + " " + c.target
        _expect(app, c.method, c.target, c.body, 200, c.ok_text)
        assert_equal(_count(HANDLER), 1, label)
        assert_equal(_count(CONVERSIONS), 1 if c.converts else 0, label)
        assert_equal(_count(ERROR_CONVERSIONS), 0, label)
        assert_equal(_count(DROPS), 0, label)
        assert_equal(_count(FROM_BODY), 1 if c.reads_body else 0, label)


def test_opted_in_errors_convert_once_on_every_shape() raises:
    # The error converts exactly once, its destructor runs exactly once
    # (`var self`), and the result conversion never runs.
    var app = error_response_app()
    for c in _shape_cases():
        _reset()
        _ = setenv(FAIL, "1")
        var label = c.method + " " + c.target
        _expect(app, c.method, c.target, c.body, 404, c.error_text)
        assert_equal(_count(HANDLER), 1, label)
        assert_equal(_count(ERROR_CONVERSIONS), 1, label)
        assert_equal(_count(DROPS), 1, label)
        assert_equal(_count(CONVERSIONS), 0, label)
        assert_equal(_count(FROM_BODY), 1 if c.reads_body else 0, label)
    _reset()


def test_copyable_error_with_borrowed_self_converts_once() raises:
    var app = error_response_app()
    _reset()
    _expect(app, "GET", "/conflict/4", "", 200, "free 4")
    assert_equal(_count(DROPS), 0)
    _reset()
    _ = setenv(FAIL, "1")
    _expect(app, "GET", "/conflict/4", "", 409, "conflict 4")
    assert_equal(_count(HANDLER), 1)
    assert_equal(_count(ERROR_CONVERSIONS), 1)
    assert_equal(_count(DROPS), 1)
    _reset()


def test_refining_trait_and_deinit_self_convert() raises:
    # `deinit self` consumes the error without running its destructor.
    var app = error_response_app()
    var cases = [
        (String("/save/1"), 409, String("duplicate Ada")),
        (String("/save/2"), 422, String("invalid Ada")),
    ]
    for want in cases:
        _reset()
        _expect(app, "POST", want[0], "Ada", want[1], want[2])
        assert_equal(_count(HANDLER), 1, want[0])
        assert_equal(_count(ERROR_CONVERSIONS), 1, want[0])
        assert_equal(_count(DROPS), 0, want[0])
        assert_equal(_count(CONVERSIONS), 0, want[0])
    _reset()
    _expect(app, "POST", "/save/3", "Ada", 200, "User(3)")
    assert_equal(_count(CONVERSIONS), 1)
    assert_equal(_count(ERROR_CONVERSIONS), 0)


def test_conditional_conformance_decides_per_instantiation() raises:
    var app = error_response_app()
    _reset()
    _ = setenv(FAIL, "1")
    _expect(app, "GET", "/missing/8", "", 404, "missing 8")
    assert_equal(_count(ERROR_CONVERSIONS), 1)
    _reset()
    _ = setenv(FAIL, "1")
    _expect(app, "GET", "/missing_plain/8", "", 500, "Internal Server Error")
    assert_equal(_count(HANDLER), 1)
    assert_equal(_count(ERROR_CONVERSIONS), 0)
    _reset()
    _expect(app, "GET", "/missing_plain/8", "", 200, "found 8")


def test_errors_that_do_not_opt_in_stay_the_fixed_500() raises:
    # A non-opted `raises T`, bare `raises`, an opted-in type erased to
    # `Error` by a bare-`raises` handler, a raised `ToResponse`-only value
    # (also `Response` itself), a same-named method and a `Variant` of
    # opted-in types: 500 with the fixed body, nothing converted.
    var app = error_response_app()
    var targets = [
        "/rejected/1",
        "/bare/1",
        "/erased/1",
        "/gone/1",
        "/lookalike/1",
        "/response/1",
        "/variant/1",
    ]
    for target in targets:
        _reset()
        _ = setenv(FAIL, "1")
        var response = app.handle(Request("GET", target))
        assert_equal(response.status, 500, target)
        assert_equal(response.text(), "Internal Server Error", target)
        assert_false(SECRET in response.text(), target)
        assert_equal(_count(HANDLER), 1, target)
        assert_equal(_count(CONVERSIONS), 0, target)
        assert_equal(_count(ERROR_CONVERSIONS), 0, target)
    _reset()
    _ = setenv(FAIL, "1")
    _ = app.handle(Request("GET", "/rejected/1"))
    assert_equal(_count(DROPS), 1)  # dropped once by the fixed-500 branch
    _reset()


def test_returned_and_raised_values_use_their_own_channel() raises:
    var app = error_response_app()
    _reset()
    _expect(app, "GET", "/stale/5", "", 200, "current 5")
    assert_equal(_count(CONVERSIONS), 1)
    assert_equal(_count(ERROR_CONVERSIONS), 0)
    _reset()
    _ = setenv(FAIL, "1")
    _expect(app, "GET", "/stale/5", "", 409, "stale 5")
    assert_equal(_count(CONVERSIONS), 0)
    assert_equal(_count(ERROR_CONVERSIONS), 1)
    # `ToResponse` alone: returned converts, raised is 500.
    _reset()
    _expect(app, "GET", "/gone/5", "", 410, "gone 5")
    assert_equal(_count(CONVERSIONS), 1)
    _reset()


def test_request_failures_convert_nothing() raises:
    # 400, 404 and 405 on opted-in routes, whether or not the handler would
    # raise: neither the handler, the error conversion nor the result
    # conversion runs.
    var app = error_response_app()
    var bad = [
        ("GET", "/int/x", ""),
        ("GET", "/int?id=", ""),
        ("GET", "/int", ""),
        ("GET", "/int_user?id=1&id=2", ""),
        ("GET", "/int_user/+4", ""),
        ("POST", "/ib/x", "Ada"),
        ("POST", "/ib?id=x", "Ada"),
        ("POST", "/ib_user", "Ada"),
        ("GET", "/conflict/x", ""),
        ("POST", "/save/x", "Ada"),
        ("GET", "/stale/x", ""),
    ]
    var bad_body = ["/body", "/body_user", "/ib/1", "/ib_user?id=1", "/save/1"]
    var missing = [
        ("GET", "/int/", ""),
        ("POST", "/ib/", "Ada"),
        ("GET", "/stale/1/2", ""),
        ("GET", "/nowhere", ""),
    ]
    var mismatched = [
        ("POST", "/none", "", "GET, HEAD"),
        ("GET", "/body", "Ada", "POST"),
        ("PUT", "/ib_user/1", "Ada", "POST"),
    ]
    for fail in [False, True]:
        for r in bad:
            _reset()
            if fail:
                _ = setenv(FAIL, "1")
            _expect(app, r[0], r[1], r[2], 400, "Bad Request")
            assert_equal(_count(FROM_BODY), 0, r[1])
            assert_equal(_count(HANDLER), 0, r[1])
            assert_equal(_count(ERROR_CONVERSIONS), 0, r[1])
            assert_equal(_count(CONVERSIONS), 0, r[1])
        for target in bad_body:
            _reset()
            if fail:
                _ = setenv(FAIL, "1")
            _expect(app, "POST", target, "", 400, "Bad Request")
            assert_equal(_count(FROM_BODY), 1, target)
            assert_equal(_count(HANDLER), 0, target)
            assert_equal(_count(ERROR_CONVERSIONS), 0, target)
            assert_equal(_count(CONVERSIONS), 0, target)
        for r in missing:
            _reset()
            if fail:
                _ = setenv(FAIL, "1")
            _expect(app, r[0], r[1], r[2], 404, "Not Found")
            assert_equal(_count(FROM_BODY), 0, r[1])
            assert_equal(_count(HANDLER), 0, r[1])
            assert_equal(_count(ERROR_CONVERSIONS), 0, r[1])
            assert_equal(_count(CONVERSIONS), 0, r[1])
        for r in mismatched:
            _reset()
            if fail:
                _ = setenv(FAIL, "1")
            _expect(app, r[0], r[1], r[2], 405, "Method Not Allowed")
            var allow = app.handle(Request(r[0], r[1], r[2])).headers.get_all(
                "Allow"
            )
            assert_equal(len(allow), 1, r[1])
            assert_equal(allow[0], r[3], r[1])
            assert_equal(_count(FROM_BODY), 0, r[1])
            assert_equal(_count(HANDLER), 0, r[1])
            assert_equal(_count(ERROR_CONVERSIONS), 0, r[1])
            assert_equal(_count(CONVERSIONS), 0, r[1])
    _reset()


def test_test_client_is_the_backend_seam() raises:
    var app = error_response_app()
    var client = TestClient(app)
    for fail in [False, True]:
        for c in _shape_cases():
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
