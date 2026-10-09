# M3-036 spike: what `TestClient.head(target, *, headers=)` returns.
# `SpikeClient` holds the candidates over the unchanged production `App`,
# `Request` and `Response`, built as production `TestClient`'s methods are:
#   A  (`head_keep`): `App.handle(Request("HEAD", target, "", headers^))`,
#      returned unchanged, the `GET`'s body included;
#   B1 (`head_drop`): that response with its body removed;
#   B2 (`head_framed`): B1 plus a `Content-Length` equal to the removed
#      body's byte length, none for 1xx, 204, 205 and 304: the Flare
#      adapter's `_without_content` rule, copied here.
# Each test states what a candidate answers, compared with `App.handle` for
# `HEAD` and for `GET`. Decision: docs/history/architecture-decisions.md,
# "TestClient HEAD decision (M3-036)". The production slice retires this
# file.

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, TestSuite

from muntin import App, Headers, Next, Request, Response, State
from muntin.testing import TestClient


struct SpikeClient[origin: Origin[mut=False]]:
    var _app: Pointer[App, Self.origin]

    def __init__(out self, ref[Self.origin] app: App):
        self._app = Pointer(to=app)

    def head_keep(
        self, target: String, *, var headers: Headers = Headers()
    ) -> Response:
        """A: what `get` does, with the method `HEAD`."""
        return self._app[].handle(Request("HEAD", target, "", headers^))

    def head_drop(
        self, target: String, *, var headers: Headers = Headers()
    ) -> Response:
        """B1: A with the body removed."""
        var response = self._app[].handle(Request("HEAD", target, "", headers^))
        response.body = String()
        return response^

    def head_framed(
        self, target: String, *, var headers: Headers = Headers()
    ) -> Response:
        """B2: B1 with the adapter's `Content-Length` rule."""
        var response = self._app[].handle(Request("HEAD", target, "", headers^))
        var length = response.body.byte_length()
        response.body = String()
        var status = response.status
        var informational = status >= 100 and status <= 199
        if (
            not informational
            and status != 204
            and status != 205
            and status != 304
        ):
            try:
                response.headers.add("Content-Length", String(length))
            except:
                pass  # `add` rejects only invalid names and values.
        return response^


# Application.


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


def report(calls: State[Calls], var req: Request) -> Response:
    """Raw, following DX's rule: the `GET` body for `HEAD` too."""
    calls[].methods[] += req.method + ";"
    var r = Response.text("report")
    try:
        r.headers.add("X-Report", "1")
    except:
        pass
    return r^


def lazy(var req: Request) -> Response:
    """Raw, breaking DX's rule: an empty body for `HEAD`."""
    if req.method == "HEAD":
        return Response.text("")
    return Response.text("lazy body")


def no_content(var req: Request) -> Response:
    return Response(204, "x")


def reset_content(var req: Request) -> Response:
    return Response(205, "abc")


def not_modified(var req: Request) -> Response:
    return Response(304, "abc")


def own_length(var req: Request) -> Response:
    """Raw, declaring its own `Content-Length` (the adapter drops it)."""
    var r = Response.text("abc")
    try:
        r.headers.add("Content-Length", "99")
    except:
        pass
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
    app.get["/report"](report, calls)
    app.get["/lazy"](lazy)
    app.get["/nc"](no_content)
    app.get["/rc"](reset_content)
    app.get["/nm"](not_modified)
    app.get["/cl"](own_length)
    app.post["/only-post"](posted)
    return app^


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


