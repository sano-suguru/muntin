# TestClient request header fields (M3-011): `TestClient.get` and `.post` take a
# keyword-only, defaulted `headers=` argument and move it into the `Request`
# they send through `App.handle`. Every response is compared with
# `App.handle(Request(...))` built from the same arguments. Decision:
# docs/history/architecture-decisions.md, "TestClient request headers decision
# (M3-010)". Must-not-compile evidence: tests/testclient_headers_api_fail.

from std.testing import assert_equal, TestSuite

from muntin import (
    App,
    FromJson,
    Headers,
    Json,
    JsonValue,
    JsonWriter,
    Request,
    Response,
    ToJson,
)
from muntin.testing import TestClient


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


def hello() -> String:
    return "hello"


def create_user(body: Json[CreateUser]) -> Json[User]:
    return Json(User(1, body.value.name))


def _spliced(head: String, body: List[UInt8], tail: String = "") -> List[UInt8]:
    """`head`'s bytes, the body bytes unread, then `tail`'s bytes."""
    var out = List(head.as_bytes())
    out.extend(Span(body))
    out.extend(Span(tail.as_bytes()))
    return out^


def echo(req: Request) -> Response:
    """Answers with the method, path, body and every header field, in
    order, each value in angle brackets."""
    var out = String("]")
    for i in range(len(req.headers)):
        out += " " + req.headers.name(i) + "=<" + req.headers.value(i) + ">"
    return Response(
        200, _spliced(req.method + " " + req.path + " [", req.body, out)
    )


def empty_probe(req: Request) -> Response:
    """Distinguishes an empty value from an absent field."""
    var v = req.headers.get("x-empty")
    if not v:
        return Response.text("absent")
    return Response.text("present <" + v.value() + ">")


def _app() -> App:
    var app = App()
    app.get["/hello"](hello)
    app.get["/echo"](echo)
    app.post["/echo"](echo)
    app.get["/empty"](empty_probe)
    app.post["/users"](create_user)
    return app^


def _fields(h: Headers) -> String:
    var out = String()
    for i in range(len(h)):
        out += h.name(i) + "=" + h.value(i) + ";"
    return out^


def _assert_same(got: Response, want: Response) raises:
    """The client's answer equals `App.handle`'s: status, body and every
    response field in order."""
    assert_equal(got.status, want.status)
    assert_equal(got.body, want.body)
    assert_equal(_fields(got.headers), _fields(want.headers))


def test_bare_forms_are_unchanged() raises:
    var app = _app()
    var client = TestClient(app)
    var g = client.get("/hello")
    assert_equal(g.status, 200)
    assert_equal(g.text(), "hello")
    _assert_same(g, app.handle(Request("GET", "/hello")))
    var p = client.post("/echo", "b")
    assert_equal(p.text(), "POST /echo [b]")
    _assert_same(p, app.handle(Request("POST", "/echo", "b")))
    var missing = client.get("/missing")
    assert_equal(missing.status, 404)
    _assert_same(missing, app.handle(Request("GET", "/missing")))
    var wrong_method = client.post("/hello", "")
    assert_equal(wrong_method.status, 405)
    assert_equal(wrong_method.text(), "Method Not Allowed")
    assert_equal(len(wrong_method.headers.get_all("Allow")), 1)
    assert_equal(wrong_method.headers.get_all("Allow")[0], "GET, HEAD")
    _assert_same(wrong_method, app.handle(Request("POST", "/hello", "")))


def test_get_with_headers() raises:
    var app = _app()
    var client = TestClient(app)
    var h = Headers()
    h.add("X-Request-Id", "42")
    var r = client.get("/echo?x=1", headers=h.copy())
    assert_equal(r.status, 200)
    assert_equal(r.text(), "GET /echo [] X-Request-Id=<42>")
    _assert_same(r, app.handle(Request("GET", "/echo?x=1", "", h.copy())))
    # A typed route reads no fields; sending some changes nothing.
    _assert_same(client.get("/hello", headers=h.copy()), client.get("/hello"))


def test_post_with_headers() raises:
    var app = _app()
    var client = TestClient(app)
    var h = Headers()
    h.add("Authorization", "Bearer t")
    var r = client.post("/echo", "payload", headers=h.copy())
    assert_equal(r.text(), "POST /echo [payload] Authorization=<Bearer t>")
    _assert_same(r, app.handle(Request("POST", "/echo", "payload", h^)))


