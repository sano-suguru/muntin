# Typed binary bodies with header fields (M3-042): `WithHeaders[B]` around a
# `FromBytes` body gives one typed handler the request's `Headers` and the
# body's bytes, converted by `from_bytes` before the handler, on every shape
# that takes a body (`post`, `put`, `patch`; body only, route values then
# body, `State` first; `String` and `ToResponse` results). Every comparison of
# bytes is by length and byte by byte, never through a lossy `String`.
# Decision: docs/history/architecture-decisions.md, "Typed binary request
# bodies with header fields decision (M3-042)". Must-not-build counterparts:
# tests/bytes_headers_api_fail.

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite

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
    ToErrorResponse,
    WithHeaders,
)
from muntin.testing import TestClient

from muntin.http import _Field

# `from_bytes` is static and sees no state, so its calls and the handlers'
# are counted in environment variables.
comptime FROM_BYTES_CALLS = "MUNTIN_TEST_BH_FROM_BYTES_CALLS"
comptime HANDLER_CALLS = "MUNTIN_TEST_BH_HANDLER_CALLS"
comptime FROM_BODY_CALLS = "MUNTIN_TEST_BH_FROM_BODY_CALLS"
comptime SEEN_AT = "MUNTIN_TEST_BH_SEEN_AT"


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


def _every_byte() -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(256):
        out.append(UInt8(i))
    return out^


