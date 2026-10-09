"""Flare request body probe (M3-038 evidence). Not Muntin.

Runs only in the `flare` pixi environment (scripts/check_flare.sh). It
measures what the pinned Flare backend hands a handler as a request body, so
the decision can say where bytes that are not UTF-8 are lost and whether a
backend can see them before they are. It is self-checking: every
observation is compared with the bytes recorded here, and a test fails if
Flare or Mojo changes.

`BodyBytes` is a Flare `Handler` of the probe's own (no Muntin, no
adapter): it answers 200 with `raw=<hex of Request.body>;text=<hex of
Request.text()>`, ASCII the wire cannot alter. It is served in a forked
child (lifecycle as in compat/flare/head/head_probe.mojo) and reached over
HTTP/1.1 (a raw `TcpStream` request with `Content-Length` and
`Connection: close`) and over cleartext HTTP/2 with prior knowledge (one
HEADERS frame, then one DATA frame carrying the body with END_STREAM; an
empty body is a HEADERS frame with END_STREAM). Each body in `cases()` is
sent on both protocols.

Observations:
- Flare delivers every body to the handler, on both protocols: none of them
  is answered by Flare itself, the ones that are not UTF-8 included;
- `Request.body` holds exactly the bytes sent, on both protocols;
- `Request.text()` replaces each maximal ill-formed subpart with U+FFFD
  (`EF BF BD`), so a sent U+FFFD and a replaced byte give the same text;
- Mojo 1.1.0's `String(from_utf8=)` raises on exactly the bodies `text()`
  changes, and for every other body holds the same bytes (NUL included).
"""

from std.ffi import c_uint, external_call
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from flare.http import (
    Handler,
    HttpServer,
    Request as FlareRequest,
    Response as FlareResponse,
)
from flare.http2 import (
    Frame,
    FrameFlags,
    FrameType,
    H2_PREFACE,
    HpackDecoder,
    HpackEncoder,
    HpackHeader,
    encode_frame,
    parse_frame,
)
from flare.net import SocketAddr
from flare.tcp import TcpStream
from flare.utils import SIGKILL, exit, fork, kill, waitpid

comptime TIMEOUT_MS = 5_000
comptime CHILD_LIFETIME_S = 30


