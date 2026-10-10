# Typed binary request body size limits (M3-043): a `FromBytes` type
# declares `comptime max_bytes`, and a body longer than that, bare or inside
# `WithHeaders[B]`, is 413 before `from_bytes` and the handler, after the
# route values and before the carrier's field rebuild. A type that declares
# nothing has no Muntin limit. Every comparison of bytes is by length and
# byte by byte. Must-not-build counterparts: tests/bytes_limit_api_fail.

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
    WithHeaders,
)
from muntin.http import _Field
from muntin.testing import TestClient

# `from_bytes` is static and sees no state, so its calls and the handlers'
# are counted in environment variables.
comptime FROM_BYTES_CALLS = "MUNTIN_TEST_LIMIT_FROM_BYTES_CALLS"
comptime HANDLER_CALLS = "MUNTIN_TEST_LIMIT_HANDLER_CALLS"

comptime LIMIT = 256
"""`Capped`'s limit: the every-byte-value body is exactly this long."""


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


def _filled(n: Int, byte: Int = 0xFF) -> List[UInt8]:
    return List[UInt8](length=n, fill=UInt8(byte))


def _within() -> List[List[UInt8]]:
    """Bodies within `LIMIT`: empty, ASCII, Japanese UTF-8, NUL, 0x80, 0xFF,
    the PNG signature, every byte value (exactly `LIMIT` bytes), a truncated
    sequence and `LIMIT` bytes of 0xFF."""
    return [
        List[UInt8](),
        List("hello".as_bytes()),
        List("こんにちは、世界".as_bytes()),
        _octets([0x00]),
        _octets([0x80]),
        _octets([0xFF]),
        _octets([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        _every_byte(),
        _octets([0xE3, 0x81]),
        _filled(LIMIT),
    ]


def _over() -> List[List[UInt8]]:
    """Bodies over `LIMIT`: one byte more (every byte value then one), and
    far more."""
    var one_more = _every_byte()
    one_more.append(0x00)
    return [one_more^, _filled(LIMIT + 2), _filled(64 * 1024)]


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


# The docs/DX.md section 4 "Body size limits" examples, verbatim.


struct Avatar(FromBytes):
    comptime max_bytes = 64 * 1024  # a longer body is 413, before from_bytes

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        if len(body) == 0:
            raise Error("empty avatar")  # 400, set_avatar not called
        return Self(body.copy())


def set_avatar(id: Int, avatar: Avatar) -> String:
    return String(id, ": ", len(avatar.data), " bytes")


struct Upload[limit: Int](FromBytes):
    comptime max_bytes = Self.limit  # one type, a limit per route

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body.copy())


def put_object(key: String, input: WithHeaders[Upload[1 << 20]]) -> String:
    var kind = input.headers.get("content-type").or_else("unknown")
    return String(key, ": ", len(input.body.data), " bytes, ", kind)


def put_icon(key: String, input: WithHeaders[Upload[4096]]) -> String:
    return String(key, ": ", len(input.body.data), " byte icon")


# Application types.


struct Capped(FromBytes):
    """Keeps every byte it receives, up to `LIMIT`; move-only."""

    comptime max_bytes = LIMIT

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        _bump(FROM_BYTES_CALLS)
        return Self(body.copy())


struct Free(FromBytes):
    """Declares no limit."""

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        _bump(FROM_BYTES_CALLS)
        return Self(len(body))


struct Zero(FromBytes):
    """Accepts only the empty body."""

    comptime max_bytes = 0

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        _bump(FROM_BYTES_CALLS)
        return Self(len(body))


struct Largest(FromBytes):
    """Declares the largest `Int`, which no body exceeds."""

    comptime max_bytes = Int.MAX

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        _bump(FROM_BYTES_CALLS)
        return Self(len(body))


struct Strict(FromBytes):
    """At most 8 bytes, and raises unless they start with 0xFF."""

    comptime max_bytes = 8

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        _bump(FROM_BYTES_CALLS)
        if len(body) == 0 or body[0] != 0xFF:
            raise Error("unsigned")
        return Self(len(body))


struct Note(FromBody):
    """A text body. Its `max_bytes` is an ordinary member, not a limit:
    only a `FromBytes` type's is one (M3-043)."""

    comptime max_bytes = 4

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body.byte_length())


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


