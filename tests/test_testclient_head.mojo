# M3-037: `TestClient.head(target, *, headers=)` on production `TestClient`.
# `head` sends `HEAD` (the application sees `HEAD`, never `GET`) and returns
# `App.handle(Request("HEAD", target, "", headers^))` unchanged: status, body
# and every field in order. It removes no body and adds no field, for any
# status; keeping the content off the wire and declaring its length is the
# network backend's (adapters/flare). Every answer here is compared with
# `App.handle` for the same request. Contract:
# docs/history/architecture-decisions.md, "TestClient HEAD decision
# (M3-036)", "Next production slice"; semantics: docs/DX.md, "`HEAD`" in
# "Proven vs. target status", and section 10. Must-not-build evidence:
# tests/methods_api_fail/testclient_head_*.

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, TestSuite

from muntin import App, Headers, Next, Request, Response, State
from muntin.testing import TestClient


# Application types and handlers.


struct Calls(Movable):
    """Counts handler calls and logs the method each raw call received."""

    var n: ArcPointer[Int]
    var methods: ArcPointer[String]

    def __init__(out self):
        self.n = ArcPointer(0)
        self.methods = ArcPointer(String())


def hello() -> String:
    return "hello"


def get_user(id: Int) -> String:
    return String("user ", id)


def field_of(id: Int, field: String) -> String:
    return String("field ", id, " ", field)


def fields_of(id: Int, headers: Headers) -> String:
    var out = String(id)
    for i in range(len(headers)):
        out += " " + headers.name(i) + "=" + headers.value(i)
    return out^


def counted(calls: State[Calls], id: Int) -> String:
    calls[].n[] += 1
    return String("counted ", id)


def failing() raises -> String:
    raise Error("detail")


def logged(calls: State[Calls], var req: Request) -> Response:
    """Raw: logs the method it receives and answers alike for both."""
    calls[].n[] += 1
    calls[].methods[] += req.method + ";"
    return Response.text("logged")


def echo(var req: Request) raises -> Response:
    """Raw: answers with the method, path, query and every field in order,
    each value in angle brackets."""
    var out = req.method + " " + req.path + " ?" + req.query + " [" + req.text()
    out += "]"
    for i in range(len(req.headers)):
        out += " " + req.headers.name(i) + "=<" + req.headers.value(i) + ">"
    return Response.text(out)


def report(req: Request) raises -> Response:
    """Raw: fields of its own, a repeated name in two casings."""
    var r = Response.text("report")
    r.headers.add("X-Report", "1")
    r.headers.add("Set-Cookie", "a=1")
    r.headers.add("set-cookie", "b=2")
    return r^


def differs(var req: Request) -> Response:
    """Raw, breaking DX's raw rule: another body for `HEAD`."""
    if req.method == "HEAD":
        return Response.text("head body")
    return Response.text("get body")


def no_content(var req: Request) -> Response:
    return Response(204, "x")


def reset_content(var req: Request) -> Response:
    return Response(205, "abc")


def not_modified(var req: Request) -> Response:
    return Response(304, "abc")


def not_modified_with_length(req: Request) raises -> Response:
    """Raw: a 304 with a body and its own `Content-Length`."""
    var r = Response(304, "abc")
    r.headers.add("Content-Length", "3")
    return r^


def own_length(req: Request) raises -> Response:
    """Raw: its own `Content-Length`, unequal to its body's length."""
    var r = Response.text("abc")
    r.headers.add("Content-Length", "99")
    return r^


def posted(var req: Request) -> Response:
    return Response.text("posted")


def _app(calls: State[Calls]) -> App:
    var app = App()
    app.get["/hello"](hello)
    app.get["/users/{id}"](get_user)
    app.get["/fields/{id}?{field}"](field_of)
    app.get["/h/{id}"](fields_of)
    app.get["/count/{id}"](counted, calls)
    app.get["/fail"](failing)
    app.get["/logged"](logged, calls)
    app.get["/echo"](echo)
    app.get["/report"](report)
    app.get["/differs"](differs)
    app.get["/nc"](no_content)
    app.get["/rc"](reset_content)
    app.get["/nm"](not_modified)
    app.get["/nm-cl"](not_modified_with_length)
    app.get["/cl"](own_length)
    app.post["/only-post"](posted)
    return app^


# Helpers.


