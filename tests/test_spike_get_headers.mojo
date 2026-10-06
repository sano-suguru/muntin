# M3-016 typed `get` header access decision spike, application side: a `Headers`
# request slot on `get`, last, registered through the spike's model of the six
# arity overloads (tests/get_headers_spike.mojo) on a production `App` and
# dispatched by production `App.handle`, through `App.handle` and `TestClient`
# (`headers=`); composed with an `Int` route value, `State`, both result
# policies, raises and generic forwarding; the routes without a `Headers` slot
# (registered through production `get` and `post`) unchanged. Decision:
# docs/history/architecture-decisions.md, "Typed get header access decision
# (M3-016)". Must-not-compile counterparts: tests/get_headers_fail.

from std.collections import Optional
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from muntin import (
    App,
    FromBody,
    Headers,
    Request,
    Response,
    State,
    ToErrorResponse,
    ToResponse,
    WithHeaders,
)
from muntin.testing import TestClient
from muntin.http import _Field

from get_headers_spike import get


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(deinit self) -> Response:
        return Response.text("Unauthorized", status=401)


struct Prefix(Movable):
    var text: String

    def __init__(out self, text: String):
        self.text = text


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        if body == "bad":
            raise Error("bad body")
        return Self(body)


@fieldwise_init
struct Count(ToResponse):
    var n: Int

    def to_response(deinit self) -> Response:
        return Response.text(String("count ", self.n), status=201)


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
    return out


def _get(app: App, target: String, var h: Headers) -> Response:
    return app.handle(Request("GET", target, "", h^))


# Handlers.


def all_fields(headers: Headers) -> String:
    return _dump(headers)


def owned_fields(var headers: Headers) raises -> String:
    headers.set("X-Mine", "1")  # the handler's own value
    return _dump(headers)


def me(headers: Headers) raises Unauthorized -> String:
    var auth = headers.get("authorization")
    if not auth:
        raise Unauthorized()
    return "me " + auth.value()


def by_id(id: Int, headers: Headers) -> String:
    return String(id, " ", _dump(headers))


def counted(headers: Headers) -> Count:
    return Count(len(headers))


def static_text(headers: Headers) -> StaticString:
    return "static"


def raising(headers: Headers) raises -> String:
    raise Error("internal")


def st(prefix: State[Prefix], headers: Headers) -> String:
    return prefix[].text + _dump(headers)


def st_id(prefix: State[Prefix], id: Int, headers: Headers) -> String:
    return String(prefix[].text, id, " ", _dump(headers))


def plain_id(id: Int) -> String:
    return String("plain ", id)


def raw(var req: Request) -> Response:
    return Response.text(String("raw ", len(req.headers)))


def update(id: Int, input: WithHeaders[Note]) -> String:
    return String(id, " ", input.body.text, " ", _dump(input.headers))


# Generic forwarding (M3-015 edge 4) reaching the new kind.


def fwd_one[
    A: Movable & Deinitable
](mut app: App, h: def(var A) thin raises Never -> String):
    get["/fwd"](app, h)


def fwd_two[
    A: Movable & Deinitable, B: Movable & Deinitable
](mut app: App, h: def(var A, var B) thin raises Never -> String):
    get["/fwd/{id}"](app, h)


def fwd_state[
    S: Movable & Deinitable, A: Movable & Deinitable
](
    mut app: App,
    h: def(State[S], var A) thin raises Never -> String,
    s: State[S],
):
    get["/fwd-state"](app, h, s)


def fwd_typed(mut app: App, h: def(var Headers) thin raises Never -> String):
    get["/fwd-typed"](app, h)


def _app(prefix: State[Prefix]) -> App:
    var app = App()
    get["/all"](app, all_fields)
    get["/owned"](app, owned_fields)
    get["/me"](app, me)
    get["/p/{id}"](app, by_id)
    get["/q?{id}"](app, by_id)
    get["/count"](app, counted)
    get["/static"](app, static_text)
    get["/raise"](app, raising)
    get["/st"](app, st, prefix)
    get["/st/{id}"](app, st_id, prefix)
    app.get["/plain/{id}"](plain_id)
    app.get["/raw"](raw)
    app.post["/n/{id}"](update)
    return app^


def test_fields_in_order_with_casing_repeats_and_empty() raises:
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    var r = _get(app, "/all", _h("X-A", "1", "x-a", "2", "E", "", "B", "3"))
    assert_equal(r.status, 200)
    assert_equal(r.body, "X-A=1;x-a=2;E=;B=3;")
    assert_equal(_get(app, "/all", Headers()).body, "")


