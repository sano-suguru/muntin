# Typed request body size limits: every `FromBytes` type declares
# `comptime max_bytes` (M3-043); a `FromBody` type may, and gets 1 MiB when
# it declares nothing or misspells the member (M3-089). A body longer than
# that, bare or inside `WithHeaders[B]`, is 413 before the conversion and
# the handler, after the route values and before the carrier's field
# rebuild and a text body's UTF-8 read. `Int.MAX` is no limit; a refining
# trait may give a `FromBytes` family a default. Every comparison of bytes
# is by length and byte by byte. `Json[T, limit=n]`: tests/test_json.mojo.
# Must-not-build counterparts: tests/bytes_limit_api_fail,
# tests/body_limit_api_fail.

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
from muntin.body import _FromBodyOrBytes
from muntin.http import _Field
from muntin.testing import TestClient

# `from_bytes` and `from_body` are static and see no state, so their calls
# and the handlers' are counted in environment variables.
comptime CONVERSIONS = "MUNTIN_TEST_LIMIT_CONVERSIONS"
comptime HANDLER_CALLS = "MUNTIN_TEST_LIMIT_HANDLER_CALLS"

comptime LIMIT = 256
"""`Capped`'s and `TextCapped`'s limit: the every-byte-value body is
exactly this long."""

comptime MIB = 1_048_576
"""A `FromBody` type's default `max_bytes`."""


def _count(name: String) -> Int:
    var n = getenv(name)
    try:
        return Int(n) if n else 0
    except:
        return -1


def _bump(name: String):
    _ = setenv(name, String(_count(name) + 1))


def _reset():
    _ = unsetenv(CONVERSIONS)
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


def _two_byte_chars(n: Int) -> List[UInt8]:
    """`n` copies of `é` (C3 A9): UTF-8 of `2 * n` bytes."""
    var out = List[UInt8]()
    for _ in range(n):
        out.append(0xC3)
        out.append(0xA9)
    return out^


