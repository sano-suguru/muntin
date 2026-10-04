# M3-012 typed header access decision spike, application side: the
# carrier model in tests/header_access_spike.mojo on the three body shapes,
# composed with `Json[T]` and with `State`, and the raw-slot adapter
# function on production `App` that the decision records as the `GET` path
# it leaves to application code. Decision and evidence: docs/ARCHITECTURE.md,
# "Typed header access decision (M3-012)".

from std.testing import assert_equal, TestSuite

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
)
from muntin.testing import TestClient

from header_access_spike import CarrierApp, SpikeWithHeaders


@fieldwise_init
struct Note(FromBody, Movable):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        if body == "bad":
            raise Error("bad body")
        return Self(body)


@fieldwise_init
struct CreateUser(FromJson):
    var name: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string())


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


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(deinit self) -> Response:
        return Response.text("Unauthorized", status=401)


struct Prefix(Movable):
    var text: String

    def __init__(out self, text: String):
        self.text = text


def _fields(h: Headers) -> String:
    var out = String()
    for i in range(len(h)):
        out += " " + h.name(i) + "=<" + h.value(i) + ">"
    return out


def note(input: SpikeWithHeaders[Note]) -> Response:
    """Echoes the body and every field; `get` decides presence."""
    var key = input.headers.get("x-api-key")
    var shown = ("<" + key.value() + ">") if key else String("absent")
    return Response.text(
        input.body.text + " key=" + shown + _fields(input.headers)
    )


def note_int(id: Int, input: SpikeWithHeaders[Note]) -> Response:
    return Response.text(
        String(id) + " " + input.body.text + _fields(input.headers)
    )


def note_state(
    prefix: State[Prefix], var input: SpikeWithHeaders[Note]
) -> Response:
    var body = input^.take_body()
    return Response.text(prefix[].text + body.text)


def note_state_fields(
    prefix: State[Prefix], input: SpikeWithHeaders[Note]
) -> Response:
    return Response.text(prefix[].text + _fields(input.headers))


def create(
    input: SpikeWithHeaders[Json[CreateUser]],
) raises Unauthorized -> Json[User]:
    if not input.headers.get("authorization"):
        raise Unauthorized()
    return Json(User(1, input.body.value.name))


def create_int(
    id: Int, input: SpikeWithHeaders[Json[CreateUser]]
) -> Json[User]:
    return Json(User(id, input.body.value.name))


def plain_json(body: Json[CreateUser]) -> Json[User]:
    return Json(User(0, body.value.name))


def plain(body: Note) -> Response:
    return Response.text("plain " + body.text)


def _app() -> CarrierApp:
    var prefix = State(Prefix("p:"))
    var app = CarrierApp()
    app.post["/note"](note)
    app.post["/note/{id}"](note_int)
    app.post["/snote"](note_state, prefix)
    app.post["/sfields"](note_state_fields, prefix)
    app.post["/users"](create)
    app.post["/users/{id}"](create_int)
    app.post["/plain-json"](plain_json)
    app.post["/plain"](plain)
    return app^


def _h(*pairs: String) raises -> Headers:
    var h = Headers()
    var i = 0
    while i + 1 < len(pairs):
        h.add(pairs[i], pairs[i + 1])
        i += 2
    return h^


def _post(
    app: CarrierApp, target: String, body: String, var h: Headers
) -> Response:
    return app.handle(Request("POST", target, body, h^))


def test_fields_reach_the_carrier_in_order_with_casing_and_repeats() raises:
    var app = _app()
    var r = _post(
        app,
        "/note",
        "hi",
        _h("X-API-Key", "k1", "X-A", "1", "Set-Cookie", "a=1", "x-a", "2"),
    )
    assert_equal(r.status, 200)
    assert_equal(
        r.body,
        "hi key=<k1> X-API-Key=<k1> X-A=<1> Set-Cookie=<a=1> x-a=<2>",
    )


def test_missing_and_empty_fields_are_the_handlers_to_read() raises:
    var app = _app()
    # Muntin interprets no field on a carrier route: absent is None.
    assert_equal(_post(app, "/note", "hi", Headers()).body, "hi key=absent")
    assert_equal(
        _post(app, "/note", "hi", _h("X-API-Key", "")).body,
        "hi key=<> X-API-Key=<>",
    )


