# Typed header access for `post` handlers in production (M3-013): the
# `WithHeaders[B]` body carrier in the body slot of `App.post` (body only and
# route value then body, stateless and stateful, `String` and `ToResponse`
# results), through `App.handle` and `TestClient` (`headers=`), composed with
# `State` and `Json[T]`; the routes that take no carrier unchanged; and
# docs/DX.md section 4's typed header access example as written there. Decision:
# docs/history/architecture-decisions.md, "Typed header access decision
# (M3-012)". Must-not-compile counterparts: tests/with_headers_api_fail.

from std.collections import Optional
from std.testing import assert_equal, assert_true, TestSuite

from muntin import (
    App,
    FromBody,
    FromJson,
    Headers,
    Json,
    JsonValue,
    JsonWriter,
    Request,
    Response,
    State,
    ToErrorResponse,
    ToJson,
    ToResponse,
    WithHeaders,
)
from muntin.testing import TestClient

from muntin.http import _Field


# Application types.


struct Note(FromBody, Movable):
    """A move-only body: `take_body` must move it out, never copy it."""

    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        if body == "bad":
            raise Error("bad body")
        return Self(body)


@fieldwise_init
struct Name(FromJson):
    var name: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string())


@fieldwise_init
struct Named(ToJson):
    var id: Int
    var name: String

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("id")
        out.int(self.id)
        out.name("name")
        out.string(self.name)
        out.end_object()


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(deinit self) -> Response:
        return Response.text("Unauthorized", status=401)


struct Prefix(Movable):
    var text: String

    def __init__(out self, text: String):
        self.text = text


def _fields(h: Headers) -> String:
    """Every field in order, with its casing and value."""
    var out = String()
    for i in range(len(h)):
        out += " " + h.name(i) + "=<" + h.value(i) + ">"
    return out


def _count(p: State[Prefix]) -> String:
    """The handle's reference count, read inside a request."""
    return String(p._shared.count())


# One carrier handler per body overload. Each echoes the body and every
# field; the stateful ones also echo the state and the reference count.


def s_body(var input: WithHeaders[Note]) -> String:
    var fields = _fields(input.headers)
    var note = input^.take_body()  # move-only body, moved out whole
    return "s_body " + note.text + fields


def r_body(input: WithHeaders[Note]) -> Response:
    return Response.text("r_body " + input.body.text + _fields(input.headers))


def s_int_body(id: Int, input: WithHeaders[Note]) -> String:
    return (
        "s_int_body "
        + String(id)
        + " "
        + input.body.text
        + _fields(input.headers)
    )


def r_int_body(id: Int, var input: WithHeaders[Note]) -> Response:
    var fields = _fields(input.headers)
    var note = input^.take_body()
    return Response.text("r_int_body " + String(id) + " " + note.text + fields)


def st_s_body(p: State[Prefix], input: WithHeaders[Note]) -> String:
    return (
        "st_s_body "
        + p[].text
        + _count(p)
        + " "
        + input.body.text
        + _fields(input.headers)
    )


def st_r_body(p: State[Prefix], var input: WithHeaders[Note]) -> Response:
    var fields = _fields(input.headers)
    var note = input^.take_body()
    return Response.text(
        "st_r_body " + p[].text + _count(p) + " " + note.text + fields
    )


def st_s_int_body(
    p: State[Prefix], id: Int, var input: WithHeaders[Note]
) -> String:
    var fields = _fields(input.headers)
    var note = input^.take_body()
    return (
        "st_s_int_body "
        + p[].text
        + _count(p)
        + " "
        + String(id)
        + " "
        + note.text
        + fields
    )


def st_r_int_body(
    p: State[Prefix], id: Int, input: WithHeaders[Note]
) -> Response:
    return Response.text(
        "st_r_int_body "
        + p[].text
        + _count(p)
        + " "
        + String(id)
        + " "
        + input.body.text
        + _fields(input.headers)
    )


# The carrier around `Json[T]` on each of the four body shapes. A missing
# credential is the handler's decision: its own 401.


def j_body(
    input: WithHeaders[Json[Name]],
) raises Unauthorized -> Json[Named]:
    if not input.headers.get("authorization"):
        raise Unauthorized()
    return Json(Named(0, input.body.value.name))


