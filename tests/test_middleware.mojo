# M3-035: middleware functions (`App.use`, `Next`) on production `App`,
# through `TestClient`. Contract: docs/history/architecture-decisions.md,
# "Middleware decision (M3-034)", "Next production slice"; semantics:
# docs/DX.md section 7. Must-not-build evidence: tests/middleware_api_fail.

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import App, Headers, Middleware, Next, Request, Response, State
from muntin.testing import TestClient


# Application types and handlers.


struct Counter(Movable):
    """Counts handler calls; the application keeps the count mutable on
    purpose (its own `ArcPointer[Int]`), as tests/test_state.mojo does."""

    var n: ArcPointer[Int]

    def __init__(out self):
        self.n = ArcPointer(0)


def hello() -> String:
    return "hello"


def get_user(id: Int) -> String:
    return "user " + String(id)


def boom() raises -> String:
    raise Error("handler detail")


def echo(var request: Request) raises -> Response:
    return Response.text(
        request.method + " " + request.path + " " + request.text()
    )


def report(request: Request) raises -> Response:
    """A raw route that answers with fields of its own."""
    var response = Response.text("report")
    response.headers.add("X-Report", "1")
    response.headers.add("Set-Cookie", "a=1")
    response.headers.add("Set-Cookie", "b=2")
    return response^


def trail(var request: Request) -> Response:
    """Answers with the request's `X-Trail` fields, in order."""
    return Response.text(",".join(request.headers.get_all("X-Trail")))


def counted(counter: State[Counter]) -> String:
    counter[].n[] += 1
    return "reached"


def routes(mut app: App, counter: State[Counter]):
    app.get["/hello"](hello)
    app.get["/users/{id}"](get_user)
    app.get["/boom"](boom)
    app.post["/echo"](echo)
    app.get["/report"](report)
    app.get["/trail"](trail)
    app.get["/blocked"](counted, counter)
    app.get["/counted"](counted, counter)


def _app(counter: State[Counter]) -> App:
    var app = App()
    routes(app, counter)
    return app^


def _requests() -> List[Request]:
    """A matched route, a typed route, a 400 for a bad route value, 404, 405
    with `Allow`, `HEAD`, a handler raise, a body and a route's own fields."""
    var r = List[Request]()
    r.append(Request("GET", "/hello"))
    r.append(Request("GET", "/users/7"))
    r.append(Request("GET", "/users/abc"))
    r.append(Request("GET", "/missing"))
    r.append(Request("POST", "/hello"))
    r.append(Request("HEAD", "/hello"))
    r.append(Request("GET", "/boom"))
    r.append(Request("POST", "/echo", "payload"))
    r.append(Request("GET", "/report"))
    return r^


def _send(app: App, request: Request) -> Response:
    """`request` through `TestClient` for the methods it has, else through
    `App.handle`, the seam `TestClient` calls."""
    var client = TestClient(app)
    var target = request.path
    if request.query.byte_length() > 0:
        target += "?" + request.query
    if request.method == "GET":
        return client.get(target, headers=request.headers.copy())
    if request.method == "HEAD":
        return client.head(target, headers=request.headers.copy())
    if request.method == "POST":
        return client.post(
            target, request.body.copy(), headers=request.headers.copy()
        )
    return app.handle(request)


def _fields(r: Response) -> String:
    var out = String()
    for i in range(len(r.headers)):
        out += r.headers.name(i) + ": " + r.headers.value(i) + "; "
    return out


def _same(a: Response, b: Response, what: String) raises:
    assert_equal(a.status, b.status, what)
    assert_equal(a.body, b.body, what)
    assert_equal(_fields(a), _fields(b), what)


def _field(r: Response, name: String) -> String:
    return r.headers.get(name).or_else("<none>")


# Middleware.


