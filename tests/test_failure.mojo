# Reports of dropped errors (M3-059): each fixed 500 `src/muntin` makes on a
# reachable path carries a `Failure` that `Response.failure()` returns and
# middleware reads, through `App.handle` and `TestClient`; the client's
# status, body and fields are unchanged. Contract:
# docs/history/architecture-decisions.md, "Dropped error report decision
# (M3-058)", "Next production slice", and "Dropped error report amendment
# (M3-059)", whose two limits are pinned here too; semantics:
# docs/reference/errors.md and docs/reference/middleware.md.
# Not reachable here, so not tested: a raise out of a route's `invoke`, which
# no adapter makes, and a failed `Allow` write.

from std.sys import stderr
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import (
    App,
    Failure,
    FromBody,
    FromBytes,
    FromJson,
    Headers,
    Json,
    JsonValue,
    JsonWriter,
    Next,
    Request,
    Response,
    ToErrorResponse,
    ToJson,
)
from muntin.http import _Field
from muntin.testing import TestClient


# Application types and handlers.


@fieldwise_init
struct Denied(Movable, Writable):
    """An application error type that is `Writable` and does not convert."""

    var who: String

    def write_to(self, mut writer: Some[Writer]):
        writer.write("denied ", self.who)


@fieldwise_init
struct Opaque(Movable):
    """An application error type that is neither `Writable` nor converted."""

    var code: Int


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):
    """A converted error: its own 500 carries no report."""

    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("gone " + String(self.id), status=500)


@fieldwise_init
struct Secret(ToJson):
    """A result whose serialization raises."""

    var text: String

    def write_json(self, mut out: JsonWriter) raises:
        raise Error("cannot write " + self.text)


@fieldwise_init
struct Unfinished(ToJson):
    """A result that leaves the writer unbalanced."""

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()


@fieldwise_init
struct Point(FromJson, ToJson):
    var x: Int

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["x"].int())

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("x")
        out.int(self.x)
        out.end_object()


@fieldwise_init
struct Configured(FromBody):
    """A body conversion that fails for a server-side reason, whatever the
    client sent."""

    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        raise Error("no parser configured")


struct Tiny(FromBytes):
    comptime max_bytes = 4

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body.copy())


def find_order(id: Int) raises -> String:
    if id == 0:
        raise Error("database password is hunter2")
    return "order " + String(id)


def deny() raises Denied -> String:
    raise Denied("ada")


def opaque() raises Opaque -> String:
    raise Opaque(7)


def missing(id: Int) raises NotFound -> String:
    raise NotFound(id)


def own_500() -> Response:
    return Response.text("busy", status=500)


def secret() -> Json[Secret]:
    return Json(Secret("token=abc"))


def unfinished() -> Json[Unfinished]:
    return Json(Unfinished())


def created_secret() -> Response:
    """A `Json[T]` converted, then given another status: the report stays
    with the response."""
    var r = Json(Secret("token=abc")).to_response()
    r.status = 201
    return r^


def fields(headers: Headers) -> String:
    return String(len(headers))


def raw(request: Request) -> Response:
    return Response.text("raw " + request.path)


def echo_point(body: Json[Point]) -> Json[Point]:
    return Json(Point(body.value.x))


def upload(body: Tiny) -> String:
    return String(len(body.data))


def hello() -> String:
    return "hello"


def configured(body: Configured) -> String:
    return body.text


def fail_with(value: String) raises -> String:
    raise Error("no " + value)


# Middleware.


def failing(var request: Request, var next: Next) raises -> Response:
    """Raises on `/mw` before the rest runs; passes every other request."""
    if request.path == "/mw":
        raise Error("middleware detail")
    return next^.run(request^)


def observed(var request: Request, var next: Next) raises -> Response:
    """Registered outside `failing`: reads the report its `next` returns and
    writes its source into a field, so a test sees that it read it."""
    var response = next^.run(request^)
    var failure = response.failure()
    if failure:
        response.headers.add("X-Seen", failure.value().source)
    return response^


def unavailable(var request: Request, var next: Next) raises -> Response:
    """Turns any 500 into a 503, in place: the report stays."""
    var response = next^.run(request^)
    if response.status == 500:
        response.status = 503
    return response^


def replaced(var request: Request, var next: Next) raises -> Response:
    """Answers any 500 with a new response: the report goes."""
    var response = next^.run(request^)
    if response.status == 500:
        return Response.text("sorry", status=500)
    return response^


def raising_after(var request: Request, var next: Next) raises -> Response:
    """Raises when the rest answered 500: its own report replaces the one it
    received."""
    var response = next^.run(request^)
    if response.status == 500:
        raise Error("after 500")
    return response^


