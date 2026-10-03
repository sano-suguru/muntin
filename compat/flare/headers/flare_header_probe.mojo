"""Flare v0.11.0 HTTP header behaviour probe (M3-002 evidence). Not Muntin.

Runs only in the `flare` pixi environment. It measures what the pinned Flare
backend preserves and changes in request and response headers, so a future
adapter can map headers faithfully. It imports Flare alone (no Muntin, no
adapter) and is self-checking: every observation it relies on is compared
with the bytes recorded here, and the probe exits non-zero if Flare changes.

Lifecycle (copied from adapters/flare/test_localhost_roundtrip.mojo): each
server binds an ephemeral loopback port and serves in a forked child that
arms a 30 s `alarm(2)`; the parent SIGKILLs and reaps every child in
`finally`. The client is Flare's raw `TcpStream`, so arbitrary request bytes
reach the server and the raw response bytes come back unparsed.

Byte notation in requests and in the recorded output: printable ASCII is
verbatim; CR, LF, HTAB, backslash are `\\r`, `\\n`, `\\t`, `\\\\`; any other
byte is `\\xHH`. The varying `Date` value is replaced by `<date>`.

The echo path reads request headers only through `HeaderMap.encode_to`,
the one public whole-map accessor (besides `write_to`); `len`, `get`,
`get_all`, `contains` are lookups by name. Iterating by index needs the
underscore fields `_keys` / `_values`.

Build and run (from the repository root):

    mkdir -p build
    pixi run --frozen -e flare mojo build --Werror -I src -I adapters/flare \\
        compat/flare/headers/flare_header_probe.mojo \\
        -o build/flare_header_probe
    ./build/flare_header_probe
"""

from std.ffi import c_uint, external_call

from flare.http import (
    Handler,
    HeaderMap,
    HttpServer,
    Request,
    Response,
    ServerConfig,
)
from flare.http.proto import H1LeniencyConfig, ascii_unchecked_string
from flare.net import SocketAddr
from flare.tcp import TcpStream
from flare.utils import SIGKILL, exit, fork, kill, waitpid

comptime TIMEOUT_MS = 5_000
comptime CHILD_LIFETIME_S = 30
comptime HEX = "0123456789ABCDEF"


# ── byte notation ──────────────────────────────────────────────────────────


def esc(bytes: Span[UInt8, _]) -> String:
    """Escapes bytes into the notation described in the module docstring."""
    var out = List[UInt8]()
    var hex = HEX.as_bytes()
    for i in range(len(bytes)):
        var c = bytes[i]
        if c == 13:
            out.append(92)
            out.append(114)
        elif c == 10:
            out.append(92)
            out.append(110)
        elif c == 9:
            out.append(92)
            out.append(116)
        elif c == 92:
            out.append(92)
            out.append(92)
        elif c >= 32 and c <= 126:
            out.append(c)
        else:
            out.append(92)
            out.append(120)
            out.append(hex[Int(c >> 4)])
            out.append(hex[Int(c & 15)])
    return ascii_unchecked_string(Span[UInt8, _](out))


def _hex_val(c: UInt8) -> Int:
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 65 and c <= 70:
        return Int(c) - 55
    return Int(c) - 87