def j_int_body(
    id: Int, var input: WithHeaders[Json[Name]]
) raises Unauthorized -> Json[Named]:
    if not input.headers.get("authorization"):
        raise Unauthorized()
    var n = input^.take_body().take()
    return Json(Named(id, n.name))


def j_st_body(
    p: State[Prefix], input: WithHeaders[Json[Name]]
) raises Unauthorized -> Json[Named]:
    if not input.headers.get("authorization"):
        raise Unauthorized()
    return Json(Named(0, p[].text + input.body.value.name))


def j_st_int_body(
    p: State[Prefix], id: Int, input: WithHeaders[Json[Name]]
) raises Unauthorized -> String:
    if not input.headers.get("authorization"):
        raise Unauthorized()
    return p[].text + String(id) + " " + input.body.value.name


# Routes that take no carrier, registered beside the carrier routes.


def plain(body: Note) -> String:
    return "plain " + body.text


def plain_int(id: Int, body: Note) -> String:
    return "plain_int " + String(id) + " " + body.text


def plain_json(body: Json[Name]) -> Json[Named]:
    return Json(Named(0, body.value.name))


def plain_json_state(
    p: State[Prefix], id: Int, body: Json[Name]
) -> Json[Named]:
    return Json(Named(id, p[].text + body.value.name))


def raw(req: Request) raises -> Response:
    return Response.text(
        "raw " + req.method + " " + req.text() + _fields(req.headers)
    )


def state_raw(p: State[Prefix], req: Request) raises -> Response:
    return Response.text(
        "state_raw " + p[].text + req.text() + _fields(req.headers)
    )


def _app(prefix: State[Prefix]) -> App:
    var app = App()
    app.post["/s"](s_body)
    app.post["/r"](r_body)
    app.post["/s/{id}"](s_int_body)
    app.post["/rq?{id}"](r_int_body)
    app.post["/st/s"](st_s_body, prefix)
    app.post["/st/r"](st_r_body, prefix)
    app.post["/st/sq?{id}"](st_s_int_body, prefix)
    app.post["/st/r/{id}"](st_r_int_body, prefix)
    app.post["/j"](j_body)
    app.post["/j/{id}"](j_int_body)
    app.post["/jq?{id}"](j_int_body)
    app.post["/jst"](j_st_body, prefix)
    app.post["/jst/{id}"](j_st_int_body, prefix)
    app.post["/jstq?{id}"](j_st_int_body, prefix)
    app.post["/plain"](plain)
    app.post["/plain/{id}"](plain_int)
    app.post["/plain-json"](plain_json)
    app.post["/plain-json/{id}"](plain_json_state, prefix)
    app.post["/raw"](raw)
    app.get["/raw"](raw)
    app.post["/state-raw"](state_raw, prefix)
    return app^


def _h(*pairs: String) raises -> Headers:
    var h = Headers()
    var i = 0
    while i + 1 < len(pairs):
        h.add(pairs[i], pairs[i + 1])
        i += 2
    return h^


def _post(app: App, target: String, body: String, var h: Headers) -> Response:
    return app.handle(Request("POST", target, body, h^))


@fieldwise_init
struct _Shape(Copyable):
    var target: String
    var tag: String
    var id: String
    """The route value the target carries, or empty."""
    var stateful: Bool


def _shapes() -> List[_Shape]:
    """The eight carrier routes, one per body overload."""
    return [
        _Shape("/s", "s_body", "", False),
        _Shape("/r", "r_body", "", False),
        _Shape("/s/7", "s_int_body", "7", False),
        _Shape("/rq?id=7", "r_int_body", "7", False),
        _Shape("/st/s", "st_s_body", "", True),
        _Shape("/st/r", "st_r_body", "", True),
        _Shape("/st/sq?id=7", "st_s_int_body", "7", True),
        _Shape("/st/r/7", "st_r_int_body", "7", True),
    ]


def _expected(
    shape: _Shape, count: String, body: String, fields: String
) -> String:
    var out = shape.tag + " "
    if shape.stateful:
        out += "p:" + count + " "
    if shape.id:
        out += shape.id + " "
    return out + body + fields


# Tests.