# docs/reference/middleware.md's logging middleware, as written.


def quoted(text: String) -> String:
    """`text` in double quotes, each byte outside printable ASCII, `"` and
    `\\` written as `\\xNN`: no control character reaches the log as itself.
    """
    var out = String('"')
    for b in text.as_bytes():
        var c = Int(b)
        if c < 0x20 or c > 0x7E or c == 0x22 or c == 0x5C:
            out += "\\x"
            for d in [c >> 4, c & 15]:
                out += chr(d + 48 if d < 10 else d + 87)
        else:
            out += chr(c)
    return out + '"'


def failure_line(
    method: String, path: String, request_id: String, failure: Failure
) -> String:
    # Every value but `source` comes from the client or the error, so each is
    # quoted; masking secrets is the application's.
    return String(
        quoted(method),
        " ",
        quoted(path),
        " client-id=",
        quoted(request_id),
        " ",
        failure.source,
        ": ",
        quoted(failure.message),
    )


def log_failures(var request: Request, var next: Next) raises -> Response:
    var method = request.method  # kept: `next` takes the request
    var path = request.path
    var request_id = request.headers.get("X-Request-Id").or_else("-")
    var response = next^.run(request^)
    var failure = response.failure()
    if failure:
        print(
            failure_line(method, path, request_id, failure.value()),
            file=stderr,
        )
    return response^


def logged(var request: Request, var next: Next) raises -> Response:
    """`log_failures`, with the line put in a field instead of standard
    error, for the test to read."""
    var method = request.method
    var path = request.path
    var request_id = request.headers.get("X-Request-Id").or_else("-")
    var response = next^.run(request^)
    var failure = response.failure()
    if failure:
        response.headers.add(
            "X-Log", failure_line(method, path, request_id, failure.value())
        )
    return response^


# Helpers.


def _routes(mut app: App):
    app.get["/orders/{id}"](find_order)
    app.get["/deny"](deny)
    app.get["/opaque"](opaque)
    app.get["/missing/{id}"](missing)
    app.get["/own"](own_500)
    app.get["/secret"](secret)
    app.get["/unfinished"](unfinished)
    app.get["/created"](created_secret)
    app.get["/fields"](fields)
    app.get["/raw"](raw)
    app.post["/points"](echo_point)
    app.post["/upload"](upload)
    app.get["/hello"](hello)
    app.get["/fail/{value}"](fail_with)
    app.post["/configured"](configured)


def _gap() -> Headers:
    """Headers holding a field `Headers.add` would refuse: the M3-002
    `_fields` gap, the only way a rebuild fails."""
    var h = Headers()
    h._fields.append(_Field("Bad Name", "v"))
    return h^


def _assert_fixed_500(r: Response) raises:
    """The client's answer is the fixed 500, whatever the report says."""
    assert_equal(r.status, 500)
    assert_equal(r.text(), "Internal Server Error")
    assert_equal(len(r.headers), 0)


def _assert_report(r: Response, source: StaticString, message: String) raises:
    var failure = r.failure()
    assert_true(failure, "no report")
    assert_equal(failure.value().source, source)
    assert_equal(failure.value().message, message)


# Tests.


def test_handler_error_text() raises:
    var app = App()
    _routes(app)
    var r = TestClient(app).get("/orders/0")
    _assert_fixed_500(r)
    _assert_report(r, Failure.HANDLER, "database password is hunter2")
    assert_equal(
        String(r.failure().value()), "handler: database password is hunter2"
    )
    assert_false(r.failure().value().message in r.text())


def test_handler_error_writable_type() raises:
    var app = App()
    _routes(app)
    var r = TestClient(app).get("/deny")
    _assert_fixed_500(r)
    _assert_report(r, Failure.HANDLER, "denied ada")


def test_handler_error_other_type_is_its_name() raises:
    var app = App()
    _routes(app)
    var r = TestClient(app).get("/opaque")
    _assert_fixed_500(r)
    _assert_report(r, Failure.HANDLER, "<test_failure.Opaque>")


def test_middleware_raise_read_by_the_middleware_outside() raises:
    var app = App()
    app.use(observed)
    app.use(failing)
    _routes(app)
    var r = TestClient(app).get("/mw")
    assert_equal(r.status, 500)
    assert_equal(r.text(), "Internal Server Error")
    assert_equal(r.headers.get("X-Seen").value(), "middleware")
    _assert_report(r, Failure.MIDDLEWARE, "middleware detail")