# Handlers: each answers `<route values>|<fields>|<bytes>` (no fields for a
# bare body) or, with the `String` policy, the byte count and sum.


def _echo(head: String, fields: String, body: List[UInt8]) -> Response:
    _bump(HANDLER_CALLS)
    return Response(200, _prefixed(head + "|" + fields + "|", body))


def _summary(head: String, fields: String, body: List[UInt8]) -> String:
    _bump(HANDLER_CALLS)
    var sum = 0
    for b in body:
        sum += Int(b)
    return String(head, "|", fields, "|", len(body), " ", sum)


def b_body(blob: Capped) -> Response:
    return _echo("", "", blob.data)


def b_value(id: Int, var blob: Capped) -> String:
    return _summary(String(id), "", blob.data)


def b_two(id: Int, tag: String, blob: Capped) -> Response:
    return _echo(String(id, " ", tag), "", blob.data)


def b_optional(tag: Optional[String], blob: Capped) -> Response:
    return _echo(tag.or_else("none"), "", blob.data)


def b_state(store: State[Store], blob: Capped) -> String:
    return _summary(store[].prefix, "", blob.data)


def b_state_value(store: State[Store], id: Int, blob: Capped) -> Response:
    return _echo(String(store[].prefix, " ", id), "", blob.data)


def b_state_two(store: State[Store], a: Int, b: Int, blob: Capped) -> String:
    return _summary(String(store[].prefix, " ", a, " ", b), "", blob.data)


def c_body(input: WithHeaders[Capped]) -> Response:
    return _echo("", _fields(input.headers), input.body.data)


def c_value(id: Int, var input: WithHeaders[Capped]) -> String:
    return _summary(String(id), _fields(input.headers), input.body.data)


def c_two(id: Int, tag: String, input: WithHeaders[Capped]) -> Response:
    return _echo(String(id, " ", tag), _fields(input.headers), input.body.data)


def c_optional(tag: Optional[String], input: WithHeaders[Capped]) -> Response:
    return _echo(tag.or_else("none"), _fields(input.headers), input.body.data)


def c_state(store: State[Store], input: WithHeaders[Capped]) -> String:
    return _summary(store[].prefix, _fields(input.headers), input.body.data)


def c_state_value(
    store: State[Store], id: Int, input: WithHeaders[Capped]
) -> Response:
    return _echo(
        String(store[].prefix, " ", id),
        _fields(input.headers),
        input.body.data,
    )


def c_state_two(
    store: State[Store], a: Int, b: Int, input: WithHeaders[Capped]
) -> String:
    return _summary(
        String(store[].prefix, " ", a, " ", b),
        _fields(input.headers),
        input.body.data,
    )


def free(f: Free) -> String:
    _bump(HANDLER_CALLS)
    return String(f.n)


def free_carrier(input: WithHeaders[Free]) -> String:
    _bump(HANDLER_CALLS)
    return String(input.body.n)


def zero(z: Zero) -> String:
    _bump(HANDLER_CALLS)
    return String(z.n)


def zero_carrier(input: WithHeaders[Zero]) -> String:
    _bump(HANDLER_CALLS)
    return String(input.body.n)


def largest(l: Largest) -> String:
    _bump(HANDLER_CALLS)
    return String(l.n)


def strict(s: Strict) -> String:
    _bump(HANDLER_CALLS)
    return String(s.n)


def strict_carrier(input: WithHeaders[Strict]) -> String:
    _bump(HANDLER_CALLS)
    return String(input.body.n)


def note(n: Note) -> String:
    return String(n.n)


def greet(body: Json[Name]) -> String:
    return "hello " + body.value.name


def raw_length(req: Request) -> Response:
    return Response.text(String(len(req.body)))


def hello() -> String:
    return "hello"


