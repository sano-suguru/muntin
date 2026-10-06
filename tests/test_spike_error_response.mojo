# M2-012 error-response decision spike, application side. Handlers and
# their error types live here; the library side
# (tests/error_response_spike.mojo) never names them. Decision and evidence:
# docs/history/architecture-decisions.md, "Error-response decision (M2-012)".

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_false, TestSuite

from muntin import App, FromBody, Request, Response, ToResponse
from muntin.testing import TestClient
from error_response_spike import ErrorResponseApp, ToErrorResponse

# Handlers are thin functions and cannot capture state, so calls are
# counted in environment variables.
comptime FROM_BODY = "MUNTIN_TEST_SPIKE_ERROR_RESPONSE_FROM_BODY"
comptime HANDLER = "MUNTIN_TEST_SPIKE_ERROR_RESPONSE_HANDLER"
comptime CONVERSIONS = "MUNTIN_TEST_SPIKE_ERROR_RESPONSE_CONVERSIONS"
comptime ERROR_CONVERSIONS = "MUNTIN_TEST_SPIKE_ERROR_RESPONSE_ERRORS"


def _reset():
    for name in [FROM_BODY, HANDLER, CONVERSIONS, ERROR_CONVERSIONS]:
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


# Results and bodies.


@fieldwise_init
struct User(Movable, ToResponse):
    var id: Int

    def to_response(var self) -> Response:
        _bump(CONVERSIONS)
        return Response.text("User(" + String(self.id) + ")")


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


# Error types that opt in: each declares `ToErrorResponse` (directly or
# through a refining trait) in its own struct declaration.


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):
    """Move-only (not `Copyable`); converts with its own data."""

    var id: Int

    def to_error_response(var self) -> Response:
        _bump(ERROR_CONVERSIONS)
        return Response.text("no user " + String(self.id), status=404)


struct Locked(ToErrorResponse):
    """Declares no trait but `ToErrorResponse` and is not `Copyable` (Mojo
    1.1.0 makes every struct `Movable` implicitly)."""

    var id: Int

    def __init__(out self, id: Int):
        self.id = id

    def to_error_response(var self) -> Response:
        _bump(ERROR_CONVERSIONS)
        return Response.text("locked " + String(self.id), status=423)


trait ApiFailure(ToErrorResponse):
    """An application's own refinement: conforming to it is conforming to
    `ToErrorResponse`."""

    pass


struct ApiError(ApiFailure, Movable):
    """One application error type with several kinds, converted in one
    place (Mojo functions declare one error type). `deinit self` moves a
    field out, which a `var self` method cannot on 1.1.0 (M2-007)."""

    var kind: Int
    var message: String

    def __init__(out self, kind: Int, var message: String):
        self.kind = kind
        self.message = message^

    def to_error_response(deinit self) -> Response:
        _bump(ERROR_CONVERSIONS)
        var status = 409 if self.kind == 1 else 422
        return Response.text(self.message^, status=status)


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
    """Opted in, and `Writable`, so Mojo 1.1.0 erases it to `Error` when it
    propagates out of a bare-`raises` function."""

    var id: Int

    def write_to(self, mut writer: Some[Writer]):
        writer.write("erasable ", self.id)

    def to_error_response(var self) -> Response:
        _bump(ERROR_CONVERSIONS)
        return Response.text("erasable", status=404)


# Error types that do not opt in: today's fixed 500 must hold for them.


@fieldwise_init
struct Rejected(Movable):
    var id: Int


@fieldwise_init
struct Gone(Movable, ToResponse):
    """`ToResponse` only: converts when returned, never when raised."""

    var id: Int

    def to_response(var self) -> Response:
        _bump(CONVERSIONS)
        return Response.text("gone " + String(self.id), status=410)


@fieldwise_init
struct Lookalike(Movable):
    """Has a `to_error_response` method but declares no conformance; Mojo
    traits are nominal, so it never runs."""

    var id: Int

    def to_error_response(var self) -> Response:
        _bump(ERROR_CONVERSIONS)
        return Response.text("lookalike", status=404)


# Handlers. Each raises for 0 and succeeds otherwise.


def plain_text(id: Int) -> String:
    _bump(HANDLER)
    return "text " + String(id)


def plain_user(id: Int) -> User:
    _bump(HANDLER)
    return User(id)


def find_user(id: Int) raises NotFound -> User:
    _bump(HANDLER)
    if id == 0:
        raise NotFound(id)
    return User(id)


def find_name(id: Int) raises NotFound -> String:
    _bump(HANDLER)
    if id == 0:
        raise NotFound(id)
    return "name " + String(id)