def test_outermost_middleware_raise_reaches_the_caller() raises:
    # No middleware is outside it; `App.handle` returns the report.
    var app = App()
    app.use(failing)
    _routes(app)
    var r = TestClient(app).get("/mw")
    _assert_fixed_500(r)
    _assert_report(r, Failure.MIDDLEWARE, "middleware detail")
    assert_equal(String(r.failure().value()), "middleware: middleware detail")


def test_json_serialization_failure() raises:
    var app = App()
    _routes(app)
    var client = TestClient(app)
    var r = client.get("/secret")
    _assert_fixed_500(r)
    _assert_report(r, Failure.RESPONSE, "cannot write token=abc")
    assert_equal(
        String(r.failure().value()), "response: cannot write token=abc"
    )
    r = client.get("/unfinished")
    _assert_fixed_500(r)
    _assert_report(r, Failure.RESPONSE, "JSON writer: incomplete document")


def test_rebuild_failure_through_the_fields_gap() raises:
    var app = App()
    _routes(app)
    var client = TestClient(app)
    for target in ["/fields", "/raw"]:
        var r = client.get(target, headers=_gap())
        _assert_fixed_500(r)
        _assert_report(
            r,
            Failure.MUNTIN,
            "the request's header fields could not be rebuilt",
        )
        assert_equal(
            String(r.failure().value()),
            "muntin: the request's header fields could not be rebuilt",
        )


def test_no_report_where_nothing_was_dropped() raises:
    var app = App()
    _routes(app)
    var client = TestClient(app)
    var json = Headers()
    json.add("Content-Type", "application/json")
    var cases: List[Response] = [
        client.get("/hello"),  # 200
        client.get("/missing/3"),  # a converted error's own 500
        client.get("/own"),  # the application's own 500
        client.get("/orders/x"),  # 400
        client.get("/nowhere"),  # 404
        client.post("/hello", ""),  # 405
        client.post("/upload", "12345"),  # 413
        client.post("/points", '{"x":1}'),  # 415
        client.post("/points", "{", headers=json^),  # 400
    ]
    var statuses: List[Int] = [200, 500, 500, 400, 404, 405, 413, 415, 400]
    for i in range(len(cases)):
        assert_equal(cases[i].status, statuses[i], String(i))
        assert_false(cases[i].failure(), String(i))
    assert_equal(cases[1].text(), "gone 3")


def test_response_built_by_the_application_has_none() raises:
    assert_false(Response.text("x").failure())
    assert_false(Response(500, "Internal Server Error").failure())
    assert_false(Response(200, List[UInt8]()).failure())
    assert_false(Json(Point(1)).to_response().failure())


def test_head_and_copy_keep_the_report() raises:
    var app = App()
    _routes(app)
    var client = TestClient(app)
    var head = client.head("/orders/0")
    _assert_fixed_500(head)
    _assert_report(head, Failure.HANDLER, "database password is hunter2")
    var copy = head.copy()
    _assert_report(copy, Failure.HANDLER, "database password is hunter2")
    # The returned report is a copy: editing it leaves the response's.
    var failure = copy.failure()
    failure.value().message = "edited"
    _assert_report(copy, Failure.HANDLER, "database password is hunter2")


def test_edits_keep_the_report() raises:
    var app = App()
    _routes(app)
    var r = TestClient(app).get("/created")
    assert_equal(r.status, 201)
    assert_equal(r.text(), "Internal Server Error")
    _assert_report(r, Failure.RESPONSE, "cannot write token=abc")


def test_middleware_changing_the_status_keeps_the_report() raises:
    var app = App()
    app.use(unavailable)
    _routes(app)
    var r = TestClient(app).get("/orders/0")
    assert_equal(r.status, 503)
    assert_equal(r.text(), "Internal Server Error")
    _assert_report(r, Failure.HANDLER, "database password is hunter2")


def test_middleware_building_a_new_response_drops_the_report() raises:
    var app = App()
    app.use(replaced)
    _routes(app)
    var r = TestClient(app).get("/orders/0")
    assert_equal(r.status, 500)
    assert_equal(r.text(), "sorry")
    assert_false(r.failure())


def test_outermost_logging_middleware() raises:
    var app = App()
    app.use(logged)
    app.use(failing)
    _routes(app)
    var client = TestClient(app)
    var id = Headers()
    id.add("X-Request-Id", "r-1")
    var r = client.get("/orders/0?q=1", headers=id^)
    assert_equal(r.status, 500)
    assert_equal(r.text(), "Internal Server Error")
    assert_equal(
        r.headers.get("X-Log").value(),
        (
            '"GET" "/orders/0" client-id="r-1" handler: "database password is'
            ' hunter2"'
        ),
    )
    r = client.get("/mw")
    assert_equal(
        r.headers.get("X-Log").value(),
        '"GET" "/mw" client-id="-" middleware: "middleware detail"',
    )
    r = client.get("/orders/1")
    assert_equal(r.text(), "order 1")
    assert_false(r.headers.get("X-Log"))


