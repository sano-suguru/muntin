"""Flare streaming and cancellation probe (evidence for the streaming and
cancellation decision, M3-053). Not Muntin.

Runs only in the `flare` pixi environment (scripts/check_flare.sh). It
measures what the pinned Flare backend does with a streamed response on the
serving path Muntin's `Server` uses (`HttpServer.serve` with a `Handler`),
so the decision can say what a Muntin stream may promise: framing, what a
source sees when the client goes away, whether other connections are served
while a stream is open, and how the idle timer treats a quiet stream. It is
self-checking and fails if Flare changes.

`Streams` is a Flare `Handler` of the probe's own (no Muntin, no adapter),
served in a forked child (lifecycle as in compat/flare/body/body_probe.mojo).
Each streamed target returns `stream_response` over a `Logged` source, which
counts its `next` calls, records whether it ever saw `cancel.cancelled()`
and, when it is destroyed, writes `calls=<n> ended=<0|1> cancelled=<0|1>` to
a file named after the target in the parent's directory, so the parent sees
whether and how the source was dropped. `/hello` is a plain buffered 200.

Sources (`kind`):
- `endless`: a 16 KiB chunk on every call, never `None`;
- `idle`: `first` on the first call, then an empty chunk ("nothing now")
  until `IDLE_MS` have passed, then `late`, then `None`;
- `fail`: two chunks, then raises.
"""

from std.ffi import c_uint, external_call
from std.os import listdir, makedirs, remove
from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.time import perf_counter_ns