def test_every_body_overload_reads_fields_in_order_with_casing_and_repeats() raises:
    # A field is sent on every shape, so a carrier route that did not get
    # its fields (a flag missing on one overload) answers without them.
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    var client = TestClient(app)
    var count = _count(prefix)
    for shape in _shapes():
        var want = _expected(
            shape,
            count,
            "hi",
            " X-API-Key=<k1> X-A=<1> Set-Cookie=<a=1> x-a=<2>",
        )
        var r = client.post(
            shape.target,
            "hi",
            headers=_h(
                "X-API-Key", "k1", "X-A", "1", "Set-Cookie", "a=1", "x-a", "2"
            ),
        )
        assert_equal(r.status, 200, shape.tag)
        assert_equal(r.text(), want, shape.tag)
        var direct = _post(
            app,
            shape.target,
            "hi",
            _h("X-API-Key", "k1", "X-A", "1", "Set-Cookie", "a=1", "x-a", "2"),
        )
        assert_equal(direct.status, r.status, shape.tag)
        assert_equal(direct.body, r.body, shape.tag)
    _ = prefix^  # the test's handle lives until here (ASAP destruction)


def test_absent_and_empty_fields_are_left_to_the_handler() raises:
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    var client = TestClient(app)
    var count = _count(prefix)
    for shape in _shapes():
        # No field: an empty `Headers`, and the handler still runs.
        var r = client.post(shape.target, "hi")
        assert_equal(r.status, 200, shape.tag)
        assert_equal(r.text(), _expected(shape, count, "hi", ""), shape.tag)
        # An empty value is a value.
        r = client.post(shape.target, "hi", headers=_h("X-Empty", ""))
        assert_equal(
            r.text(), _expected(shape, count, "hi", " X-Empty=<>"), shape.tag
        )
    _ = prefix^  # the test's handle lives until here (ASAP destruction)


def test_a_missing_field_gets_the_handlers_status() raises:
    # Muntin answers no missing field itself: the handler chose 401 through its
    # error type, on every JSON carrier shape.
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    var ok = String('{"name":"Ada"}')
    for target in ["/j", "/j/5", "/jq?id=5", "/jst", "/jst/5", "/jstq?id=5"]:
        var r = _post(app, target, ok, _h("Content-Type", "application/json"))
        assert_equal(r.status, 401, target)
        assert_equal(r.text(), "Unauthorized", target)
        r = _post(
            app,
            target,
            ok,
            _h("Content-Type", "application/json", "authorization", ""),
        )
        assert_equal(r.status, 200, target)  # present, even empty


def test_body_conversion_failure_is_400_with_fields_present() raises:
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    for shape in _shapes():
        var r = _post(app, shape.target, "bad", _h("X-API-Key", "k1"))
        assert_equal(r.status, 400, shape.tag)
        assert_equal(r.text(), "Bad Request", shape.tag)


def test_the_route_value_is_converted_first() raises:
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    # An invalid route value is 400 before the body, valid or not.
    for target in [
        "/s/x",
        "/rq?id=x",
        "/rq",
        "/st/sq?id=x",
        "/st/sq",
        "/st/r/x",
    ]:
        for body in ["hi", "bad"]:
            var r = _post(app, target, body, _h("X-A", "1"))
            assert_equal(r.status, 400, target)
    # Then the body: the route value reaches the handler first.
    assert_equal(
        _post(app, "/s/-3", "hi", _h("X-A", "1")).text(),
        "s_int_body -3 hi X-A=<1>",
    )


def test_state_composes_and_requests_do_not_touch_the_reference_count() raises:
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    var between = _count(prefix)
    var client = TestClient(app)
    for _ in range(3):
        for shape in _shapes():
            if not shape.stateful:
                continue
            var r = client.post(shape.target, "hi", headers=_h("A", "b"))
            # The count read inside the handler is the count between requests.
            assert_equal(
                r.text(), _expected(shape, between, "hi", " A=<b>"), shape.tag
            )
            assert_equal(_count(prefix), between, shape.tag)


