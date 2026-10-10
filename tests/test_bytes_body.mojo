# Typed binary request bodies (M3-041): a `FromBytes` body receives the
# request body's bytes, whatever they are, before the handler, on every shape
# that takes a `FromBody` body (`post`, `put`, `patch`; body only, route
# values then body, `State` first). Every comparison of bytes is by length and
# byte by byte, never through a lossy `String`. Must-not-build counterparts:
# tests/from_bytes_api_fail.

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_true, TestSuite

from muntin import (
    App,
    FromBody,
    FromBytes,
    FromJson,
    Headers,
    Json,
    JsonValue,
    Next,
    Request,
    Response,
    State,
)
from muntin.testing import TestClient

# `from_bytes` is static and sees no state, so its calls and the handlers'
# are counted in environment variables.
comptime FROM_BYTES_CALLS = "MUNTIN_TEST_BYTES_FROM_BYTES_CALLS"
comptime HANDLER_CALLS = "MUNTIN_TEST_BYTES_HANDLER_CALLS"
comptime FROM_BODY_CALLS = "MUNTIN_TEST_BYTES_FROM_BODY_CALLS"


def _count(name: String) -> Int:
    var n = getenv(name)
    try:
        return Int(n) if n else 0
    except:
        return -1


def _bump(name: String):
    _ = setenv(name, String(_count(name) + 1))


def _reset():
    _ = unsetenv(FROM_BYTES_CALLS)
    _ = unsetenv(HANDLER_CALLS)
    _ = unsetenv(FROM_BODY_CALLS)


def _octets(values: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for v in values:
        out.append(UInt8(v))
    return out^


def _png() -> List[UInt8]:
    return _octets([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])


def _every_byte() -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(256):
        out.append(UInt8(i))
    return out^


def _bodies() -> List[List[UInt8]]:
    """ASCII, Japanese UTF-8, empty, NUL, 0x80, 0xFF, the PNG signature, every
    byte value, a truncated sequence, a sent U+FFFD then 0xFF."""
    return [
        List("hello".as_bytes()),
        List("こんにちは、世界".as_bytes()),
        List[UInt8](),
        _octets([0x00]),
        _octets([0x61, 0x00, 0x62, 0x00]),
        _octets([0x80]),
        _octets([0xFF]),
        _png(),
        _every_byte(),
        _octets([0xE3, 0x81]),
        _octets([0xEF, 0xBF, 0xBD, 0xFF]),
    ]


def _assert_same(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], String(what, ": byte ", i))


def _prefixed(prefix: String, body: List[UInt8]) -> List[UInt8]:
    var out = List(prefix.as_bytes())
    out.extend(Span(body))
    return out^


# The docs/DX.md section 4 "Typed binary bodies" example, verbatim.


struct Image(FromBytes):
    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        if len(body) < 8 or body[0] != 0x89 or body[1] != 0x50:
            raise Error("not a PNG")  # 400, upload not called
        return Self(body.copy())  # the bytes are borrowed: keep a copy


def upload(image: Image) -> String:  # `var image: Image` also works
    return String(len(image.data), " bytes")


# Application types.


struct Blob(FromBytes):
    """Keeps every byte it receives; move-only (no `Copyable`)."""

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        _bump(FROM_BYTES_CALLS)
        return Self(body.copy())

    def take(deinit self) -> List[UInt8]:
        return self.data^


@fieldwise_init
struct Size(FromBytes):
    """Reads the bytes without keeping them, and does not raise."""

    var n: Int
    var sum: Int

    @staticmethod
    def from_bytes(body: List[UInt8]) -> Self:
        var sum = 0
        for b in body:
            sum += Int(b)
        return Self(len(body), sum)


struct Signed(FromBytes):
    """Accepts a body that starts with 0xFF 0x00; raises on anything else."""

    var payload: List[UInt8]

    def __init__(out self, var payload: List[UInt8]):
        self.payload = payload^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        _bump(FROM_BYTES_CALLS)
        if len(body) < 2 or body[0] != 0xFF or body[1] != 0x00:
            raise Error("unsigned")
        var payload = List[UInt8]()
        for i in range(2, len(body)):
            payload.append(body[i])
        return Self(payload^)


struct Note(FromBody):
    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(FROM_BODY_CALLS)
        return Self(body)


@fieldwise_init
struct Name(FromJson):
    var name: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string())