def test_body_conversion_failure_is_400_with_fields_present() raises:
    var app = _app()
    var r = _post(app, "/note", "bad", _h("X-API-Key", "k1"))
    assert_equal(r.status, 400)
    assert_equal(r.body, "Bad Request")


def test_route_value_then_carrier() raises:
    var app = _app()
    assert_equal(
        _post(app, "/note/7", "hi", _h("X-1", "a")).body, "7 hi X-1=<a>"
    )
    # The route value is converted first: 400 before the body.
    assert_equal(_post(app, "/note/x", "bad", _h("X-1", "a")).status, 400)
    assert_equal(_post(app, "/note/7", "bad", _h("X-1", "a")).status, 400)


def test_composes_with_state() raises:
    var app = _app()
    assert_equal(_post(app, "/snote", "hi", _h("A", "b")).body, "p:hi")
    assert_equal(
        _post(app, "/sfields", "hi", _h("A", "b", "a", "c")).body,
        "p: A=<b> a=<c>",
    )


def test_json_body_keeps_its_order_inside_the_carrier() raises:
    var app = _app()
    var ok = String('{"name":"Ada"}')
    var json_type = String("application/json")
    var r = _post(
        app, "/users", ok, _h("Content-Type", json_type, "Authorization", "t")
    )
    assert_equal(r.status, 200)
    assert_equal(r.body, '{"id":1,"name":"Ada"}')
    assert_equal(r.headers.get("content-type").value(), "application/json")
    # 415 without exactly one JSON Content-Type, whatever else is sent;
    # a field named "1" cannot stand in for the verdict.
    assert_equal(_post(app, "/users", ok, _h("Authorization", "t")).status, 415)
    assert_equal(_post(app, "/users", ok, _h("1", "1")).status, 415)
    assert_equal(
        _post(
            app,
            "/users",
            ok,
            _h("Content-Type", json_type, "Content-Type", json_type),
        ).status,
        415,
    )
    # 413 after 415, before parsing; malformed JSON is 400.
    var big = String("x") * 1_048_577  # over the cap; never parsed
    assert_equal(_post(app, "/users", big, Headers()).status, 415)
    assert_equal(
        _post(app, "/users", big, _h("Content-Type", json_type)).status, 413
    )
    assert_equal(
        _post(app, "/users", "{", _h("Content-Type", json_type)).status, 400
    )
    # A missing field is the handler's decision: here its own 401.
    r = _post(app, "/users", ok, _h("Content-Type", json_type))
    assert_equal(r.status, 401)
    # Route value first, then 415, 413, 400.
    assert_equal(_post(app, "/users/x", big, Headers()).status, 400)
    assert_equal(_post(app, "/users/5", ok, Headers()).status, 415)
    assert_equal(
        _post(app, "/users/5", big, _h("Content-Type", json_type)).status, 413
    )
    r = _post(app, "/users/5", ok, _h("Content-Type", json_type, "X", "y"))
    assert_equal(r.body, '{"id":5,"name":"Ada"}')


def test_other_body_routes_receive_no_fields() raises:
    var app = _app()
    # The JSON adapter's arity check is exact on a plain Json[T] route: it
    # would answer 415 if field strings followed the verdict.
    var r = _post(
        app,
        "/plain-json",
        '{"name":"Ada"}',
        _h("Content-Type", "application/json", "X-A", "1"),
    )
    assert_equal(r.status, 200)
    assert_equal(_post(app, "/plain", "hi", _h("X-A", "1")).body, "plain hi")


def test_unmatched_is_404() raises:
    var app = _app()
    assert_equal(_post(app, "/nope", "hi", _h("X-A", "1")).status, 404)


# The GET path the decision leaves to application code: a function
# parameterized by a typed handler is itself a raw handler, so production
# `App` registers it on the existing raw `get` overloads, stateless and
# stateful. No Muntin change; it has no route values (raw literals declare
# none) and the result policy is the helper's.


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
        client.get("/me", headers=_h("Authorization", "t")).body, "me t"
    )
    assert_equal(client.get("/me").status, 401)
    assert_equal(
        client.get("/count", headers=_h("A", "1", "B", "2")).body, "p:2"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