struct _Shape(Copyable):
    var method: String
    var target: String
    var head: String
    var carrier: Bool
    var response: Bool

    def __init__(
        out self,
        method: String,
        target: String,
        head: String,
        carrier: Bool,
        response: Bool,
    ):
        self.method = method
        self.target = target
        self.head = head
        self.carrier = carrier
        self.response = response


def _shapes() -> List[_Shape]:
    """Every registered `Capped` route, bare (`/b`) and in a carrier
    (`/c`): method, target, the handler's echo of its route values and
    state, and its result policy."""
    var out = List[_Shape]()
    for m in ["POST", "PUT", "PATCH"]:
        for k in ["b", "c"]:
            var p = String("/", m.lower(), "/", k)
            var c = k == "c"
            out.append(_Shape(m, p, "", c, True))
            out.append(_Shape(m, p + "/v/%34%32", "42", c, False))
            out.append(_Shape(m, p + "/two/7?tag=a+b", "7 a b", c, True))
            out.append(_Shape(m, p + "/st", "st", c, False))
            out.append(_Shape(m, p + "/st/v/3", "st 3", c, True))
            out.append(_Shape(m, p + "/st/two/1/2", "st 1 2", c, False))
    out.append(_Shape("POST", "/opt/b?tag=x", "x", False, True))
    out.append(_Shape("POST", "/opt/b", "none", False, True))
    out.append(_Shape("POST", "/opt/c?tag=x", "x", True, True))
    out.append(_Shape("POST", "/opt/c", "none", True, True))
    return out^


def limit_app() -> App:
    var app = App()
    var store = State(Store("st"))
    app.post["/post/b"](b_body)
    app.post["/post/b/v/{id}"](b_value)
    app.post["/post/b/two/{id}?{tag}"](b_two)
    app.post["/post/b/st"](b_state, store)
    app.post["/post/b/st/v/{id}"](b_state_value, store)
    app.post["/post/b/st/two/{a}/{b}"](b_state_two, store)
    app.post["/post/c"](c_body)
    app.post["/post/c/v/{id}"](c_value)
    app.post["/post/c/two/{id}?{tag}"](c_two)
    app.post["/post/c/st"](c_state, store)
    app.post["/post/c/st/v/{id}"](c_state_value, store)
    app.post["/post/c/st/two/{a}/{b}"](c_state_two, store)
    app.put["/put/b"](b_body)
    app.put["/put/b/v/{id}"](b_value)
    app.put["/put/b/two/{id}?{tag}"](b_two)
    app.put["/put/b/st"](b_state, store)
    app.put["/put/b/st/v/{id}"](b_state_value, store)
    app.put["/put/b/st/two/{a}/{b}"](b_state_two, store)
    app.put["/put/c"](c_body)
    app.put["/put/c/v/{id}"](c_value)
    app.put["/put/c/two/{id}?{tag}"](c_two)
    app.put["/put/c/st"](c_state, store)
    app.put["/put/c/st/v/{id}"](c_state_value, store)
    app.put["/put/c/st/two/{a}/{b}"](c_state_two, store)
    app.patch["/patch/b"](b_body)
    app.patch["/patch/b/v/{id}"](b_value)
    app.patch["/patch/b/two/{id}?{tag}"](b_two)
    app.patch["/patch/b/st"](b_state, store)
    app.patch["/patch/b/st/v/{id}"](b_state_value, store)
    app.patch["/patch/b/st/two/{a}/{b}"](b_state_two, store)
    app.patch["/patch/c"](c_body)
    app.patch["/patch/c/v/{id}"](c_value)
    app.patch["/patch/c/two/{id}?{tag}"](c_two)
    app.patch["/patch/c/st"](c_state, store)
    app.patch["/patch/c/st/v/{id}"](c_state_value, store)
    app.patch["/patch/c/st/two/{a}/{b}"](c_state_two, store)
    app.post["/opt/b?{tag}"](b_optional)
    app.post["/opt/c?{tag}"](c_optional)
    app.post["/free"](free)
    app.post["/free/c"](free_carrier)
    app.post["/zero"](zero)
    app.post["/zero/c"](zero_carrier)
    app.post["/largest"](largest)
    app.post["/strict"](strict)
    app.post["/strict/c"](strict_carrier)
    app.post["/note"](note)
    app.post["/greet"](greet)
    app.post["/raw"](raw_length)
    app.get["/hello"](hello)
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


