"""Socket-free contract tests for the Flare adapter (M1-002; headers M3-005).

Runs only in the `flare` pixi environment (see scripts/check_flare.sh). Every
dispatch goes through `MuntinHandler.serve`, the entry point Flare's server
calls, and from there through the real `App.handle`.
"""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from flare.http import Request as FlareRequest, Response as FlareResponse
from muntin import App, FromBody, Headers, Request, Response
from muntin.testing import TestClient
from muntin_flare import MuntinHandler, to_flare_response, to_muntin_request


def hello() -> String:
    return "hello"


def goodbye() -> String:
    return "goodbye"


def list_items(limit: Int) -> String:
    return "items " + String(limit)


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("expected name=<text>")
        return Self(String(body[byte=5:]))


def create_user(body: CreateUser) -> String:
    return "created " + body.name


struct RawText(FromBody):
    """Accepts any body, including an empty one, unchanged: a backend that
    rejected or rewrote a body itself would differ from `TestClient`."""

    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def echo(body: RawText) -> String:
    return "[" + body.text + "]"


def app_with_routes() -> App:
    var app = App()
    app.get["/hello"](hello)
    app.get["/goodbye"](goodbye)
    app.get["/items?{limit}"](list_items)
    app.post["/users"](create_user)
    app.post["/echo"](echo)
    return app^


def test_request_conversion_keeps_method_target_and_body() raises:
    var request = to_muntin_request(
        FlareRequest("POST", "/items?page=1&x", body=List("ping".as_bytes()))
    )

    assert_equal(request.method, "POST")
    # The adapter passes the target verbatim; Muntin's Request splits it.
    assert_equal(request.path, "/items")
    assert_equal(request.query, "page=1&x")
    assert_equal(request.body, "ping")


def test_request_body_is_decoded_as_lossy_utf8() raises:
    var bytes = List("hé".as_bytes())
    bytes.append(0xFF)

    var request = to_muntin_request(FlareRequest("POST", "/", body=bytes^))

    assert_equal(request.body, "hé�")


def test_response_conversion_keeps_status_and_body() raises:
    var response = to_flare_response(Response.text("created", status=201))

    assert_equal(response.status, 201)
    assert_equal(response.text(), "created")


def test_registered_routes_dispatch_through_app_handle() raises:
    var handler = MuntinHandler(app_with_routes())

    var hello_response = handler.serve(FlareRequest("GET", "/hello"))
    var goodbye_response = handler.serve(FlareRequest("GET", "/goodbye"))

    assert_equal(hello_response.status, 200)
    assert_equal(hello_response.text(), "hello")
    assert_equal(goodbye_response.status, 200)
    assert_equal(goodbye_response.text(), "goodbye")


def test_unmatched_path_is_not_found() raises:
    var handler = MuntinHandler(app_with_routes())

    var response = handler.serve(FlareRequest("GET", "/missing"))

    assert_equal(response.status, 404)
    assert_equal(response.text(), "Not Found")


def test_unmatched_method_is_not_found() raises:
    var handler = MuntinHandler(app_with_routes())

    var response = handler.serve(FlareRequest("POST", "/hello"))

    assert_equal(response.status, 404)
    assert_equal(response.text(), "Not Found")


def test_adapter_matches_in_memory_backend() raises:
    var handler = MuntinHandler(app_with_routes())
    var client = TestClient(handler.app)

    for path in [
        "/hello",
        "/goodbye",
        "/missing",
        "/hello?x=1",
        "/items?limit=010",
        "/items?limit=abc",
        "/items?limit=1&limit=2",
        "/items",
    ]:
        var expected = client.get(path)
        var actual = handler.serve(FlareRequest("GET", path))
        assert_equal(actual.status, expected.status, path)
        assert_equal(actual.text(), expected.text(), path)


def test_adapter_post_body_matches_in_memory_backend() raises:
    var handler = MuntinHandler(app_with_routes())
    var client = TestClient(handler.app)

    for want in [
        ("/users", "name=Ada"),
        ("/users?name=Bob", "name=Ada"),
        ("/users", "Ada"),
        ("/users", ""),
        ("/echo", ""),
        ("/echo", " a=b&c?d \n"),
        ("/hello", "name=Ada"),
        ("/missing", "name=Ada"),
    ]:
        var path = String(want[0])
        var body = String(want[1])
        var expected = client.post(path, body)
        var actual = handler.serve(
            FlareRequest("POST", path, body=List(body.as_bytes()))
        )
        assert_equal(actual.status, expected.status, path + " " + body)
        assert_equal(actual.text(), expected.text(), path + " " + body)
    assert_equal(
        handler.serve(
            FlareRequest("POST", "/users", body=List("name=Ada".as_bytes()))
        ).text(),
        "created Ada",
    )
    assert_equal(
        handler.serve(FlareRequest("POST", "/echo", body=List[UInt8]())).text(),
        "[]",
    )