def _h(*pairs: String) raises -> Headers:
    var h = Headers()
    var i = 0
    while i + 1 < len(pairs):
        h.add(pairs[i], pairs[i + 1])
        i += 2
    return h^


def _fields(r: Response) -> String:
    var out = String()
    for i in range(len(r.headers)):
        out += r.headers.name(i) + ": " + r.headers.value(i) + "; "
    return out


def _same(a: Response, b: Response, what: String) raises:
    assert_equal(a.status, b.status, what)
    assert_equal(a.body, b.body, what)
    assert_equal(_fields(a), _fields(b), what)


def _expect(
    app: App,
    target: String,
    status: Int,
    body: String,
    fields: String,
    headers: Headers = Headers(),
) raises -> Response:
    """`head(target, headers=...)` answers `status`, `body` and `fields`,
    and equals `App.handle(Request("HEAD", target, "", ...))` with the same
    fields, sent after it (so a handler runs twice)."""
    var got = TestClient(app).head(target, headers=headers.copy())
    assert_equal(got.status, status, target)
    assert_equal(got.text(), body, target)
    assert_equal(_fields(got), fields, target)
    _same(got, app.handle(Request("HEAD", target, "", headers.copy())), target)
    return got^


# Tests.


def test_head_is_app_handle_unchanged() raises:
    var calls = State(Calls())
    var app = _app(calls)
    var h = _h("X-A", "1", "x-a", "2", "X-Empty", "")
    # Typed routes: none, a path value, a path and a query value, a `Headers`
    # slot, state.
    _ = _expect(app, "/hello", 200, "hello", "", h)
    _ = _expect(app, "/users/7", 200, "user 7", "", h)
    _ = _expect(app, "/fields/3?field=name", 200, "field 3 name", "", h)
    _ = _expect(app, "/h/1", 200, "1 X-A=1 x-a=2 X-Empty=", "", h)
    _ = _expect(app, "/count/5", 200, "counted 5", "", h)
    # A raw route with fields of its own: order, casing and repeats kept.
    _ = _expect(
        app,
        "/report",
        200,
        "report",
        "X-Report: 1; Set-Cookie: a=1; set-cookie: b=2; ",
        h,
    )
    # Muntin's own answers, each with its body.
    _ = _expect(app, "/users/abc", 400, "Bad Request", "", h)
    _ = _expect(app, "/count/abc", 400, "Bad Request", "", h)
    _ = _expect(app, "/fields/3", 400, "Bad Request", "", h)
    _ = _expect(app, "/missing", 404, "Not Found", "", h)
    _ = _expect(
        app, "/only-post", 405, "Method Not Allowed", "Allow: POST; ", h
    )
    _ = _expect(app, "/fail", 500, "Internal Server Error", "", h)
    # `_expect` sends each request twice (`head`, then `App.handle`): `/count/5`
    # ran twice, and `/count/abc`'s 400 never reached its handler.
    assert_equal(calls[].n[], 2)


def test_head_sends_head() raises:
    # The equality with `App.handle` alone would not catch a client sending
    # `GET` on a route that answers `HEAD` as `GET`; the raw route's log does.
    var calls = State(Calls())
    var app = _app(calls)
    var client = TestClient(app)
    var r = client.head("/logged")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "logged")
    assert_equal(calls[].methods[], "HEAD;")
    _ = client.get("/logged")
    assert_equal(calls[].methods[], "HEAD;GET;")
    assert_equal(client.head("/echo").text(), "HEAD /echo ? []")


def test_head_keeps_a_body_that_differs_from_get() raises:
    var app = _app(State(Calls()))
    var client = TestClient(app)
    _ = _expect(app, "/differs", 200, "head body", "")
    assert_equal(client.get("/differs").text(), "get body")


def test_head_equals_get_on_typed_routes() raises:
    var app = _app(State(Calls()))
    var client = TestClient(app)
    for t in ["/hello", "/users/7", "/fields/3?field=name", "/users/abc"]:
        _same(client.head(t), client.get(t), t)
    var h = _h("X-A", "b")
    _same(
        client.head("/h/1", headers=h.copy()),
        client.get("/h/1", headers=h.copy()),
        "/h/1",
    )
    assert_equal(client.head("/users/7").text(), "user 7")