def test_repeated_fields_keep_order_and_casing() raises:
    var app = _app()
    var client = TestClient(app)
    var h = Headers()
    h.add("X-A", "1")
    h.add("Set-Cookie", "a=1")
    h.add("x-a", "2")
    h.add("Set-Cookie", "b=2")
    var r = client.post("/echo", "", headers=h.copy())
    assert_equal(
        r.text(),
        "POST /echo [] X-A=<1> Set-Cookie=<a=1> x-a=<2> Set-Cookie=<b=2>",
    )
    _assert_same(r, app.handle(Request("POST", "/echo", "", h.copy())))
    _assert_same(
        client.get("/echo", headers=h.copy()),
        app.handle(Request("GET", "/echo", "", h^)),
    )


def test_empty_value_is_sent_as_a_value() raises:
    var app = _app()
    var client = TestClient(app)
    var h = Headers()
    h.add("X-Empty", "")
    var r = client.get("/empty", headers=h.copy())
    assert_equal(r.text(), "present <>")
    _assert_same(r, app.handle(Request("GET", "/empty", "", h^)))
    assert_equal(client.get("/empty").text(), "absent")


def test_ownership_follows_request() raises:
    var app = _app()
    var client = TestClient(app)
    var h = Headers()
    h.add("X-A", "1")
    # `.copy()` leaves `h` usable; changing it later does not reach a
    # request already sent, and the next request sends the new fields.
    var first = client.get("/echo", headers=h.copy())
    h.add("X-B", "2")
    assert_equal(first.text(), "GET /echo [] X-A=<1>")
    assert_equal(len(h), 2)
    var second = client.get("/echo", headers=h.copy())
    assert_equal(second.text(), "GET /echo [] X-A=<1> X-B=<2>")
    # `^` moves the fields in (using `h` afterwards does not compile:
    # tests/testclient_headers_api_fail/use_after_move.mojo).
    var moved = client.post("/echo", "b", headers=h^)
    assert_equal(moved.text(), "POST /echo [b] X-A=<1> X-B=<2>")


def test_default_is_empty_on_every_call() raises:
    var app = _app()
    var client = TestClient(app)
    var h = Headers()
    h.add("X-A", "1")
    _ = client.get("/echo", headers=h.copy())
    _ = client.post("/echo", "", headers=h^)
    assert_equal(client.get("/echo").text(), "GET /echo []")
    assert_equal(client.post("/echo", "").text(), "POST /echo []")


def test_json_body_route_needs_the_field() raises:
    var app = _app()
    var client = TestClient(app)
    var body = String('{"name":"Ada"}')
    var json = Headers()
    json.add("Content-Type", "application/json")
    var ok = client.post("/users", body, headers=json.copy())
    assert_equal(ok.status, 200)
    assert_equal(ok.text(), '{"id":1,"name":"Ada"}')
    assert_equal(_fields(ok.headers), "Content-Type=application/json;")
    _assert_same(ok, app.handle(Request("POST", "/users", body, json.copy())))
    # Without the field the M3-008 rule still answers 415, as today.
    var missing = client.post("/users", body)
    assert_equal(missing.status, 415)
    assert_equal(missing.text(), "Unsupported Media Type")
    _assert_same(missing, app.handle(Request("POST", "/users", body)))
    var plain = Headers()
    plain.add("Content-Type", "text/plain")
    _assert_same(
        client.post("/users", body, headers=plain.copy()),
        app.handle(Request("POST", "/users", body, plain.copy())),
    )
    assert_equal(client.post("/users", body, headers=plain^).status, 415)
    var twice = json.copy()
    twice.add("Content-Type", "application/json")
    _assert_same(
        client.post("/users", body, headers=twice.copy()),
        app.handle(Request("POST", "/users", body, twice.copy())),
    )
    assert_equal(client.post("/users", body, headers=twice^).status, 415)
    var charset = Headers()
    charset.add("content-type", "application/json; charset=utf-8")
    assert_equal(client.post("/users", body, headers=charset^).status, 200)
    var malformed = client.post("/users", "{", headers=json.copy())
    assert_equal(malformed.status, 400)
    _assert_same(malformed, app.handle(Request("POST", "/users", "{", json^)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