def _bodies() -> List[List[UInt8]]:
    """ASCII, Japanese UTF-8, empty, NUL, 0x80, 0xFF, every byte value, a
    truncated UTF-8 sequence, a sent U+FFFD then 0xFF."""
    return [
        List("hello".as_bytes()),
        List("こんにちは".as_bytes()),
        List[UInt8](),
        _octets([0x00]),
        _octets([0x61, 0x00, 0x62, 0x00]),
        _octets([0x80]),
        _octets([0xFF]),
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


def _fields(h: Headers) -> String:
    """Every field in order, with its casing and value."""
    var out = String()
    for i in range(len(h)):
        out += h.name(i) + "=<" + h.value(i) + ">;"
    return out


def _h(*pairs: String) raises -> Headers:
    var h = Headers()
    var i = 0
    while i + 1 < len(pairs):
        h.add(pairs[i], pairs[i + 1])
        i += 2
    return h^


def _sent() raises -> Headers:
    """Repeated names, differing casing, an empty value, in this order."""
    return _h("X-Sig", "a", "x-sig", "b", "Empty", "", "Content-Type", "x/y")


comptime SENT_FIELDS = "X-Sig=<a>;x-sig=<b>;Empty=<>;Content-Type=<x/y>;"


# The docs/DX.md section 4 "Typed binary bodies with header fields" example,
# verbatim.


struct Upload(FromBytes):
    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        if len(body) == 0:
            raise Error("empty upload")  # 400, put_object not called
        return Self(body.copy())  # the bytes are borrowed: keep a copy


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(var self) -> Response:
        return Response.text("missing signature", status=401)


def put_object(
    key: String, input: WithHeaders[Upload]
) raises Unauthorized -> String:
    var signature = input.headers.get("x-signature")
    if not signature:
        raise Unauthorized()  # Muntin gives the field no meaning
    var kind = input.headers.get("content-type").or_else("unknown")
    return String(key, ": ", len(input.body.data), " bytes, ", kind)


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


@fieldwise_init
struct Pinned(FromBytes):
    """Records the address of the bytes it receives, to show they are
    `Request.body` itself, not a copy."""

    var n: Int

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        _ = setenv(SEEN_AT, String(Int(body.unsafe_ptr())))
        return Self(len(body))


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


# Handlers. Each `Response` handler answers `<route values>|<fields>|<bytes>`;
# each `String` handler, which cannot carry bytes that are not UTF-8, answers
# the fields, the byte count and the byte sum.


def _echo(head: String, h: Headers, body: List[UInt8]) -> Response:
    _bump(HANDLER_CALLS)
    return Response(200, _prefixed(head + "|" + _fields(h) + "|", body))


def _summary(head: String, h: Headers, body: List[UInt8]) -> String:
    _bump(HANDLER_CALLS)
    var sum = 0
    for b in body:
        sum += Int(b)
    return String(head, "|", _fields(h), "|", len(body), " ", sum)


def r_body(input: WithHeaders[Blob]) -> Response:
    return _echo("", input.headers, input.body.data)


def s_body(var input: WithHeaders[Blob]) -> String:
    var h = input.headers.copy()
    return _summary("", h, input^.take_body().take())


def r_value(id: Int, var input: WithHeaders[Blob]) -> Response:
    var h = input.headers.copy()
    return _echo(String(id), h, input^.take_body().take())


def s_value(id: Int, input: WithHeaders[Blob]) -> String:
    return _summary(String(id), input.headers, input.body.data)


def r_two(id: Int, tag: String, input: WithHeaders[Blob]) -> Response:
    return _echo(String(id, " ", tag), input.headers, input.body.data)


def s_two(id: Int, tag: String, input: WithHeaders[Blob]) -> String:
    return _summary(String(id, " ", tag), input.headers, input.body.data)


def r_optional(tag: Optional[String], input: WithHeaders[Blob]) -> Response:
    return _echo(tag.or_else("none"), input.headers, input.body.data)


def r_state(store: State[Store], input: WithHeaders[Blob]) -> Response:
    return _echo(store[].prefix, input.headers, input.body.data)


def s_state(store: State[Store], input: WithHeaders[Blob]) -> String:
    return _summary(store[].prefix, input.headers, input.body.data)


def r_state_value(
    store: State[Store], id: Int, var input: WithHeaders[Blob]
) -> Response:
    var h = input.headers.copy()
    return _echo(String(store[].prefix, " ", id), h, input^.take_body().take())


def s_state_value(
    store: State[Store], id: Int, input: WithHeaders[Blob]
) -> String:
    return _summary(
        String(store[].prefix, " ", id), input.headers, input.body.data
    )


def r_state_two(
    store: State[Store], a: Int, b: Int, input: WithHeaders[Blob]
) -> Response:
    return _echo(
        String(store[].prefix, " ", a, " ", b), input.headers, input.body.data
    )


def s_state_two(
    store: State[Store], a: Int, b: Int, input: WithHeaders[Blob]
) -> String:
    return _summary(
        String(store[].prefix, " ", a, " ", b), input.headers, input.body.data
    )


def signed(input: WithHeaders[Signed]) -> Response:
    return _echo("", input.headers, input.body.payload)


def pinned(input: WithHeaders[Pinned]) -> String:
    return String(input.body.n, " ", len(input.headers))


def bare(blob: Blob) -> Response:
    return _echo("bare", Headers(), blob.data)


def text_carrier(input: WithHeaders[Note]) -> String:
    _bump(HANDLER_CALLS)
    return "[" + input.body.text + "]" + _fields(input.headers)


def json_carrier(input: WithHeaders[Json[Name]]) -> String:
    return "hello " + input.body.value.name + " " + _fields(input.headers)


def raw_echo(req: Request) -> Response:
    return Response(200, _prefixed(_fields(req.headers) + "|", req.body))


struct _Shape(Copyable):
    var method: String
    var target: String
    var head: String
    var response: Bool

    def __init__(
        out self, method: String, target: String, head: String, response: Bool
    ):
        self.method = method
        self.target = target
        self.head = head
        self.response = response


def _shapes() -> List[_Shape]:
    """Every registered carrier route: method, target, the handler's echo
    of its route values and state, and its result policy."""
    var out = List[_Shape]()
    for m in ["POST", "PUT", "PATCH"]:
        var p = "/" + m.lower()
        out.append(_Shape(m, p + "/r", "", True))
        out.append(_Shape(m, p + "/s", "", False))
        out.append(_Shape(m, p + "/r/%34%32", "42", True))
        out.append(_Shape(m, p + "/s/7", "7", False))
        out.append(_Shape(m, p + "/r2/7?tag=a+b", "7 a b", True))
        out.append(_Shape(m, p + "/s2/7?tag=x", "7 x", False))
        out.append(_Shape(m, p + "/st/r", "st", True))
        out.append(_Shape(m, p + "/st/s", "st", False))
        out.append(_Shape(m, p + "/st/r/3", "st 3", True))
        out.append(_Shape(m, p + "/st/s/3", "st 3", False))
        out.append(_Shape(m, p + "/st/r/1/2", "st 1 2", True))
        out.append(_Shape(m, p + "/st/s/1/2", "st 1 2", False))
    out.append(_Shape("POST", "/opt?tag=x", "x", True))
    out.append(_Shape("POST", "/opt", "none", True))
    return out^


def carrier_app() -> App:
    var app = App()
    var store = State(Store("st"))
    app.post["/post/r"](r_body)
    app.post["/post/s"](s_body)
    app.post["/post/r/{id}"](r_value)
    app.post["/post/s/{id}"](s_value)
    app.post["/post/r2/{id}?{tag}"](r_two)
    app.post["/post/s2/{id}?{tag}"](s_two)
    app.post["/post/st/r"](r_state, store)
    app.post["/post/st/s"](s_state, store)
    app.post["/post/st/r/{id}"](r_state_value, store)
    app.post["/post/st/s/{id}"](s_state_value, store)
    app.post["/post/st/r/{a}/{b}"](r_state_two, store)
    app.post["/post/st/s/{a}/{b}"](s_state_two, store)
    app.put["/put/r"](r_body)
    app.put["/put/s"](s_body)
    app.put["/put/r/{id}"](r_value)
    app.put["/put/s/{id}"](s_value)
    app.put["/put/r2/{id}?{tag}"](r_two)
    app.put["/put/s2/{id}?{tag}"](s_two)
    app.put["/put/st/r"](r_state, store)
    app.put["/put/st/s"](s_state, store)
    app.put["/put/st/r/{id}"](r_state_value, store)
    app.put["/put/st/s/{id}"](s_state_value, store)
    app.put["/put/st/r/{a}/{b}"](r_state_two, store)
    app.put["/put/st/s/{a}/{b}"](s_state_two, store)
    app.patch["/patch/r"](r_body)
    app.patch["/patch/s"](s_body)
    app.patch["/patch/r/{id}"](r_value)
    app.patch["/patch/s/{id}"](s_value)
    app.patch["/patch/r2/{id}?{tag}"](r_two)
    app.patch["/patch/s2/{id}?{tag}"](s_two)
    app.patch["/patch/st/r"](r_state, store)
    app.patch["/patch/st/s"](s_state, store)
    app.patch["/patch/st/r/{id}"](r_state_value, store)
    app.patch["/patch/st/s/{id}"](s_state_value, store)
    app.patch["/patch/st/r/{a}/{b}"](r_state_two, store)
    app.patch["/patch/st/s/{a}/{b}"](s_state_two, store)
    app.post["/opt?{tag}"](r_optional)
    app.post["/signed"](signed)
    app.post["/pinned"](pinned)
    app.post["/bare"](bare)
    app.post["/note"](text_carrier)
    app.post["/greet"](json_carrier)
    app.post["/raw"](raw_echo)
    return app^


def _send(
    client: TestClient,
    method: String,
    target: String,
    body: List[UInt8],
    var h: Headers,
) -> Response:
    if method == "POST":
        return client.post(target, body.copy(), headers=h^)
    if method == "PUT":
        return client.put(target, body.copy(), headers=h^)
    return client.patch(target, body.copy(), headers=h^)


def _expected(shape: _Shape, fields: String, body: List[UInt8]) -> List[UInt8]:
    if shape.response:
        return _prefixed(shape.head + "|" + fields + "|", body)
    var sum = 0
    for b in body:
        sum += Int(b)
    return List(
        String(shape.head, "|", fields, "|", len(body), " ", sum).as_bytes()
    )


def test_dx_example() raises:
    var app = App()
    app.put["/objects/{key}"](put_object)
    var client = TestClient(app)
    var bytes = _octets([0x89, 0x50, 0x00, 0xFF, 0x80])
    var ok = client.put(
        "/objects/logo.png",
        bytes.copy(),
        headers=_h("X-Signature", "s1", "Content-Type", "image/png"),
    )
    assert_equal(ok.status, 200)
    assert_equal(ok.text(), "logo.png: 5 bytes, image/png")
    var unsigned = client.put("/objects/a", bytes.copy())
    assert_equal(unsigned.status, 401)
    assert_equal(unsigned.text(), "missing signature")
    var empty = client.put(
        "/objects/a", List[UInt8](), headers=_h("X-Signature", "s1")
    )
    assert_equal(empty.status, 400)
    assert_equal(empty.text(), "Bad Request")
    var get = client.get("/objects/a")
    assert_equal(get.status, 405)
    assert_equal(get.headers.get("allow").value(), "PUT")


def test_every_shape_receives_the_fields_and_the_bytes() raises:
    var app = carrier_app()
    var client = TestClient(app)
    for shape in _shapes():
        for body in _bodies():
            _reset()
            var r = _send(client, shape.method, shape.target, body, _sent())
            var what = shape.method + " " + shape.target
            assert_equal(r.status, 200, what)
            _assert_same(r.body, _expected(shape, SENT_FIELDS, body), what)
            assert_equal(_count(FROM_BYTES_CALLS), 1, what)
            assert_equal(_count(HANDLER_CALLS), 1, what)
            # `App.handle` with the same `Request` gives the same answer.
            var direct = app.handle(
                Request(shape.method, shape.target, body.copy(), _sent())
            )
            _assert_same(direct.body, r.body, what + " App.handle")
        # No field at all: an empty `Headers`, the bytes unchanged.
        var none = _send(
            client, shape.method, shape.target, _every_byte(), Headers()
        )
        _assert_same(
            none.body, _expected(shape, "", _every_byte()), shape.target
        )


def test_from_bytes_borrows_request_body_itself() raises:
    """Inside the carrier `from_bytes` still receives the borrowed
    `Request.body`, not a copy (no middleware, which copies the request
    once)."""
    var app = carrier_app()
    var req = Request("POST", "/pinned", _every_byte(), _sent())
    _ = unsetenv(SEEN_AT)
    var r = app.handle(req)
    assert_equal(r.text(), "256 4")
    assert_equal(getenv(SEEN_AT), String(Int(req.body.unsafe_ptr())))


def test_from_bytes_raise_is_400_and_the_handler_is_not_called() raises:
    var app = carrier_app()
    var client = TestClient(app)
    for body in _bodies():
        _reset()
        var r = client.post("/signed", body.copy(), headers=_sent())
        assert_equal(r.status, 400)
        assert_equal(r.text(), "Bad Request")
        assert_equal(len(r.headers), 0)
        assert_equal(_count(FROM_BYTES_CALLS), 1)
        assert_equal(_count(HANDLER_CALLS), 0)
    _reset()
    var ok = client.post(
        "/signed", _octets([0xFF, 0x00, 0x80, 0xFE]), headers=_sent()
    )
    assert_equal(ok.status, 200)
    _assert_same(
        ok.body, _prefixed("|" + SENT_FIELDS + "|", _octets([0x80, 0xFE])), "ok"
    )
    assert_equal(_count(HANDLER_CALLS), 1)


def test_bad_route_value_is_400_before_the_fields_and_from_bytes() raises:
    var app = carrier_app()
    var client = TestClient(app)
    var cases: List[Tuple[String, String]] = [
        ("POST", "/post/r/x"),
        ("PUT", "/put/s/%FF"),
        ("PATCH", "/patch/r/1x"),
        ("POST", "/post/r2/x?tag=a"),
        ("PUT", "/put/s2/1"),
        ("PATCH", "/patch/r2/1?tag="),
        ("POST", "/post/s2/1?tag=a&tag=b"),
        ("POST", "/opt?tag=a&tag=b"),
        ("POST", "/opt?tag=%FF"),
        ("PUT", "/put/st/r/x"),
        ("PATCH", "/patch/st/s/1/x"),
    ]
    for c in cases:
        var method = c[0]
        var target = c[1]
        _reset()
        var r = _send(client, method, target, _octets([0xFF, 0x00]), _sent())
        assert_equal(r.status, 400, method + " " + target)
        assert_equal(r.text(), "Bad Request")
        assert_equal(_count(FROM_BYTES_CALLS), 0, target)
        assert_equal(_count(HANDLER_CALLS), 0, target)
        # The route value answers before the field rebuild: a field the
        # rebuild refuses is still 400 here, not the fixed 500.
        var h = _sent()
        h._fields.append(_Field("Bad Name", "v"))
        var bad = app.handle(Request(method, target, _octets([0xFF]), h^))
        assert_equal(bad.status, 400, target + " with a bad field")
        assert_equal(_count(FROM_BYTES_CALLS), 0, target)


def test_invalid_in_memory_fields_are_the_fixed_500_before_from_bytes() raises:
    # The M3-002 known gap: `_fields` is reachable by name. The rebuild runs
    # before the conversion, so `from_bytes` is not called and the answer is
    # the fixed 500 on every shape, whatever the bytes.
    var app = carrier_app()
    for shape in _shapes():
        for body in [_octets([0xFF]), _octets([0xFF, 0x00])]:
            _reset()
            var h = Headers()
            h._fields.append(_Field("X-Inject", "a\r\nSet-Cookie: evil=1"))
            var r = app.handle(
                Request(shape.method, shape.target, body.copy(), h^)
            )
            assert_equal(r.status, 500, shape.target)
            assert_equal(r.text(), "Internal Server Error")
            assert_equal(_count(FROM_BYTES_CALLS), 0, shape.target)
            assert_equal(_count(HANDLER_CALLS), 0, shape.target)
    # `/signed` would raise on 0xFF alone: the rebuild still answers first.
    var h = Headers()
    h._fields.append(_Field("Bad Name", "v"))
    _reset()
    assert_equal(
        app.handle(Request("POST", "/signed", _octets([0xFF]), h^)).status,
        500,
    )
    assert_equal(_count(FROM_BYTES_CALLS), 0)


def test_404_405_and_head_convert_nothing() raises:
    var app = carrier_app()
    var client = TestClient(app)
    _reset()
    var missing = client.post("/missing", _octets([0xFF]), headers=_sent())
    assert_equal(missing.status, 404)
    var too_deep = client.post("/post/r/1/x", _octets([0xFF]), headers=_sent())
    assert_equal(too_deep.status, 404)
    var get = client.get("/post/r", headers=_sent())
    assert_equal(get.status, 405)
    assert_equal(get.headers.get("allow").value(), "POST")
    var head = client.head("/put/st/r/1/2")
    assert_equal(head.status, 405)
    assert_equal(head.headers.get("allow").value(), "PUT")
    var delete = app.handle(
        Request("DELETE", "/patch/r", _octets([0xFF]), _sent())
    )
    assert_equal(delete.status, 405)
    assert_equal(delete.headers.get("allow").value(), "PATCH")
    var wrong = client.put("/post/s", _octets([0xFF]), headers=_sent())
    assert_equal(wrong.status, 405)
    assert_equal(_count(FROM_BYTES_CALLS), 0)
    assert_equal(_count(HANDLER_CALLS), 0)


def replace(var request: Request, var next: Next) raises -> Response:
    """Replaces every body with 0xFE 0x00 0xFF and appends a field."""
    request.body = _octets([0xFE, 0x00, 0xFF])
    request.headers.add("X-Added", "mw")
    return next^.run(request^)


def test_middleware_replacement_reaches_the_carrier() raises:
    var app = carrier_app()
    app.use(replace)
    var client = TestClient(app)
    for shape in _shapes():
        for body in _bodies():
            _reset()
            var r = _send(client, shape.method, shape.target, body, _sent())
            _assert_same(
                r.body,
                _expected(
                    shape,
                    SENT_FIELDS + "X-Added=<mw>;",
                    _octets([0xFE, 0x00, 0xFF]),
                ),
                shape.target,
            )
            assert_equal(_count(FROM_BYTES_CALLS), 1)


def test_a_carrier_built_by_hand_takes_explicit_headers() raises:
    var c = WithHeaders(Blob(_octets([0xFF, 0x00])), _h("X-A", "1"))
    assert_equal(c.headers.get("x-a").value(), "1")
    var blob = c^.take_body()
    _assert_same(blob^.take(), _octets([0xFF, 0x00]), "by hand")


def _wrap[B: FromBytes](var body: B, var headers: Headers) -> WithHeaders[B]:
    """Generic code bounded by `FromBytes` builds a carrier."""
    return WithHeaders(body^, headers^)


def _wrap_text[
    B: FromBody
](var body: B, var headers: Headers) -> WithHeaders[B]:
    """Generic code bounded by `FromBody` still builds one."""
    return WithHeaders(body^, headers^)


def test_generic_code_builds_a_carrier_from_either_bound() raises:
    var b = _wrap(Blob(_octets([0x80])), _h("X-A", "1"))
    _assert_same(b.body.data, _octets([0x80]), "FromBytes bound")
    var t = _wrap_text(Note("n"), _h("X-A", "1"))
    assert_equal(t.body.text, "n")
    assert_equal(len(t.headers), 1)


def test_text_json_bare_and_raw_routes_are_unchanged() raises:
    var app = carrier_app()
    var client = TestClient(app)
    for body in _bodies():
        var text: Optional[String] = None
        try:
            text = String(from_utf8=Span(body))
        except:
            pass
        _reset()
        # A text carrier: still UTF-8 400 before `from_body`, else `from_body`.
        var n = client.post("/note", body.copy(), headers=_sent())
        if text:
            assert_equal(n.status, 200)
            assert_equal(n.text(), "[" + text.value() + "]" + SENT_FIELDS)
            assert_equal(_count(FROM_BODY_CALLS), 1)
        else:
            assert_equal(n.status, 400)
            assert_equal(_count(FROM_BODY_CALLS), 0)
            assert_equal(_count(HANDLER_CALLS), 0)
        assert_equal(_count(FROM_BYTES_CALLS), 0)
        # A bare `FromBytes` body receives no field.
        _assert_same(
            client.post("/bare", body.copy(), headers=_sent()).body,
            _prefixed("bare||", body),
            "bare",
        )
        # The raw escape hatch still receives every field and byte.
        _assert_same(
            client.post("/raw", body.copy(), headers=_sent()).body,
            _prefixed(SENT_FIELDS + "|", body),
            "raw",
        )
    # A JSON carrier: 415, 413, UTF-8 400, JSON 400, in that order.
    var bad = List('{"name":"'.as_bytes())
    bad.append(0xFF)
    bad.extend(Span('"}'.as_bytes()))
    var json = _h("Content-Type", "application/json")
    assert_equal(client.post("/greet", bad.copy(), headers=_sent()).status, 415)
    var big = List[UInt8](length=1_048_577, fill=UInt8(0xFF))
    assert_equal(client.post("/greet", big^, headers=json.copy()).status, 413)
    assert_equal(client.post("/greet", bad^, headers=json.copy()).status, 400)
    assert_equal(client.post("/greet", "{", headers=json.copy()).status, 400)
    assert_equal(
        client.post("/greet", '{"name":"Ada"}', headers=json.copy()).text(),
        "hello Ada Content-Type=<application/json>;",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