struct Store(Movable):
    var prefix: String

    def __init__(out self, prefix: String):
        self.prefix = prefix


# Handlers.


def echo(blob: Blob) -> Response:
    _bump(HANDLER_CALLS)
    return Response(200, blob.data.copy())


def echo_owned(id: Int, var blob: Blob) -> Response:
    _bump(HANDLER_CALLS)
    return Response(200, _prefixed(String(id, "|"), blob^.take()))


def echo_two(id: Int, tag: String, blob: Blob) -> Response:
    _bump(HANDLER_CALLS)
    return Response(200, _prefixed(String(id, " ", tag, "|"), blob.data))


def echo_optional(tag: Optional[String], blob: Blob) -> Response:
    _bump(HANDLER_CALLS)
    return Response(200, _prefixed(tag.or_else("none") + "|", blob.data))


def echo_state(store: State[Store], blob: Blob) -> Response:
    _bump(HANDLER_CALLS)
    return Response(200, _prefixed(store[].prefix + "|", blob.data))


def echo_state_value(store: State[Store], id: Int, var blob: Blob) -> Response:
    _bump(HANDLER_CALLS)
    return Response(
        200, _prefixed(String(store[].prefix, " ", id, "|"), blob^.take())
    )


def echo_state_two(store: State[Store], a: Int, b: Int, blob: Blob) -> Response:
    _bump(HANDLER_CALLS)
    return Response(
        200, _prefixed(String(store[].prefix, " ", a, " ", b, "|"), blob.data)
    )


def size(s: Size) raises -> String:
    _bump(HANDLER_CALLS)
    return String(s.n, " ", s.sum)


def signed(s: Signed) -> Response:
    _bump(HANDLER_CALLS)
    return Response(200, s.payload.copy())


def note(n: Note) -> String:
    return "[" + n.text + "]"


def greet(body: Json[Name]) -> String:
    return "hello " + body.value.name


def raw_echo(req: Request) -> Response:
    return Response(200, req.body.copy())


def bytes_app() -> App:
    var app = App()
    app.post["/blob"](echo)
    app.put["/blob"](echo)
    app.patch["/blob"](echo)
    app.post["/blob/{id}"](echo_owned)
    app.put["/blob/{id}"](echo_owned)
    app.patch["/blob/{id}"](echo_owned)
    app.post["/two/{id}?{tag}"](echo_two)
    app.put["/two/{id}?{tag}"](echo_two)
    app.patch["/two/{id}?{tag}"](echo_two)
    app.post["/opt?{tag}"](echo_optional)
    var store = State(Store("s"))
    app.post["/state"](echo_state, store)
    app.put["/state/{id}"](echo_state_value, store)
    app.patch["/state/{a}/{b}"](echo_state_two, store)
    app.post["/size"](size)
    app.post["/signed"](signed)
    app.post["/note"](note)
    app.post["/greet"](greet)
    app.post["/raw"](raw_echo)
    app.get["/raw"](raw_echo)
    return app^


def _send(
    client: TestClient, method: String, target: String, body: List[UInt8]
) -> Response:
    if method == "POST":
        return client.post(target, body.copy())
    if method == "PUT":
        return client.put(target, body.copy())
    return client.patch(target, body.copy())


def test_dx_example() raises:
    var app = App()
    app.post["/upload"](upload)
    var client = TestClient(app)
    var png = _png()
    png.extend(Span(_octets([0x00, 0xFF, 0x80])))
    var ok = client.post("/upload", png^)
    assert_equal(ok.status, 200)
    assert_equal(ok.text(), "11 bytes")
    var bad = client.post("/upload", "GIF89a")
    assert_equal(bad.status, 400)
    assert_equal(bad.text(), "Bad Request")
    var get = client.get("/upload")
    assert_equal(get.status, 405)
    assert_equal(get.headers.get("allow").value(), "POST")


