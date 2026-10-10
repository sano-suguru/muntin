# Binary request and response bodies (M3-040): `Request.body` and
# `Response.body` hold bytes, a raw handler receives and returns any bytes,
# and a typed text body reads them as UTF-8 or answers 400. Every comparison
# of bytes is by length and byte by byte, never through a lossy `String`.

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import (
    App,
    FromBody,
    FromJson,
    Headers,
    Json,
    JsonValue,
    Next,
    Request,
    Response,
    WithHeaders,
)
from muntin.testing import TestClient

comptime FROM_BODY_CALLED = "MUNTIN_TEST_BINARY_FROM_BODY_CALLED"


def _octets(values: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for v in values:
        out.append(UInt8(v))
    return out^


def _every_byte() -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(256):
        out.append(UInt8(i))
    for i in range(256):
        out.append(UInt8(255 - i))
    return out^


def _text_bodies() -> List[List[UInt8]]:
    """Well-formed UTF-8: ASCII, Japanese, a U+FFFD the client sent, NUL,
    empty."""
    return [
        List("hello".as_bytes()),
        List("こんにちは、世界".as_bytes()),
        _octets([0x61, 0xEF, 0xBF, 0xBD, 0x62]),
        _octets([0x61, 0x00, 0x62, 0x00]),
        _octets([0x00]),
        List[UInt8](),
    ]


def _binary_bodies() -> List[List[UInt8]]:
    """Not UTF-8: 0x80, 0xFF, a truncated sequence, an overlong form, a
    surrogate, a sent U+FFFD then 0xFF, the PNG signature, every byte."""
    return [
        _octets([0x80]),
        _octets([0xFF]),
        _octets([0xE3, 0x81]),
        _octets([0xC0, 0xAF]),
        _octets([0xED, 0xA0, 0x80]),
        _octets([0xEF, 0xBF, 0xBD, 0xFF]),
        _octets([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        _every_byte(),
    ]


def _all_bodies() -> List[List[UInt8]]:
    var out = _text_bodies()
    for b in _binary_bodies():
        out.append(b.copy())
    return out^


def _assert_same(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], String(what, ": byte ", i))


# Raw handlers.


def echo(req: Request) -> Response:
    """The raw byte echo: the body bytes back, unread."""
    return Response(200, req.body.copy())


def take(var req: Request) -> Response:
    """Owns the request and moves the body bytes into the response."""
    var body = req.body^
    req.body = List[UInt8]()
    return Response(201, body^)


def png(req: Request) -> Response:
    """A binary response a handler builds itself; Muntin adds no field."""
    var r = Response(
        200, _octets([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    )
    try:
        r.headers.add("Content-Type", "image/png")
    except:
        pass
    return r^


def as_text(req: Request) raises -> Response:
    """Reads the body as text: raises when it is not UTF-8 (the fixed
    500)."""
    return Response.text("text " + req.text())


# Typed text bodies.


struct Anything(FromBody):
    """Accepts any text, recording that `from_body` ran."""

    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        _ = setenv(FROM_BODY_CALLED, "1")
        return Self(body)


def typed(body: Anything) -> String:
    return "[" + body.text + "]"


def typed_with_headers(input: WithHeaders[Anything]) -> String:
    return "{" + input.body.text + "}"


@fieldwise_init
struct Name(FromJson):
    var name: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string())


def greet(body: Json[Name]) -> String:
    return "hello " + body.value.name


# Middleware.


def reverse(var request: Request, var next: Next) raises -> Response:
    """Replaces the body with its bytes reversed, as bytes, before the
    routes; no text conversion."""
    var reversed = List[UInt8]()
    for i in range(len(request.body)):
        reversed.append(request.body[len(request.body) - 1 - i])
    request.body = reversed^
    return next^.run(request^)


def tag(var request: Request, var next: Next) raises -> Response:
    """Passes the request on unchanged and marks the answer."""
    var response = next^.run(request^)
    response.headers.add("X-Seen", "1")
    return response^


def binary_app() -> App:
    var app = App()
    app.post["/echo"](echo)
    app.put["/echo"](echo)
    app.patch["/echo"](echo)
    app.delete["/echo"](echo)
    app.post["/take"](take)
    app.get["/png"](png)
    app.post["/text"](as_text)
    app.post["/typed"](typed)
    app.post["/carrier"](typed_with_headers)
    app.post["/greet"](greet)
    return app^


def test_raw_echo_returns_every_body_byte_for_byte() raises:
    var app = binary_app()
    var client = TestClient(app)
    for body in _all_bodies():
        # `App.handle` with a bytes `Request`, and `TestClient`'s bytes
        # overloads, which build the same `Request`.
        _assert_same(
            app.handle(Request("POST", "/echo", body.copy())).body,
            body,
            "App.handle",
        )
        var post = client.post("/echo", body.copy())
        assert_equal(post.status, 200)
        _assert_same(post.body, body, "TestClient.post")
        _assert_same(client.put("/echo", body.copy()).body, body, "put")
        _assert_same(client.patch("/echo", body.copy()).body, body, "patch")
        # A DELETE body reaches a raw handler through `App.handle`.
        _assert_same(
            app.handle(Request("DELETE", "/echo", body.copy())).body,
            body,
            "delete",
        )
        var taken = client.post("/take", body.copy())
        assert_equal(taken.status, 201)
        _assert_same(taken.body, body, "moved out")
        # Muntin adds no field, for bytes as for text.
        assert_equal(len(post.headers), 0)


def test_text_and_bytes_requests_hold_the_same_bytes() raises:
    for body in _text_bodies():
        var text = String(from_utf8=Span(body))
        var from_text = Request("POST", "/x?q=1", text)
        var from_bytes = Request("POST", "/x?q=1", body.copy())
        _assert_same(from_text.body, from_bytes.body, "Request")
        assert_equal(from_text.path, from_bytes.path)
        assert_equal(from_text.query, from_bytes.query)
        assert_equal(from_bytes.text(), text)
        _assert_same(Response(200, text).body, body, "Response")
        _assert_same(Response.text(text).body, body, "Response.text")
        assert_equal(Response(200, body.copy()).text(), text)


def test_text_of_bytes_that_are_not_utf8_raises() raises:
    for body in _binary_bodies():
        var raised = False
        try:
            _ = Request("POST", "/", body.copy()).text()
        except:
            raised = True
        assert_true(raised)
        raised = False
        try:
            _ = Response(200, body.copy()).text()
        except:
            raised = True
        assert_true(raised)


def test_binary_response_keeps_its_bytes_and_fields() raises:
    var app = binary_app()
    var r = TestClient(app).get("/png")
    assert_equal(r.status, 200)
    _assert_same(
        r.body,
        _octets([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        "png",
    )
    assert_equal(len(r.headers), 1)
    assert_equal(r.headers.get("content-type").value(), "image/png")
    # `TestClient.head` returns the in-memory answer, body included.
    _assert_same(TestClient(app).head("/png").body, r.body, "HEAD")


def test_raw_text_read_of_binary_body_is_the_handler_error() raises:
    var app = binary_app()
    var client = TestClient(app)
    assert_equal(client.post("/text", "hé").text(), "text hé")
    for body in _binary_bodies():
        var r = client.post("/text", body.copy())
        assert_equal(r.status, 500)
        assert_equal(r.text(), "Internal Server Error")


def test_typed_text_body_that_is_not_utf8_is_400_before_from_body() raises:
    var app = binary_app()
    var client = TestClient(app)
    var json = Headers()
    json.add("Content-Type", "application/json")
    for body in _binary_bodies():
        _ = unsetenv(FROM_BODY_CALLED)
        var r = client.post("/typed", body.copy())
        assert_equal(r.status, 400)
        assert_equal(r.text(), "Bad Request")
        assert_false(getenv(FROM_BODY_CALLED) == "1")
        var c = client.post("/carrier", body.copy(), headers=json.copy())
        assert_equal(c.status, 400)
        assert_false(getenv(FROM_BODY_CALLED) == "1")
    for body in _text_bodies():
        var text = String(from_utf8=Span(body))
        var r = client.post("/typed", body.copy())
        assert_equal(r.status, 200)
        assert_equal(r.text(), "[" + text + "]")
        assert_equal(client.post("/typed", text).text(), "[" + text + "]")
        assert_equal(
            client.post("/carrier", body.copy(), headers=json.copy()).text(),
            "{" + text + "}",
        )


def test_json_body_is_never_parsed_from_replaced_bytes() raises:
    var app = binary_app()
    var client = TestClient(app)
    var json = Headers()
    json.add("Content-Type", "application/json")
    # A U+FFFD the client sent is a value.
    var sent = List('{"name":"'.as_bytes())
    sent.extend(Span(_octets([0xEF, 0xBF, 0xBD])))
    sent.extend(Span('"}'.as_bytes()))
    var ok = client.post("/greet", sent^, headers=json.copy())
    assert_equal(ok.status, 200)
    assert_equal(ok.text(), "hello �")
    # A byte that is not UTF-8 inside a string is 400, never "hello �".
    var bad = List('{"name":"'.as_bytes())
    bad.append(0xFF)
    bad.extend(Span('"}'.as_bytes()))
    var refused = client.post("/greet", bad.copy(), headers=json.copy())
    assert_equal(refused.status, 400)
    assert_equal(refused.text(), "Bad Request")
    # Order: 415 (no Content-Type) before the UTF-8 400, and 413 for a body
    # over 1 MiB before it too.
    assert_equal(client.post("/greet", bad^).status, 415)
    var big = List[UInt8](length=1_048_577, fill=UInt8(0xFF))
    assert_equal(client.post("/greet", big^, headers=json.copy()).status, 413)


def test_middleware_passes_and_changes_bytes_without_text() raises:
    var app = binary_app()
    app.use(tag)
    app.use(reverse)
    var client = TestClient(app)
    for body in _all_bodies():
        var want = List[UInt8]()
        for i in range(len(body)):
            want.append(body[len(body) - 1 - i])
        var r = client.post("/echo", body.copy())
        assert_equal(r.status, 200)
        _assert_same(r.body, want, "reversed by middleware")
        assert_equal(r.headers.get("x-seen").value(), "1")
    # Middleware sees the body bytes on 404 and 405 too.
    var missing = client.post("/missing", _octets([0xFF]))
    assert_equal(missing.status, 404)
    assert_equal(missing.headers.get("x-seen").value(), "1")
    var other = client.post("/png", _octets([0xFF]))
    assert_equal(other.status, 405)
    assert_equal(other.headers.get("allow").value(), "GET, HEAD")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
