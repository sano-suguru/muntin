# `HEAD` through `get` routes (M3-027): through `App.handle`, a `HEAD` request
# is matched against `GET` routes only, the exact token `HEAD` only, and runs
# the `GET` route's steps: a typed handler gets the `GET`'s arguments, so the
# answer equals the `GET`'s (status, body and header fields), the body kept
# (keeping it off the wire is the backend's); a raw `get` handler sees
# `req.method == "HEAD"`, and one that follows DX's raw rule answers as for
# the `GET`. Every other request keeps its
# answer, 404 included. Decision: docs/history/architecture-decisions.md,
# "HEAD decision (M3-026)". The Flare adapter's side: adapters/flare.

from std.memory import ArcPointer
from std.testing import assert_equal, TestSuite

from muntin import (
    App,
    FromBody,
    Headers,
    Json,
    JsonWriter,
    Request,
    Response,
    State,
    ToErrorResponse,
    ToJson,
)


# Application types.


struct Calls(Movable):
    """Counts handler calls; the counter is the oracle for "handler not
    called". `methods` logs the method each raw call received."""

    var n: ArcPointer[Int]
    var methods: ArcPointer[String]

    def __init__(out self):
        self.n = ArcPointer(0)
        self.methods = ArcPointer(String())


@fieldwise_init
struct Item(ToJson):
    var id: Int

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("id")
        out.int(self.id)
        out.end_object()


@fieldwise_init
struct Conflict(ToErrorResponse):
    var id: Int

    def to_error_response(deinit self) -> Response:
        return Response.text(String("conflict ", self.id), status=409)


struct Note(FromBody):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


# Handlers: `get`'s shapes, stateless and stateful.


def hello() -> String:
    return "hello"


def get_user(id: Int) -> String:
    return String("user ", id)


def name_of(name: String) -> String:
    return "name " + name


def field_of(id: Int, field: String) -> String:
    return String("field ", id, " ", field)


def page_of(size: Optional[Int]) -> String:
    if size:
        return String("page size ", size.value())
    return "page size 20"


def fields_of(id: Int, headers: Headers) -> String:
    var out = String(id)
    for i in range(len(headers)):
        out += " " + headers.name(i) + "=" + headers.value(i)
    return out^


def item(id: Int) -> Json[Item]:
    return Json(Item(id))


def reserve(id: Int) raises Conflict -> String:
    if id == 0:
        raise Conflict(id)
    return String("reserved ", id)


def failing(id: Int) raises -> String:
    raise Error("internal")


def counted(calls: State[Calls], id: Int) -> String:
    calls[].n[] += 1
    return String("counted ", id)


def counted_fields(calls: State[Calls], id: Int, headers: Headers) -> String:
    calls[].n[] += 1
    return String("counted ", id, " ", len(headers))


# Raw handlers follow DX's raw rule: the `GET` answer for `HEAD` too. The
# stateful one records the method it received in its state.


def page(var req: Request) -> Response:
    var r = Response.text("page " + req.path + "?" + req.query)
    try:
        r.headers.add("X-Page", req.path)
    except:
        pass
    return r^


def keyed(calls: State[Calls], var req: Request) -> Response:
    calls[].n[] += 1
    calls[].methods[] += req.method + ";"
    return Response.text("keyed")


def posted(body: Note) -> String:
    return "posted " + body.text


def posted_id(id: Int, body: Note) -> String:
    return String("posted ", id, " ", body.text)


def removed(id: Int) -> String:
    return String("removed ", id)


def _app(calls: State[Calls]) -> App:
    var app = App()
    app.get["/hello"](hello)
    app.get["/users/{id}"](get_user)
    app.get["/names/{name}"](name_of)
    app.get["/fields/{id}?{field}"](field_of)
    app.get["/pages?{size}"](page_of)
    app.get["/h/{id}"](fields_of)
    app.get["/items/{id}"](item)
    app.get["/stock/{id}"](reserve)
    app.get["/fail/{id}"](failing)
    app.get["/count/{id}"](counted, calls)
    app.get["/count-h/{id}"](counted_fields, calls)
    app.get["/report"](page)
    app.get["/keyed"](keyed, calls)
    app.post["/only-post"](posted)
    app.put["/only-put"](posted)
    app.patch["/only-patch"](posted)
    app.delete["/only-delete/{id}"](removed)
    return app^


def _h(*pairs: String) raises -> Headers:
    var h = Headers()
    var i = 0
    while i + 1 < len(pairs):
        h.add(pairs[i], pairs[i + 1])
        i += 2
    return h^


def _dump(h: Headers) -> String:
    var out = String()
    for i in range(len(h)):
        out += h.name(i) + "=" + h.value(i) + ";"
    return out^


def _same_as_get(
    app: App,
    target: String,
    status: Int,
    body: String,
    headers: Headers = Headers(),
) raises:
    """`GET target` answers `status` and `body`, and `HEAD target` answers
    exactly that, body and header fields included."""
    var get = app.handle(Request("GET", target, "", headers.copy()))
    var head = app.handle(Request("HEAD", target, "", headers.copy()))
    assert_equal(get.status, status, target)
    assert_equal(get.body, body, target)
    assert_equal(head.status, get.status, target)
    assert_equal(head.body, get.body, target)
    assert_equal(_dump(head.headers), _dump(get.headers), target)