def test_json_inside_the_carrier_keeps_the_full_order() raises:
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    var ok = String('{"name":"Ada"}')
    var big = String("x") * 1_048_577  # over the cap; never parsed
    var ct = String("application/json")
    # 404 first.
    assert_equal(_post(app, "/j/1/2", ok, _h("Content-Type", ct)).status, 404)
    # Query 400 (in `App.handle`), before 415 and 413.
    for target in ["/jq", "/jq?id=1&id=2", "/jstq", "/jstq?other=1"]:
        assert_equal(_post(app, target, big, Headers()).status, 400, target)
    # Route value 400, before 415 and 413.
    for target in ["/j/x", "/jq?id=x", "/jst/x", "/jstq?id=x"]:
        assert_equal(_post(app, target, big, Headers()).status, 400, target)
    for target in ["/j", "/j/5", "/jq?id=5", "/jst", "/jst/5", "/jstq?id=5"]:
        # 415 without exactly one JSON `Content-Type`, whatever else is
        # sent: a field named "1" cannot stand in for the verdict.
        var auth = String("t")
        assert_equal(
            _post(app, target, big, _h("Authorization", auth)).status,
            415,
            target,
        )
        assert_equal(_post(app, target, ok, _h("1", "1")).status, 415, target)
        assert_equal(
            _post(app, target, ok, _h("1", "1", "1", "1")).status, 415, target
        )
        assert_equal(
            _post(
                app, target, ok, _h("Content-Type", ct, "Content-Type", ct)
            ).status,
            415,
            target,
        )
        assert_equal(
            _post(app, target, ok, _h("Content-Type", "text/plain")).status,
            415,
            target,
        )
        # 413 after 415, before parsing.
        assert_equal(
            _post(app, target, big, _h("Content-Type", ct)).status, 413, target
        )
        # Malformed JSON or a `from_json` raise: 400, before the handler.
        assert_equal(
            _post(app, target, "{", _h("Content-Type", ct)).status, 400, target
        )
        assert_equal(
            _post(app, target, "{}", _h("Content-Type", ct)).status,
            400,
            target,
        )
        # Then the handler: its 401, or 200 with the fields.
        assert_equal(
            _post(app, target, ok, _h("Content-Type", ct)).status, 401, target
        )
        var r = _post(
            app,
            target,
            ok,
            _h("X-A", "1", "Content-Type", ct, "Authorization", auth),
        )
        assert_equal(r.status, 200, target)
    var r = _post(app, "/j/5", ok, _h("Content-Type", ct, "Authorization", "t"))
    assert_equal(r.text(), '{"id":5,"name":"Ada"}')
    assert_equal(r.headers.get("content-type").value(), "application/json")
    r = _post(app, "/jst", ok, _h("Content-Type", ct, "Authorization", "t"))
    assert_equal(r.text(), '{"id":0,"name":"p:Ada"}')
    r = _post(
        app,
        "/jstq?id=5",
        ok,
        _h(
            "Content-Type",
            "application/json; charset=utf-8",
            "Authorization",
            "t",
        ),
    )
    assert_equal(r.text(), "p:5 Ada")


def test_routes_without_a_carrier_are_unchanged_with_fields_present() raises:
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    var client = TestClient(app)
    var fields = String(" X-A=<1> x-a=<2>")
    # Typed routes without a carrier receive no header strings: the plain
    # JSON adapters' arity check is exact, so trailing fields would be 415.
    var ct = String("application/json")
    var r = _post(
        app, "/plain-json", '{"name":"Ada"}', _h("Content-Type", ct, "X-A", "1")
    )
    assert_equal(r.status, 200)
    assert_equal(r.text(), '{"id":0,"name":"Ada"}')
    r = _post(
        app,
        "/plain-json/4",
        '{"name":"Ada"}',
        _h("X-A", "1", "Content-Type", ct, "x-a", "2"),
    )
    assert_equal(r.text(), '{"id":4,"name":"p:Ada"}')
    assert_equal(
        client.post("/plain", "hi", headers=_h("X-A", "1")).text(), "plain hi"
    )
    assert_equal(
        client.post("/plain/3", "hi", headers=_h("X-A", "1")).text(),
        "plain_int 3 hi",
    )
    assert_equal(
        client.post("/plain", "bad", headers=_h("X-A", "1")).status, 400
    )
    # Raw routes still get the whole request, fields included.
    assert_equal(
        client.post("/raw", "b", headers=_h("X-A", "1", "x-a", "2")).text(),
        "raw POST b" + fields,
    )
    assert_equal(
        client.get("/raw", headers=_h("X-A", "1", "x-a", "2")).text(),
        "raw GET " + fields,
    )
    assert_equal(
        client.post(
            "/state-raw", "b", headers=_h("X-A", "1", "x-a", "2")
        ).text(),
        "state_raw p:b" + fields,
    )


