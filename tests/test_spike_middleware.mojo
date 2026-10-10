# M3-034 middleware decision spike, application side. Middleware, handlers and
# application types live here; the library side (tests/middleware_spike.mojo)
# never names them. Every candidate runs against the same production `App` and
# the same request set. Decision and evidence: docs/history/architecture-decisions.md,
# "Middleware decision (M3-034)".

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import App, Request, Response, State
from middleware_spike import Middleware, MwApp, Next


# Application types and handlers.


struct Counter(Movable):
    """Counts handler calls; the application keeps the count mutable on
    purpose (its own `ArcPointer[Int]`), as tests/test_spike_state.mojo does."""

    var n: ArcPointer[Int]

    def __init__(out self):
        self.n = ArcPointer(0)


def hello() -> String:
    return "hello"


def get_user(id: Int) -> String:
    return "user " + String(id)


def boom() raises -> String:
    raise Error("internal detail")


def _spliced(head: String, body: List[UInt8], tail: String = "") -> List[UInt8]:
    """`head`'s bytes, the body bytes unread, then `tail`'s bytes."""
    var out = List(head.as_bytes())
    out.extend(Span(body))
    out.extend(Span(tail.as_bytes()))
    return out^


def echo(var request: Request) -> Response:
    return Response(200, _spliced(request.method + " ", request.body))


def trail(var request: Request) -> Response:
    """Answers with the request's `X-Trail` fields, in order."""
    return Response.text(",".join(request.headers.get_all("X-Trail")))


def counted(counter: State[Counter]) -> String:
    counter[].n[] += 1
    return "reached"


def _app(counter: State[Counter]) -> App:
    var app = App()
    app.get["/hello"](hello)
    app.get["/users/{id}"](get_user)
    app.get["/boom"](boom)
    app.post["/echo"](echo)
    app.get["/trail"](trail)
    app.get["/blocked"](counted, counter)
    app.get["/counted"](counted, counter)
    return app^


def _requests() -> List[Request]:
    """A matched route, a typed route, a 400 for a bad route value, 404, 405
    with `Allow`, `HEAD`, a handler raise and a body."""
    var r = List[Request]()
    r.append(Request("GET", "/hello"))
    r.append(Request("GET", "/users/7"))
    r.append(Request("GET", "/users/abc"))
    r.append(Request("GET", "/missing"))
    r.append(Request("POST", "/hello"))
    r.append(Request("HEAD", "/hello"))
    r.append(Request("GET", "/boom"))
    r.append(Request("POST", "/echo", "payload"))
    return r^


def _fields(r: Response) -> String:
    var out = String()
    for i in range(len(r.headers)):
        out += r.headers.name(i) + ": " + r.headers.value(i) + "; "
    return out


def _same(a: Response, b: Response, what: String) raises:
    assert_equal(a.status, b.status, what)
    assert_equal(a.body, b.body, what)
    assert_equal(_fields(a), _fields(b), what)


# F: middleware functions.


def passthrough(var request: Request, var next: Next) raises -> Response:
    return next^.run(request^)


def trail_a(var request: Request, var next: Next) raises -> Response:
    request.headers.add("X-Trail", "a")
    var response = next^.run(request^)
    response.headers.add("X-Back", "a")
    return response^


def trail_b(var request: Request, var next: Next) raises -> Response:
    request.headers.add("X-Trail", "b")
    var response = next^.run(request^)
    response.headers.add("X-Back", "b")
    return response^


def gate(var request: Request, var next: Next) raises -> Response:
    if request.path == "/blocked":
        return Response.text("Forbidden", status=403)
    return next^.run(request^)


def rewrite(var request: Request, var next: Next) raises -> Response:
    if request.path == "/old":
        request.path = "/hello"
    return next^.run(request^)


def stamp(var request: Request, var next: Next) raises -> Response:
    """Tags every answer with the method it saw."""
    var method = request.method
    var response = next^.run(request^)
    response.headers.add("X-Seen", method)
    return response^


def fail_before(var request: Request, var next: Next) raises -> Response:
    raise Error("middleware detail")


def fail_after(var request: Request, var next: Next) raises -> Response:
    _ = next^.run(request^)
    raise Error("middleware detail")


