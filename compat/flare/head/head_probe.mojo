"""Flare v0.11.0 `HEAD` probe (M3-026 evidence; re-pinned by M3-027). Not
Muntin.

Runs only in the `flare` pixi environment (scripts/check_flare.sh). It
measures what the pinned Flare backend and the adapter send for a
`HEAD` request, so the decision can say which part of the system keeps a
`HEAD` response's content off the wire. It is self-checking: every
observation is compared with the bytes recorded here, and the probe exits
non-zero if Flare changes.

Two servers, each in a forked child (lifecycle and raw client as in
compat/flare/headers/flare_header_probe.mojo; the client is Flare's raw
`TcpStream`, so the response bytes come back unparsed):

- `MuntinHandler` over the same `App` (`get /hello`, `/cl`, `/nm`, `/rc`):
  since M3-027, `App.handle` answers `HEAD` as the `GET` and the adapter
  sends no content (M3-026's rule);
- `HeadAsGet`, a probe handler that answers a `HEAD` request with the
  response `App.handle` gives the same request as `GET`, converted by the
  adapter's own `to_muntin_request`/`to_flare_response`. It reports the
  method Flare delivered in `X-Flare-Method`. A target under `/empty/` is
  answered with the body removed instead, the other place content could
  be dropped. A target under `/declared/` is answered with the body
  removed and a `Content-Length` field of its length added after the
  adapter's conversion, the one place a length could travel beside an
  empty body. `/nm` is a raw route answering 304 with a 3-byte body: a
  Muntin 304 body is not defined as the 200 representation, so the probe
  measures what goes out when its body is removed and no length declared.
  `/rc` does the same with 205, which never carries content.

Byte notation as in the header probe: CR, LF are `\\r`, `\\n`; the varying
`Date` value is `<date>`. The h2c cases send one HEADERS frame on stream 1
after the preface (cleartext HTTP/2 with prior knowledge, which the default
`ServerConfig()` server accepts on the same port) and render the frames the
server sends back on it.

Observation 1 and the h2c cases through `MuntinHandler` recorded the answers
before M3-027 (`HEAD` was 404, with `Not Found` in DATA over h2c); M3-027
re-pinned them to its answers and added `HEAD /nm` and `HEAD /rc` through
`MuntinHandler`, which match the 304 and 205 observations through
`HeadAsGet` without the probe's `X-Flare-Method`.

Build and run (from the repository root):

    mkdir -p build
    pixi run --frozen -e flare mojo build --Werror -I src -I adapters/flare \\
        compat/flare/head/head_probe.mojo -o build/head_probe
    ./build/head_probe
"""

from std.ffi import c_uint, external_call

from flare.http import (
    Handler,
    HttpServer,
    Request as FlareRequest,
    Response as FlareResponse,
)
from flare.http.proto import ascii_unchecked_string
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
from muntin import App, Request, Response
from muntin_flare import MuntinHandler, to_flare_response, to_muntin_request

comptime TIMEOUT_MS = 5_000
comptime CHILD_LIFETIME_S = 30


def hello() -> String:
    return "hello"


def length_field(var req: Request) -> Response:
    var r = Response.text("abc")
    try:
        r.headers.add("Content-Length", "99")
    except:
        pass
    return r^


def not_modified(var req: Request) -> Response:
    return Response(304, "abc")


def reset_content(var req: Request) -> Response:
    return Response(205, "abc")


def probe_app() -> App:
    var app = App()
    app.get["/hello"](hello)
    app.get["/cl"](length_field)
    app.get["/nm"](not_modified)
    app.get["/rc"](reset_content)
    return app^


struct HeadAsGet(Handler):
    """Answers `HEAD` with `App.handle`'s answer to the same `GET`."""

    var app: App

    def __init__(out self, var app: App):
        self.app = app^

    def serve(self, request: FlareRequest) -> FlareResponse:
        var empty = request.url.startswith("/empty/")
        var declared = request.url.startswith("/declared/")
        var target = request.url
        if empty:
            target = String(request.url[byte=6:])
        elif declared:
            target = String(request.url[byte=9:])
        var method = request.method
        if method == "HEAD":
            method = "GET"
        var answer: Response
        try:
            var r = to_muntin_request(request)
            answer = self.app.handle(Request(method, target, r.body))
        except:
            answer = Response.text("Bad Request", status=400)
        var length = answer.body.byte_length()
        if empty or declared:
            answer.body = ""
        var out = to_flare_response(answer)
        try:
            if declared:
                out.headers.append("Content-Length", String(length))
            out.headers.append("X-Flare-Method", request.method)
        except:
            pass
        return out^


# ── byte notation ──────────────────────────────────────────────────────────