def test_head_applies_no_status_rule_and_adds_no_length() raises:
    var app = _app(State(Calls()))
    # 204, 205 and 304 keep the body the handler gave them.
    _ = _expect(app, "/nc", 204, "x", "")
    _ = _expect(app, "/rc", 205, "abc", "")
    _ = _expect(app, "/nm", 304, "abc", "")
    # A handler's own `Content-Length` is kept, and no second one is added.
    var r = _expect(app, "/nm-cl", 304, "abc", "Content-Length: 3; ")
    assert_equal(len(r.headers.get_all("Content-Length")), 1)
    r = _expect(app, "/cl", 200, "abc", "Content-Length: 99; ")
    assert_equal(len(r.headers.get_all("Content-Length")), 1)


def test_head_sends_the_given_fields_and_splits_the_target() raises:
    var app = _app(State(Calls()))
    var client = TestClient(app)
    # None by default; the target split at its first `?`, query undecoded.
    assert_equal(client.head("/echo").text(), "HEAD /echo ? []")
    assert_equal(
        client.head("/echo?a=%41&b=?").text(), "HEAD /echo ?a=%41&b=? []"
    )
    # In order, with their casing, repeats and an empty value.
    var h = _h("X-A", "1", "Set-Cookie", "a=1", "x-a", "2", "X-Empty", "")
    var want = "HEAD /echo ?q=1 [] X-A=<1> Set-Cookie=<a=1> x-a=<2> X-Empty=<>"
    _ = _expect(app, "/echo?q=1", 200, want, "", h)
    # `.copy()` leaves `h` usable; `^` moves it.
    assert_equal(client.head("/echo?q=1", headers=h.copy()).text(), want)
    assert_equal(len(h), 4)
    assert_equal(client.head("/echo?q=1", headers=h^).text(), want)
    # A typed `Headers` slot receives them too.
    var slot = _h("X-B", "2")
    assert_equal(client.head("/h/9", headers=slot^).text(), "9 X-B=2")
    assert_equal(client.head("/h/9").text(), "9")


# Middleware.


def seen(var request: Request, var next: Next) raises -> Response:
    var method = request.method
    var response = next^.run(request^)
    response.headers.add("X-Seen", method)
    return response^


def gate(var request: Request, var next: Next) raises -> Response:
    if request.path.startswith("/count"):
        return Response.text("Forbidden", status=403)
    return next^.run(request^)


def own_404(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    if response.status == 404:
        return Response.text("no such page", status=404)
    return response^


def test_head_through_middleware() raises:
    var calls = State(Calls())
    var app = _app(calls)
    app.use(seen)
    app.use(gate)
    app.use(own_404)
    # Middleware sees `HEAD` and adds its field.
    _ = _expect(app, "/hello", 200, "hello", "X-Seen: HEAD; ")
    _ = _expect(app, "/differs", 200, "head body", "X-Seen: HEAD; ")
    # A short circuit: the handler never runs.
    _ = _expect(app, "/count/1", 403, "Forbidden", "X-Seen: HEAD; ")
    assert_equal(calls[].n[], 0)
    # A replaced 404 comes back as the middleware wrote it.
    _ = _expect(app, "/missing", 404, "no such page", "X-Seen: HEAD; ")
    # The raw route behind the chain receives `HEAD` (from `head`, then from
    # `App.handle`).
    _ = _expect(app, "/logged", 200, "logged", "X-Seen: HEAD; ")
    assert_equal(calls[].methods[], "HEAD;HEAD;")


# The other methods.


def test_every_method_sends_its_own_method() raises:
    var app = App()
    app.get["/echo"](echo)
    app.post["/echo"](echo)
    app.put["/echo"](echo)
    app.patch["/echo"](echo)
    app.delete["/echo"](echo)
    var client = TestClient(app)
    var h = _h("X-A", "1")
    var rows = [
        (client.get("/echo?q", headers=h.copy()), "GET /echo ?q []"),
        (client.head("/echo?q", headers=h.copy()), "HEAD /echo ?q []"),
        (client.post("/echo?q", "b", headers=h.copy()), "POST /echo ?q [b]"),
        (client.put("/echo?q", "b", headers=h.copy()), "PUT /echo ?q [b]"),
        (client.patch("/echo?q", "b", headers=h.copy()), "PATCH /echo ?q [b]"),
        (client.delete("/echo?q", headers=h.copy()), "DELETE /echo ?q []"),
    ]
    for row in rows:
        assert_equal(row[0].status, 200, row[1])
        assert_equal(row[0].text(), row[1] + " X-A=<1>")
        assert_true(len(row[0].headers) == 0, row[1])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