def _expected(shape: _Shape, body: List[UInt8]) -> List[UInt8]:
    var fields = String(SENT_FIELDS) if shape.carrier else String()
    if shape.response:
        return _prefixed(shape.head + "|" + fields + "|", body)
    var sum = 0
    for b in body:
        sum += Int(b)
    return List(
        String(shape.head, "|", fields, "|", len(body), " ", sum).as_bytes()
    )


def _assert_413(r: Response, what: String) raises:
    assert_equal(r.status, 413, what)
    assert_equal(r.text(), "Content Too Large", what)
    assert_equal(len(r.headers), 0, what)
    assert_equal(_count(FROM_BYTES_CALLS), 0, what + ": from_bytes")
    assert_equal(_count(HANDLER_CALLS), 0, what + ": handler")


def test_dx_examples() raises:
    var app = App()
    app.put["/users/{id}/avatar"](set_avatar)
    app.put["/objects/{key}"](put_object)
    app.put["/icons/{key}"](put_icon)
    var client = TestClient(app)
    var at = client.put("/users/7/avatar", _filled(64 * 1024))
    assert_equal(at.status, 200)
    assert_equal(at.text(), "7: 65536 bytes")
    var over = client.put("/users/7/avatar", _filled(64 * 1024 + 1))
    assert_equal(over.status, 413)
    assert_equal(over.text(), "Content Too Large")
    assert_equal(client.put("/users/x/avatar", _filled(70000)).status, 400)
    assert_equal(client.put("/users/7/avatar", List[UInt8]()).status, 400)
    var png = _h("Content-Type", "image/png")
    var big = client.put("/objects/a.png", _filled(1 << 20), headers=png^)
    assert_equal(big.text(), "a.png: 1048576 bytes, image/png")
    assert_equal(
        client.put("/objects/a.png", _filled((1 << 20) + 1)).status, 413
    )
    assert_equal(
        client.put("/icons/i", _filled(4096)).text(), "i: 4096 byte icon"
    )
    assert_equal(client.put("/icons/i", _filled(4097)).status, 413)


def test_within_the_limit_every_body_reaches_from_bytes_byte_for_byte() raises:
    var app = limit_app()
    var client = TestClient(app)
    for shape in _shapes():
        for body in _within():
            _reset()
            var r = _send(client, shape.method, shape.target, body, _sent())
            assert_equal(r.status, 200, shape.target)
            _assert_same(r.body, _expected(shape, body), shape.target)
            assert_equal(_count(FROM_BYTES_CALLS), 1, shape.target)
            assert_equal(_count(HANDLER_CALLS), 1, shape.target)


def test_one_byte_over_the_limit_is_413_before_from_bytes() raises:
    var app = limit_app()
    var client = TestClient(app)
    for shape in _shapes():
        for body in _over():
            _reset()
            var what = String(shape.target, " with ", len(body), " bytes")
            _assert_413(
                _send(client, shape.method, shape.target, body, _sent()), what
            )
            # The same through `App.handle` directly.
            _assert_413(
                app.handle(
                    Request(shape.method, shape.target, body.copy(), _sent())
                ),
                what + " (App.handle)",
            )


def test_exactly_the_limit_is_accepted() raises:
    var app = limit_app()
    for shape in _shapes():
        _reset()
        var r = app.handle(
            Request(shape.method, shape.target, _filled(LIMIT, 0x00), _sent())
        )
        assert_equal(r.status, 200, shape.target)
        _reset()
        var over = app.handle(
            Request(
                shape.method, shape.target, _filled(LIMIT + 1, 0x00), _sent()
            )
        )
        _assert_413(over, shape.target)