def esc(bytes: Span[UInt8, _]) -> String:
    var out = List[UInt8]()
    for i in range(len(bytes)):
        var c = bytes[i]
        if c == 13:
            out.append(92)
            out.append(114)
        elif c == 10:
            out.append(92)
            out.append(110)
        else:
            out.append(c)
    return ascii_unchecked_string(Span[UInt8, _](out))


def normalize_date(s: String) raises -> String:
    """Replaces the value of every (escaped) `Date` field with `<date>`."""
    var out = s
    var at = 0
    while True:
        var start = out.find("\\r\\nDate: ", at)
        if start < 0:
            return out
        var value = start + 10
        var end = out.find("\\r\\n", value)
        # IMF-fixdate, e.g. "Sat, 03 Oct 2026 10:00:00 GMT" (29 bytes).
        if end - value != 29:
            raise Error("unexpected Date value")
        out = String(out[byte=:value]) + "<date>" + String(out[byte=end:])
        at = value


# ── server lifecycle and raw client ────────────────────────────────────────


@fieldwise_init
struct _Child(Copyable):
    var pid: Int
    var port: UInt16


def _serve_muntin() raises -> _Child:
    var server = HttpServer.bind(SocketAddr.localhost(0))
    var port = server.local_addr().port
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        try:
            server.serve(MuntinHandler(probe_app()))
        except e:
            print("server child: serve failed:", e)
        exit(1)
    return _Child(pid, port)


def _serve_head_as_get() raises -> _Child:
    var server = HttpServer.bind(SocketAddr.localhost(0))
    var port = server.local_addr().port
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        try:
            server.serve(HeadAsGet(probe_app()))
        except e:
            print("server child: serve failed:", e)
        exit(1)
    return _Child(pid, port)


def exchange(port: UInt16, request: String) raises -> String:
    """Sends `request` and returns every byte until the server closes."""
    var stream = TcpStream.connect(SocketAddr.localhost(port))
    stream.set_recv_timeout(TIMEOUT_MS)
    stream.write_all(request.as_bytes())
    var out = List[UInt8]()
    var buf = List[UInt8]()
    buf.resize(4096, 0)
    while True:
        var n = stream.read(buf.unsafe_ptr(), len(buf))
        if n == 0:
            break
        for i in range(n):
            out.append(buf[i])
    return normalize_date(esc(Span[UInt8, _](out)))


def req(method: String, path: String, connection: String = "close") -> String:
    return String(
        method,
        " ",
        path,
        " HTTP/1.1\r\nHost: probe\r\nConnection: ",
        connection,
        "\r\n\r\n",
    )


# ── h2c (prior knowledge) ──────────────────────────────────────────────────


def _frame_bytes(
    typ: FrameType, flags: UInt8, sid: Int, var payload: List[UInt8]
) -> List[UInt8]:
    var f = Frame()
    f.header.type = typ.copy()
    f.header.flags = FrameFlags(flags)
    f.header.stream_id = sid
    f.payload = payload^
    return encode_frame(f)


def _render_fields(fields: List[HpackHeader]) -> String:
    var out = String()
    for i in range(len(fields)):
        if i > 0:
            out += "; "
        var v = fields[i].value
        if (
            fields[i].name == "date"
            and v.endswith(" GMT")
            and v.byte_length() == 29
        ):
            v = "<date>"
        out += fields[i].name + ": " + v
    return out


