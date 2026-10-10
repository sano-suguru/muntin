# M2-014 raw-Request decision spike, application side. Handlers and their error
# types live here; the library side (tests/raw_spike.mojo) never names them.
# Decision and evidence: docs/history/architecture-decisions.md, "Raw Request
# decision (M2-014)".

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_true, TestSuite

from muntin import FromBody, Request, Response, ToErrorResponse, ToResponse
from raw_spike import RawApp

# Handlers are thin functions and cannot capture state, so calls are
# counted in environment variables.
comptime FROM_BODY = "MUNTIN_TEST_SPIKE_RAW_FROM_BODY"
comptime HANDLER = "MUNTIN_TEST_SPIKE_RAW_HANDLER"


def _reset():
    for name in [FROM_BODY, HANDLER]:
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


# Application types.


@fieldwise_init
struct User(Movable, ToResponse):
    var id: Int

    def to_response(var self) -> Response:
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


@fieldwise_init
struct BadSignature(Movable, ToErrorResponse):
    var reason: String

    def to_error_response(var self) -> Response:
        return Response.text("bad signature: " + self.reason, status=401)


@fieldwise_init
struct Unmapped(Movable):
    """Declares no error-response conformance: a raise is the fixed 500."""

    var reason: String


# Raw handlers.


def _spliced(head: String, body: List[UInt8], tail: String = "") -> List[UInt8]:
    """`head`'s bytes, the body bytes unread, then `tail`'s bytes."""
    var out = List(head.as_bytes())
    out.extend(Span(body))
    out.extend(Span(tail.as_bytes()))
    return out^


def _fields(req: Request) -> List[UInt8]:
    return _spliced(
        req.method + "|" + req.path + "|" + req.query + "|", req.body
    )


def echo(req: Request) -> Response:
    _bump(HANDLER)
    return Response(202, _fields(req))


def take_body(var req: Request) -> Response:
    """Owns the request and moves its body into the response."""
    _bump(HANDLER)
    var body = req.body^
    req.body = List[UInt8]()
    return Response(201, body^)


def verify(req: Request) raises -> Response:
    _bump(HANDLER)
    if req.text() != "signed":
        raise Error("secret key mismatch")
    return Response.text("verified")


def verify_typed(req: Request) raises BadSignature -> Response:
    _bump(HANDLER)
    if Span(req.body) != "signed".as_bytes():
        raise BadSignature("unsigned")
    return Response.text("verified")


def verify_unmapped(req: Request) raises Unmapped -> Response:
    _bump(HANDLER)
    raise Unmapped("secret")


def first(req: Request) -> Response:
    return Response.text("raw")


# Typed handlers, one per production shape.


def hello() -> String:
    return "hello"


def hello_static() -> StaticString:
    return "static"


def teapot() -> Response:
    return Response.text("teapot", status=418)


def get_user(id: Int) -> User:
    return User(id)


def get_text(id: Int) -> String:
    return "id " + String(id)


def create(body: Name) -> String:
    _bump(HANDLER)
    return "created " + body.text


def create_response(var body: Name) -> Response:
    _bump(HANDLER)
    return Response.text("made " + body.text, status=201)


def update(id: Int, body: Name) -> String:
    return String(id) + " " + body.text


def update_user(id: Int, var body: Name) -> User:
    return User(id)


def typed_first(body: Name) -> String:
    return "typed"


def _app() -> RawApp:
    var app = RawApp()
    app.get["/raw"](echo)
    app.post["/webhook"](echo)
    app.post["/take"](take_body)
    app.post["/verify"](verify)
    app.post["/verify_typed"](verify_typed)
    app.post["/verify_unmapped"](verify_unmapped)
    app.get["/hello"](hello)
    app.get["/static"](hello_static)
    app.get["/teapot"](teapot)
    app.get["/users/{id}"](get_user)
    app.get["/items?{id}"](get_text)
    app.post["/users"](create)
    app.post["/made"](create_response)
    app.post["/users/{id}"](update)
    app.post["/profiles?{id}"](update_user)
    return app^