def tracing(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    response.headers.add("X-Trace", "1")
    return response^


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


def stamp(var request: Request, var next: Next) raises -> Response:
    """Tags every answer with the method it saw."""
    var method = request.method
    var response = next^.run(request^)
    response.headers.add("X-Seen", method)
    return response^


def inner(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    response.headers.add("X-Inner", "1")
    return response^


def gate(var request: Request, var next: Next) raises -> Response:
    if request.path == "/blocked" or request.path == "/nowhere":
        return Response.text("Forbidden", status=403)
    return next^.run(request^)


def rewrite(var request: Request, var next: Next) raises -> Response:
    if request.path == "/old":
        request.path = "/hello"
    return next^.run(request^)


def tagged[
    value: StaticString
](var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    response.headers.add("X-Tag", value)
    return response^


def fail_before(var request: Request, var next: Next) raises -> Response:
    raise Error("middleware detail")


def fail_after(var request: Request, var next: Next) raises -> Response:
    _ = next^.run(request^)
    raise Error("middleware detail")


def borrowing(request: Request, var next: Next) raises -> Response:
    """Borrows the request, so it passes a copy on."""
    var response = next^.run(request.copy())
    response.headers.add("X-Borrowed", request.path)
    return response^


def not_raising(var request: Request, var next: Next) -> Response:
    var response = next^.run(request^)
    response.status = 299 if response.status == 200 else response.status
    return response^


def own_404(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    if response.status == 404:
        return Response.text("no such page", status=404)
    return response^


def narrow_allow(var request: Request, var next: Next) raises -> Response:
    """Changes `Allow` on a 405 to `GET` alone."""
    var response = next^.run(request^)
    if response.status == 405:
        response.headers.set("Allow", "GET")
    return response^


def drop_allow(var request: Request, var next: Next) raises -> Response:
    """Answers a 405 without `Allow`."""
    var response = next^.run(request^)
    if response.status == 405:
        return Response(405, response.body.copy())
    return response^


# Tests.


def test_the_dx_example_as_written() raises:
    # docs/DX.md section 7.
    var app = App()
    app.use(tracing)
    app.get["/hello"](hello)
    var client = TestClient(app)
    var r = client.get("/hello")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "hello")
    assert_equal(_fields(r), "X-Trace: 1; ")
    r = client.get("/missing")
    assert_equal(r.status, 404)
    assert_equal(r.text(), "Not Found")
    assert_equal(_fields(r), "X-Trace: 1; ")
    r = client.post("/hello", "")
    assert_equal(r.status, 405)
    assert_equal(r.text(), "Method Not Allowed")
    assert_equal(_fields(r), "Allow: GET, HEAD; X-Trace: 1; ")


def test_no_middleware_keeps_the_routes_answers() raises:
    # The contract without middleware, as before M3-035.
    var counter = State(Counter())
    var app = _app(counter)
    var r = _requests()
    var want = [
        (200, String("hello"), String("")),
        (200, String("user 7"), String("")),
        (400, String("Bad Request"), String("")),
        (404, String("Not Found"), String("")),
        (405, String("Method Not Allowed"), String("Allow: GET, HEAD; ")),
        (200, String("hello"), String("")),
        (500, String("Internal Server Error"), String("")),
        (200, String("POST /echo payload"), String("")),
        (
            200,
            String("report"),
            String("X-Report: 1; Set-Cookie: a=1; Set-Cookie: b=2; "),
        ),
    ]
    assert_equal(len(r), len(want))
    for i in range(len(r)):
        var got = _send(app, r[i])
        assert_equal(got.status, want[i][0], r[i].path)
        assert_equal(got.text(), want[i][1], r[i].path)
        assert_equal(_fields(got), want[i][2], r[i].path)


def test_pass_through_answers_as_without_middleware() raises:
    var counter = State(Counter())
    var plain = _app(counter)
    var one = _app(counter)
    one.use(passthrough)
    var two = _app(counter)
    two.use(passthrough)
    two.use(passthrough)
    for request in _requests():
        var expected = _send(plain, request)
        _same(_send(one, request), expected, "one " + request.path)
        _same(_send(two, request), expected, "two " + request.path)


def test_middleware_sees_every_request() raises:
    # 404, 405 with `Allow`, the route value's 400, the handler's 500, a body
    # and `HEAD` all pass through middleware; `HEAD` arrives as `HEAD` and
    # its answer keeps the GET's body (the backend drops it, M3-027).
    var counter = State(Counter())
    var plain = _app(counter)
    var app = _app(counter)
    app.use(stamp)
    for request in _requests():
        var expected = _send(plain, request)
        var got = _send(app, request)
        assert_equal(got.status, expected.status, request.path)
        assert_equal(got.body, expected.body, request.path)
        assert_equal(
            _fields(got),
            _fields(expected) + "X-Seen: " + request.method + "; ",
            request.method + " " + request.path,
        )
    var head = _send(app, Request("HEAD", "/hello"))
    assert_equal(head.text(), "hello")
    assert_equal(_field(head, "X-Seen"), "HEAD")
    var not_allowed = _send(app, Request("POST", "/hello"))
    assert_equal(not_allowed.status, 405)
    assert_equal(_field(not_allowed, "Allow"), "GET, HEAD")


def test_order_is_registration_order_outermost_first() raises:
    var counter = State(Counter())
    var app = _app(counter)
    app.use(trail_a)
    app.use(trail_b)
    var r = TestClient(app).get("/trail")
    assert_equal(r.text(), "a,b")
    assert_equal(",".join(r.headers.get_all("X-Back")), "b,a")


def test_use_before_or_after_routes_is_the_same_chain() raises:
    var counter = State(Counter())
    var before = App()
    before.use(trail_a)
    before.use(stamp)
    routes(before, counter)
    var after = _app(counter)
    after.use(trail_a)
    after.use(stamp)
    var between = App()
    between.use(trail_a)
    between.get["/hello"](hello)
    between.use(stamp)
    between.get["/trail"](trail)
    for target in ["/hello", "/trail", "/missing"]:
        var a = TestClient(before).get(target)
        _same(a, TestClient(after).get(target), target)
        _same(a, TestClient(between).get(target), target)
        assert_equal(_field(a, "X-Seen"), "GET", target)
        assert_equal(_field(a, "X-Back"), "a", target)


def test_short_circuit_runs_nothing_after_it() raises:
    var counter = State(Counter())
    var app = _app(counter)
    app.use(stamp)
    app.use(gate)
    app.use(inner)
    var client = TestClient(app)
    var r = client.get("/blocked")
    assert_equal(r.status, 403)
    assert_equal(r.text(), "Forbidden")
    # The outer middleware ran; the inner one and the handler did not.
    assert_equal(_fields(r), "X-Seen: GET; ")
    assert_equal(counter[].n[], 0)
    # A path no route matches is answered by the middleware too.
    var nowhere = client.get("/nowhere")
    assert_equal(nowhere.status, 403)
    assert_equal(nowhere.text(), "Forbidden")
    var reached = client.get("/counted")
    assert_equal(reached.text(), "reached")
    assert_equal(_fields(reached), "X-Inner: 1; X-Seen: GET; ")
    assert_equal(counter[].n[], 1)


def test_request_and_response_can_be_changed() raises:
    var counter = State(Counter())
    var app = _app(counter)
    app.use(rewrite)
    app.use(tagged["v1"])
    app.use(tagged["v2"])
    var r = TestClient(app).get("/old")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "hello")
    assert_equal(",".join(r.headers.get_all("X-Tag")), "v2,v1")
    assert_equal(TestClient(_app(counter)).get("/old").status, 404)


def test_a_body_reaches_the_route_through_middleware() raises:
    var counter = State(Counter())
    var app = _app(counter)
    app.use(trail_a)
    var r = TestClient(app).post("/echo", "payload")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "POST /echo payload")
    assert_equal(_field(r, "X-Back"), "a")


def test_a_raise_before_the_rest_is_the_fixed_500() raises:
    var counter = State(Counter())
    var app = _app(counter)
    app.use(fail_before)
    var r = TestClient(app).get("/counted")
    assert_equal(r.status, 500)
    assert_equal(r.text(), "Internal Server Error")
    assert_equal(len(r.headers), 0)
    assert_equal(counter[].n[], 0)


def test_a_raise_after_the_rest_is_the_fixed_500() raises:
    var counter = State(Counter())
    var app = _app(counter)
    app.use(fail_after)
    var r = TestClient(app).get("/counted")
    assert_equal(r.status, 500)
    assert_equal(r.text(), "Internal Server Error")
    assert_equal(len(r.headers), 0)
    assert_equal(counter[].n[], 1)


def test_a_raise_is_answered_at_the_failing_middleware() raises:
    # The inner middleware's raise becomes the 500 at its own call; the
    # outer one gets it from `next` and still adds its field.
    var counter = State(Counter())
    var before = _app(counter)
    before.use(stamp)
    before.use(fail_before)
    var r = TestClient(before).get("/counted")
    assert_equal(r.status, 500)
    assert_equal(r.text(), "Internal Server Error")
    assert_equal(_fields(r), "X-Seen: GET; ")
    assert_equal(counter[].n[], 0)
    var after = _app(counter)
    after.use(stamp)
    after.use(fail_after)
    r = TestClient(after).get("/counted")
    assert_equal(r.status, 500)
    assert_equal(r.text(), "Internal Server Error")
    assert_equal(_fields(r), "X-Seen: GET; ")
    assert_equal(counter[].n[], 1)


def test_no_error_text_reaches_the_client() raises:
    var counter = State(Counter())
    var app = _app(counter)
    app.use(stamp)
    app.use(fail_after)
    for target in ["/counted", "/boom", "/missing"]:
        var r = TestClient(app).get(target)
        assert_equal(r.status, 500, target)
        assert_false("detail" in r.text(), target)
        assert_false("detail" in _fields(r), target)


def test_two_middleware_running_the_rest_reach_the_route_once() raises:
    var counter = State(Counter())
    var app = _app(counter)
    app.use(passthrough)
    app.use(stamp)
    var r = TestClient(app).get("/counted")
    assert_equal(r.text(), "reached")
    assert_equal(counter[].n[], 1)


def test_borrowing_and_non_raising_middleware_register() raises:
    var counter = State(Counter())
    var app = _app(counter)
    app.use(borrowing)
    app.use(not_raising)
    var r = TestClient(app).get("/hello")
    assert_equal(r.status, 299)
    assert_equal(r.text(), "hello")
    assert_equal(_field(r, "X-Borrowed"), "/hello")
    # The function type is public: a value of it registers too.
    var m: Middleware = passthrough
    app.use(m)
    assert_equal(TestClient(app).get("/users/7").text(), "user 7")


def test_a_middleware_answers_a_404_itself() raises:
    var counter = State(Counter())
    var app = _app(counter)
    app.use(own_404)
    var r = TestClient(app).get("/missing")
    assert_equal(r.status, 404)
    assert_equal(r.text(), "no such page")
    assert_equal(TestClient(app).get("/hello").text(), "hello")


def test_a_middleware_changes_or_drops_allow_on_a_405() raises:
    # Muntin's own 405 carries `Allow`; a middleware's answer is sent as it
    # wrote it (the application's responsibility, M3-030's condition).
    var counter = State(Counter())
    var narrowed = _app(counter)
    narrowed.use(narrow_allow)
    var r = TestClient(narrowed).post("/hello", "")
    assert_equal(r.status, 405)
    assert_equal(_fields(r), "Allow: GET; ")
    var dropped = _app(counter)
    dropped.use(drop_allow)
    r = TestClient(dropped).post("/hello", "")
    assert_equal(r.status, 405)
    assert_equal(r.text(), "Method Not Allowed")
    assert_equal(len(r.headers), 0)


def test_middleware_survives_moving_the_app() raises:
    var counter = State(Counter())
    var app = _app(counter)
    app.use(stamp)
    var moved = app^
    var held = List[App]()
    held.append(moved^)
    var r = TestClient(held[0]).get("/hello")
    assert_equal(r.text(), "hello")
    assert_equal(_field(r, "X-Seen"), "GET")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