def h2_exchange(port: UInt16, method: String, path: String) raises -> String:
    """One request on stream 1 over h2c; the stream-1 frames the server sent
    back, rendered, until END_STREAM, RST_STREAM or GOAWAY. `/END` marks a
    frame that carries END_STREAM."""
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(":method", method))
    hdrs.append(HpackHeader(":scheme", "http"))
    hdrs.append(HpackHeader(":path", path))
    hdrs.append(HpackHeader(":authority", "probe"))
    var block = HpackEncoder().encode(Span[HpackHeader, _](hdrs))

    var wire = List(H2_PREFACE.as_bytes())
    wire.extend(Span(_frame_bytes(FrameType.SETTINGS(), 0, 0, List[UInt8]())))
    wire.extend(
        Span(
            _frame_bytes(
                FrameType.HEADERS(),
                FrameFlags.END_HEADERS() | FrameFlags.END_STREAM(),
                1,
                block^,
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
    var out = String()
    while True:
        var maybe = parse_frame(Span[UInt8, _](acc)[pos:])
        if not maybe:
            var n = stream.read(buf.unsafe_ptr(), len(buf))
            if n == 0:
                out += " EOF"
                break
            for k in range(n):
                acc.append(buf[k])
            continue
        var f = maybe.value().copy()
        pos += 9 + f.header.length
        var t = f.header.type.value
        if (
            t == FrameType.SETTINGS().value
            or t == FrameType.WINDOW_UPDATE().value
            or t == FrameType.PING().value
        ):
            continue
        if out.byte_length() > 0:
            out += " "
        if t == FrameType.GOAWAY().value:
            out += "GOAWAY"
            break
        if f.header.stream_id != 1:
            out += String(f.header.type.name(), "@", f.header.stream_id)
            continue
        if t == FrameType.HEADERS().value:
            var decoded = decoder.decode(Span[UInt8, _](f.payload))
            out += "HEADERS{" + _render_fields(decoded) + "}"
        elif t == FrameType.DATA().value:
            out += "DATA{" + esc(Span[UInt8, _](f.payload)) + "}"
        elif t == FrameType.RST_STREAM().value:
            out += "RST_STREAM"
            break
        else:
            out += f.header.type.name()
        if f.header.flags.has(FrameFlags.END_STREAM()):
            out += "/END"
            break
    return out


# ── checks ─────────────────────────────────────────────────────────────────


struct Checks:
    var failures: Int

    def __init__(out self):
        self.failures = 0

    def eq(mut self, name: String, got: String, want: String):
        if got == want:
            print("ok  ", name, "\n     ", got)
        else:
            self.failures += 1
            print("FAIL", name, "\n  got: ", got, "\n  want:", want)


def run_h1(mut c: Checks, muntin: UInt16, head_as_get: UInt16) raises:
    c.eq(
        (
            "1. HEAD on a get route through MuntinHandler: the GET's 200 and"
            " Content-Length 5, no content"
        ),
        exchange(muntin, req("HEAD", "/hello")),
        (
            "HTTP/1.1 200 OK\\r\\nContent-Length: 5\\r\\nDate:"
            " <date>\\r\\nConnection: close\\r\\n\\r\\n"
        ),
    )
    c.eq(
        (
            "1b. HEAD on a raw 304 with a body through MuntinHandler: Flare"
            " frames Content-Length 0 itself, no content"
        ),
        exchange(muntin, req("HEAD", "/nm")),
        (
            "HTTP/1.1 304 Not Modified\\r\\nContent-Length: 0\\r\\nDate:"
            " <date>\\r\\nConnection: close\\r\\n\\r\\n"
        ),
    )
    c.eq(
        (
            "1c. HEAD on a raw 205 with a body through MuntinHandler:"
            " Content-Length 0, no content"
        ),
        exchange(muntin, req("HEAD", "/rc")),
        (
            "HTTP/1.1 205 Unknown\\r\\nContent-Length: 0\\r\\nDate:"
            " <date>\\r\\nConnection: close\\r\\n\\r\\n"
        ),
    )
    c.eq(
        "2. GET for comparison",
        exchange(head_as_get, req("GET", "/hello")),
        (
            "HTTP/1.1 200 OK\\r\\nX-Flare-Method: GET\\r\\nContent-Length:"
            " 5\\r\\nDate: <date>\\r\\nConnection: close\\r\\n\\r\\nhello"
        ),
    )
    c.eq(
        (
            "3. HEAD answered with the GET response: Flare delivers HEAD, sends"
            " GET's Content-Length and no content"
        ),
        exchange(head_as_get, req("HEAD", "/hello")),
        (
            "HTTP/1.1 200 OK\\r\\nX-Flare-Method: HEAD\\r\\nContent-Length:"
            " 5\\r\\nDate: <date>\\r\\nConnection: close\\r\\n\\r\\n"
        ),
    )
    c.eq(
        (
            "4. HEAD answered with the body removed before the adapter:"
            " Content-Length 0, not GET's 5"
        ),
        exchange(head_as_get, req("HEAD", "/empty/hello")),
        (
            "HTTP/1.1 200 OK\\r\\nX-Flare-Method: HEAD\\r\\nContent-Length:"
            " 0\\r\\nDate: <date>\\r\\nConnection: close\\r\\n\\r\\n"
        ),
    )
    c.eq(
        (
            "5. a handler's Content-Length is dropped by the adapter: the"
            " body's length goes out"
        ),
        exchange(head_as_get, req("HEAD", "/cl")),
        (
            "HTTP/1.1 200 OK\\r\\nX-Flare-Method: HEAD\\r\\nContent-Length:"
            " 3\\r\\nDate: <date>\\r\\nConnection: close\\r\\n\\r\\n"
        ),
    )
    c.eq(
        (
            "5b. HEAD answered with the body removed and its length declared:"
            " the declared length, no content"
        ),
        exchange(head_as_get, req("HEAD", "/declared/hello")),
        (
            "HTTP/1.1 200 OK\\r\\nX-Flare-Method: HEAD\\r\\nContent-Length:"
            " 5\\r\\nDate: <date>\\r\\nConnection: close\\r\\n\\r\\n"
        ),
    )
    c.eq(
        (
            "5c. a 304 with a body, removed, no length declared: Flare frames"
            " Content-Length 0 itself over HTTP/1.1"
        ),
        exchange(head_as_get, req("HEAD", "/empty/nm")),
        (
            "HTTP/1.1 304 Not Modified\\r\\nX-Flare-Method: HEAD\\r\\n"
            "Content-Length: 0\\r\\nDate: <date>\\r\\nConnection:"
            " close\\r\\n\\r\\n"
        ),
    )
    c.eq(
        (
            "5d. a 205 with a body, removed, no length declared: Content-Length"
            " 0 (the GET's content length), no content"
        ),
        exchange(head_as_get, req("HEAD", "/empty/rc")),
        (
            "HTTP/1.1 205 Unknown\\r\\nX-Flare-Method: HEAD\\r\\n"
            "Content-Length: 0\\r\\nDate: <date>\\r\\nConnection:"
            " close\\r\\n\\r\\n"
        ),
    )
    c.eq(
        "6. keep-alive: HEAD then GET on one connection, two whole responses",
        exchange(
            head_as_get,
            req("HEAD", "/hello", "keep-alive") + req("GET", "/hello"),
        ),
        (
            "HTTP/1.1 200 OK\\r\\nX-Flare-Method: HEAD\\r\\nContent-Length:"
            " 5\\r\\nDate: <date>\\r\\nConnection: keep-alive\\r\\n\\r\\n"
            "HTTP/1.1 200 OK\\r\\nX-Flare-Method: GET\\r\\nContent-Length:"
            " 5\\r\\nDate: <date>\\r\\nConnection: close\\r\\n\\r\\nhello"
        ),
    )


def run_h2c(mut c: Checks, muntin: UInt16, head_as_get: UInt16) raises:
    c.eq(
        "h2. GET for comparison",
        h2_exchange(head_as_get, "GET", "/hello"),
        "HEADERS{:status: 200; x-flare-method: GET} DATA{hello}/END",
    )
    c.eq(
        (
            "h2. HEAD answered with the GET response: Flare sends the content"
            " in DATA"
        ),
        h2_exchange(head_as_get, "HEAD", "/hello"),
        "HEADERS{:status: 200; x-flare-method: HEAD} DATA{hello}/END",
    )
    c.eq(
        "h2. HEAD answered with the body removed: no DATA, no content-length",
        h2_exchange(head_as_get, "HEAD", "/empty/hello"),
        "HEADERS{:status: 200; x-flare-method: HEAD}/END",
    )
    c.eq(
        (
            "h2. HEAD answered with the body removed and its length declared:"
            " the declared content-length, no DATA"
        ),
        h2_exchange(head_as_get, "HEAD", "/declared/hello"),
        "HEADERS{:status: 200; content-length: 5; x-flare-method: HEAD}/END",
    )
    c.eq(
        (
            "h2. a 304 with a body, removed, no length declared: no"
            " content-length, no DATA"
        ),
        h2_exchange(head_as_get, "HEAD", "/empty/nm"),
        "HEADERS{:status: 304; x-flare-method: HEAD}/END",
    )
    c.eq(
        (
            "h2. a 205 with a body, removed, no length declared: no"
            " content-length, no DATA"
        ),
        h2_exchange(head_as_get, "HEAD", "/empty/rc"),
        "HEADERS{:status: 205; x-flare-method: HEAD}/END",
    )
    c.eq(
        (
            "h2. HEAD on a get route through MuntinHandler: the GET's"
            " content-length, no DATA"
        ),
        h2_exchange(muntin, "HEAD", "/hello"),
        "HEADERS{:status: 200; content-length: 5}/END",
    )
    c.eq(
        (
            "h2. HEAD on a raw 304 with a body through MuntinHandler: no"
            " content-length, no DATA"
        ),
        h2_exchange(muntin, "HEAD", "/nm"),
        "HEADERS{:status: 304}/END",
    )
    c.eq(
        (
            "h2. HEAD on a raw 205 with a body through MuntinHandler: no"
            " content-length, no DATA"
        ),
        h2_exchange(muntin, "HEAD", "/rc"),
        "HEADERS{:status: 205}/END",
    )


def main() raises:
    var c = Checks()
    var muntin = _serve_muntin()
    try:
        var head_as_get = _serve_head_as_get()
        try:
            run_h1(c, muntin.port, head_as_get.port)
            run_h2c(c, muntin.port, head_as_get.port)
        finally:
            _ = kill(head_as_get.pid, SIGKILL)
            waitpid(head_as_get.pid)
    finally:
        _ = kill(muntin.pid, SIGKILL)
        waitpid(muntin.pid)

    if c.failures > 0:
        raise Error(String(c.failures, " HEAD observation(s) changed"))
    print("all HEAD observations hold")