def tagged[
    value: StaticString
](var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    response.headers.add("X-Tag", value)
    return response^


# A and A': middleware structs.


@fieldwise_init
struct Tag(ImplicitlyCopyable, Middleware):
    var value: String

    def handle(self, var request: Request, var next: Next) raises -> Response:
        var response = next^.run(request^)
        response.headers.add("X-Tag", self.value)
        return response^


@fieldwise_init
struct Pass(ImplicitlyCopyable, Middleware):
    def handle(self, var request: Request, var next: Next) raises -> Response:
        return next^.run(request^)


@fieldwise_init
struct Gate(Middleware):
    var blocked: String

    def handle(self, var request: Request, var next: Next) raises -> Response:
        if request.path == self.blocked:
            return Response.text("Forbidden", status=403)
        return next^.run(request^)


struct Tracked(Middleware):
    """Counts its own drops in a count the test keeps."""

    var drops: ArcPointer[Int]

    def __init__(out self, drops: ArcPointer[Int]):
        self.drops = drops

    def __init__(out self, *, deinit move: Self):
        self.drops = move.drops^

    def __deinit__(deinit self):
        self.drops[] += 1

    def handle(self, var request: Request, var next: Next) raises -> Response:
        return next^.run(request^)


# H: hooks.


def no_early(request: Request) raises -> Optional[Response]:
    return None


def unchanged(request: Request, var response: Response) raises -> Response:
    return response^


def gate_before(request: Request) raises -> Optional[Response]:
    if request.path == "/blocked":
        return Response.text("Forbidden", status=403)
    return None


def stamp_after(request: Request, var response: Response) raises -> Response:
    response.headers.add("X-Seen", request.method)
    return response^


# Tests.


def test_no_middleware_answers_as_the_app() raises:
    var counter = State(Counter())
    var plain = _app(counter)
    var wrapped = MwApp(_app(counter))
    for request in _requests():
        _same(wrapped.handle(request), plain.handle(request), request.path)


def test_passthrough_answers_as_the_app_for_each_candidate() raises:
    var counter = State(Counter())
    var plain = _app(counter)
    var f = MwApp(_app(counter))
    f.use(passthrough)
    var a = MwApp(_app(counter))
    a.use(Pass())
    var a_static = MwApp(_app(counter))
    a_static.use[Pass()]()
    var h = MwApp(_app(counter))
    h.before(no_early)
    h.after(unchanged)
    for request in _requests():
        var expected = plain.handle(request)
        _same(f.handle(request), expected, "F " + request.path)
        _same(a.handle(request), expected, "A " + request.path)
        _same(a_static.handle(request), expected, "A' " + request.path)
        _same(h.handle(request), expected, "H " + request.path)


def test_middleware_sees_every_request() raises:
    # 404, 405, the pre-handler 400 and a handler's 500 all pass through
    # middleware, and `HEAD` arrives as `HEAD`.
    var counter = State(Counter())
    var f = MwApp(_app(counter))
    f.use(stamp)
    var h = MwApp(_app(counter))
    h.after(stamp_after)
    for request in _requests():
        assert_equal(
            f.handle(request).headers.get("X-Seen").or_else("<none>"),
            request.method,
            request.path,
        )
        assert_equal(
            h.handle(request).headers.get("X-Seen").or_else("<none>"),
            request.method,
            request.path,
        )
    assert_equal(f.handle(Request("GET", "/missing")).status, 404)
    var not_allowed = f.handle(Request("POST", "/hello"))
    assert_equal(not_allowed.status, 405)
    assert_equal(
        not_allowed.headers.get("Allow").or_else("<none>"), "GET, HEAD"
    )


def test_order_is_registration_order_outermost_first() raises:
    var counter = State(Counter())
    var f = MwApp(_app(counter))
    f.use(trail_a)
    f.use(trail_b)
    var r = f.handle(Request("GET", "/trail"))
    assert_equal(r.text(), "a,b")
    assert_equal(",".join(r.headers.get_all("X-Back")), "b,a")


def test_use_after_routes_is_the_same_chain() raises:
    # `MwApp` takes the routes as an `App`, so the order of `use` and route
    # registration cannot differ; production `App.use` would make the same
    # rule a statement: middleware wraps every route, whenever registered.
    var counter = State(Counter())
    var f = MwApp(_app(counter))
    f.use(stamp)
    f.app.get["/late"](hello)
    assert_equal(
        f.handle(Request("GET", "/late"))
        .headers.get("X-Seen")
        .or_else("<none>"),
        "GET",
    )


def _blocked_then_reached(app: MwApp) raises:
    var r = app.handle(Request("GET", "/blocked"))
    assert_equal(r.status, 403)
    assert_equal(r.text(), "Forbidden")
    assert_equal(app.handle(Request("GET", "/counted")).text(), "reached")


def test_short_circuit_skips_the_rest() raises:
    var counter = State(Counter())
    var f = MwApp(_app(counter))
    f.use(gate)
    var a = MwApp(_app(counter))
    a.use(Gate(String("/blocked")))
    var h = MwApp(_app(counter))
    h.before(gate_before)
    _blocked_then_reached(f)
    _blocked_then_reached(a)
    _blocked_then_reached(h)
    assert_equal(counter[].n[], 3)


def test_request_and_response_can_be_changed() raises:
    var counter = State(Counter())
    var f = MwApp(_app(counter))
    f.use(rewrite)
    f.use(tagged["v1"])
    var r = f.handle(Request("GET", "/old"))
    assert_equal(r.status, 200)
    assert_equal(r.text(), "hello")
    assert_equal(r.headers.get("X-Tag").or_else("<none>"), "v1")


def test_a_raise_in_middleware_is_the_fixed_500() raises:
    var counter = State(Counter())
    var before = MwApp(_app(counter))
    before.use(fail_before)
    var after = MwApp(_app(counter))
    after.use(fail_after)
    var r = before.handle(Request("GET", "/counted"))
    assert_equal(r.status, 500)
    assert_equal(r.text(), "Internal Server Error")
    assert_equal(counter[].n[], 0)
    r = after.handle(Request("GET", "/counted"))
    assert_equal(r.status, 500)
    assert_equal(r.text(), "Internal Server Error")
    assert_equal(counter[].n[], 1)


def test_a_raise_is_answered_at_the_failing_middleware() raises:
    # The inner middleware's raise becomes the 500 at its own call; the
    # outer one gets it from `next` and still adds its field.
    var counter = State(Counter())
    var f = MwApp(_app(counter))
    f.use(stamp)
    f.use(fail_before)
    var r = f.handle(Request("GET", "/counted"))
    assert_equal(r.status, 500)
    assert_equal(r.text(), "Internal Server Error")
    assert_equal(r.headers.get("X-Seen").or_else("<none>"), "GET")
    assert_equal(counter[].n[], 0)


def test_runtime_and_compile_time_configuration() raises:
    # A takes a value built at run time; F and A' take compile-time values.
    var counter = State(Counter())
    var suffix = String("time")
    var a = MwApp(_app(counter))
    a.use(Tag("run" + suffix))
    assert_equal(
        a.handle(Request("GET", "/hello"))
        .headers.get("X-Tag")
        .or_else("<none>"),
        "runtime",
    )
    var f = MwApp(_app(counter))
    f.use(tagged["compile"])
    assert_equal(
        f.handle(Request("GET", "/hello"))
        .headers.get("X-Tag")
        .or_else("<none>"),
        "compile",
    )
    var a_static = MwApp(_app(counter))
    a_static.use[Tag("static")]()
    assert_equal(
        a_static.handle(Request("GET", "/hello"))
        .headers.get("X-Tag")
        .or_else("<none>"),
        "static",
    )


def test_a_middleware_value_is_dropped_once_and_survives_moves() raises:
    var drops = ArcPointer(0)
    var counter = State(Counter())
    var a = MwApp(_app(counter))
    a.use(Tracked(drops))
    assert_equal(drops[], 0)
    var moved = a^
    var again = moved^
    assert_equal(again.handle(Request("GET", "/hello")).text(), "hello")
    assert_equal(drops[], 0)
    _ = again^
    assert_equal(drops[], 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