def test_owned_slot_is_a_fresh_value() raises:
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    var req = Request("GET", "/owned", "", _h("A", "1"))
    var r = app.handle(req)
    assert_equal(r.body, "A=1;X-Mine=1;")
    assert_equal(len(req.headers), 1)  # the request's fields are untouched


def test_missing_field_is_the_handlers_status() raises:
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    assert_equal(_get(app, "/me", Headers()).status, 401)
    assert_equal(_get(app, "/me", _h("Authorization", "t")).body, "me t")


def test_route_value_then_headers() raises:
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    assert_equal(_get(app, "/p/7", _h("A", "1")).body, "7 A=1;")
    assert_equal(_get(app, "/q?id=8", _h("A", "1")).body, "8 A=1;")
    assert_equal(_get(app, "/p/x", _h("A", "1")).status, 400)
    assert_equal(_get(app, "/q", _h("A", "1")).status, 400)
    assert_equal(_get(app, "/q?id=1&id=2", _h("A", "1")).status, 400)


def test_results_and_raises() raises:
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    var c = _get(app, "/count", _h("A", "1", "B", "2"))
    assert_equal(c.status, 201)
    assert_equal(c.body, "count 2")
    assert_equal(_get(app, "/static", Headers()).body, "static")
    assert_equal(_get(app, "/raise", Headers()).status, 500)


def test_state_composes() raises:
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    var before = prefix._shared.count()
    assert_equal(_get(app, "/st", _h("A", "1")).body, "p:A=1;")
    assert_equal(_get(app, "/st/3", _h("A", "1")).body, "p:3 A=1;")
    assert_equal(_get(app, "/st/x", _h("A", "1")).status, 400)
    assert_equal(prefix._shared.count(), before)
    _ = app^  # keep the routes' handles alive past the read (ASAP)


def test_gap_field_is_the_fixed_500_after_the_route_value() raises:
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    for target in ["/all", "/owned", "/p/1", "/q?id=1", "/st", "/st/1"]:
        var h = Headers()
        h._fields.append(_Field("Bad Name", "v"))
        assert_equal(_get(app, target, h^).status, 500, target)
    for target in ["/p/x", "/q?id=x", "/st/x"]:
        var h = Headers()
        h._fields.append(_Field("Bad Name", "v"))
        assert_equal(_get(app, target, h^).status, 400, target)
    # A route without a Headers slot never rebuilds the fields.
    var h = Headers()
    h._fields.append(_Field("Bad Name", "v"))
    assert_equal(_get(app, "/plain/4", h^).body, "plain 4")


def test_other_routes_unchanged_with_fields_present() raises:
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    assert_equal(_get(app, "/plain/4", _h("A", "1")).body, "plain 4")
    assert_equal(_get(app, "/raw", _h("A", "1", "B", "2")).body, "raw 2")
    var r = app.handle(Request("POST", "/n/2", "hi", _h("A", "1")))
    assert_equal(r.body, "2 hi A=1;")


def test_testclient_headers() raises:
    var prefix = State(Prefix("p:"))
    var app = _app(prefix)
    var client = TestClient(app)
    assert_equal(client.get("/all", headers=_h("X", "y")).body, "X=y;")
    assert_equal(client.get("/all").body, "")
    assert_equal(client.get("/p/2", headers=_h("X", "y")).body, "2 X=y;")
    assert_equal(client.get("/missing").status, 404)


def test_first_registration_wins() raises:
    var app = App()
    app.get["/a/{id}"](plain_id)
    get["/a/{id}"](app, by_id)
    get["/b/{id}"](app, by_id)
    app.get["/b/{id}"](plain_id)
    assert_equal(_get(app, "/a/1", _h("A", "1")).body, "plain 1")
    assert_equal(_get(app, "/b/1", _h("A", "1")).body, "1 A=1;")


def test_generic_and_typed_forwarding() raises:
    var app = App()
    fwd_one(app, all_fields)
    fwd_two(app, by_id)
    fwd_state(app, st, State(Prefix("s:")))
    fwd_typed(app, all_fields)
    var typed: def(var Headers) thin raises Never -> String = all_fields
    get["/typed"](app, typed)
    assert_equal(_get(app, "/fwd", _h("A", "1")).body, "A=1;")
    assert_equal(_get(app, "/fwd/5", _h("A", "1")).body, "5 A=1;")
    assert_equal(_get(app, "/fwd-state", _h("A", "1")).body, "s:A=1;")
    assert_equal(_get(app, "/fwd-typed", _h("A", "1")).body, "A=1;")
    assert_equal(_get(app, "/typed", _h("A", "1")).body, "A=1;")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