def _flare_request(fields: List[Tuple[String, String]]) raises -> FlareRequest:
    """A Flare request carrying `fields` as Flare's parser would store
    them; `append` checks only CR/LF, so HTTP/2-only shapes (a `:` inside a
    name, control bytes) can be reproduced in process."""
    var req = FlareRequest("POST", "/hook?x=1", List("b".as_bytes()))
    for f in fields:
        req.headers.append(f[0], f[1])
    return req^


def _fields(h: Headers) -> String:
    var out = String()
    for i in range(len(h)):
        out += h.name(i) + "=" + h.value(i) + ";"
    return out^


def test_request_headers_are_rebuilt_in_order() raises:
    var got = to_muntin_request(
        _flare_request(
            [
                (String("X-B"), String("2")),
                (String("Content-Type"), String("text/plain; q=1")),
                (String("x-b"), String("")),
                (String("X-Odd"), String("a: b\tc")),
                (String("X-Utf8"), String("é")),
            ]
        )
    )
    assert_equal(
        _fields(got.headers),
        "X-B=2;Content-Type=text/plain; q=1;x-b=;X-Odd=a: b\tc;X-Utf8=é;",
    )
    assert_equal(got.body, "b")
    assert_equal(got.query, "x=1")


def _served(fields: List[Tuple[String, String]]) raises -> FlareResponse:
    return MuntinHandler(App()).serve(_flare_request(fields))


def test_unrepresentable_request_headers_answer_400() raises:
    # A name with `:` (HTTP/2 admits it) would be misread by a first-colon
    # parse; a control byte cannot be a Muntin value. Neither reaches App.
    var forged = _served([(String("x-user:admin"), String("zzz"))])
    assert_equal(forged.status, 400)
    assert_equal(String(from_utf8_lossy=Span(forged.body)), "Bad Request")
    var beside = _served(
        [
            (String("x-user:admin"), String("zzz")),
            (String("x-user"), String("admin: zzz")),
        ]
    )
    assert_equal(beside.status, 400)
    var ctl = _served([(String("x-ctl"), String("a") + chr(1) + String("b"))])
    assert_equal(ctl.status, 400)


def test_response_headers_follow_the_outbound_rule() raises:
    var resp = Response.text("hi", status=202)
    resp.headers.add("X-First", "1")
    resp.headers.add("Keep-Alive", "timeout=5")
    resp.headers.add("Proxy-Connection", "keep-alive")
    resp.headers.add("upgrade", "websocket")
    resp.headers.add("TE", "gzip")
    resp.headers.add("Trailer", "X-Trail")
    resp.headers.add("Content-Length", "999")
    resp.headers.add("Transfer-Encoding", "chunked")
    resp.headers.add("Connection", "keep-alive, X-Hop ,\tx-other")
    resp.headers.add("x-hop", "secret")
    resp.headers.add("X-Other", "o")
    resp.headers.add("Set-Cookie", "a=1")
    resp.headers.add("Set-Cookie", "b=2")
    resp.headers.add("X-Empty", "")
    resp.headers.add("X-Hopper", "kept")
    var out = to_flare_response(resp)
    assert_equal(out.status, 202)
    var wire = List[UInt8]()
    out.headers.encode_to(wire)
    assert_equal(
        String(from_utf8_lossy=Span(wire)),
        (
            "X-First: 1\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nX-Empty: \r\n"
            "X-Hopper: kept\r\n"
        ),
    )


def test_internal_name_write_is_a_500() raises:
    # Mojo has no private fields: a write through `_fields` bypasses
    # `Headers.add`. The adapter re-checks every field.
    var bad = Response.text("hi")
    bad.headers.add("X-Ok", "1")
    bad.headers._fields[0].value = String("a") + chr(0) + String("b")
    var out = to_flare_response(bad)
    assert_equal(out.status, 500)
    assert_equal(out.headers.len(), 0)


def test_responses_without_headers_add_none() raises:
    var out = to_flare_response(Response.text("hello"))
    assert_equal(out.headers.len(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