def test_every_body_reaches_from_bytes_byte_for_byte() raises:
    var app = bytes_app()
    var client = TestClient(app)
    for body in _bodies():
        for method in ["POST", "PUT", "PATCH"]:
            _reset()
            var r = _send(client, method, "/blob", body)
            assert_equal(r.status, 200, method)
            _assert_same(r.body, body, method + " /blob")
            assert_equal(_count(FROM_BYTES_CALLS), 1)
            assert_equal(_count(HANDLER_CALLS), 1)
            # `App.handle` with the same `Request` gives the same answer.
            var direct = app.handle(Request(method, "/blob", body.copy()))
            _assert_same(direct.body, body, method + " App.handle")
            # Muntin adds no field.
            assert_equal(len(r.headers), 0)
        # A text request whose bytes are this body's reaches the same bytes.
        try:
            var text = String(from_utf8=Span(body))
            _assert_same(client.post("/blob", text).body, body, "text")
        except:
            pass  # not UTF-8: no `String` holds it
        var s = client.post("/size", body.copy())
        var sum = 0
        for b in body:
            sum += Int(b)
        assert_equal(s.text(), String(len(body), " ", sum))


def test_route_values_and_state_then_bytes() raises:
    var app = bytes_app()
    var client = TestClient(app)
    for body in _bodies():
        for method in ["POST", "PUT", "PATCH"]:
            _assert_same(
                _send(client, method, "/blob/%34%32", body).body,
                _prefixed("42|", body),
                method + " route value, owned body",
            )
            _assert_same(
                _send(client, method, "/two/7?tag=a+b", body).body,
                _prefixed("7 a b|", body),
                method + " two route values",
            )
        _assert_same(
            client.post("/opt?tag=x", body.copy()).body,
            _prefixed("x|", body),
            "optional value",
        )
        _assert_same(
            client.post("/opt", body.copy()).body,
            _prefixed("none|", body),
            "absent optional value",
        )
        _assert_same(
            client.post("/state", body.copy()).body,
            _prefixed("s|", body),
            "State, body",
        )
        _assert_same(
            client.put("/state/3", body.copy()).body,
            _prefixed("s 3|", body),
            "State, value, body",
        )
        _assert_same(
            client.patch("/state/1/2", body.copy()).body,
            _prefixed("s 1 2|", body),
            "State, two values, body",
        )


def test_no_muntin_cap_on_a_bytes_body() raises:
    # One byte over the JSON cap (1 MiB): only `Json[T]` has a Muntin cap.
    var app = bytes_app()
    var big = List[UInt8](length=1_048_577, fill=UInt8(0xFF))
    big[0] = 0x00
    var r = TestClient(app).post("/blob", big.copy())
    assert_equal(r.status, 200)
    assert_equal(len(r.body), len(big))
    assert_true(r.body == big)  # one comparison; per-byte asserts are slow


def test_from_bytes_raise_is_400_and_the_handler_is_not_called() raises:
    var app = bytes_app()
    var client = TestClient(app)
    for body in _bodies():
        _reset()
        var r = client.post("/signed", body.copy())
        assert_equal(r.status, 400)
        assert_equal(r.text(), "Bad Request")
        assert_equal(len(r.headers), 0)
        assert_equal(_count(FROM_BYTES_CALLS), 1)
        assert_equal(_count(HANDLER_CALLS), 0)
    _reset()
    var ok = client.post("/signed", _octets([0xFF, 0x00, 0x80, 0xFE]))
    assert_equal(ok.status, 200)
    _assert_same(ok.body, _octets([0x80, 0xFE]), "signed payload")
    assert_equal(_count(HANDLER_CALLS), 1)


def test_bad_route_value_is_400_before_from_bytes() raises:
    var app = bytes_app()
    var client = TestClient(app)
    # Each method and target selects a bytes route whose route value is
    # invalid, missing, empty or repeated.
    var cases: List[Tuple[String, String]] = [
        ("POST", "/blob/x"),
        ("PUT", "/blob/%FF"),
        ("PATCH", "/blob/1x"),
        ("POST", "/two/x?tag=a"),
        ("PUT", "/two/1"),
        ("PATCH", "/two/1?tag="),
        ("POST", "/two/1?tag=a&tag=b"),
        ("POST", "/opt?tag=a&tag=b"),
        ("POST", "/opt?tag=%FF"),
        ("PUT", "/state/x"),
        ("PATCH", "/state/1/x"),
    ]
    for c in cases:
        var method = c[0]
        var target = c[1]
        _reset()
        var r = _send(client, method, target, _octets([0xFF, 0x00]))
        assert_equal(r.status, 400, method + " " + target)
        assert_equal(r.text(), "Bad Request")
        assert_equal(_count(FROM_BYTES_CALLS), 0, target)
        assert_equal(_count(HANDLER_CALLS), 0, target)