def test_head_answers_what_get_answers_on_every_get_shape() raises:
    var calls = State(Calls())
    var app = _app(calls)
    _same_as_get(app, "/hello", 200, "hello")
    _same_as_get(app, "/hello?x=1", 200, "hello")
    _same_as_get(app, "/users/042", 200, "user 42")
    _same_as_get(app, "/names/J%C3%B6rg", 200, "name Jörg")
    # Two route values, each decoded once.
    _same_as_get(app, "/fields/7?field=%2541+b", 200, "field 7 %41 b")
    # An optional value: absent, empty and present.
    _same_as_get(app, "/pages", 200, "page size 20")
    _same_as_get(app, "/pages?size=", 200, "page size 20")
    _same_as_get(app, "/pages?size=5", 200, "page size 5")
    # The `Headers` slot receives the request's fields, in order.
    _same_as_get(app, "/h/3", 200, "3 X-A=1 x-a=2", _h("X-A", "1", "x-a", "2"))
    # Stateful, with and without `Headers`.
    _same_as_get(app, "/count/5", 200, "counted 5")
    _same_as_get(app, "/count-h/5", 200, "counted 5 1", _h("X-A", "1"))
    assert_equal(calls[].n[], 4)


def test_head_converts_results_and_errors_as_get_does() raises:
    var app = _app(State(Calls()))
    _same_as_get(app, "/items/7", 200, '{"id":7}')
    var head = app.handle(Request("HEAD", "/items/7"))
    assert_equal(head.headers.get("content-type").value(), "application/json")
    # A `ToErrorResponse` raise, its return, and the fixed 500.
    _same_as_get(app, "/stock/0", 409, "conflict 0")
    _same_as_get(app, "/stock/3", 200, "reserved 3")
    _same_as_get(app, "/fail/1", 500, "Internal Server Error")


def test_head_bad_request_calls_no_handler() raises:
    var calls = State(Calls())
    var app = _app(calls)
    for target in [
        "/count/x",
        "/count/%zz",
        "/count-h/x",
        "/fields/7",
        "/fields/7?field=1&field=2",
        "/pages?size=x",
    ]:
        var head = app.handle(Request("HEAD", target, "", _h("X-A", "1")))
        assert_equal(head.status, 400, target)
        assert_equal(head.body, "Bad Request", target)
    assert_equal(calls[].n[], 0)
    _same_as_get(app, "/users/abc", 400, "Bad Request")


def test_raw_get_handler_sees_head() raises:
    var calls = State(Calls())
    var app = _app(calls)
    # A raw handler that gives `HEAD` its `GET` answer is answered the same.
    _same_as_get(app, "/report?a=1", 200, "page /report?a=1")
    var head = app.handle(Request("HEAD", "/report?a=1"))
    assert_equal(_dump(head.headers), "X-Page=/report;")
    # It receives the request as sent: `_same_as_get` sends GET, then HEAD.
    _same_as_get(app, "/keyed", 200, "keyed")
    assert_equal(calls[].methods[], "GET;HEAD;")
    assert_equal(calls[].n[], 2)


def test_head_only_reaches_get_routes() raises:
    var app = _app(State(Calls()))
    # Paths served only by routes of other methods, and no route at all.
    for target in [
        "/only-post",
        "/only-put",
        "/only-patch",
        "/only-delete/1",
        "/missing",
        "/users",
    ]:
        var r = app.handle(Request("HEAD", target, "x"))
        assert_equal(r.status, 404, target)
        assert_equal(r.body, "Not Found", target)
    # Only the exact token maps; every other method stays byte for byte.
    for method in ["head", "Head", "HEAD ", "OPTIONS"]:
        for target in ["/hello", "/users/7", "/report"]:
            var r = app.handle(Request(method, target))
            assert_equal(r.status, 404, String(method, " ", target))
            assert_equal(r.body, "Not Found", String(method, " ", target))


def first(id: Int) -> String:
    return String("first ", id)


def second(id: Int) -> String:
    return String("second ", id)


def by_name(name: String) -> String:
    return "by name " + name


def test_first_registration_wins_and_never_falls_through() raises:
    var app = App()
    # Another method first on the path: HEAD skips it and reaches the get.
    app.post["/a/{id}"](posted_id)
    app.get["/a/{id}"](first)
    # The get first: it answers, the route after it is never tried.
    app.get["/b/{id}"](first)
    app.delete["/b/{id}"](removed)
    app.get["/b/{id}"](second)
    # A get route that answers 400 does not fall through to the next.
    app.get["/c/{id}"](first)
    app.get["/c/{name}"](by_name)
    _same_as_get(app, "/a/1", 200, "first 1")
    _same_as_get(app, "/b/2", 200, "first 2")
    _same_as_get(app, "/c/x", 400, "Bad Request")
    assert_equal(app.handle(Request("DELETE", "/b/2")).body, "removed 2")


# docs/DX.md, "`HEAD`" in "Proven vs. target status", as written there.


def show_user(id: Int) -> String:
    return String("user ", id)


def report(req: Request) -> Response:  # raw: req.method is "GET" or "HEAD"
    return Response.text("report")  # the GET body for both


def drop(id: Int) -> String:
    return String("dropped ", id)


def test_dx_example() raises:
    var app = App()  # its own App
    app.get["/users/{id}"](show_user)
    app.get["/report"](report)
    app.delete["/cache/{id}"](drop)
    _same_as_get(app, "/users/7", 200, "user 7")
    _same_as_get(app, "/users/abc", 400, "Bad Request")
    _same_as_get(app, "/report", 200, "report")
    for r in [
        app.handle(Request("HEAD", "/cache/1")),
        app.handle(Request("HEAD", "/missing")),
        app.handle(Request("head", "/users/7")),
        app.handle(Request("OPTIONS", "/users/7")),
    ]:
        assert_equal(r.status, 404)
        assert_equal(r.body, "Not Found")
    assert_equal(app.handle(Request("DELETE", "/cache/1")).body, "dropped 1")

    var head = app.handle(Request("HEAD", "/users/7"))  # no TestClient.head
    assert_equal(head.status, 200)
    assert_equal(head.text(), "user 7")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