def replace_missing(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    if response.status == 404:
        return Response.text("custom missing", status=404)
    return response^


# Helpers.


def _fields(r: Response) -> String:
    var out = String()
    for i in range(len(r.headers)):
        out += r.headers.name(i) + ": " + r.headers.value(i) + "; "
    return out


def _same(a: Response, b: Response, what: String) raises:
    assert_equal(a.status, b.status, what)
    assert_equal(a.body, b.body, what)
    assert_equal(_fields(a), _fields(b), what)


def _targets() -> List[String]:
    """Typed, route value, query, stateful, raw, 400, 500, 405, 404, and raw
    204, 205 and 304 answers with a body."""
    var t = List[String]()
    t.append("/hello")
    t.append("/users/7")
    t.append("/fields/3?field=name")
    t.append("/count/5")
    t.append("/report")
    t.append("/users/abc")
    t.append("/fields/3")
    t.append("/fail")
    t.append("/only-post")
    t.append("/missing")
    t.append("/nc")
    t.append("/rc")
    t.append("/nm")
    return t^


def _h(name: String, value: String) raises -> Headers:
    var h = Headers()
    h.add(name, value)
    return h^


# A: the response of `App.handle`, unchanged.


def test_a_equals_app_handle_for_head() raises:
    var calls = State(Calls())
    var app = _app(calls)
    var client = SpikeClient(app)
    for t in _targets():
        _same(client.head_keep(t), app.handle(Request("HEAD", t)), t)


def test_a_equals_the_get_answer() raises:
    # Every route here answers `HEAD` as `GET` (the raw ones follow DX's
    # rule), so A's answer is `TestClient.get`'s, body and fields included,
    # except 405, whose `GET` is a 405 too with the same `Allow`.
    var calls = State(Calls())
    var app = _app(calls)
    var client = SpikeClient(app)
    var get = TestClient(app)
    for t in _targets():
        _same(client.head_keep(t), get.get(t), t)
    var r = client.head_keep("/only-post")
    assert_equal(r.status, 405)
    assert_equal(_fields(r), "Allow: POST; ")
    assert_equal(r.body, "Method Not Allowed")


def test_a_statuses_and_bodies() raises:
    var calls = State(Calls())
    var app = _app(calls)
    var client = SpikeClient(app)
    var r = client.head_keep("/users/7")
    assert_equal(r.status, 200)
    assert_equal(r.body, "user 7")
    r = client.head_keep("/users/abc")
    assert_equal(r.status, 400)
    assert_equal(r.body, "Bad Request")
    r = client.head_keep("/fields/3")
    assert_equal(r.status, 400)
    r = client.head_keep("/fail")
    assert_equal(r.status, 500)
    assert_equal(r.body, "Internal Server Error")
    r = client.head_keep("/missing")
    assert_equal(r.status, 404)
    assert_equal(r.body, "Not Found")
    r = client.head_keep("/nm")
    assert_equal(r.status, 304)
    assert_equal(r.body, "abc")


def test_a_sends_headers_and_head_reaches_raw_and_stateful_routes() raises:
    var calls = State(Calls())
    var app = _app(calls)
    var client = SpikeClient(app)
    var r = client.head_keep("/h/1", headers=_h("X-A", "b"))
    assert_equal(r.body, "1 X-A=b")
    var h = _h("X-A", "b")
    _same(
        client.head_keep("/h/1", headers=h.copy()),
        app.handle(Request("HEAD", "/h/1", "", h^)),
        "headers",
    )
    _ = client.head_keep("/report")
    _ = TestClient(app).get("/report")
    assert_equal(calls[].methods[], "HEAD;GET;")
    _ = client.head_keep("/count/1")
    assert_equal(calls[].n[], 1)


def test_a_shows_a_raw_handler_breaking_the_head_rule() raises:
    # The raw rule (DX): answer `HEAD` with the `GET`'s body, because the
    # backend declares that body's length. A shows the difference.
    var calls = State(Calls())
    var app = _app(calls)
    var client = SpikeClient(app)
    assert_equal(client.head_keep("/lazy").body, "")
    assert_equal(TestClient(app).get("/lazy").body, "lazy body")


def test_a_with_middleware() raises:
    # `HEAD` reaches middleware as `HEAD`; a field it adds, its short-circuit
    # (the handler not called) and its replacement come back unchanged.
    var calls = State(Calls())
    var app = _app(calls)
    app.use(seen)
    app.use(gate)
    app.use(replace_missing)
    var client = SpikeClient(app)
    for t in _targets():
        _same(client.head_keep(t), app.handle(Request("HEAD", t)), t)
    var r = client.head_keep("/hello")
    assert_equal(r.body, "hello")
    assert_equal(_fields(r), "X-Seen: HEAD; ")
    r = client.head_keep("/count/1")
    assert_equal(r.status, 403)
    assert_equal(r.body, "Forbidden")
    assert_equal(calls[].n[], 0)
    r = client.head_keep("/missing")
    assert_equal(r.body, "custom missing")
    assert_equal(_fields(r), "X-Seen: HEAD; ")


# B1: the body removed.


def test_b1_differs_from_app_handle_only_in_the_body() raises:
    var calls = State(Calls())
    var app = _app(calls)
    var client = SpikeClient(app)
    for t in _targets():
        var b = client.head_drop(t)
        var a = app.handle(Request("HEAD", t))
        assert_equal(b.status, a.status, t)
        assert_equal(_fields(b), _fields(a), t)
        assert_equal(b.body, "", t)


def test_b1_hides_a_raw_handler_breaking_the_head_rule() raises:
    # The rule-breaking raw route looks like a rule-following route with the
    # same status and fields (`/hello`); A tells them apart (above).
    var calls = State(Calls())
    var app = _app(calls)
    var client = SpikeClient(app)
    _same(client.head_drop("/lazy"), client.head_drop("/hello"), "lazy")
    assert_true(
        client.head_keep("/lazy").body != TestClient(app).get("/lazy").body
    )


def test_b1_hides_which_answer_came_back() raises:
    # 404 and a middleware's own 404 differ only in the body.
    var calls = State(Calls())
    var plain = _app(calls)
    var app = _app(calls)
    app.use(replace_missing)
    _same(
        SpikeClient(plain).head_drop("/missing"),
        SpikeClient(app).head_drop("/missing"),
        "missing",
    )
    assert_true(
        plain.handle(Request("HEAD", "/missing")).body
        != app.handle(Request("HEAD", "/missing")).body
    )


# B2: the body removed and a `Content-Length` declared.


def test_b2_declares_the_removed_length() raises:
    var calls = State(Calls())
    var app = _app(calls)
    var client = SpikeClient(app)
    var r = client.head_framed("/users/7")
    assert_equal(r.body, "")
    assert_equal(_fields(r), "Content-Length: 6; ")
    r = client.head_framed("/users/abc")
    assert_equal(_fields(r), "Content-Length: 11; ")
    r = client.head_framed("/only-post")
    assert_equal(_fields(r), "Allow: POST; Content-Length: 18; ")
    r = client.head_framed("/report")
    assert_equal(_fields(r), "X-Report: 1; Content-Length: 6; ")
    r = client.head_framed("/lazy")
    assert_equal(_fields(r), "Content-Length: 0; ")
    for t in [String("/nc"), String("/rc"), String("/nm")]:
        r = client.head_framed(t)
        assert_equal(_fields(r), "", t)
        assert_equal(r.body, "", t)


def test_b2_adds_a_field_app_handle_never_returns() raises:
    var calls = State(Calls())
    var app = _app(calls)
    var client = SpikeClient(app)
    for t in _targets():
        var a = app.handle(Request("HEAD", t))
        assert_true(not a.headers.get("Content-Length"), t)
    assert_true(
        Bool(client.head_framed("/hello").headers.get("Content-Length"))
    )


def test_b2_keeps_a_handlers_own_length_beside_its_own() raises:
    # The adapter drops a handler's `Content-Length` (M3-005) before its
    # `HEAD` rule; B2 copies only the rule, so two lengths come back. A
    # returns the handler's field, as `TestClient.get` does for `GET`.
    var calls = State(Calls())
    var app = _app(calls)
    var client = SpikeClient(app)
    assert_equal(
        _fields(client.head_framed("/cl")),
        "Content-Length: 99; Content-Length: 3; ",
    )
    _same(client.head_keep("/cl"), TestClient(app).get("/cl"), "cl")
    assert_equal(_fields(client.head_keep("/cl")), "Content-Length: 99; ")


def test_a_carries_what_b2_declares() raises:
    # A's body length is B2's `Content-Length` for every status that has
    # one: the information B2 adds is already in A.
    var calls = State(Calls())
    var app = _app(calls)
    var client = SpikeClient(app)
    for t in _targets():
        var declared = client.head_framed(t).headers.get("Content-Length")
        if declared:
            assert_equal(
                String(client.head_keep(t).body.byte_length()),
                declared.value(),
                t,
            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