def lock(id: Int) raises Locked -> String:
    _bump(HANDLER)
    if id == 0:
        raise Locked(id)
    return "unlocked"


def update(id: Int, var body: Name) raises ApiError -> User:
    _bump(HANDLER)
    if id == 0:
        raise ApiError(1, "conflict on " + body.text)
    return User(id)


def rename(id: Int, body: Name) raises ApiError -> String:
    _bump(HANDLER)
    if id == 0:
        raise ApiError(2, "invalid name " + body.text)
    return "renamed " + body.text


def check(id: Int) raises Stale -> Stale:
    _bump(HANDLER)
    if id == 0:
        raise Stale(id)
    return Stale(id)


def reject(id: Int) raises Rejected -> User:
    _bump(HANDLER)
    if id == 0:
        raise Rejected(id)
    return User(id)


def gone(id: Int) raises Gone -> Gone:
    _bump(HANDLER)
    if id == 0:
        raise Gone(id)
    return Gone(id)


def look(id: Int) raises Lookalike -> String:
    _bump(HANDLER)
    if id == 0:
        raise Lookalike(id)
    return "look"


def fail(id: Int) raises -> String:
    _bump(HANDLER)
    if id == 0:
        raise Error("database password is hunter2")
    return "ok"


def _find_erasable(id: Int) raises Erasable -> String:
    if id == 0:
        raise Erasable(id)
    return "found"


def erased(id: Int) raises -> String:
    """Declares bare `raises`: the `Erasable` raised inside arrives as
    `Error`."""
    _bump(HANDLER)
    return _find_erasable(id)


def make_app() -> ErrorResponseApp:
    var app = ErrorResponseApp()
    app.get["/text/{id}"](plain_text)
    app.get["/plain/{id}"](plain_user)
    app.get["/users/{id}"](find_user)
    app.get["/names?{id}"](find_name)
    app.get["/locks/{id}"](lock)
    app.post["/users/{id}"](update)
    app.post["/names/{id}"](rename)
    app.get["/stale/{id}"](check)
    app.get["/rejected/{id}"](reject)
    app.get["/gone/{id}"](gone)
    app.get["/look/{id}"](look)
    app.get["/fail/{id}"](fail)
    app.get["/erased/{id}"](erased)
    return app^


def _expect(
    app: ErrorResponseApp,
    method: String,
    target: String,
    status: Int,
    body: String,
    request_body: String = "Ada",
) raises:
    var response = app.handle(Request(method, target, request_body))
    assert_equal(response.status, status, method + " " + target)
    assert_equal(response.body, body, method + " " + target)


def _expect_counts(handler: Int, conversions: Int, errors: Int) raises:
    assert_equal(_count(HANDLER), handler, "handler calls")
    assert_equal(_count(CONVERSIONS), conversions, "result conversions")
    assert_equal(_count(ERROR_CONVERSIONS), errors, "error conversions")


def test_successful_results_are_unchanged() raises:
    # Non-raising handlers (`E = Never`) and opted-in raising handlers that
    # return: `String` is a 200 text response, `ToResponse` converts once,
    # the error conversion never runs.
    var app = make_app()
    _reset()
    _expect(app, "GET", "/text/1", 200, "text 1")
    _expect(app, "GET", "/plain/1", 200, "User(1)")
    _expect(app, "GET", "/users/2", 200, "User(2)")
    _expect(app, "GET", "/names?id=3", 200, "name 3")
    _expect(app, "GET", "/locks/1", 200, "unlocked")
    _expect(app, "POST", "/users/4", 200, "User(4)")
    _expect(app, "POST", "/names/5", 200, "renamed Ada")
    _expect_counts(handler=7, conversions=3, errors=0)


def test_opted_in_error_types_convert_themselves() raises:
    # Move-only, undeclared-trait and refinement-conforming error types, with
    # `String` and `ToResponse` results, on GET `def(Int)` (path and query
    # value) and POST `def(Int, B)`: the error converts once, the result
    # conversion never runs.
    var app = make_app()
    _reset()
    _expect(app, "GET", "/users/0", 404, "no user 0")
    _expect(app, "GET", "/names?id=0", 404, "no user 0")
    _expect(app, "GET", "/locks/0", 423, "locked 0")
    _expect(app, "POST", "/users/0", 409, "conflict on Ada")
    _expect(app, "POST", "/names/0", 422, "invalid name Ada")
    _expect_counts(handler=5, conversions=0, errors=5)
    comptime assert conforms_to(ApiError, ToErrorResponse)
    assert_false(conforms_to(NotFound, Copyable))
    assert_false(conforms_to(Locked, Copyable))