def test_first_registration_wins() raises:
    var prefix = State(Prefix("p:"))
    var app = App()
    app.post["/a"](s_body)
    app.post["/a"](plain)
    app.post["/b"](plain)
    app.post["/b"](s_body)
    app.post["/c"](raw)
    app.post["/c"](st_s_body, prefix)
    app.post["/d"](st_r_body, prefix)
    app.post["/d"](raw)
    var client = TestClient(app)
    assert_equal(
        client.post("/a", "hi", headers=_h("X", "1")).text(), "s_body hi X=<1>"
    )
    assert_equal(
        client.post("/b", "hi", headers=_h("X", "1")).text(), "plain hi"
    )
    assert_equal(
        client.post("/c", "hi", headers=_h("X", "1")).text(),
        "raw POST hi X=<1>",
    )
    var want = "st_r_body p:" + _count(prefix) + " hi X=<1>"
    assert_equal(client.post("/d", "hi", headers=_h("X", "1")).text(), want)
    _ = prefix^  # the test's handle lives until here (ASAP destruction)


def test_invalid_in_memory_fields_are_the_fixed_500() raises:
    # The M3-002 known gap: `_fields` is reachable by name, so an in-memory
    # `Headers` can hold a field `add` would refuse. On a carrier route the
    # rebuild through `add` raises, and the answer is the fixed 500, not
    # 400, on every shape and before the body is converted.
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    for shape in _shapes():
        for body in ["hi", "bad"]:
            var h = Headers()
            h._fields.append(_Field("X-Inject", "a\r\nSet-Cookie: evil=1"))
            var r = _post(app, shape.target, body, h^)
            assert_equal(r.status, 500, shape.tag)
            assert_equal(r.text(), "Internal Server Error", shape.tag)
    var ok = String('{"name":"Ada"}')
    for target in ["/j", "/j/5", "/jst", "/jst/5"]:
        var h = _h("Content-Type", "application/json")
        h._fields.append(_Field("Bad Name", "v"))
        assert_equal(_post(app, target, ok, h^).status, 500, target)
    # The rebuild runs after the route value and the JSON steps: an
    # invalid route value is still 400, a JSON body without its
    # `Content-Type` 415, and one over the cap 413.
    for target in ["/s/x", "/rq?id=x", "/st/sq?id=x", "/st/r/x", "/jst/x"]:
        var h = Headers()
        h._fields.append(_Field("Bad Name", "v"))
        assert_equal(_post(app, target, "hi", h^).status, 400, target)
    var big = String("x") * 1_048_577
    for target in ["/j", "/j/5", "/jst", "/jst/5"]:
        var h = Headers()
        h._fields.append(_Field("Bad Name", "v"))
        assert_equal(_post(app, target, ok, h^).status, 415, target)
        h = _h("Content-Type", "application/json")
        h._fields.append(_Field("Bad Name", "v"))
        assert_equal(_post(app, target, big, h^).status, 413, target)
    # A route without a carrier never rebuilds the fields.
    var h = Headers()
    h._fields.append(_Field("Bad Name", "v"))
    assert_equal(_post(app, "/plain", "hi", h^).text(), "plain hi")


def test_unmatched_path_is_404_and_unmatched_method_405() raises:
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    assert_equal(_post(app, "/nope", "hi", _h("X-A", "1")).status, 404)
    var get = app.handle(Request("GET", "/s"))
    assert_equal(get.status, 405)
    assert_equal(get.text(), "Method Not Allowed")
    assert_equal(len(get.headers.get_all("Allow")), 1)
    assert_equal(get.headers.get_all("Allow")[0], "POST")


def test_a_carrier_built_by_hand_takes_explicit_headers() raises:
    var c = WithHeaders(Note("n"), _h("X-A", "1"))
    assert_equal(c.headers.get("x-a").value(), "1")
    var note = c^.take_body()
    assert_equal(note.text, "n")