def test_raw_handlers_receive_the_whole_request() raises:
    _reset()
    var app = _app()
    var targets = ["/webhook", "/webhook?", "/webhook?a?b=c?", "/webhook?x=1&x"]
    for t in targets:
        var sent = Request("POST", t, " payload?\n")
        var r = app.handle(sent)
        assert_equal(r.status, 202)
        assert_equal(r.body, _fields(sent))
    var g = Request("GET", "/raw?id=abc")
    assert_equal(app.handle(g).body, _fields(g))
    assert_equal(_count(HANDLER), 5)


def test_borrowed_and_owned_requests_register() raises:
    var app = _app()
    var r = app.handle(Request("POST", "/take", "moved"))
    assert_equal(r.status, 201)
    assert_equal(r.text(), "moved")


def test_raw_routes_run_no_typed_extraction() raises:
    _reset()
    var app = _app()
    # An empty body fails `Name.from_body` and a non-integer `id` fails
    # `_parse_int`; neither runs for a raw route.
    var r = app.handle(Request("POST", "/webhook?id=abc", ""))
    assert_equal(r.status, 202)
    assert_equal(_count(FROM_BODY), 0)
    assert_equal(_count(HANDLER), 1)


def test_raw_routes_run_only_after_route_selection() raises:
    _reset()
    var app = _app()
    assert_equal(app.handle(Request("GET", "/webhook")).status, 404)
    assert_equal(app.handle(Request("POST", "/raw")).status, 404)
    assert_equal(app.handle(Request("POST", "/webhook/x")).status, 404)
    assert_equal(_count(HANDLER), 0)


def test_raw_raise_is_the_fixed_500() raises:
    var app = _app()
    var r = app.handle(Request("POST", "/verify", "forged"))
    assert_equal(r.status, 500)
    assert_equal(r.text(), "Internal Server Error")
    assert_equal(app.handle(Request("POST", "/verify", "signed")).status, 200)
    var u = app.handle(Request("POST", "/verify_unmapped"))
    assert_equal(u.status, 500)
    assert_equal(u.text(), "Internal Server Error")


def test_raw_raise_uses_to_error_response() raises:
    var app = _app()
    var r = app.handle(Request("POST", "/verify_typed", "forged"))
    assert_equal(r.status, 401)
    assert_equal(r.text(), "bad signature: unsigned")
    var ok = app.handle(Request("POST", "/verify_typed", "signed"))
    assert_equal(ok.status, 200)
    assert_equal(ok.text(), "verified")


def test_typed_shapes_are_unchanged_beside_raw() raises:
    _reset()
    var app = _app()
    assert_equal(app.handle(Request("GET", "/hello")).text(), "hello")
    assert_equal(app.handle(Request("GET", "/static")).text(), "static")
    assert_equal(app.handle(Request("GET", "/teapot")).status, 418)
    assert_equal(app.handle(Request("GET", "/users/7")).text(), "User(7)")
    assert_equal(app.handle(Request("GET", "/users/x")).status, 400)
    assert_equal(app.handle(Request("GET", "/items?id=3")).text(), "id 3")
    assert_equal(
        app.handle(Request("POST", "/users", "ann")).text(), "created ann"
    )
    assert_equal(app.handle(Request("POST", "/users", "")).status, 400)
    # A typed body handler returning `Response` still reaches the generic
    # body overload: `Name` is not `Request`, so no raw overload is viable.
    var made = app.handle(Request("POST", "/made", "bob"))
    assert_equal(made.status, 201)
    assert_equal(made.text(), "made bob")
    assert_equal(app.handle(Request("POST", "/users/4", "cy")).text(), "4 cy")
    var p = app.handle(Request("POST", "/profiles?id=9", "dee"))
    assert_equal(p.text(), "User(9)")
    assert_equal(_count(FROM_BODY), 5)
    assert_equal(_count(HANDLER), 2)


def test_first_registered_route_wins_across_kinds() raises:
    var raw_first = RawApp()
    raw_first.post["/same"](first)
    raw_first.post["/same"](typed_first)
    assert_equal(raw_first.handle(Request("POST", "/same", "x")).text(), "raw")
    var typed = RawApp()
    typed.post["/same"](typed_first)
    typed.post["/same"](first)
    assert_equal(typed.handle(Request("POST", "/same", "x")).text(), "typed")
    # The typed route still answers its own 400; a matched route never
    # falls through to a later one.
    assert_equal(typed.handle(Request("POST", "/same", "")).status, 400)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