def test_types_that_do_not_opt_in_stay_a_fixed_500() raises:
    # A plain error type, a `ToResponse` type (its `to_response` does not
    # run when raised), and a type with a same-named method but no
    # conformance: the fixed 500, nothing converted.
    var app = make_app()
    _reset()
    _expect(app, "GET", "/rejected/0", 500, "Internal Server Error")
    _expect(app, "GET", "/gone/0", 500, "Internal Server Error")
    _expect(app, "GET", "/look/0", 500, "Internal Server Error")
    _expect_counts(handler=3, conversions=0, errors=0)
    # Returned, `Gone` converts as any `ToResponse` result.
    _expect(app, "GET", "/gone/7", 410, "gone 7")
    _expect_counts(handler=4, conversions=1, errors=0)
    comptime assert conforms_to(Gone, ToResponse)
    comptime assert not conforms_to(Gone, ToErrorResponse)
    comptime assert not conforms_to(Lookalike, ToErrorResponse)


def test_returned_and_raised_values_use_their_own_channel() raises:
    # `Stale` conforms to both traits: returned, `to_response`; raised,
    # `to_error_response`. Neither implies the other.
    var app = make_app()
    _reset()
    _expect(app, "GET", "/stale/3", 200, "current 3")
    _expect_counts(handler=1, conversions=1, errors=0)
    _expect(app, "GET", "/stale/0", 409, "stale 0")
    _expect_counts(handler=2, conversions=1, errors=1)


def test_bare_raises_stays_a_fixed_500() raises:
    # `raises` is `Error`, which carries only text and cannot opt in. An
    # opted-in, `Writable` type raised inside a bare-`raises` handler is
    # erased to `Error` on the way out, so it is 500 too: the declared
    # error type decides, not what was thrown inside.
    var app = make_app()
    _reset()
    _expect(app, "GET", "/fail/0", 500, "Internal Server Error")
    _expect(app, "GET", "/erased/0", 500, "Internal Server Error")
    _expect_counts(handler=2, conversions=0, errors=0)
    _expect(app, "GET", "/fail/1", 200, "ok")
    _expect(app, "GET", "/erased/1", 200, "found")


def test_request_failures_and_404_are_unchanged() raises:
    # Opted-in handlers: a bad route value or body is 400 and no route is
    # 404, the handler and both conversions never run.
    var app = make_app()
    _reset()
    _expect(app, "GET", "/users/x", 400, "Bad Request")
    _expect(app, "GET", "/names", 400, "Bad Request")
    _expect(app, "GET", "/names?id=1&id=2", 400, "Bad Request")
    _expect(app, "POST", "/users/x", 400, "Bad Request")
    _expect(app, "POST", "/users/0", 400, "Bad Request", "")
    _expect(app, "GET", "/users", 404, "Not Found")
    _expect(app, "PUT", "/users/0", 404, "Not Found")
    _expect_counts(handler=0, conversions=0, errors=0)
    assert_equal(_count(FROM_BODY), 1, "from_body calls")


def test_opted_in_handlers_survive_app_moves() raises:
    var app = make_app()
    var moved = app^
    var apps = List[ErrorResponseApp]()
    apps.append(moved^)
    var last = apps.pop()
    _expect(last, "GET", "/users/0", 404, "no user 0")
    _expect(last, "GET", "/rejected/0", 500, "Internal Server Error")


# Keeping the fixed 500: what an application can already write on the
# production `App`, unchanged. A wrapper parameterized by the handler and a
# mapping function is itself a non-raising handler.


def not_found(var e: NotFound) -> Response:
    return Response.text("mapped " + String(e.id), status=404)


def mapped[
    E: Deinitable,
    R: ToResponse,
    //,
    handler: def(Int) thin raises E -> R,
    on_error: def(var E) thin -> Response,
](id: Int) -> Response:
    try:
        return handler(id).to_response()
    except e:
        return on_error(e^)


def test_application_wrapper_maps_errors_on_the_production_app() raises:
    # Works today, with production unchanged; the cost is one wrapper per
    # argument shape and the wrapper spelled at every registration.
    var app = App()
    app.get["/users/{id}"](mapped[find_user, not_found])
    var client = TestClient(app)
    var missing = client.get("/users/0")
    assert_equal(missing.status, 404)
    assert_equal(missing.text(), "mapped 0")
    assert_equal(client.get("/users/1").text(), "User(1)")
    assert_equal(client.get("/users/x").status, 400)
    # The production `App` has no error conversion: the same handler
    # registered directly is the fixed 500.
    app.get["/direct/{id}"](find_user)
    assert_equal(TestClient(app).get("/direct/0").status, 500)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