def test_logger_misses_a_report_an_inner_middleware_replaces() raises:
    """A limit docs/reference/errors.md states: the logger reads only the report
    on the response it receives."""
    var app = App()
    app.use(logged)
    app.use(replaced)
    _routes(app)
    var r = TestClient(app).get("/orders/0")
    assert_equal(r.status, 500)
    assert_equal(r.text(), "sorry")
    assert_false(r.failure())
    assert_false(r.headers.get("X-Log"))


def test_logger_reads_only_the_last_of_two_failures() raises:
    """The handler fails, then a middleware raises: only the middleware's
    report reaches the logger (docs/reference/errors.md)."""
    var app = App()
    app.use(logged)
    app.use(raising_after)
    _routes(app)
    var r = TestClient(app).get("/orders/0")
    _assert_report(r, Failure.MIDDLEWARE, "after 500")
    assert_equal(
        r.headers.get("X-Log").value(),
        '"GET" "/orders/0" client-id="-" middleware: "after 500"',
    )


def test_server_side_body_conversion_failure_is_an_unreported_400() raises:
    """A limit docs/reference/errors.md states: Muntin cannot tell a
    conversion's own failure from bad input."""
    var app = App()
    app.use(logged)
    _routes(app)
    var r = TestClient(app).post("/configured", "valid")
    assert_equal(r.status, 400)
    assert_false(r.failure())
    assert_false(r.headers.get("X-Log"))


def test_dx_logging_example() raises:
    var app = App()
    app.use(log_failures)
    app.use(failing)
    _routes(app)
    var client = TestClient(app)
    var id = Headers()
    id.add("X-Request-Id", "r-1")
    var r = client.get("/orders/0", headers=id^)
    _assert_fixed_500(r)
    _assert_report(r, Failure.HANDLER, "database password is hunter2")
    assert_equal(client.get("/orders/1").text(), "order 1")


def _assert_inert(line: String) raises:
    """Every byte of `line` is printable ASCII."""
    for b in line.as_bytes():
        assert_true(Int(b) >= 0x20 and Int(b) <= 0x7E, line)


def test_failure_line_escapes_every_value() raises:
    var line = failure_line(
        "G\x1bET",
        "/a\x1b[2Kforged\u009b",
        "a\nb\tc",
        Failure(_source=Failure.HANDLER, _message="bad\r\nX: 1\x7f\u202e"),
    )
    _assert_inert(line)
    assert_equal(
        line,
        (
            '"G\\x1bET" "/a\\x1b[2Kforged\\xc2\\x9b" client-id="a\\x0ab\\x09c"'
            ' handler: "bad\\x0d\\x0aX: 1\\x7f\\xe2\\x80\\xae"'
        ),
    )
    assert_equal(quoted('say "\\"'), '"say \\x22\\x5c\\x22"')
    # Why the example does not use `repr`: it leaves a C1 control as it is.
    assert_true("\u009b" in repr(String("\u009b")))


def test_logged_line_escapes_client_values() raises:
    """Client-controlled method, path, request ID and error text, through
    `App.handle`: none reaches the line as itself."""
    var app = App()
    app.use(logged)
    app.use(failing)
    _routes(app)
    var client = TestClient(app)
    var id = Headers()
    id.add("X-Request-Id", "r\t1\u009b")
    var r = client.get("/fail/a\x1b[2Kforged", headers=id^)
    assert_equal(r.status, 500)
    _assert_report(r, Failure.HANDLER, "no a\x1b[2Kforged")
    var line = r.headers.get("X-Log").value()
    _assert_inert(line)
    assert_equal(
        line,
        (
            '"GET" "/fail/a\\x1b[2Kforged" client-id="r\\x091\\xc2\\x9b"'
            ' handler: "no a\\x1b[2Kforged"'
        ),
    )
    r = app.handle(Request("G\x1bET", "/mw", "", Headers()))
    _assert_report(r, Failure.MIDDLEWARE, "middleware detail")
    line = r.headers.get("X-Log").value()
    _assert_inert(line)
    assert_equal(
        line, '"G\\x1bET" "/mw" client-id="-" middleware: "middleware detail"'
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