def hex(bytes: Span[UInt8, _]) -> String:
    var digits = "0123456789abcdef"
    var out = String()
    for i in range(len(bytes)):
        var b = Int(bytes[i])
        out += String(digits[byte=b // 16]) + String(digits[byte=b % 16])
    return out^


@fieldwise_init
struct Case(Copyable):
    var name: String
    var bytes: List[UInt8]
    var utf8: Bool
    """Whether the bytes are well-formed UTF-8."""
    var text: String
    """The hex of what `Request.text()` gives for them."""


def _bytes(values: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for v in values:
        out.append(UInt8(v))
    return out^


def cases() -> List[Case]:
    var out = List[Case]()
    out.append(Case("ascii", List("hello".as_bytes()), True, "68656c6c6f"))
    out.append(
        Case("utf8", List("hé✓".as_bytes()), True, hex("hé✓".as_bytes()))
    )
    out.append(Case("x80", _bytes([0x80]), False, "efbfbd"))
    out.append(Case("xff", _bytes([0xFF]), False, "efbfbd"))
    # The first two bytes of U+3042 (E3 81 82).
    out.append(Case("truncated", _bytes([0xE3, 0x81]), False, "efbfbd"))
    out.append(Case("overlong", _bytes([0xC0, 0xAF]), False, "efbfbdefbfbd"))
    out.append(
        Case(
            "surrogate", _bytes([0xED, 0xA0, 0x80]), False, "efbfbdefbfbdefbfbd"
        )
    )
    # A U+FFFD the client sent is well-formed.
    out.append(
        Case("fffd", _bytes([0x61, 0xEF, 0xBF, 0xBD, 0x62]), True, "61efbfbd62")
    )
    # ... and its text equals a replaced byte's.
    out.append(
        Case("fffd_ff", _bytes([0xEF, 0xBF, 0xBD, 0xFF]), False, "efbfbdefbfbd")
    )
    out.append(Case("nul", _bytes([0x61, 0x00, 0x62, 0x00]), True, "61006200"))
    out.append(Case("empty", List[UInt8](), True, ""))
    # The PNG signature: an octet stream that is not UTF-8.
    out.append(
        Case(
            "png",
            _bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            False,
            "efbfbd504e470d0a1a0a",
        )
    )
    # An octet stream that happens to be well-formed UTF-8.
    out.append(
        Case("octets_utf8", _bytes([0x00, 0x01, 0x7F, 0x0A]), True, "00017f0a")
    )
    return out^


struct BodyBytes(Handler):
    def __init__(out self):
        pass

    def serve(self, request: FlareRequest) -> FlareResponse:
        var text = request.text()
        var answer = String(
            "raw=", hex(Span(request.body)), ";text=", hex(text.as_bytes())
        )
        return FlareResponse(status=200, body=List(answer.as_bytes()))


@fieldwise_init
struct _Child(Copyable):
    var pid: Int
    var port: UInt16


def _serve() raises -> _Child:
    var server = HttpServer.bind(SocketAddr.localhost(0))
    var port = server.local_addr().port
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        try:
            server.serve(BodyBytes())
        except e:
            print("server child: serve failed:", e)
        exit(1)
    return _Child(pid, port)


def h1_post(port: UInt16, body: List[UInt8]) raises -> Tuple[String, String]:
    """`POST /p` over HTTP/1.1 with `body`; the status line and the response
    body (ASCII here) after the blank line."""
    var head = String(
        (
            "POST /p HTTP/1.1\r\nHost: probe\r\nContent-Type:"
            " application/octet-stream\r\nContent-Length: "
        ),
        len(body),
        "\r\nConnection: close\r\n\r\n",
    )
    var wire = List(head.as_bytes())
    wire.extend(Span(body))
    var stream = TcpStream.connect(SocketAddr.localhost(port))
    stream.set_recv_timeout(TIMEOUT_MS)
    stream.write_all(Span[UInt8, _](wire))
    var acc = List[UInt8]()
    var buf = List[UInt8]()
    buf.resize(4096, 0)
    while True:
        var n = stream.read(buf.unsafe_ptr(), len(buf))
        if n == 0:
            break
        for k in range(n):
            acc.append(buf[k])
    var text = String(from_utf8=Span(acc))
    var line_end = text.find("\r\n")
    var blank = text.find("\r\n\r\n")
    if line_end < 0 or blank < 0:
        raise Error("no HTTP/1.1 response")
    return (String(text[byte=:line_end]), String(text[byte = blank + 4 :]))


def _frame(
    typ: FrameType, flags: UInt8, sid: Int, var payload: List[UInt8]
) -> List[UInt8]:
    var f = Frame()
    f.header.type = typ.copy()
    f.header.flags = FrameFlags(flags)
    f.header.stream_id = sid
    f.payload = payload^
    return encode_frame(f)


def h2_post(port: UInt16, body: List[UInt8]) raises -> Tuple[String, String]:
    """`POST /p` over h2c on stream 1 with `body` in one DATA frame; the
    `:status` value and the response body."""
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(":method", "POST"))
    hdrs.append(HpackHeader(":scheme", "http"))
    hdrs.append(HpackHeader(":path", "/p"))
    hdrs.append(HpackHeader(":authority", "probe"))
    hdrs.append(HpackHeader("content-type", "application/octet-stream"))
    var block = HpackEncoder().encode(Span[HpackHeader, _](hdrs))
    var wire = List(H2_PREFACE.as_bytes())
    wire.extend(Span(_frame(FrameType.SETTINGS(), 0, 0, List[UInt8]())))
    if len(body) == 0:
        wire.extend(
            Span(
                _frame(
                    FrameType.HEADERS(),
                    FrameFlags.END_HEADERS() | FrameFlags.END_STREAM(),
                    1,
                    block^,
                )
            )
        )
    else:
        wire.extend(
            Span(
                _frame(FrameType.HEADERS(), FrameFlags.END_HEADERS(), 1, block^)
            )
        )
        wire.extend(
            Span(
                _frame(
                    FrameType.DATA(), FrameFlags.END_STREAM(), 1, body.copy()
                )
            )
        )
    var stream = TcpStream.connect(SocketAddr.localhost(port))
    stream.set_recv_timeout(TIMEOUT_MS)
    stream.write_all(Span[UInt8, _](wire))
    var decoder = HpackDecoder()
    var acc = List[UInt8]()
    var buf = List[UInt8]()
    buf.resize(4096, 0)
    var pos = 0
    var status = String()
    var out = List[UInt8]()
    while True:
        var maybe = parse_frame(Span[UInt8, _](acc)[pos:])
        if not maybe:
            var n = stream.read(buf.unsafe_ptr(), len(buf))
            if n == 0:
                raise Error("connection closed before the response ended")
            for k in range(n):
                acc.append(buf[k])
            continue
        var f = maybe.value().copy()
        pos += 9 + f.header.length
        if f.header.stream_id != 1:
            if f.header.type.value == FrameType.GOAWAY().value:
                raise Error("GOAWAY")
            continue
        if f.header.type.value == FrameType.HEADERS().value:
            var fields = decoder.decode(Span[UInt8, _](f.payload))
            status = fields[0].value
        elif f.header.type.value == FrameType.DATA().value:
            out.extend(Span[UInt8, _](f.payload))
        elif f.header.type.value == FrameType.RST_STREAM().value:
            raise Error("RST_STREAM")
        if f.header.flags.has(FrameFlags.END_STREAM()):
            break
    return (status^, String(from_utf8=Span(out)))


def test_flare_delivers_every_body_unchanged() raises:
    var child = _serve()
    try:
        for c in cases():
            var expected = String("raw=", hex(Span(c.bytes)), ";text=", c.text)
            var h1 = h1_post(child.port, c.bytes)
            print("observed HTTP/1.1", c.name + ":", h1[0], h1[1])
            assert_equal(h1[0], "HTTP/1.1 200 OK", c.name)
            assert_equal(h1[1], expected, c.name)
            var h2 = h2_post(child.port, c.bytes)
            print("observed h2c", c.name + ":", h2[0], h2[1])
            assert_equal(h2[0], "200", c.name)
            assert_equal(h2[1], expected, c.name)
    finally:
        _ = kill(child.pid, SIGKILL)
        waitpid(child.pid)


def test_from_utf8_raises_exactly_where_text_replaces() raises:
    for c in cases():
        var request = FlareRequest("POST", "/p", body=c.bytes.copy())
        var lossy = hex(request.text().as_bytes())
        assert_equal(lossy, c.text, c.name)
        # `text()` changes exactly the bodies that are not UTF-8.
        assert_equal(lossy == hex(Span(c.bytes)), c.utf8, c.name)
        var raised = False
        try:
            var s = String(from_utf8=Span(c.bytes))
            assert_equal(hex(s.as_bytes()), hex(Span(c.bytes)), c.name)
            assert_equal(s.byte_length(), len(c.bytes), c.name)
        except:
            raised = True
        assert_equal(raised, not c.utf8, c.name)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