def unesc(s: String) -> List[UInt8]:
    """Decodes only `\\xHH`; every other byte of `s` is taken verbatim."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i < len(b):
        if b[i] == 92 and i + 3 < len(b) and b[i + 1] == 120:
            out.append(UInt8(_hex_val(b[i + 2]) * 16 + _hex_val(b[i + 3])))
            i += 4
        else:
            out.append(b[i])
            i += 1
    return out^


def bytes_string(s: String) -> String:
    """A `String` holding exactly the bytes `unesc(s)`, unvalidated."""
    var b = unesc(s)
    return ascii_unchecked_string(Span[UInt8, _](b))


def normalize_date(s: String) raises -> String:
    """Replaces the value of the (escaped) `Date` field with `<date>`."""
    var start = s.find("\\r\\nDate: ")
    if start < 0:
        return s
    var value = start + 10
    var end = s.find("\\r\\n", value)
    var date = String(s[byte=value:end])
    # IMF-fixdate, e.g. "Sat, 03 Oct 2026 10:00:00 GMT" (29 bytes).
    if date.byte_length() != 29 or not date.endswith(" GMT"):
        raise Error("unexpected Date value: " + date)
    return String(s[byte=:value]) + "<date>" + String(s[byte=end:])


# ── the probe handler ──────────────────────────────────────────────────────


def _bytes(s: String) -> List[UInt8]:
    return List(s.as_bytes())


struct ProbeHandler(Handler):
    """`/echo` reports what Flare handed the handler; other paths build a
    response with headers set in a specific way."""

    def __init__(out self):
        pass

    def serve(self, req: Request) raises -> Response:
        var url = req.url
        if url == "/echo":
            # Only public whole-map access: `encode_to` (and `write_to`)
            # dump every entry, in order, original casing, bytes verbatim.
            var out = _bytes(
                String(
                    "len=",
                    req.headers.len(),
                    " get(x-a)=",
                    req.headers.get("x-a"),
                    " get_all(x-a)=",
                    len(req.headers.get_all("x-a")),
                    "\n",
                )
            )
            req.headers.encode_to(out)
            return Response(status=200, body=out^)
        if url == "/plain":
            # Exactly what adapters/flare/muntin_flare.mojo builds today.
            return Response(status=200, body=List("hello".as_bytes()))
        var resp = Response(status=200, body=List("hi".as_bytes()))
        if url == "/case":
            resp.headers.set("X-MiXeD-cAsE", "v")
        elif url == "/order":
            resp.headers.set("B-Second", "1")
            resp.headers.set("A-First", "2")
            resp.headers.append("b-second", "3")
        elif url == "/cookies":
            resp.headers.append("Set-Cookie", "a=1")
            resp.headers.append("Set-Cookie", "b=2")
        elif url == "/set-after-append":
            resp.headers.append("X-D", "1")
            resp.headers.append("x-d", "2")
            resp.headers.set("X-d", "3")
        elif url == "/empty":
            resp.headers.set("X-Empty", "")
        elif url == "/utf8":
            resp.headers.set("X-U", "é")
        elif url == "/bytes":
            resp.headers.set("X-Bin", bytes_string("a\\xFFb\\x00c\\x01"))
        elif url == "/bad-name":
            resp.headers.set("X:Y Z", "v")
        elif url == "/content-length":
            resp.headers.set("Content-Length", "999")
        elif url == "/transfer-encoding":
            resp.headers.set("Transfer-Encoding", "chunked")
        elif url == "/connection":
            resp.headers.set("Connection", "keep-alive")
        elif url == "/content-type":
            resp.headers.set("content-TYPE", "application/x-probe; q=1")
        elif url == "/date-server":
            resp.headers.set("Date", "handler-date")
            resp.headers.set("Server", "probe")
        elif url == "/inject":
            var errors = String()
            try:
                resp.headers.set("X-Inj", "a\r\nInjected: 1")
            except e:
                errors += String(e) + ";"
            try:
                resp.headers.append("X-Inj\n", "v")
            except e:
                errors += String(e) + ";"
            try:
                resp.headers.set("X-Inj", "a\rb")
            except e:
                errors += String(e)
            resp.body = _bytes(errors)
        else:
            return Response(status=404)
        return resp^


# ── server lifecycle and raw client ────────────────────────────────────────


@fieldwise_init
struct _Child(Copyable):
    var pid: Int
    var port: UInt16


def _serve_in_child(var config: ServerConfig) raises -> _Child:
    var server = HttpServer.bind(SocketAddr.localhost(0), config^)
    var port = server.local_addr().port
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        try:
            server.serve(ProbeHandler())
        except e:
            print("server child: serve failed:", e)
        exit(1)
    return _Child(pid, port)


def exchange(port: UInt16, request: String) raises -> String:
    """Sends `unesc(request)` and returns the whole response, escaped and
    with `Date` normalized. Reads until the server closes."""
    var stream = TcpStream.connect(SocketAddr.localhost(port))
    stream.set_recv_timeout(TIMEOUT_MS)
    var raw = unesc(request)
    stream.write_all(Span[UInt8, _](raw))
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


def get(path: String, extra: String = "") -> String:
    return (
        "GET "
        + path
        + " HTTP/1.1\r\nHost: probe\r\n"
        + extra
        + "Connection: close\r\n\r\n"
    )


comptime BAD = (
    "HTTP/1.1 400 Bad Request\\r\\nContent-Type: text/plain\\r\\n"
    "Content-Length: 15\\r\\nDate: <date>\\r\\nConnection: close\\r\\n\\r\\n"
    "400 Bad Request"
)


def echo_ok(body: String) -> String:
    """The full response `/echo` gives for an accepted request."""
    return (
        "HTTP/1.1 200 OK\\r\\nContent-Length: "
        + String(len(unesc(body)))
        + "\\r\\nDate: <date>\\r\\nConnection: close\\r\\n\\r\\n"
        + esc(Span[UInt8, _](unesc(body)))
    )


def ok_with(fields: String, body: String = "hi") -> String:
    """A 200 from a non-echo path: handler `fields` (escaped), then Flare's
    own; `body` is raw, with only `\\xHH` decoded, like a request."""
    var raw = unesc(body)
    return (
        "HTTP/1.1 200 OK\\r\\n"
        + fields
        + "Content-Length: "
        + String(len(raw))
        + "\\r\\nDate: <date>\\r\\nConnection: close\\r\\n\\r\\n"
        + esc(Span[UInt8, _](raw))
    )


def check_defaults(mut c: Checks):
    var d = ServerConfig()
    var l = d.h1_leniency.copy()
    c.eq(
        "1. ServerConfig() defaults used by HttpServer.bind",
        String(
            "skip_header_decode=",
            d.skip_header_decode_for_short_requests,
            " max_header_size=",
            d.max_header_size,
            " expose_error_messages=",
            d.expose_error_messages,
            " keep_alive=",
            d.keep_alive,
            " | lf_only=",
            l.allow_lf_only_line_endings,
            " mixed_case_method=",
            l.allow_mixed_case_method,
            " ows_around_colon=",
            l.allow_ows_around_colon,
            " obs_fold=",
            l.allow_obs_fold,
            " oversized_header_list=",
            l.allow_oversized_header_list,
            " multiple_content_length=",
            l.allow_multiple_content_length,
            " te_chunked_when_cl=",
            l.allow_te_chunked_when_cl_present,
            " obs_text_in_field_value=",
            l.accept_obs_text_in_field_value,
            " leading_ws=",
            l.allow_leading_whitespace_before_request_line,
        ),
        (
            "skip_header_decode=False max_header_size=8192"
            " expose_error_messages=False keep_alive=True | lf_only=False"
            " mixed_case_method=False ows_around_colon=False obs_fold=False"
            " oversized_header_list=False multiple_content_length=False"
            " te_chunked_when_cl=False obs_text_in_field_value=False"
            " leading_ws=False"
        ),
    )


def check_header_map(mut c: Checks) raises:
    """`HeaderMap` semantics in process (no server)."""
    var h = HeaderMap()
    h.append("X-D", "1")
    h.append("x-d", "2")
    h.set("X-d", "3")
    var wire = List[UInt8]()
    h.encode_to(wire)
    c.eq(
        "3. set after two appends: first match rewritten (name too), rest kept",
        esc(Span[UInt8, _](wire)) + " get=" + h.get("x-D"),
        "X-d: 3\\r\\nx-d: 2\\r\\n get=3",
    )
    _ = h.remove("X-D")
    c.eq("3. remove drops every case variant", String(h.len()), "0")


def main() raises:
    var c = Checks()
    check_defaults(c)
    check_header_map(c)

    var strict = _serve_in_child(ServerConfig())
    try:
        var lenient = _serve_in_child(
            ServerConfig(
                h1_leniency=H1LeniencyConfig(
                    accept_obs_text_in_field_value=True
                )
            )
        )
        try:
            run_inbound(c, strict.port, lenient.port)
            run_outbound(c, strict.port)
        finally:
            _ = kill(lenient.pid, SIGKILL)
            waitpid(lenient.pid)
    finally:
        _ = kill(strict.pid, SIGKILL)
        waitpid(strict.pid)

    if c.failures > 0:
        raise Error(String(c.failures, " header observation(s) changed"))
    print("all header observations hold")


def run_inbound(mut c: Checks, port: UInt16, lenient: UInt16) raises:
    # Casing, order and repeats across names (Host and Connection included).
    c.eq(
        "2. casing, order, repeats (X-A / x-a / X-A) all kept",
        exchange(
            port,
            (
                "GET /echo HTTP/1.1\r\nhOsT: probe\r\nX-A: 1\r\nContent-Type:"
                " t\r\nx-a: 2\r\nX-A: 3\r\nConnection: close\r\n\r\n"
            ),
        ),
        echo_ok(
            "len=6 get(x-a)=1 get_all(x-a)=3\nhOsT: probe\r\nX-A: 1\r\n"
            "Content-Type: t\r\nx-a: 2\r\nX-A: 3\r\nConnection: close\r\n"
        ),
    )
    c.eq(
        "2. empty values and SP/HTAB trimmed at both ends, inner kept",
        exchange(
            port,
            get("/echo", "X-E:\r\nX-E2:   \r\nX-W: \t a \t b \t \r\n"),
        ),
        echo_ok(
            "len=5 get(x-a)= get_all(x-a)=0\nHost: probe\r\nX-E: \r\n"
            "X-E2: \r\nX-W: a \t b\r\nConnection: close\r\n"
        ),
    )
    c.eq(
        "2. OWS before colon rejected",
        exchange(port, get("/echo", "X-O : v\r\n")),
        BAD,
    )
    c.eq(
        "2. obs-fold rejected",
        exchange(port, get("/echo", "X-F: a\r\n b\r\n")),
        BAD,
    )
    c.eq(
        "2. UTF-8 obs-text (é = C3 A9) rejected by default",
        exchange(port, get("/echo", "X-H: \\xC3\\xA9\r\n")),
        BAD,
    )
    c.eq(
        "2. invalid UTF-8 obs-text (FF) rejected by default",
        exchange(port, get("/echo", "X-H: \\xFF\r\n")),
        BAD,
    )
    c.eq(
        "2. lenient obs-text: é stored as its bytes",
        exchange(lenient, get("/echo", "X-H: \\xC3\\xA9\r\n")),
        echo_ok(
            "len=3 get(x-a)= get_all(x-a)=0\nHost: probe\r\nX-H: \\xC3\\xA9\r\n"
            "Connection: close\r\n"
        ),
    )
    c.eq(
        "2. lenient obs-text: FF stored raw (String not valid UTF-8)",
        exchange(lenient, get("/echo", "X-H: a\\xFFb\r\n")),
        echo_ok(
            "len=3 get(x-a)= get_all(x-a)=0\nHost: probe\r\nX-H: a\\xFFb\r\n"
            "Connection: close\r\n"
        ),
    )
    c.eq(
        "2. lenient obs-text: high byte in a NAME still rejected",
        exchange(lenient, get("/echo", "X-\\xC3\\xA9: v\r\n")),
        BAD,
    )
    c.eq(
        "2. NUL in value rejected",
        exchange(port, get("/echo", "X-N: a\\x00b\r\n")),
        BAD,
    )
    c.eq(
        "2. bare CR in value rejected",
        exchange(port, get("/echo", "X-N: a\rb\r\n")),
        BAD,
    )
    c.eq(
        "2. 0x01 in value rejected",
        exchange(port, get("/echo", "X-N: a\\x01b\r\n")),
        BAD,
    )
    c.eq(
        "2. DEL (0x7F) in value rejected",
        exchange(port, get("/echo", "X-N: a\\x7Fb\r\n")),
        BAD,
    )
    c.eq(
        "2. non-token byte in name rejected",
        exchange(port, get("/echo", "X(A): v\r\n")),
        BAD,
    )
    c.eq(
        "2. duplicate Host rejected (also differing case)",
        exchange(port, get("/echo", "host: probe\r\n")),
        BAD,
    )
    c.eq(
        "2. duplicate Content-Length, same value, rejected",
        exchange(
            port,
            (
                "POST /echo HTTP/1.1\r\nHost: probe\r\nContent-Length: 1\r\n"
                "Content-Length: 1\r\nConnection: close\r\n\r\nx"
            ),
        ),
        BAD,
    )
    c.eq(
        "2. HTTP/1.1 request without Host accepted",
        exchange(port, "GET /echo HTTP/1.1\r\nConnection: close\r\n\r\n"),
        echo_ok("len=1 get(x-a)= get_all(x-a)=0\nConnection: close\r\n"),
    )


def run_outbound(mut c: Checks, port: UInt16) raises:
    c.eq(
        "3. adapter-shaped Response(200, body=hello): Flare-added fields",
        exchange(port, get("/plain")),
        ok_with("", "hello"),
    )
    c.eq(
        "3. handler name casing kept on the wire",
        exchange(port, get("/case")),
        ok_with("X-MiXeD-cAsE: v\\r\\n"),
    )
    c.eq(
        "3. order across names is insertion order",
        exchange(port, get("/order")),
        ok_with("B-Second: 1\\r\\nA-First: 2\\r\\nb-second: 3\\r\\n"),
    )
    c.eq(
        "3. two appended Set-Cookie both emitted, in order",
        exchange(port, get("/cookies")),
        ok_with("Set-Cookie: a=1\\r\\nSet-Cookie: b=2\\r\\n"),
    )
    c.eq(
        "3. set after appends leaves the later duplicate",
        exchange(port, get("/set-after-append")),
        ok_with("X-d: 3\\r\\nx-d: 2\\r\\n"),
    )
    c.eq(
        "3. empty value emitted",
        exchange(port, get("/empty")),
        ok_with("X-Empty: \\r\\n"),
    )
    c.eq(
        "3. non-ASCII value bytes emitted raw",
        exchange(port, get("/utf8")),
        ok_with("X-U: \\xC3\\xA9\\r\\n"),
    )
    c.eq(
        "3. FF, NUL and 0x01 in a value emitted raw (only CR/LF checked)",
        exchange(port, get("/bytes")),
        ok_with("X-Bin: a\\xFFb\\x00c\\x01\\r\\n"),
    )
    c.eq(
        "3. non-token name (colon, space) emitted verbatim",
        exchange(port, get("/bad-name")),
        ok_with("X:Y Z: v\\r\\n"),
    )
    c.eq(
        "3. handler Content-Length dropped, Flare writes the body length",
        exchange(port, get("/content-length")),
        ok_with(""),
    )
    c.eq(
        "3. handler Transfer-Encoding passed through beside Content-Length",
        exchange(port, get("/transfer-encoding")),
        ok_with("Transfer-Encoding: chunked\\r\\n"),
    )
    c.eq(
        "3. handler Connection dropped, Flare decides it",
        exchange(port, get("/connection")),
        ok_with(""),
    )
    c.eq(
        "3. handler Content-Type kept unchanged (name casing too)",
        exchange(port, get("/content-type")),
        ok_with("content-TYPE: application/x-probe; q=1\\r\\n"),
    )
    c.eq(
        "3. handler Date dropped (Flare's own), handler Server kept",
        exchange(port, get("/date-server")),
        ok_with("Server: probe\\r\\n"),
    )
    c.eq(
        "3. CR or LF in set/append name or value raises HeaderInjectionError",
        exchange(port, get("/inject")),
        ok_with(
            "",
            (
                "HeaderInjectionError: field='X-Inj' value='a\r\nInjected:"
                " 1';HeaderInjectionError: field='X-Inj\n' value='v';"
                "HeaderInjectionError: field='X-Inj' value='a\rb'"
            ),
        ),
    )