def test_a_zero_limit_accepts_only_the_empty_body() raises:
    var app = limit_app()
    var client = TestClient(app)
    for target in ["/zero", "/zero/c"]:
        _reset()
        var empty = client.post(target, List[UInt8](), headers=_sent())
        assert_equal(empty.status, 200, target)
        assert_equal(empty.text(), "0", target)
        _reset()
        _assert_413(
            client.post(target, _octets([0x00]), headers=_sent()), target
        )


def test_no_declared_limit_and_the_largest_int_are_unlimited() raises:
    assert_equal(Free.max_bytes, Int.MAX)
    assert_equal(Largest.max_bytes, Int.MAX)
    assert_equal(Capped.max_bytes, LIMIT)
    assert_equal(Upload[7].max_bytes, 7)
    var app = limit_app()
    var client = TestClient(app)
    var big = _filled(2 << 20)
    for target in ["/free", "/free/c", "/largest"]:
        _reset()
        var r = client.post(target, big.copy(), headers=_sent())
        assert_equal(r.status, 200, target)
        assert_equal(r.text(), String(2 << 20), target)
        assert_equal(_count(FROM_BYTES_CALLS), 1, target)


def test_a_bad_route_value_is_400_before_the_limit() raises:
    var app = limit_app()
    var client = TestClient(app)
    for m in ["POST", "PUT", "PATCH"]:
        for k in ["b", "c"]:
            var p = String("/", m.lower(), "/", k)
            for target in [
                p + "/v/x",
                p + "/v/%zz",
                p + "/two/7?tag=a&tag=b",
                p + "/two/7",  # the query value is missing
                p + "/two/x?tag=a",
                p + "/st/v/x",
                p + "/st/two/1/x",
            ]:
                _reset()
                var r = _send(client, m, target, _filled(1 << 20), _sent())
                assert_equal(r.status, 400, target)
                assert_equal(_count(FROM_BYTES_CALLS), 0, target)
                assert_equal(_count(HANDLER_CALLS), 0, target)
    for target in ["/opt/b?tag=1&tag=2", "/opt/c?tag=1&tag=2"]:
        _reset()
        var r = client.post(target, _filled(LIMIT + 1), headers=_sent())
        assert_equal(r.status, 400, target)
        assert_equal(_count(FROM_BYTES_CALLS), 0, target)


def test_404_405_and_head_convert_nothing() raises:
    var app = limit_app()
    _reset()
    var big = _filled(LIMIT + 1)
    assert_equal(
        app.handle(Request("POST", "/missing", big.copy(), _sent())).status,
        404,
    )
    assert_equal(
        app.handle(
            Request("POST", "/post/b/v/1/2", big.copy(), _sent())
        ).status,
        404,
    )
    var get = app.handle(Request("GET", "/post/b", big.copy(), _sent()))
    assert_equal(get.status, 405)
    assert_equal(get.headers.get("allow").or_else(""), "POST")
    var delete = app.handle(
        Request("DELETE", "/put/c/v/7", big.copy(), _sent())
    )
    assert_equal(delete.status, 405)
    assert_equal(delete.headers.get("allow").or_else(""), "PUT")
    var head = app.handle(Request("HEAD", "/hello", big.copy(), _sent()))
    assert_equal(head.status, 200)
    assert_equal(head.text(), "hello")
    assert_equal(_count(FROM_BYTES_CALLS), 0)
    assert_equal(_count(HANDLER_CALLS), 0)


def _bad() -> Headers:
    """A field an in-memory `Headers` can hold only through the M3-002
    `_fields` gap, which the carrier's rebuild answers with the fixed 500."""
    var h = Headers()
    h._fields.append(_Field("Bad Name", "v"))
    return h^


