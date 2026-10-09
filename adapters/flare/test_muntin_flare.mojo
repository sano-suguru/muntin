"""Socket-free contract tests for the Flare adapter (M1-002; headers M3-005;
`HEAD` M3-027; 405 M3-031; request body bytes M3-038).

Runs only in the `flare` pixi environment (see scripts/check_flare.sh). Every
dispatch goes through `MuntinHandler.serve`, a Flare handler entry point that
answers through the same `_serve_app` as `Server`'s, and from there through
the real `App.handle`.
"""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from flare.http import Request as FlareRequest, Response as FlareResponse
from muntin import App, FromBody, Headers, Next, Request, Response
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


def _octets(values: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for v in values:
        out.append(UInt8(v))
    return out^


def _well_formed_bodies() -> List[List[UInt8]]:
    """Request bodies that are well-formed UTF-8 (M3-038)."""
    return [
        List("ping".as_bytes()),
        List("hé✓".as_bytes()),
        _octets([0x61, 0xEF, 0xBF, 0xBD, 0x62]),  # a U+FFFD the client sent
        _octets([0x61, 0x00, 0x62, 0x00]),  # NUL
        List[UInt8](),
        _octets([0x00, 0x01, 0x7F, 0x0A]),  # octets that happen to be UTF-8
    ]


def _ill_formed_bodies() -> List[List[UInt8]]:
    """Request bodies that are not UTF-8 (M3-038)."""
    return [
        _octets([0x80]),
        _octets([0xFF]),
        _octets([0x68, 0xC3, 0xA9, 0xFF]),  # "hé" then 0xFF
        _octets([0xE3, 0x81]),  # truncated U+3042
        _octets([0xC0, 0xAF]),  # overlong
        _octets([0xED, 0xA0, 0x80]),  # a surrogate
        _octets([0xEF, 0xBF, 0xBD, 0xFF]),  # a sent U+FFFD, then 0xFF
        _octets([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),  # PNG
    ]


def _same_bytes(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def test_request_body_keeps_well_formed_bytes() raises:
    for body in _well_formed_bodies():
        var request = to_muntin_request(
            FlareRequest("POST", "/", body=body.copy())
        )
        assert_true(_same_bytes(request.body.as_bytes(), Span(body)))
        assert_equal(request.body.byte_length(), len(body))


def test_request_body_that_is_not_utf8_cannot_be_converted() raises:
    for body in _ill_formed_bodies():
        var raised = False
        try:
            _ = to_muntin_request(FlareRequest("POST", "/", body=body.copy()))
        except:
            raised = True
        assert_true(raised)


def reached(req: Request) -> Response:
    return Response.text("reached " + String(req.body.byte_length()))


def seen(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    response.headers.add("X-Seen", "1")
    return response^


def body_app() -> App:
    var app = App()
    app.use(seen)
    app.post["/reached"](reached)
    app.get["/hello"](hello)
    return app^


def test_request_body_that_is_not_utf8_answers_400_before_app_handle() raises:
    var handler = MuntinHandler(body_app())
    for body in _ill_formed_bodies():
        # A route, a path only `GET` matches (405 in `App.handle`) and a
        # path no route matches (404): the adapter's 400 comes first, and
        # neither the middleware nor a handler runs.
        for target in ["/reached", "/hello", "/missing"]:
            var out = handler.serve(
                FlareRequest("POST", target, body=body.copy())
            )
            assert_equal(out.status, 400)
            assert_equal(out.text(), "Bad Request")
            assert_equal(_wire(out), "")
        # `HEAD`: the adapter's 400 under the `HEAD` rule (M3-027).
        var head = handler.serve(
            FlareRequest("HEAD", "/hello", body=body.copy())
        )
        assert_equal(head.status, 400)
        assert_equal(len(head.body), 0)
        assert_equal(_wire(head), "Content-Length: 11\r\n")
    for body in _well_formed_bodies():
        var out = handler.serve(
            FlareRequest("POST", "/reached", body=body.copy())
        )
        assert_equal(out.status, 200)
        assert_equal(out.text(), "reached " + String(len(body)))
        assert_equal(_wire(out), "X-Seen: 1\r\n")


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


def test_unmatched_method_is_405_with_allow() raises:
    var handler = MuntinHandler(app_with_routes())

    var response = handler.serve(FlareRequest("POST", "/hello"))

    assert_equal(response.status, 405)
    assert_equal(response.text(), "Method Not Allowed")
    # `to_flare_response` keeps `App.handle`'s `Allow` as given.
    assert_equal(_wire(response), "Allow: GET, HEAD\r\n")
    var direct = handler.app.handle(Request("POST", "/hello"))
    assert_equal(_wire(to_flare_response(direct^)), _wire(response))


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
    them; `append` checks only CR/LF, so HTTP/2-only shapes (control bytes,
    and a `:` inside a name, which Flare v0.11.0 admitted over HTTP/2) can be
    reproduced in process."""
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
    # A name with `:` (Flare v0.11.0 admitted it over HTTP/2) would be
    # misread by a first-colon parse; a control byte cannot be a Muntin
    # value. Neither reaches App.
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
    # Invalid UTF-8, as Flare v0.12.0 delivers it over HTTP/2.
    var bad = List[UInt8]()
    bad.append(0x61)
    bad.append(0xFF)
    var invalid = _served(
        [(String("x-obs"), String(unsafe_from_utf8=Span(bad)))]
    )
    assert_equal(invalid.status, 400)


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


# `HEAD` (M3-027): every exit of `MuntinHandler.serve` sends the `GET`
# answer's status and fields, no body, and the body's length.


def length_field(var req: Request) -> Response:
    var r = Response.text("abc", status=202)
    try:
        r.headers.add("X-Request-Id", "7")
        r.headers.add("Content-Length", "99")
    except:
        pass
    return r^


def internal_write(var req: Request) -> Response:
    var bad = Response.text("never")
    try:
        bad.headers.add("X-Ok", "1")
    except:
        pass
    bad.headers._fields[0].value = String("a") + chr(0) + String("b")
    return bad^


def continue_(var req: Request) -> Response:
    return Response(100, "abc")


def early_hints(var req: Request) -> Response:
    return Response(103, "abc")


def no_content(var req: Request) -> Response:
    return Response(204, "abc")


def reset_content(var req: Request) -> Response:
    return Response(205, "abc")


def not_modified(var req: Request) -> Response:
    var r = Response(304, "abc")
    try:
        r.headers.add("ETag", '"v1"')
    except:
        pass
    return r^


def out_of_range(var req: Request) -> Response:
    return Response(99, "abc")


def head_app() -> App:
    var app = app_with_routes()
    app.get["/cl"](length_field)
    app.get["/bad-field"](internal_write)
    app.get["/100"](continue_)
    app.get["/103"](early_hints)
    app.get["/204"](no_content)
    app.get["/205"](reset_content)
    app.get["/304"](not_modified)
    app.get["/99"](out_of_range)
    return app^


def _wire(response: FlareResponse) -> String:
    var wire = List[UInt8]()
    response.headers.encode_to(wire)
    return String(from_utf8_lossy=Span(wire))


def test_head_sends_get_fields_and_length_without_body() raises:
    var handler = MuntinHandler(head_app())
    # (target, status): `App.handle`'s answers, its 400, 404 and 405
    # included, and `to_flare_response`'s fixed 500.
    for want in [
        ("/hello", 200),
        ("/items?limit=010", 200),
        ("/items?limit=abc", 400),
        ("/missing", 404),
        # Only a `post` route serves `/users`: `GET` and `HEAD` are 405.
        ("/users", 405),
        ("/cl", 202),
        ("/bad-field", 500),
        # Below 100 is not 1xx: the rule declares its length.
        ("/99", 99),
    ]:
        var target = String(want[0])
        var get = handler.serve(FlareRequest("GET", target))
        var head = handler.serve(FlareRequest("HEAD", target))
        assert_equal(get.status, want[1], target)
        assert_true(len(get.body) > 0, target)
        assert_equal(head.status, get.status, target)
        assert_equal(len(head.body), 0, target)
        # The GET's fields, then the length of the GET's body, nothing else;
        # the handler's own `Content-Length: 99` stays dropped.
        assert_equal(
            _wire(head),
            _wire(get) + "Content-Length: " + String(len(get.body)) + "\r\n",
            target,
        )
    var cl = handler.serve(FlareRequest("HEAD", "/cl"))
    assert_equal(_wire(cl), "X-Request-Id: 7\r\nContent-Length: 3\r\n")
    var bad = handler.serve(FlareRequest("HEAD", "/bad-field"))
    assert_equal(_wire(bad), "Content-Length: 21\r\n")
    var not_allowed = handler.serve(FlareRequest("HEAD", "/users"))
    assert_equal(not_allowed.status, 405)
    assert_equal(len(not_allowed.body), 0)
    assert_equal(_wire(not_allowed), "Allow: POST\r\nContent-Length: 18\r\n")


def test_head_declares_no_length_for_statuses_without_content() raises:
    var handler = MuntinHandler(head_app())
    for want in [
        ("/100", 100),
        ("/103", 103),
        ("/204", 204),
        ("/205", 205),
        ("/304", 304),
    ]:
        var target = String(want[0])
        var get = handler.serve(FlareRequest("GET", target))
        var head = handler.serve(FlareRequest("HEAD", target))
        # A non-empty body that the length would otherwise come from.
        assert_equal(get.text(), "abc", target)
        assert_equal(head.status, want[1], target)
        assert_equal(len(head.body), 0, target)
        assert_equal(_wire(head), _wire(get), target)
        assert_false(head.headers.contains("content-length"), target)
    assert_equal(
        _wire(handler.serve(FlareRequest("HEAD", "/304"))), 'ETag: "v1"\r\n'
    )


def test_head_rule_covers_the_adapters_own_400() raises:
    var req = FlareRequest("HEAD", "/hello")
    req.headers.append("x-user:admin", "zzz")
    var head = MuntinHandler(head_app()).serve(req)
    assert_equal(head.status, 400)
    assert_equal(len(head.body), 0)
    assert_equal(_wire(head), "Content-Length: 11\r\n")


def test_other_methods_keep_their_body() raises:
    var handler = MuntinHandler(head_app())
    var get = handler.serve(FlareRequest("GET", "/cl"))
    assert_equal(get.text(), "abc")
    assert_equal(_wire(get), "X-Request-Id: 7\r\n")
    # Only the exact token `HEAD` is the rule's: `head` is 405 in `App.handle`
    # and goes out with its body.
    for method in ["head", "Head", "OPTIONS"]:
        var r = handler.serve(FlareRequest(method, "/hello"))
        assert_equal(r.status, 405, method)
        assert_equal(r.text(), "Method Not Allowed", method)
        assert_equal(_wire(r), "Allow: GET, HEAD\r\n", method)
    var post = handler.serve(
        FlareRequest("POST", "/users", body=List("name=Ada".as_bytes()))
    )
    assert_equal(post.text(), "created Ada")
    assert_equal(_wire(post), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