# The GET path the decision leaves to application code: a function parameterized
# by a typed handler is itself a raw handler, so production `App` registers it
# as a raw `get` handler, stateless and stateful. No Muntin change; it has no
# route values (raw literals declare none) and the result policy is the
# helper's.


def headers_of[
    E: Deinitable, R: ToResponse, //, f: def(Headers) thin raises E -> R
](var req: Request) raises E -> Response:
    return f(req.headers.copy()).to_response()


def state_headers_of[
    S: Movable & Deinitable,
    E: Deinitable,
    R: ToResponse,
    //,
    f: def(State[S], Headers) thin raises E -> R,
](prefix: State[S], var req: Request) raises E -> Response:
    return f(prefix, req.headers.copy()).to_response()


def me(h: Headers) raises Unauthorized -> Response:
    var auth = h.get("authorization")
    if not auth:
        raise Unauthorized()
    return Response.text("me " + auth.value())


def me_state(prefix: State[Prefix], h: Headers) -> Response:
    return Response.text(prefix[].text + String(len(h)))


def test_raw_slot_adapter_function_on_production_app() raises:
    var prefix = State(Prefix("p:"))
    var app = App()
    app.get["/me"](headers_of[me])
    app.get["/count"](state_headers_of[me_state], prefix)
    var client = TestClient(app)
    assert_equal(
        client.get("/me", headers=_h("Authorization", "t")).text(), "me t"
    )
    assert_equal(client.get("/me").status, 401)
    assert_equal(
        client.get("/count", headers=_h("A", "1", "B", "2")).text(), "p:2"
    )


# docs/DX.md section 4, "Typed header access", as written there, with
# section 4's `CreateUser` and `User`.


@fieldwise_init
struct CreateUser(FromJson):
    var name: String
    var age: Int
    var nickname: Optional[String]

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        var nick = Optional[String]()
        var n = value.get("nickname")
        if n and not n.value().is_null():
            nick = n.value().string()
        return Self(value["name"].string(), value["age"].int(), nick^)


@fieldwise_init
struct User(ToJson):
    var id: Int
    var name: String

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("id")
        out.int(self.id)
        out.name("name")
        out.string(self.name)
        out.end_object()


struct Users(Movable):
    var token: String

    def __init__(out self, token: String):
        self.token = token

    def allows(self, token: String) -> Bool:
        return token == self.token


def create_user(
    users: State[Users], input: WithHeaders[Json[CreateUser]]
) raises Unauthorized -> Json[User]:
    var token = input.headers.get("authorization")  # Optional[String]
    if not token or not users[].allows(token.value()):
        raise Unauthorized()  # ToErrorResponse: 401
    return Json(User(1, input.body.value.name))


def update_note(id: Int, var input: WithHeaders[Note]) -> String:
    var traces = input.headers.get_all("x-trace")  # every value, in order
    var note = input^.take_body()  # the body, moved out
    return String(id, " ", note.text, " traces=", len(traces))


def test_dx_typed_header_access_example() raises:
    var users = State(Users("secret"))
    var app = App()
    app.post["/users"](create_user, users)  # stateful, body only
    app.post["/notes/{id}"](update_note)  # def(Int, B)
    var client = TestClient(app)
    var body = String('{"name":"Ada","age":36}')
    var r = client.post(
        "/users",
        body,
        headers=_h(
            "Content-Type", "application/json", "Authorization", "secret"
        ),
    )
    assert_equal(r.status, 200)
    assert_equal(r.text(), '{"id":1,"name":"Ada"}')
    r = client.post(
        "/users",
        body,
        headers=_h("Content-Type", "application/json", "Authorization", "x"),
    )
    assert_equal(r.status, 401)
    assert_equal(
        client.post(
            "/users", body, headers=_h("Content-Type", "application/json")
        ).status,
        401,
    )
    assert_equal(
        client.post(
            "/users", body, headers=_h("Authorization", "secret")
        ).status,
        415,
    )
    r = client.post(
        "/notes/3", "hi", headers=_h("X-Trace", "a", "x-trace", "b")
    )
    assert_equal(r.text(), "3 hi traces=2")
    assert_true(client.post("/notes/x", "hi").status == 400)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