def test_the_carrier_answers_413_before_its_field_rebuild() raises:
    # Over the limit, 413 answers before the rebuild's 500; within it, the
    # rebuild's 500 answers before `from_bytes`.
    var app = limit_app()
    var routes: List[Tuple[String, String]] = [
        (String("POST"), String("/post/c")),
        (String("PATCH"), String("/patch/c/st/two/1/2")),
        (String("PUT"), String("/put/c/two/7?tag=x")),
        (String("POST"), String("/opt/c?tag=x")),
        (String("POST"), String("/zero/c")),
    ]
    for route in routes:
        _reset()
        _assert_413(
            app.handle(Request(route[0], route[1], _filled(LIMIT + 1), _bad())),
            route[1],
        )
        _reset()
        var within = app.handle(
            Request(route[0], route[1], List[UInt8](), _bad())
        )
        assert_equal(within.status, 500, route[1])
        assert_equal(within.text(), "Internal Server Error", route[1])
        assert_equal(_count(FROM_BYTES_CALLS), 0, route[1])
        assert_equal(_count(HANDLER_CALLS), 0, route[1])


def test_a_from_bytes_raise_within_the_limit_is_still_400() raises:
    var app = limit_app()
    var client = TestClient(app)
    for target in ["/strict", "/strict/c"]:
        _reset()
        var ok = client.post(target, _filled(8), headers=_sent())
        assert_equal(ok.text(), "8", target)
        _reset()
        var raised = client.post(target, _filled(8, 0x00), headers=_sent())
        assert_equal(raised.status, 400, target)
        assert_equal(raised.text(), "Bad Request", target)
        assert_equal(_count(FROM_BYTES_CALLS), 1, target)
        assert_equal(_count(HANDLER_CALLS), 0, target)
        # Over the limit, a body `from_bytes` would also reject is 413:
        # the limit answers first.
        _reset()
        _assert_413(
            client.post(target, _filled(9, 0x00), headers=_sent()), target
        )


def shrink(var request: Request, var next: Next) raises -> Response:
    """Replaces a body over `LIMIT` with three bytes; keeps the others."""
    if len(request.body) > LIMIT:
        request.body = _octets([0xFE, 0x00, 0xFF])
    return next^.run(request^)


def grow(var request: Request, var next: Next) raises -> Response:
    """Appends `LIMIT` bytes to every body."""
    request.body.extend(Span(_filled(LIMIT, 0x01)))
    return next^.run(request^)


def test_the_limit_measures_the_body_after_middleware() raises:
    var shrunk = limit_app()
    shrunk.use(shrink)
    var client = TestClient(shrunk)
    for shape in _shapes():
        for body in [_filled(LIMIT + 1), _filled(4096)]:
            _reset()
            var r = _send(client, shape.method, shape.target, body, _sent())
            assert_equal(r.status, 200, shape.target)
            _assert_same(
                r.body,
                _expected(shape, _octets([0xFE, 0x00, 0xFF])),
                shape.target,
            )
            assert_equal(_count(FROM_BYTES_CALLS), 1, shape.target)
    var grown = limit_app()
    grown.use(grow)
    var client2 = TestClient(grown)
    for shape in _shapes():
        _reset()
        var r = _send(
            client2, shape.method, shape.target, _octets([0x01]), _sent()
        )
        _assert_413(r, shape.target)
        _reset()
        var empty = _send(
            client2, shape.method, shape.target, List[UInt8](), _sent()
        )
        assert_equal(empty.status, 200, shape.target)


def test_text_json_raw_and_unlimited_routes_are_unchanged() raises:
    var app = limit_app()
    var client = TestClient(app)
    var big = _filled(2 << 20, 0x61)
    # A text body has no Muntin limit, whatever members its type declares.
    assert_equal(client.post("/note", big.copy()).text(), String(2 << 20))
    assert_equal(client.post("/note", _octets([0xFF])).status, 400)
    assert_equal(client.post("/raw", big.copy()).text(), String(2 << 20))
    var json = _h("Content-Type", "application/json")
    assert_equal(
        client.post("/greet", '{"name":"Ada"}', headers=json.copy()).text(),
        "hello Ada",
    )
    assert_equal(client.post("/greet", '{"name":"Ada"}').status, 415)
    var over_json = List('"'.as_bytes())
    over_json.extend(Span(_filled(1 << 20, 0x61)))
    assert_equal(
        client.post("/greet", over_json^, headers=json.copy()).status, 413
    )
    assert_equal(client.get("/hello").text(), "hello")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