def test_404_405_and_head_convert_nothing() raises:
    var app = bytes_app()
    var client = TestClient(app)
    _reset()
    var missing = client.post("/missing", _octets([0xFF]))
    assert_equal(missing.status, 404)
    var too_deep = client.post("/blob/1/x", _octets([0xFF]))
    assert_equal(too_deep.status, 404)
    var get = client.get("/blob")
    assert_equal(get.status, 405)
    assert_equal(get.headers.get("allow").value(), "POST, PUT, PATCH")
    var head = client.head("/blob")
    assert_equal(head.status, 405)
    var delete = app.handle(Request("DELETE", "/blob", _octets([0xFF])))
    assert_equal(delete.status, 405)
    var opt = client.put("/opt", _octets([0xFF]))
    assert_equal(opt.status, 405)
    assert_equal(opt.headers.get("allow").value(), "POST")
    assert_equal(_count(FROM_BYTES_CALLS), 0)
    assert_equal(_count(HANDLER_CALLS), 0)


def replace(var request: Request, var next: Next) raises -> Response:
    """Replaces every body with 0xFE 0x00 0xFF before the routes."""
    request.body = _octets([0xFE, 0x00, 0xFF])
    return next^.run(request^)


def reverse(var request: Request, var next: Next) raises -> Response:
    """Replaces the body with its bytes reversed, as bytes."""
    var reversed = List[UInt8]()
    for i in range(len(request.body)):
        reversed.append(request.body[len(request.body) - 1 - i])
    request.body = reversed^
    return next^.run(request^)


def test_middleware_replacement_reaches_from_bytes() raises:
    var app = bytes_app()
    app.use(replace)
    var client = TestClient(app)
    for body in _bodies():
        _assert_same(
            client.post("/blob", body.copy()).body,
            _octets([0xFE, 0x00, 0xFF]),
            "replaced",
        )
        _assert_same(
            client.patch("/state/1/2", body.copy()).body,
            _prefixed("s 1 2|", _octets([0xFE, 0x00, 0xFF])),
            "replaced, stateful",
        )
    var reversing = bytes_app()
    reversing.use(reverse)
    var c2 = TestClient(reversing)
    for body in _bodies():
        var want = List[UInt8]()
        for i in range(len(body)):
            want.append(body[len(body) - 1 - i])
        _assert_same(
            c2.put("/blob/5", body.copy()).body,
            _prefixed("5|", want),
            "reversed",
        )


def test_text_json_and_raw_routes_are_unchanged() raises:
    var app = bytes_app()
    var client = TestClient(app)
    var json = Headers()
    json.add("Content-Type", "application/json")
    for body in _bodies():
        var text: Optional[String] = None
        try:
            text = String(from_utf8=Span(body))
        except:
            pass
        _reset()
        var n = client.post("/note", body.copy())
        if text:
            assert_equal(n.status, 200)
            assert_equal(n.text(), "[" + text.value() + "]")
            assert_equal(_count(FROM_BODY_CALLS), 1)
        else:
            # A text body that is not UTF-8 is still 400 before `from_body`.
            assert_equal(n.status, 400)
            assert_equal(_count(FROM_BODY_CALLS), 0)
        assert_equal(_count(FROM_BYTES_CALLS), 0)
        # The raw escape hatch still receives every body byte for byte.
        _assert_same(client.post("/raw", body.copy()).body, body, "raw")
    # JSON: 415, 413, UTF-8 400, JSON 400, in that order.
    var bad = List('{"name":"'.as_bytes())
    bad.append(0xFF)
    bad.extend(Span('"}'.as_bytes()))
    assert_equal(client.post("/greet", bad.copy()).status, 415)
    var big = List[UInt8](length=1_048_577, fill=UInt8(0xFF))
    assert_equal(client.post("/greet", big^, headers=json.copy()).status, 413)
    assert_equal(client.post("/greet", bad^, headers=json.copy()).status, 400)
    assert_equal(client.post("/greet", "{", headers=json.copy()).status, 400)
    assert_equal(
        client.post("/greet", '{"name":"Ada"}', headers=json.copy()).text(),
        "hello Ada",
    )
    # A raw `get` still answers `HEAD`.
    assert_equal(client.head("/raw").status, 200)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