from flare.http import (
    Cancel,
    ChunkSource,
    Handler,
    HttpServer,
    Request as FlareRequest,
    Response as FlareResponse,
    stream_response,
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
comptime IDLE_MS = 1_500
"""Longer than Flare v0.12.0's default idle timeout (500 ms)."""
comptime LOG_DIR = "build/stream_probe_logs"


def _usleep(us: Int):
    _ = external_call["usleep", c_uint](c_uint(us))


def _now_ms() -> Int:
    return Int(perf_counter_ns() // 1_000_000)


struct Logged(ChunkSource):
    var kind: String
    var path: String
    var calls: Int
    var ended: Bool
    var cancelled: Bool
    var start_ms: Int

    def __init__(out self, kind: String, path: String):
        self.kind = kind
        self.path = path
        self.calls = 0
        self.ended = False
        self.cancelled = False
        self.start_ms = _now_ms()

    def __deinit__(deinit self):
        try:
            with open(self.path, "w") as f:
                f.write(
                    "calls=",
                    self.calls,
                    " ended=",
                    Int(self.ended),
                    " cancelled=",
                    Int(self.cancelled),
                )
        except:
            pass

    def next(mut self, cancel: Cancel) raises -> Optional[List[UInt8]]:
        self.calls += 1
        if cancel.cancelled():
            self.cancelled = True
        if self.kind == "endless":
            var chunk = List[UInt8]()
            chunk.resize(16 * 1024, UInt8(ord("x")))
            return chunk^
        if self.kind == "fail":
            if self.calls > 2:
                raise Error("source failed")
            return List(String("c", self.calls, "\n").as_bytes())
        # idle
        if self.calls == 1:
            return List(String("first\n").as_bytes())
        if self.ended:
            return None
        if _now_ms() - self.start_ms < IDLE_MS:
            return List[UInt8]()
        self.ended = True
        return List(String("late\n").as_bytes())


struct Streams(Handler):
    def __init__(out self):
        pass

    def serve(self, request: FlareRequest) raises -> FlareResponse:
        var path = request.url
        if path == "/hello":
            return FlareResponse(status=200, body=List("hello".as_bytes()))
        var kind = String(path[byte=1:].split("-")[0])
        return stream_response(
            Logged(kind, String(LOG_DIR, "/", path[byte=1:]))
        )


@fieldwise_init
struct _Child(Copyable):
    var pid: Int
    var port: UInt16


def _serve() raises -> _Child:
    makedirs(LOG_DIR, exist_ok=True)
    for name in listdir(LOG_DIR):
        remove(String(LOG_DIR, "/", name))
    var server = HttpServer.bind(SocketAddr.localhost(0))
    var port = server.local_addr().port
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        try:
            server.serve(Streams())
        except e:
            print("server child: serve failed:", e)
        exit(1)
    return _Child(pid, port)


def _stop(child: _Child):
    _ = kill(child.pid, SIGKILL)
    _ = waitpid(child.pid)


def _log(name: String) raises -> String:
    """The source's record, waiting up to `TIMEOUT_MS` for it; `""` if the
    source was not destroyed by then."""
    var path = String(LOG_DIR, "/", name)
    var waited = 0
    while waited < TIMEOUT_MS:
        if exists(path):
            _usleep(50_000)
            with open(path, "r") as f:
                return f.read()
        _usleep(50_000)
        waited += 50
    return ""


def _connect(port: UInt16) raises -> TcpStream:
    var stream = TcpStream.connect(SocketAddr.localhost(port))
    stream.set_recv_timeout(TIMEOUT_MS)
    return stream^


def _get(mut stream: TcpStream, target: String) raises:
    var req = String("GET ", target, " HTTP/1.1\r\nHost: probe\r\n\r\n")
    stream.write_all(Span[UInt8, _](List(req.as_bytes())))


def _read_some(mut stream: TcpStream, at_least: Int) raises -> List[UInt8]:
    var acc = List[UInt8]()
    var buf = List[UInt8]()
    buf.resize(65536, 0)
    while len(acc) < at_least:
        var n = stream.read(buf.unsafe_ptr(), len(buf))
        if n == 0:
            break
        for k in range(n):
            acc.append(buf[k])
    return acc^


def _read_to_close(mut stream: TcpStream) raises -> String:
    var acc = List[UInt8]()
    var buf = List[UInt8]()
    buf.resize(4096, 0)
    while True:
        var n: Int
        try:
            n = stream.read(buf.unsafe_ptr(), len(buf))
        except:
            break
        if n == 0:
            break
        for k in range(n):
            acc.append(buf[k])
    return String(from_utf8_lossy=Span(acc))


def _hello(port: UInt16) raises -> String:
    var c = _connect(port)
    var req = String(
        "GET /hello HTTP/1.1\r\nHost: probe\r\nConnection: close\r\n\r\n"
    )
    c.write_all(Span[UInt8, _](List(req.as_bytes())))
    var text = _read_to_close(c)
    return String(text[byte = : text.find("\r\n")])


def test_h1_stream_is_chunked_and_ends() raises:
    """An `idle` source over HTTP/1.1: chunked framing, no `Content-Length`,
    every chunk and the terminator arrive, and the idle timer (500 ms) does
    not cut a stream that is quiet for 1.5 s. Flare re-polls a source that
    has nothing on every writable edge, so a quiet source is a busy loop."""
    var child = _serve()
    var c = _connect(child.port)
    _get(c, "/idle-h1")
    var text = _read_to_close_or_terminator(c)
    var log = _log("idle-h1")
    _stop(child)
    assert_true(text.find("Transfer-Encoding: chunked") >= 0, text)
    assert_true(text.find("Content-Length") < 0, text)
    assert_true(text.find("first\n") >= 0, text)
    assert_true(text.find("late\n") >= 0, text)
    assert_true(text.find("\r\n0\r\n\r\n") >= 0, text)
    # The source is polled on every writable edge while it has nothing: a
    # busy loop, far more calls than chunks (780,490 in 1.5 s once, Linux).
    assert_true(log.endswith(" ended=1 cancelled=0"), log)
    var calls = Int(log[byte = 6 : log.find(" ")])
    assert_true(calls > 1_000, log)


def _read_to_close_or_terminator(mut stream: TcpStream) raises -> String:
    var acc = List[UInt8]()
    var buf = List[UInt8]()
    buf.resize(4096, 0)
    while True:
        var n = stream.read(buf.unsafe_ptr(), len(buf))
        if n == 0:
            break
        for k in range(n):
            acc.append(buf[k])
        var text = String(from_utf8_lossy=Span(acc))
        if text.find("\r\n0\r\n\r\n") >= 0:
            return text
    return String(from_utf8_lossy=Span(acc))


def test_h1_other_connections_served_while_stream_open() raises:
    """While an `idle` stream is open and quiet, a request on another
    connection is answered before the stream ends: a stream holds the
    reactor only for each `next` call, unlike a running handler (M3-046)."""
    var child = _serve()
    var c = _connect(child.port)
    _get(c, "/idle-hol")
    _ = _read_some(c, 1)
    var t0 = _now_ms()
    var status = _hello(child.port)
    var waited = _now_ms() - t0
    _stop(child)
    assert_equal(status, "HTTP/1.1 200 OK")
    assert_true(waited < IDLE_MS // 2, String("waited ms: ", waited))


def test_h1_client_gone_drops_source_without_cancel() raises:
    """The client closes an `endless` stream after 64 KiB: Flare destroys
    the source, never having signalled `cancelled()` to it, and the server
    keeps serving."""
    var child = _serve()
    var c = _connect(child.port)
    _get(c, "/endless-h1")
    _ = _read_some(c, 64 * 1024)
    c.close()
    var log = _log("endless-h1")
    var status = _hello(child.port)
    _stop(child)
    assert_true(log.startswith("calls="), String("source not dropped: ", log))
    assert_true(log.endswith(" ended=0 cancelled=0"), log)
    assert_equal(status, "HTTP/1.1 200 OK")


def test_h1_source_raise_truncates() raises:
    """A `fail` source raising on its third call: the status line and
    fields have gone out, then the connection closes with no chunked
    terminator, so the client can tell the body is incomplete. The two
    chunks the source produced before raising never arrive (the reactor
    pulls up to 16 per writable edge before writing, and the raise drops
    the batch). The source is destroyed."""
    var child = _serve()
    var c = _connect(child.port)
    _get(c, "/fail-h1")
    var text = _read_to_close(c)
    var log = _log("fail-h1")
    _stop(child)
    assert_true(text.startswith("HTTP/1.1 200 OK\r\n"), text)
    assert_true(text.find("Transfer-Encoding: chunked") >= 0, text)
    assert_true(text.find("c1") < 0 and text.find("c2") < 0, text)
    assert_true(text.find("\r\n0\r\n\r\n") < 0, text)
    assert_true(log.startswith("calls=3 "), log)


def _frame(
    typ: FrameType, flags: UInt8, sid: Int, var payload: List[UInt8]
) -> List[UInt8]:
    var f = Frame()
    f.header.type = typ.copy()
    f.header.flags = FrameFlags(flags)
    f.header.stream_id = sid
    f.payload = payload^
    return encode_frame(f)


def _h2_get(target: String, sid: Int) raises -> List[UInt8]:
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(":method", "GET"))
    hdrs.append(HpackHeader(":scheme", "http"))
    hdrs.append(HpackHeader(":path", target))
    hdrs.append(HpackHeader(":authority", "probe"))
    var block = HpackEncoder().encode(Span[HpackHeader, _](hdrs))
    return _frame(
        FrameType.HEADERS(),
        FrameFlags.END_HEADERS() | FrameFlags.END_STREAM(),
        sid,
        block^,
    )


def _h2_open(port: UInt16, target: String) raises -> TcpStream:
    var wire = List(H2_PREFACE.as_bytes())
    wire.extend(Span(_frame(FrameType.SETTINGS(), 0, 0, List[UInt8]())))
    wire.extend(Span(_h2_get(target, 1)))
    var c = _connect(port)
    c.write_all(Span[UInt8, _](wire))
    return c^


struct _H2Reader(Movable):
    var acc: List[UInt8]
    var pos: Int

    def __init__(out self):
        self.acc = List[UInt8]()
        self.pos = 0

    def next_frame(mut self, mut c: TcpStream) raises -> Frame:
        var buf = List[UInt8]()
        buf.resize(65536, 0)
        while True:
            var maybe = parse_frame(Span[UInt8, _](self.acc)[self.pos :])
            if maybe:
                var f = maybe.value().copy()
                self.pos += 9 + f.header.length
                return f^
            var n = c.read(buf.unsafe_ptr(), len(buf))
            if n == 0:
                raise Error("connection closed")
            for k in range(n):
                self.acc.append(buf[k])


def test_h2c_stream_reset_drops_source_without_cancel() raises:
    """Over h2c, an `endless` stream on stream 1 is reset by the client
    (`RST_STREAM`, CANCEL) after its first DATA frame: Flare destroys the
    source without signalling `cancelled()`, and stream 3 of the same
    connection is answered."""
    var child = _serve()
    var c = _h2_open(child.port, "/endless-h2rst")
    var reader = _H2Reader()
    while True:
        var f = reader.next_frame(c)
        if (
            f.header.stream_id == 1
            and f.header.type.value == FrameType.DATA().value
        ):
            break
    var wire = _frame(
        FrameType.RST_STREAM(), 0, 1, [UInt8(0), UInt8(0), UInt8(0), UInt8(8)]
    )
    wire.extend(Span(_h2_get("/hello", 3)))
    c.write_all(Span[UInt8, _](wire))
    var decoder = HpackDecoder()
    var status: String
    while True:
        var f = reader.next_frame(c)
        if (
            f.header.stream_id == 3
            and f.header.type.value == FrameType.HEADERS().value
        ):
            status = decoder.decode(Span[UInt8, _](f.payload))[0].value
            break
        if f.header.type.value == FrameType.HEADERS().value:
            _ = decoder.decode(Span[UInt8, _](f.payload))
    var log = _log("endless-h2rst")
    _stop(child)
    assert_equal(status, "200")
    assert_true(log.startswith("calls="), String("source not dropped: ", log))
    assert_true(log.endswith(" ended=0 cancelled=0"), log)


def test_h2c_client_gone_drops_source_without_cancel() raises:
    """Over h2c, the client closes the connection during an `endless`
    stream: the source is destroyed without `cancelled()`."""
    var child = _serve()
    var c = _h2_open(child.port, "/endless-h2close")
    var reader = _H2Reader()
    while True:
        var f = reader.next_frame(c)
        if (
            f.header.stream_id == 1
            and f.header.type.value == FrameType.DATA().value
        ):
            break
    c.close()
    var log = _log("endless-h2close")
    _stop(child)
    assert_true(log.startswith("calls="), String("source not dropped: ", log))
    assert_true(log.endswith(" ended=0 cancelled=0"), log)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