def _within_text() -> List[List[UInt8]]:
    """UTF-8 bodies within `LIMIT`: empty, ASCII, Japanese, NUL, `LIMIT`
    bytes of `a`, and `LIMIT` bytes of two-byte characters."""
    return [
        List[UInt8](),
        List("hello".as_bytes()),
        List("こんにちは、世界".as_bytes()),
        _octets([0x00]),
        _filled(LIMIT, 0x61),
        _two_byte_chars(LIMIT // 2),
    ]


def _over_text() -> List[List[UInt8]]:
    """Bodies over `LIMIT`: UTF-8 one byte over, bytes that are not UTF-8
    (413, not the UTF-8 read's 400), and far more."""
    var one_more = _two_byte_chars(LIMIT // 2)
    one_more.append(0x61)
    return [one_more^, _filled(LIMIT + 1), _filled(64 * 1024, 0x61)]


def _is_text(path: String) -> Bool:
    """A route of `TextCapped` (`/<method>/t...`, `/<method>/tc...`,
    `/opt/t`, `/opt/tc`) rather than `Capped`."""
    var parts = String(path.split("?")[0]).split("/")
    return len(parts) > 2 and (parts[2] == "t" or parts[2] == "tc")


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


# docs/reference/body-limits.md: the text between the `# example:` lines
# is what the page shows (scripts/check_doc_examples.py).


# fmt: off
# example: bodies-limit-avatar
from muntin import App, FromBytes, WithHeaders


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
# example: end


# example: bodies-limit-blob
struct Blob[limit: Int](FromBytes):
    comptime max_bytes = Self.limit  # one type, a limit per route

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body.copy())


def put_blob(key: String, input: WithHeaders[Blob[1 << 20]]) -> String:
    var kind = input.headers.get("content-type").or_else("unknown")
    return String(key, ": ", len(input.body.data), " bytes, ", kind)


def put_icon(key: String, input: WithHeaders[Blob[4096]]) -> String:
    return String(key, ": ", len(input.body.data), " byte icon")
# example: end


# example: body-limits-text
from muntin import App, FromBody


struct Article(FromBody):
    comptime max_bytes = 8 << 20  # a longer body is 413, before the UTF-8 read

    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


struct Comment(FromBody):  # declares no max_bytes: 1 MiB
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def publish(id: Int, article: Article) -> String:
    return String(id, ": ", article.text.byte_length(), " bytes")


def add_comment(id: Int, comment: Comment) -> String:
    return String(id, ": ", comment.text.byte_length(), " byte comment")
# example: end


# example: body-limits-json
from muntin import App, Json, JsonFields


@fieldwise_init
struct NewPost(JsonFields):
    var title: String


def create_post(post: Json[NewPost, limit=64 * 1024]) -> String:
    return "posted " + post.value.title


def import_posts(posts: Json[List[NewPost], limit=8 << 20]) -> String:
    return String(len(posts.value), " posts")
# example: end
# fmt: on


# Application types.


trait Kept(_FromBodyOrBytes):
    """A body type whose value is the bytes it received, so one handler
    serves a bytes body and a text body."""

    def kept(self) -> List[UInt8]:
        ...


struct Capped(FromBytes, Kept):
    """Keeps every byte it receives, up to `LIMIT`; move-only."""

    comptime max_bytes = LIMIT

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        _bump(CONVERSIONS)
        return Self(body.copy())

    def kept(self) -> List[UInt8]:
        return self.data.copy()


struct TextCapped(FromBody, Kept):
    """Keeps the text it receives, up to `LIMIT` bytes; move-only."""

    comptime max_bytes = LIMIT

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(CONVERSIONS)
        return Self(List(body.as_bytes()))

    def kept(self) -> List[UInt8]:
        return self.data.copy()


struct Plain(FromBody):
    """Declares no `max_bytes`: `FromBody`'s 1 MiB."""

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(CONVERSIONS)
        return Self(body.byte_length())


struct Misspelled(FromBody):
    """`max_byte` is not the member: the 1 MiB default holds, so a typo
    fails closed."""

    comptime max_byte = Int.MAX

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(CONVERSIONS)
        return Self(body.byte_length())


struct FreeText(FromBody):
    """Declares `Int.MAX`: no limit."""

    comptime max_bytes = Int.MAX

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(CONVERSIONS)
        return Self(body.byte_length())


struct ZeroText(FromBody):
    """Accepts only the empty text."""

    comptime max_bytes = 0

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(CONVERSIONS)
        return Self(body.byte_length())


struct StrictText(FromBody):
    """At most 8 bytes, and raises unless they start with `!`."""

    comptime max_bytes = 8

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(CONVERSIONS)
        if not body.startswith("!"):
            raise Error("unsigned")
        return Self(body.byte_length())


struct Free(FromBytes):
    """Declares `Int.MAX`, which no body exceeds: no limit."""

    comptime max_bytes = Int.MAX

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        _bump(CONVERSIONS)
        return Self(len(body))


trait SmallUpload(FromBytes):
    """An application family of bytes bodies: a refining trait gives
    `max_bytes` a default its types inherit."""

    comptime max_bytes: Int = 16


struct Icon(SmallUpload):
    """Inherits `SmallUpload`'s 16."""

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        _bump(CONVERSIONS)
        return Self(len(body))


struct Banner(SmallUpload):
    """Overrides `SmallUpload`'s default."""

    comptime max_bytes = 32

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        _bump(CONVERSIONS)
        return Self(len(body))


struct Zero(FromBytes):
    """Accepts only the empty body."""

    comptime max_bytes = 0

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        _bump(CONVERSIONS)
        return Self(len(body))


struct Strict(FromBytes):
    """At most 8 bytes, and raises unless they start with 0xFF."""

    comptime max_bytes = 8

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        _bump(CONVERSIONS)
        if len(body) == 0 or body[0] != 0xFF:
            raise Error("unsigned")
        return Self(len(body))


struct Note(FromBody):
    """A text body whose type declares a limit of 4 bytes (M3-089)."""

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


def b_body[B: Kept](blob: B) -> Response:
    return _echo("", "", blob.kept())


def b_value[B: Kept](id: Int, var blob: B) -> String:
    return _summary(String(id), "", blob.kept())


def b_two[B: Kept](id: Int, tag: String, blob: B) -> Response:
    return _echo(String(id, " ", tag), "", blob.kept())


def b_optional[B: Kept](tag: Optional[String], blob: B) -> Response:
    return _echo(tag.or_else("none"), "", blob.kept())


def b_state[B: Kept](store: State[Store], blob: B) -> String:
    return _summary(store[].prefix, "", blob.kept())


def b_state_value[B: Kept](store: State[Store], id: Int, blob: B) -> Response:
    return _echo(String(store[].prefix, " ", id), "", blob.kept())


def b_state_two[
    B: Kept
](store: State[Store], a: Int, b: Int, blob: B) -> String:
    return _summary(String(store[].prefix, " ", a, " ", b), "", blob.kept())


def c_body[B: Kept](input: WithHeaders[B]) -> Response:
    return _echo("", _fields(input.headers), input.body.kept())


def c_value[B: Kept](id: Int, var input: WithHeaders[B]) -> String:
    return _summary(String(id), _fields(input.headers), input.body.kept())


def c_two[B: Kept](id: Int, tag: String, input: WithHeaders[B]) -> Response:
    return _echo(
        String(id, " ", tag), _fields(input.headers), input.body.kept()
    )


def c_optional[
    B: Kept
](tag: Optional[String], input: WithHeaders[B]) -> Response:
    return _echo(tag.or_else("none"), _fields(input.headers), input.body.kept())


def c_state[B: Kept](store: State[Store], input: WithHeaders[B]) -> String:
    return _summary(store[].prefix, _fields(input.headers), input.body.kept())


def c_state_value[
    B: Kept
](store: State[Store], id: Int, input: WithHeaders[B]) -> Response:
    return _echo(
        String(store[].prefix, " ", id),
        _fields(input.headers),
        input.body.kept(),
    )


def c_state_two[
    B: Kept
](store: State[Store], a: Int, b: Int, input: WithHeaders[B]) -> String:
    return _summary(
        String(store[].prefix, " ", a, " ", b),
        _fields(input.headers),
        input.body.kept(),
    )


def free(f: Free) -> String:
    _bump(HANDLER_CALLS)
    return String(f.n)


def free_carrier(input: WithHeaders[Free]) -> String:
    _bump(HANDLER_CALLS)
    return String(input.body.n)


def icon(i: Icon) -> String:
    _bump(HANDLER_CALLS)
    return String(i.n)


def banner(input: WithHeaders[Banner]) -> String:
    _bump(HANDLER_CALLS)
    return String(input.body.n)


def zero(z: Zero) -> String:
    _bump(HANDLER_CALLS)
    return String(z.n)


def zero_carrier(input: WithHeaders[Zero]) -> String:
    _bump(HANDLER_CALLS)
    return String(input.body.n)


def strict(s: Strict) -> String:
    _bump(HANDLER_CALLS)
    return String(s.n)


def strict_carrier(input: WithHeaders[Strict]) -> String:
    _bump(HANDLER_CALLS)
    return String(input.body.n)


def plain(b: Plain) -> String:
    _bump(HANDLER_CALLS)
    return String(b.n)


def plain_carrier(input: WithHeaders[Plain]) -> String:
    _bump(HANDLER_CALLS)
    return String(input.body.n)


def misspelled(b: Misspelled) -> String:
    _bump(HANDLER_CALLS)
    return String(b.n)


def misspelled_carrier(input: WithHeaders[Misspelled]) -> String:
    _bump(HANDLER_CALLS)
    return String(input.body.n)


def free_text(b: FreeText) -> String:
    _bump(HANDLER_CALLS)
    return String(b.n)


def free_text_carrier(input: WithHeaders[FreeText]) -> String:
    _bump(HANDLER_CALLS)
    return String(input.body.n)


def zero_text(b: ZeroText) -> String:
    _bump(HANDLER_CALLS)
    return String(b.n)


def zero_text_carrier(input: WithHeaders[ZeroText]) -> String:
    _bump(HANDLER_CALLS)
    return String(input.body.n)


def strict_text(b: StrictText) -> String:
    _bump(HANDLER_CALLS)
    return String(b.n)


def strict_text_carrier(input: WithHeaders[StrictText]) -> String:
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
    var text: Bool

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
        self.text = _is_text(target)


def _shapes() -> List[_Shape]:
    """Every registered `Capped` route, bare (`/b`) and in a carrier
    (`/c`), and every `TextCapped` one (`/t`, `/tc`): method, target, the
    handler's echo of its route values and state, and its result policy."""
    var out = List[_Shape]()
    for m in ["POST", "PUT", "PATCH"]:
        for k in ["b", "c", "t", "tc"]:
            var p = String("/", m.lower(), "/", k)
            var c = k == "c" or k == "tc"
            out.append(_Shape(m, p, "", c, True))
            out.append(_Shape(m, p + "/v/%34%32", "42", c, False))
            out.append(_Shape(m, p + "/two/7?tag=a+b", "7 a b", c, True))
            out.append(_Shape(m, p + "/st", "st", c, False))
            out.append(_Shape(m, p + "/st/v/3", "st 3", c, True))
            out.append(_Shape(m, p + "/st/two/1/2", "st 1 2", c, False))
    for k in ["b", "c", "t", "tc"]:
        var c = k == "c" or k == "tc"
        out.append(_Shape("POST", String("/opt/", k, "?tag=x"), "x", c, True))
        out.append(_Shape("POST", String("/opt/", k), "none", c, True))
    return out^


def _within_for(shape: _Shape) -> List[List[UInt8]]:
    return _within_text() if shape.text else _within()


def _over_for(shape: _Shape) -> List[List[UInt8]]:
    return _over_text() if shape.text else _over()


def limit_app() -> App:
    var app = App()
    var store = State(Store("st"))
    app.post["/post/b"](b_body[Capped])
    app.post["/post/b/v/{id}"](b_value[Capped])
    app.post["/post/b/two/{id}?{tag}"](b_two[Capped])
    app.post["/post/b/st"](b_state[Capped], store)
    app.post["/post/b/st/v/{id}"](b_state_value[Capped], store)
    app.post["/post/b/st/two/{a}/{b}"](b_state_two[Capped], store)
    app.post["/post/c"](c_body[Capped])
    app.post["/post/c/v/{id}"](c_value[Capped])
    app.post["/post/c/two/{id}?{tag}"](c_two[Capped])
    app.post["/post/c/st"](c_state[Capped], store)
    app.post["/post/c/st/v/{id}"](c_state_value[Capped], store)
    app.post["/post/c/st/two/{a}/{b}"](c_state_two[Capped], store)
    app.put["/put/b"](b_body[Capped])
    app.put["/put/b/v/{id}"](b_value[Capped])
    app.put["/put/b/two/{id}?{tag}"](b_two[Capped])
    app.put["/put/b/st"](b_state[Capped], store)
    app.put["/put/b/st/v/{id}"](b_state_value[Capped], store)
    app.put["/put/b/st/two/{a}/{b}"](b_state_two[Capped], store)
    app.put["/put/c"](c_body[Capped])
    app.put["/put/c/v/{id}"](c_value[Capped])
    app.put["/put/c/two/{id}?{tag}"](c_two[Capped])
    app.put["/put/c/st"](c_state[Capped], store)
    app.put["/put/c/st/v/{id}"](c_state_value[Capped], store)
    app.put["/put/c/st/two/{a}/{b}"](c_state_two[Capped], store)
    app.patch["/patch/b"](b_body[Capped])
    app.patch["/patch/b/v/{id}"](b_value[Capped])
    app.patch["/patch/b/two/{id}?{tag}"](b_two[Capped])
    app.patch["/patch/b/st"](b_state[Capped], store)
    app.patch["/patch/b/st/v/{id}"](b_state_value[Capped], store)
    app.patch["/patch/b/st/two/{a}/{b}"](b_state_two[Capped], store)
    app.patch["/patch/c"](c_body[Capped])
    app.patch["/patch/c/v/{id}"](c_value[Capped])
    app.patch["/patch/c/two/{id}?{tag}"](c_two[Capped])
    app.patch["/patch/c/st"](c_state[Capped], store)
    app.patch["/patch/c/st/v/{id}"](c_state_value[Capped], store)
    app.patch["/patch/c/st/two/{a}/{b}"](c_state_two[Capped], store)
    app.post["/opt/b?{tag}"](b_optional[Capped])
    app.post["/opt/c?{tag}"](c_optional[Capped])
    app.post["/post/t"](b_body[TextCapped])
    app.post["/post/t/v/{id}"](b_value[TextCapped])
    app.post["/post/t/two/{id}?{tag}"](b_two[TextCapped])
    app.post["/post/t/st"](b_state[TextCapped], store)
    app.post["/post/t/st/v/{id}"](b_state_value[TextCapped], store)
    app.post["/post/t/st/two/{a}/{b}"](b_state_two[TextCapped], store)
    app.post["/post/tc"](c_body[TextCapped])
    app.post["/post/tc/v/{id}"](c_value[TextCapped])
    app.post["/post/tc/two/{id}?{tag}"](c_two[TextCapped])
    app.post["/post/tc/st"](c_state[TextCapped], store)
    app.post["/post/tc/st/v/{id}"](c_state_value[TextCapped], store)
    app.post["/post/tc/st/two/{a}/{b}"](c_state_two[TextCapped], store)
    app.put["/put/t"](b_body[TextCapped])
    app.put["/put/t/v/{id}"](b_value[TextCapped])
    app.put["/put/t/two/{id}?{tag}"](b_two[TextCapped])
    app.put["/put/t/st"](b_state[TextCapped], store)
    app.put["/put/t/st/v/{id}"](b_state_value[TextCapped], store)
    app.put["/put/t/st/two/{a}/{b}"](b_state_two[TextCapped], store)
    app.put["/put/tc"](c_body[TextCapped])
    app.put["/put/tc/v/{id}"](c_value[TextCapped])
    app.put["/put/tc/two/{id}?{tag}"](c_two[TextCapped])
    app.put["/put/tc/st"](c_state[TextCapped], store)
    app.put["/put/tc/st/v/{id}"](c_state_value[TextCapped], store)
    app.put["/put/tc/st/two/{a}/{b}"](c_state_two[TextCapped], store)
    app.patch["/patch/t"](b_body[TextCapped])
    app.patch["/patch/t/v/{id}"](b_value[TextCapped])
    app.patch["/patch/t/two/{id}?{tag}"](b_two[TextCapped])
    app.patch["/patch/t/st"](b_state[TextCapped], store)
    app.patch["/patch/t/st/v/{id}"](b_state_value[TextCapped], store)
    app.patch["/patch/t/st/two/{a}/{b}"](b_state_two[TextCapped], store)
    app.patch["/patch/tc"](c_body[TextCapped])
    app.patch["/patch/tc/v/{id}"](c_value[TextCapped])
    app.patch["/patch/tc/two/{id}?{tag}"](c_two[TextCapped])
    app.patch["/patch/tc/st"](c_state[TextCapped], store)
    app.patch["/patch/tc/st/v/{id}"](c_state_value[TextCapped], store)
    app.patch["/patch/tc/st/two/{a}/{b}"](c_state_two[TextCapped], store)
    app.post["/opt/t?{tag}"](b_optional[TextCapped])
    app.post["/opt/tc?{tag}"](c_optional[TextCapped])
    app.post["/plain"](plain)
    app.post["/plain/c"](plain_carrier)
    app.post["/misspelled"](misspelled)
    app.post["/misspelled/c"](misspelled_carrier)
    app.post["/free-text"](free_text)
    app.post["/free-text/c"](free_text_carrier)
    app.post["/zero-text"](zero_text)
    app.post["/zero-text/c"](zero_text_carrier)
    app.post["/strict-text"](strict_text)
    app.post["/strict-text/c"](strict_text_carrier)
    app.post["/free"](free)
    app.post["/free/c"](free_carrier)
    app.post["/icon"](icon)
    app.post["/banner"](banner)
    app.post["/zero"](zero)
    app.post["/zero/c"](zero_carrier)
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
    assert_equal(_count(CONVERSIONS), 0, what + ": conversion")
    assert_equal(_count(HANDLER_CALLS), 0, what + ": handler")


def test_dx_examples() raises:
    var app = App()
    # fmt: off
    # example: bodies-limit-avatar
    app.put["/users/{id}/avatar"](set_avatar)
    # PUT /users/7/avatar  65,536 bytes  -> 200 "7: 65536 bytes"
    # PUT /users/7/avatar  65,537 bytes  -> 413 "Content Too Large"  (from_bytes and set_avatar not called)
    # PUT /users/x/avatar  70,000 bytes  -> 400 "Bad Request"  (the route value answers first, whatever the length)
    # PUT /users/7/avatar  empty         -> 400 "Bad Request"  (from_bytes raised)
    # example: end
    # example: bodies-limit-blob
    app.put["/blobs/{key}"](put_blob)
    app.put["/icons/{key}"](put_icon)
    # PUT /blobs/a.png  Content-Type: image/png  1,048,576 bytes -> 200 "a.png: 1048576 bytes, image/png"
    # PUT /blobs/a.png  1,048,577 bytes                          -> 413 "Content Too Large"
    # PUT /icons/i  4,096 bytes -> 200 "i: 4096 byte icon";  4,097 bytes -> 413
    # example: end
    # fmt: on
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
    var big = client.put("/blobs/a.png", _filled(1 << 20), headers=png^)
    assert_equal(big.text(), "a.png: 1048576 bytes, image/png")
    assert_equal(client.put("/blobs/a.png", _filled((1 << 20) + 1)).status, 413)
    assert_equal(
        client.put("/icons/i", _filled(4096)).text(), "i: 4096 byte icon"
    )
    assert_equal(client.put("/icons/i", _filled(4097)).status, 413)


def _json_padded(text: String, n: Int) -> List[UInt8]:
    """`text` followed by spaces, `n` bytes in all: still the same JSON."""
    var out = List(text.as_bytes())
    while len(out) < n:
        out.append(0x20)
    return out^


def test_dx_text_and_json_examples() raises:
    var app = App()
    # fmt: off
    # example: body-limits-text
    app.put["/articles/{id}"](publish)
    app.post["/articles/{id}/comments"](add_comment)
    # PUT /articles/7  8,388,608 bytes  -> 200 "7: 8388608 bytes"
    # PUT /articles/7  8,388,609 bytes  -> 413 "Content Too Large"  (from_body and publish not called, UTF-8 or not)
    # POST /articles/7/comments  1,048,576 bytes -> 200 "7: 1048576 byte comment";  1,048,577 bytes -> 413
    # example: end
    # example: body-limits-json
    app.post["/posts"](create_post)
    app.post["/posts/import"](import_posts)
    # POST /posts  Content-Type: application/json  65,536 bytes -> 200 "posted a";  65,537 bytes -> 413
    #   (after the 415 check, before parsing)
    # POST /posts/import  Content-Type: application/json  2 MiB -> 200 (Json[T] alone: 413 past 1 MiB)
    # example: end
    # fmt: on
    var client = TestClient(app)
    _reset()
    var at = client.put("/articles/7", _filled(8 << 20, 0x61))
    assert_equal(at.text(), "7: 8388608 bytes")
    _assert_413(client.put("/articles/7", _filled((8 << 20) + 1, 0x61)), "a")
    _assert_413(client.put("/articles/7", _filled((8 << 20) + 1)), "not UTF-8")
    assert_equal(
        client.post("/articles/7/comments", _filled(MIB, 0x61)).text(),
        "7: 1048576 byte comment",
    )
    _assert_413(
        client.post("/articles/7/comments", _filled(MIB + 1, 0x61)), "comment"
    )
    # A direct call checks no limit: the rule is `App.handle`'s.
    var long = String(unsafe_from_utf8=_filled(MIB + 1, 0x61))
    assert_equal(Comment.from_body(long).text.byte_length(), MIB + 1)
    var json = _h("Content-Type", "application/json")
    var post = '{"title":"a"}'
    assert_equal(
        client.post(
            "/posts", _json_padded(post, 64 * 1024), headers=json.copy()
        ).text(),
        "posted a",
    )
    _assert_413(
        client.post(
            "/posts", _json_padded(post, 64 * 1024 + 1), headers=json.copy()
        ),
        "post",
    )
    assert_equal(
        client.post("/posts", _json_padded(post, 64 * 1024 + 1)).status, 415
    )
    var posts = _json_padded("[" + post + "," + post + "]", 2 * MIB)
    assert_equal(
        client.post("/posts/import", posts^, headers=json.copy()).text(),
        "2 posts",
    )


def test_within_the_limit_every_body_reaches_the_conversion_byte_for_byte() raises:
    var app = limit_app()
    var client = TestClient(app)
    for shape in _shapes():
        for body in _within_for(shape):
            _reset()
            var r = _send(client, shape.method, shape.target, body, _sent())
            assert_equal(r.status, 200, shape.target)
            _assert_same(r.body, _expected(shape, body), shape.target)
            assert_equal(_count(CONVERSIONS), 1, shape.target)
            assert_equal(_count(HANDLER_CALLS), 1, shape.target)
            # The same through `App.handle` directly.
            _reset()
            var direct = app.handle(
                Request(shape.method, shape.target, body.copy(), _sent())
            )
            assert_equal(direct.status, 200, shape.target + " (App.handle)")
            _assert_same(
                direct.body,
                _expected(shape, body),
                shape.target + " (App.handle)",
            )
            assert_equal(_count(CONVERSIONS), 1, shape.target + " (App.handle)")
            assert_equal(
                _count(HANDLER_CALLS), 1, shape.target + " (App.handle)"
            )


def test_one_byte_over_the_limit_is_413_before_the_conversion() raises:
    # On a text route this includes a body that is not UTF-8: 413, not the
    # UTF-8 read's 400.
    var app = limit_app()
    var client = TestClient(app)
    for shape in _shapes():
        for body in _over_for(shape):
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


def test_a_text_body_is_413_before_its_utf8_read() raises:
    # Within the limit, bytes that are not UTF-8 are the read's 400 without
    # `from_body`; one byte more is 413.
    var app = limit_app()
    for shape in _shapes():
        if not shape.text:
            continue
        _reset()
        var bad = app.handle(
            Request(shape.method, shape.target, _filled(LIMIT), _sent())
        )
        assert_equal(bad.status, 400, shape.target)
        assert_equal(bad.text(), "Bad Request", shape.target)
        assert_equal(_count(CONVERSIONS), 0, shape.target)
        assert_equal(_count(HANDLER_CALLS), 0, shape.target)
        _reset()
        _assert_413(
            app.handle(
                Request(shape.method, shape.target, _filled(LIMIT + 1), _sent())
            ),
            shape.target,
        )


def test_a_text_type_that_declares_nothing_gets_one_mib() raises:
    assert_equal(Plain.max_bytes, MIB)
    assert_equal(Misspelled.max_bytes, MIB)
    assert_equal(TextCapped.max_bytes, LIMIT)
    var app = limit_app()
    var client = TestClient(app)
    # A misspelled member is not the limit: the default holds (fails
    # closed).
    for target in ["/plain", "/plain/c", "/misspelled", "/misspelled/c"]:
        _reset()
        var at = client.post(target, _filled(MIB, 0x61), headers=_sent())
        assert_equal(at.status, 200, target)
        assert_equal(at.text(), String(MIB), target)
        assert_equal(_count(CONVERSIONS), 1, target)
        _reset()
        _assert_413(
            client.post(target, _filled(MIB + 1, 0x61), headers=_sent()), target
        )


def test_a_zero_limit_accepts_only_the_empty_body() raises:
    var app = limit_app()
    var client = TestClient(app)
    for target in ["/zero", "/zero/c", "/zero-text", "/zero-text/c"]:
        _reset()
        var empty = client.post(target, List[UInt8](), headers=_sent())
        assert_equal(empty.status, 200, target)
        assert_equal(empty.text(), "0", target)
        _reset()
        _assert_413(
            client.post(target, _octets([0x00]), headers=_sent()), target
        )


def test_the_largest_int_is_no_limit() raises:
    assert_equal(Free.max_bytes, Int.MAX)
    assert_equal(FreeText.max_bytes, Int.MAX)
    assert_equal(Capped.max_bytes, LIMIT)
    assert_equal(Blob[7].max_bytes, 7)
    var app = limit_app()
    var client = TestClient(app)
    var big = _filled(2 << 20, 0x61)
    for target in ["/free", "/free/c", "/free-text", "/free-text/c"]:
        _reset()
        var r = client.post(target, big.copy(), headers=_sent())
        assert_equal(r.status, 200, target)
        assert_equal(r.text(), String(2 << 20), target)
        assert_equal(_count(CONVERSIONS), 1, target)


def test_a_refining_trait_gives_a_family_default() raises:
    # Bytes bodies only: a refining trait cannot give `FromBody`'s
    # `max_bytes` another default (tests/body_limit_api_fail).
    assert_equal(Icon.max_bytes, 16)
    assert_equal(Banner.max_bytes, 32)
    var app = limit_app()
    var client = TestClient(app)
    var limits: List[Tuple[String, Int]] = [
        (String("/icon"), 16),
        (String("/banner"), 32),
    ]
    for c in limits:
        _reset()
        var at = client.post(c[0], _filled(c[1]), headers=_sent())
        assert_equal(at.text(), String(c[1]), c[0])
        _reset()
        _assert_413(client.post(c[0], _filled(c[1] + 1), headers=_sent()), c[0])


def test_a_bad_route_value_is_400_before_the_limit() raises:
    var app = limit_app()
    var client = TestClient(app)
    for m in ["POST", "PUT", "PATCH"]:
        for k in ["b", "c", "t", "tc"]:
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
                assert_equal(_count(CONVERSIONS), 0, target)
                assert_equal(_count(HANDLER_CALLS), 0, target)
    for k in ["b", "c", "t", "tc"]:
        var target = String("/opt/", k, "?tag=1&tag=2")
        _reset()
        var r = client.post(target, _filled(LIMIT + 1), headers=_sent())
        assert_equal(r.status, 400, target)
        assert_equal(_count(CONVERSIONS), 0, target)


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
    var text = app.handle(Request("GET", "/patch/tc/st", big.copy(), _sent()))
    assert_equal(text.status, 405)
    assert_equal(text.headers.get("allow").or_else(""), "PATCH")
    var head = app.handle(Request("HEAD", "/hello", big.copy(), _sent()))
    assert_equal(head.status, 200)
    assert_equal(head.text(), "hello")
    assert_equal(_count(CONVERSIONS), 0)
    assert_equal(_count(HANDLER_CALLS), 0)


def _bad() -> Headers:
    """A field an in-memory `Headers` can hold only through the M3-002
    `_fields` gap, which the carrier's rebuild answers with the fixed 500."""
    var h = Headers()
    h._fields.append(_Field("Bad Name", "v"))
    return h^


def test_the_carrier_answers_413_before_its_field_rebuild() raises:
    # Over the limit, 413 answers before the rebuild's 500; within it, the
    # rebuild's 500 answers before the conversion.
    var app = limit_app()
    var routes: List[Tuple[String, String]] = [
        (String("POST"), String("/post/c")),
        (String("PATCH"), String("/patch/c/st/two/1/2")),
        (String("PUT"), String("/put/c/two/7?tag=x")),
        (String("POST"), String("/opt/c?tag=x")),
        (String("POST"), String("/zero/c")),
        (String("POST"), String("/post/tc")),
        (String("PUT"), String("/put/tc/st/v/3")),
        (String("PATCH"), String("/patch/tc/two/7?tag=x")),
        (String("POST"), String("/opt/tc")),
        (String("POST"), String("/zero-text/c")),
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
        assert_equal(_count(CONVERSIONS), 0, route[1])
        assert_equal(_count(HANDLER_CALLS), 0, route[1])


def test_a_conversion_raise_within_the_limit_is_still_400() raises:
    var app = limit_app()
    var client = TestClient(app)
    var cases: List[Tuple[String, Int]] = [
        (String("/strict"), 0xFF),
        (String("/strict/c"), 0xFF),
        (String("/strict-text"), 0x21),
        (String("/strict-text/c"), 0x21),
    ]
    for c in cases:
        var target = c[0]
        _reset()
        var ok = client.post(target, _filled(8, c[1]), headers=_sent())
        assert_equal(ok.text(), "8", target)
        _reset()
        var raised = client.post(target, _filled(8, 0x00), headers=_sent())
        assert_equal(raised.status, 400, target)
        assert_equal(raised.text(), "Bad Request", target)
        assert_equal(_count(CONVERSIONS), 1, target)
        assert_equal(_count(HANDLER_CALLS), 0, target)
        # Over the limit, a body the conversion would also reject is 413:
        # the limit answers first.
        _reset()
        _assert_413(
            client.post(target, _filled(9, 0x00), headers=_sent()), target
        )


def _shrunk(path: String) -> List[UInt8]:
    """Three bytes: not UTF-8 on a bytes route, UTF-8 on a text one."""
    if _is_text(path):
        return _octets([0x7E, 0x00, 0x7F])
    return _octets([0xFE, 0x00, 0xFF])


def shrink(var request: Request, var next: Next) raises -> Response:
    """Replaces a body over `LIMIT` with three bytes; keeps the others."""
    if len(request.body) > LIMIT:
        request.body = _shrunk(request.path)
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
                r.body, _expected(shape, _shrunk(shape.target)), shape.target
            )
            assert_equal(_count(CONVERSIONS), 1, shape.target)
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


def test_a_text_types_max_bytes_is_its_limit_and_raw_has_none() raises:
    var app = limit_app()
    var client = TestClient(app)
    var big = _filled(2 << 20, 0x61)
    # `Note` declares 4 (M3-089): before, a text body had no Muntin limit
    # whatever members its type declared.
    assert_equal(client.post("/note", _filled(4, 0x61)).text(), "4")
    assert_equal(client.post("/note", _filled(5, 0x61)).status, 413)
    assert_equal(client.post("/note", big.copy()).status, 413)
    assert_equal(client.post("/note", _octets([0xFF])).status, 400)
    # A raw route has none: the handler reads the bytes itself.
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
