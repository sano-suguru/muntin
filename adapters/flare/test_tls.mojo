"""`Server` over TLS (M3-051, decided in docs/history/architecture-decisions.md
"Server TLS decision (M3-051)").

Runs only in the `flare` pixi environment, after scripts/check_flare.sh has
written the PEM files under `build/tls/` with the environment's `openssl`: a
self-signed certificate for `127.0.0.1` and its key (PKCS#8, and in the
older EC form, plain and encrypted), a key that does not belong to it, the
same key encrypted, and a certificate whose PEM block is damaged; a root CA
with an intermediate and a certificate the intermediate signs; and the odd
files the start-up checks refuse (scripts/check_flare.sh lists them all).
Every connection is a real TLS connection over loopback through Flare's
`TlsStream`, which verifies the server's certificate against the CA each
case names (the self-signed certificate unless it says otherwise) and offers
the ALPN protocols each case names.

As in `adapters/flare/test_server.mojo` (whose fork, pipe and reap helpers
this file imports), each serving test binds in the parent, forks a child that
calls `server.serve(app)` and reaps it within a bound.
"""

from std.ffi import c_int, c_uint, external_call
from std.testing import assert_equal, assert_true, TestSuite

from flare.http2 import (
    FrameFlags,
    FrameType,
    H2_PREFACE,
    HpackDecoder,
    HpackEncoder,
    HpackHeader,
    parse_frame,
)
from flare.net import SocketAddr
from flare.runtime import libc_nanosleep_ms, monotonic_now_ms
from flare.tcp import TcpStream
from flare.tls import TlsConfig, TlsStream
from flare.utils import SIGTERM, exit, fork, kill
from muntin import App, Request, Response
from muntin_flare import Server, Tls
from test_server import (
    CHILD_LIFETIME_S,
    STOP_BOUND_MS,
    _Child,
    _close,
    _exit_code,
    _h2_frame,
    _held_pipes,
    _is_reset,
    _read_byte,
    _reap_within,
    _refused_within,
    _stop,
    _write_byte,
    stoppable_app,
)

comptime DIR = "build/tls/"
comptime CERT = DIR + "cert.pem"
comptime KEY = DIR + "key.pem"
comptime OTHER_KEY = DIR + "other_key.pem"
comptime ENCRYPTED_KEY = DIR + "encrypted_key.pem"
comptime DAMAGED_CERT = DIR + "damaged_cert.pem"
comptime TRADITIONAL_KEY = DIR + "traditional_key.pem"
comptime TRADITIONAL_ENCRYPTED_KEY = DIR + "traditional_encrypted_key.pem"
comptime MISSING = DIR + "missing.pem"
comptime ROOT = DIR + "root.pem"
comptime LEAF = DIR + "leaf.pem"
comptime LEAF_KEY = DIR + "leaf_key.pem"
comptime CHAIN = DIR + "chain.pem"
comptime COMMENTED_KEY = DIR + "commented_key.pem"
comptime ENCRYPTED_FIRST_KEY = DIR + "encrypted_first_key.pem"
comptime CERT_LINK = DIR + "cert_link.pem"
comptime FIFO = DIR + "fifo.pem"
comptime BIG = DIR + "big.pem"
comptime READ_MS = 5_000
comptime LIMIT = 100
comptime IDLE_MS = 1_000
comptime GRACE_MS = 1_500


def _tls() -> Tls:
    return Tls(cert_file=CERT, key_file=KEY)


def length(var req: Request) -> Response:
    return Response(200, String(len(req.body)))


def echo(var req: Request) -> Response:
    return Response(200, req.body.copy())


def https_app() -> App:
    var app = stoppable_app()
    app.post["/length"](length)
    app.post["/echo"](echo)
    return app^


def _serve(var server: Server, app: App) raises -> _Child:
    """Forks a child that serves the borrowed `app` on `server` and exits 0
    when `serve` returns, 1 when it raises. The caller must reap `pid`."""
    var port = server.port()
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        # SIGPIPE stays ignored, as in an application once `bind` was given
        # `tls` (Flare ignores it then; here `main` already has).
        try:
            server.serve(app)
        except e:
            print("server child: serve failed:", e)
            exit(1)
        exit(0)
    return _Child(pid, port)


def _alpn(protocols: String) -> List[String]:
    var out = List[String]()
    for p in protocols.split(","):
        if p.byte_length() > 0:
            out.append(String(p))
    return out^


def _connect(
    port: Int, alpn: String, ca: String = CERT, server_name: String = ""
) raises -> TlsStream:
    """A verified TLS connection: the server's certificate must chain to
    `ca` and name `server_name`, or `127.0.0.1` when it is empty."""
    var stream = TlsStream.connect(
        "127.0.0.1",
        UInt16(port),
        TlsConfig(ca_bundle=ca, server_name=server_name, alpn=_alpn(alpn)),
    )
    stream.set_recv_timeout(READ_MS)
    return stream^


def _read_all(mut stream: TlsStream) -> Tuple[String, String]:
    """Every byte until the server closes, and how the read ended."""
    var out = List[UInt8]()
    var buf = List[UInt8](length=4096, fill=0)
    var how = String("eof")
    while True:
        try:
            var n = stream.read(buf.unsafe_ptr(), len(buf))
            if n == 0:
                break
            for i in range(n):
                out.append(buf[i])
        except e:
            how = "reset" if _is_reset(String(e)) else String(e)
            break
    return (String(from_utf8_lossy=Span(out)), how)


def _h1(
    port: Int,
    alpn: String,
    method: String,
    target: String,
    selected: String = "http/1.1",
) raises -> String:
    """One HTTP/1.1 request with `Connection: close` over TLS, after checking
    the ALPN protocol the server selected: the whole answer."""
    var stream = _connect(port, alpn)
    assert_equal(stream.alpn_selected(), selected)
    stream.write_all(
        (
            method
            + " "
            + target
            + " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        ).as_bytes()
    )
    return _read_all(stream)[0]


def _h1_post(port: Int, body_len: Int) raises -> String:
    var stream = _connect(port, "http/1.1")
    var wire = List(
        (
            "POST /length HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close"
            + "\r\nContent-Length: "
            + String(body_len)
            + "\r\n\r\n"
        ).as_bytes()
    )
    for _ in range(body_len):
        wire.append(UInt8(ord("x")))
    stream.write_all(Span[UInt8, _](wire))
    return _read_all(stream)[0]


def _h2_headers(
    sid: Int, method: String, path: String, end_stream: Bool
) -> List[UInt8]:
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(":method", method))
    hdrs.append(HpackHeader(":scheme", "https"))
    hdrs.append(HpackHeader(":path", path))
    hdrs.append(HpackHeader(":authority", "127.0.0.1"))
    var flags = FrameFlags.END_HEADERS()
    if end_stream:
        flags |= FrameFlags.END_STREAM()
    return _h2_frame(
        FrameType.HEADERS(),
        flags,
        sid,
        HpackEncoder().encode(Span[HpackHeader, _](hdrs)),
    )


@fieldwise_init
struct _H2Answer(Copyable):
    var status: String
    var body: String
    var reset_code: Int
    """The RST_STREAM error code, or -1 when the stream was not reset."""
    var data: List[UInt8]
    """The DATA frames' bytes, as received."""
    var data_frames: Int
    var content_length: String
    """The `content-length` field, or empty when there is none."""


def _h2_exchange(
    mut stream: TlsStream, var frames: List[UInt8]
) raises -> List[_H2Answer]:
    """Sends the client preface and SETTINGS, acknowledges the server's
    SETTINGS, then sends `frames`, which open streams 1 and 3, and reads
    until both have ended (END_STREAM or RST_STREAM)."""
    var wire = List(H2_PREFACE.as_bytes())
    wire.extend(Span(_h2_frame(FrameType.SETTINGS(), 0, 0, List[UInt8]())))
    stream.write_all(Span[UInt8, _](wire))
    var answers = List[_H2Answer]()
    for _ in range(2):
        answers.append(_H2Answer("", "", -1, List[UInt8](), 0, ""))
    var ended = List[Bool](length=2, fill=False)
    var acc = List[UInt8]()
    var buf = List[UInt8](length=4096, fill=0)
    var pos = 0
    var sent = False
    var decoder = HpackDecoder()
    while not (ended[0] and ended[1]):
        var maybe = parse_frame(Span[UInt8, _](acc)[pos:])
        if not maybe:
            var n = stream.read(buf.unsafe_ptr(), len(buf))
            if n == 0:
                raise Error("closed before both streams ended")
            for i in range(n):
                acc.append(buf[i])
            continue
        var f = maybe.value().copy()
        pos += 9 + f.header.length
        var sid = f.header.stream_id
        if (
            f.header.type.value == FrameType.SETTINGS().value
            and sid == 0
            and not f.header.flags.has(FrameFlags.ACK())
        ):
            stream.write_all(
                Span[UInt8, _](
                    _h2_frame(
                        FrameType.SETTINGS(),
                        FrameFlags.ACK(),
                        0,
                        List[UInt8](),
                    )
                )
            )
            if not sent:
                stream.write_all(Span[UInt8, _](frames))
                sent = True
            continue
        if sid != 1 and sid != 3:
            continue
        var i = (sid - 1) // 2
        if f.header.type.value == FrameType.HEADERS().value:
            var fields = decoder.decode(Span[UInt8, _](f.payload))
            for field in fields:
                if field.name == ":status":
                    answers[i].status = field.value
                elif field.name == "content-length":
                    answers[i].content_length = field.value
        elif f.header.type.value == FrameType.DATA().value:
            answers[i].body += String(from_utf8_lossy=Span(f.payload))
            answers[i].data.extend(Span(f.payload))
            answers[i].data_frames += 1
        elif f.header.type.value == FrameType.RST_STREAM().value:
            var p = f.payload.copy()
            answers[i].reset_code = (
                (Int(p[0]) << 24)
                | (Int(p[1]) << 16)
                | (Int(p[2]) << 8)
                | Int(p[3])
            )
            ended[i] = True
            continue
        if f.header.flags.has(FrameFlags.END_STREAM()):
            ended[i] = True
    return answers^


# ── Serving over TLS ───────────────────────────────────────────────────────


def test_https_answers_http11() raises:
    """With `tls`, the same `App` answers over HTTP/1.1 inside TLS, whether
    the client offers `http/1.1` or no ALPN at all."""
    var app = https_app()
    var child = _serve(Server.bind("127.0.0.1", 0, tls=_tls()), app)
    try:
        var raw = _h1(child.port, "http/1.1", "GET", "/hello")
        assert_true(raw.startswith("HTTP/1.1 200"), raw)
        assert_true(raw.endswith("\r\n\r\nhello"), raw)
        raw = _h1(child.port, "", "GET", "/users/7", selected="")
        assert_true(raw.startswith("HTTP/1.1 200"), raw)
        assert_true(raw.endswith("\r\n\r\nuser 7"), raw)
        raw = _h1(child.port, "http/1.1", "GET", "/missing")
        assert_true(raw.startswith("HTTP/1.1 404"), raw)
        raw = _h1(child.port, "http/1.1", "DELETE", "/hello")
        assert_true(raw.startswith("HTTP/1.1 405"), raw)
    finally:
        _stop(child.pid)


def test_known_flare_deviation_alpn_with_no_common_protocol_is_served() raises:
    """Not Muntin's contract: a known deviation of Flare v0.12.0, pinned so
    a Flare change is noticed. A client that offers only protocols the
    server does not serve is answered over HTTP/1.1 with no protocol
    selected; RFC 7301 section 3.2 requires a `no_application_protocol`
    alert instead. When Flare refuses the handshake, this test fails: change
    it to expect the refusal and drop the deviation from docs/DX.md section
    1, "HTTPS", and the M3-051 record; do not restore the old behaviour."""
    var app = https_app()
    var child = _serve(Server.bind("127.0.0.1", 0, tls=_tls()), app)
    try:
        var raw = _h1(child.port, "h3,foo", "GET", "/users/7", selected="")
        assert_true(raw.startswith("HTTP/1.1 200"), raw)
        assert_true(raw.endswith("\r\n\r\nuser 7"), raw)
    finally:
        _stop(child.pid)


def test_https_answers_http2() raises:
    """A client offering `h2` and `http/1.1` gets HTTP/2 (the server's
    first preference), and two streams on one connection are answered."""
    var app = https_app()
    var child = _serve(Server.bind("127.0.0.1", 0, tls=_tls()), app)
    try:
        var stream = _connect(child.port, "h2,http/1.1")
        assert_equal(stream.alpn_selected(), "h2")
        var frames = _h2_headers(1, "GET", "/hello", True)
        frames.extend(Span(_h2_headers(3, "GET", "/users/7", True)))
        var answers = _h2_exchange(stream, frames^)
        assert_equal(answers[0].status, "200")
        assert_equal(answers[0].body, "hello")
        assert_equal(answers[1].status, "200")
        assert_equal(answers[1].body, "user 7")
    finally:
        _stop(child.pid)


def _binary_body() -> List[UInt8]:
    """Every byte value, 0x00 and 0x80 to 0xFF included: not UTF-8."""
    var out = List[UInt8]()
    for b in range(256):
        out.append(UInt8(b))
    return out^


def _h1_body(raw: List[UInt8]) -> List[UInt8]:
    """What follows the head of a whole HTTP/1.1 answer."""
    for i in range(len(raw) - 3):
        if (
            raw[i] == 13
            and raw[i + 1] == 10
            and raw[i + 2] == 13
            and raw[i + 3] == 10
        ):
            return List(Span(raw)[i + 4 :])
    return List[UInt8]()


def test_binary_bodies_and_head_over_https() raises:
    """Over TLS, as in cleartext, a body that is not UTF-8 reaches the
    handler and comes back byte for byte, over HTTP/1.1 and HTTP/2; and
    `HEAD` on a `GET` route answers the GET's `Content-Length` with no
    content (over HTTP/2, no DATA frame)."""
    var app = https_app()
    var child = _serve(Server.bind("127.0.0.1", 0, tls=_tls()), app)
    try:
        var body = _binary_body()
        var stream = _connect(child.port, "http/1.1")
        var wire = List(
            (
                "POST /echo HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection:"
                + " close\r\nContent-Length: "
                + String(len(body))
                + "\r\n\r\n"
            ).as_bytes()
        )
        wire.extend(Span(body))
        stream.write_all(Span[UInt8, _](wire))
        var raw = List[UInt8]()
        var buf = List[UInt8](length=4096, fill=0)
        while True:
            var n = stream.read(buf.unsafe_ptr(), len(buf))
            if n == 0:
                break
            raw.extend(Span(buf)[:n])
        assert_true(_h1_body(raw) == body, "HTTP/1.1 echo changed the bytes")

        var head = _h1(child.port, "http/1.1", "HEAD", "/hello")
        assert_true(head.startswith("HTTP/1.1 200"), head)
        assert_true("Content-Length: 5\r\n" in head, head)
        assert_true(head.endswith("\r\n\r\n"), head)

        var h2 = _connect(child.port, "h2")
        var frames = _h2_headers(1, "POST", "/echo", False)
        frames.extend(
            Span(
                _h2_frame(
                    FrameType.DATA(), FrameFlags.END_STREAM(), 1, body.copy()
                )
            )
        )
        frames.extend(Span(_h2_headers(3, "HEAD", "/hello", True)))
        var answers = _h2_exchange(h2, frames^)
        assert_equal(answers[0].status, "200")
        assert_true(answers[0].data == body, "HTTP/2 echo changed the bytes")
        assert_equal(answers[1].status, "200")
        assert_equal(answers[1].content_length, "5")
        assert_equal(answers[1].data_frames, 0)
    finally:
        _stop(child.pid)


def test_https_does_not_answer_cleartext() raises:
    """A TLS `Server` answers no cleartext request: the bytes are not a TLS
    handshake, so the connection ends with no HTTP answer."""
    var app = https_app()
    var child = _serve(Server.bind("127.0.0.1", 0, tls=_tls()), app)
    try:
        var stream = TcpStream.connect(SocketAddr.localhost(UInt16(child.port)))
        stream.set_recv_timeout(READ_MS)
        stream.write_all(
            "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
            .as_bytes()
        )
        var buf = List[UInt8](length=4096, fill=0)
        var got = String()
        try:
            while True:
                var n = stream.read(buf.unsafe_ptr(), len(buf))
                if n == 0:
                    break
                got += String(from_utf8_lossy=Span(buf)[:n])
        except e:
            assert_true(_is_reset(String(e)), String(e))
        assert_true(not got.startswith("HTTP/"), got)
    finally:
        _stop(child.pid)


def _client_error(
    port: Int, ca: String = CERT, server_name: String = ""
) -> String:
    """Why a verified connection failed, or `connected`."""
    try:
        var stream = _connect(port, "http/1.1", ca, server_name)
        _ = stream^
        return "connected"
    except e:
        return String(e)


def test_https_sends_the_intermediate_certificate() raises:
    """A `cert_file` holding a certificate and then its intermediate is sent
    whole: a client that trusts only the root verifies the connection. The
    same certificate without its intermediate is not verified, so the
    intermediate the client needed came from the server."""
    var app = https_app()
    var child = _serve(
        Server.bind(
            "127.0.0.1", 0, tls=Tls(cert_file=CHAIN, key_file=LEAF_KEY)
        ),
        app,
    )
    try:
        var stream = _connect(child.port, "http/1.1", ROOT)
        stream.write_all(
            "GET /hello HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection:"
            " close\r\n\r\n".as_bytes()
        )
        var raw = _read_all(stream)[0]
        assert_true(raw.startswith("HTTP/1.1 200"), raw)
        assert_true(raw.endswith("\r\n\r\nhello"), raw)
    finally:
        _stop(child.pid)
    child = _serve(
        Server.bind("127.0.0.1", 0, tls=Tls(cert_file=LEAF, key_file=LEAF_KEY)),
        app,
    )
    try:
        var why = _client_error(child.port, ROOT)
        assert_true(why.startswith("CertificateUntrusted"), why)
    finally:
        _stop(child.pid)


def test_client_refuses_an_untrusted_or_misnamed_certificate() raises:
    """The verification every other test relies on is real: the client
    refuses the server's certificate when it trusts another CA, or when the
    certificate does not name the host it asked for (it names only
    `127.0.0.1`), and accepts it otherwise."""
    var app = https_app()
    var child = _serve(Server.bind("127.0.0.1", 0, tls=_tls()), app)
    try:
        assert_equal(_client_error(child.port), "connected")
        var untrusted = _client_error(child.port, ROOT)
        assert_true(untrusted.startswith("CertificateUntrusted"), untrusted)
        var misnamed = _client_error(child.port, CERT, "localhost")
        assert_true(
            misnamed.startswith("CertificateHostnameMismatch"), misnamed
        )
    finally:
        _stop(child.pid)


# ── Start-up errors ────────────────────────────────────────────────────────


def _bind_error(cert: String, key: String, port: Int = 0) -> String:
    try:
        var server = Server.bind(
            "127.0.0.1", port, tls=Tls(cert_file=cert, key_file=key)
        )
        return "bound port " + String(server.port())
    except e:
        return String(e)


def test_bind_names_a_file_it_cannot_read() raises:
    """A missing file raises naming it, before anything is bound: on a port
    another `Server` holds, the TLS error comes first, not the address in
    use."""
    var held = Server.bind("127.0.0.1", 0)
    var port = held.port()
    var cert = _bind_error(MISSING, KEY, port)
    assert_true(
        cert.startswith(
            "TLS certificate file cannot be read: " + MISSING + " ("
        ),
        cert,
    )
    var key = _bind_error(CERT, MISSING, port)
    assert_true(
        key.startswith("TLS key file cannot be read: " + MISSING + " ("), key
    )


def test_bind_names_a_file_with_the_wrong_content() raises:
    """Files that are not what their role needs raise naming the file:
    swapped files, an encrypted key (OpenSSL would otherwise ask for its
    passphrase on the terminal) and a key given as the certificate's own
    file. Each is checked before anything is bound."""
    var held = Server.bind("127.0.0.1", 0)
    var port = held.port()
    assert_equal(
        _bind_error(KEY, CERT, port),
        "TLS certificate file has no PEM certificate (-----BEGIN"
        " CERTIFICATE-----): "
        + KEY,
    )
    assert_equal(
        _bind_error(CERT, CERT, port),
        "TLS key file has no PEM private key: " + CERT,
    )
    assert_equal(
        _bind_error(CERT, ENCRYPTED_KEY, port),
        "TLS key file holds an encrypted private key, which is not supported: "
        + ENCRYPTED_KEY,
    )
    assert_equal(
        _bind_error(CERT, TRADITIONAL_ENCRYPTED_KEY, port),
        "TLS key file holds an encrypted private key, which is not supported: "
        + TRADITIONAL_ENCRYPTED_KEY,
    )


def test_bind_refuses_files_that_are_not_small_pem_files() raises:
    """Whatever the path names, `bind` neither blocks nor fills memory, and
    raises naming it: a device past 1 MiB, a FIFO with no writer (it reads
    as empty), an empty file, a directory (it cannot be read) and a file over
    1 MiB. Run in a child that has a bound, so a hang fails the test."""
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        var cases = List[Tuple[String, String, String]]()
        cases.append(
            (
                "/dev/zero",
                KEY,
                "TLS certificate file is larger than 1048576 bytes: /dev/zero",
            )
        )
        cases.append((CERT, FIFO, "TLS key file is empty: " + FIFO))
        cases.append((CERT, "/dev/null", "TLS key file is empty: /dev/null"))
        cases.append(
            (
                DIR,
                KEY,
                "TLS certificate file cannot be read: "
                + DIR
                + " (Is a directory)",
            )
        )
        cases.append(
            (
                BIG,
                KEY,
                "TLS certificate file is larger than 1048576 bytes: " + BIG,
            )
        )
        cases.append(
            (CERT, BIG, "TLS key file is larger than 1048576 bytes: " + BIG)
        )
        var failed = False
        for c in cases:
            var got = _bind_error(c[0], c[1])
            if got != c[2]:
                print("expected:", c[2], "got:", got)
                failed = True
        exit(1 if failed else 0)
    var ended = _reap_within(pid, 5_000)
    assert_equal(_exit_code(ended[0]), 0, "bind blocked or raised otherwise")


def test_bind_judges_the_first_private_key_block() raises:
    """Only a line that begins a PEM block counts, and the key judged is the
    first private key block: text that names an encrypted key outside a block, or an encrypted
    key after the plain one, is served; an encrypted key before a plain one
    is refused. A certificate reached through a symbolic link is served."""
    assert_equal(
        _bind_error(CERT, ENCRYPTED_FIRST_KEY),
        "TLS key file holds an encrypted private key, which is not supported: "
        + ENCRYPTED_FIRST_KEY,
    )
    var app = https_app()
    var child = _serve(
        Server.bind(
            "127.0.0.1",
            0,
            tls=Tls(cert_file=CERT_LINK, key_file=COMMENTED_KEY),
        ),
        app,
    )
    try:
        var raw = _h1(child.port, "http/1.1", "GET", "/hello")
        assert_true(raw.endswith("\r\n\r\nhello"), raw)
    finally:
        _stop(child.pid)


def test_https_serves_a_key_in_the_older_ec_form() raises:
    """A key in the older `BEGIN EC PRIVATE KEY` form, as `openssl ecparam
    -genkey` writes it, is accepted and served."""
    var app = https_app()
    var child = _serve(
        Server.bind(
            "127.0.0.1", 0, tls=Tls(cert_file=CERT, key_file=TRADITIONAL_KEY)
        ),
        app,
    )
    try:
        var raw = _h1(child.port, "http/1.1", "GET", "/hello")
        assert_true(raw.endswith("\r\n\r\nhello"), raw)
    finally:
        _stop(child.pid)


def test_bind_names_both_files_when_openssl_refuses_them() raises:
    """When Flare cannot load the pair, here a key that does not belong to
    the certificate or a damaged PEM block, `bind` raises naming both files
    and no cause, since Flare reports none."""
    var why = "TLS certificate or private key could not be loaded: "
    assert_equal(_bind_error(CERT, OTHER_KEY), why + CERT + ", " + OTHER_KEY)
    assert_equal(
        _bind_error(DAMAGED_CERT, KEY), why + DAMAGED_CERT + ", " + KEY
    )
    # Flare bound the port before OpenSSL refused the pair: it is free again.
    var probe = Server.bind("127.0.0.1", 0)
    var port = probe.port()
    _ = probe^
    assert_equal(
        _bind_error(CERT, OTHER_KEY, port), why + CERT + ", " + OTHER_KEY
    )
    var again = Server.bind("127.0.0.1", port)
    assert_equal(again.port(), port)


def _order_error(
    port: Int, idle_timeout_ms: Int, host: String, cert: String
) -> String:
    try:
        var server = Server.bind(
            host,
            port,
            idle_timeout_ms=idle_timeout_ms,
            tls=Tls(cert_file=cert, key_file=KEY),
        )
        return "bound port " + String(server.port())
    except e:
        return String(e)


def test_bind_checks_the_settings_and_the_host_before_the_tls_files() raises:
    """The port, the settings and the host are checked before the TLS files
    are opened."""
    assert_equal(
        _order_error(70000, 1, "localhost", MISSING), "port out of range: 70000"
    )
    assert_equal(
        _order_error(0, 0, "localhost", MISSING),
        "idle_timeout_ms out of range: 0",
    )
    var host = _order_error(0, 1, "localhost", MISSING)
    assert_true(
        not host.startswith("TLS") and not host.startswith("bound"), host
    )
    var files = _order_error(0, 1, "127.0.0.1", MISSING)
    assert_true(
        files.startswith("TLS certificate file cannot be read: " + MISSING),
        files,
    )


# ── The three settings over TLS ────────────────────────────────────────────


def test_body_limit_over_https() raises:
    """`max_body_bytes` bounds what Flare receives inside TLS, as in
    cleartext: over HTTP/1.1 a body at the limit is answered and one byte
    more is 413; over HTTP/2 the longer stream is reset with
    ENHANCE_YOUR_CALM (0xb) and the next stream on the connection is
    answered."""
    var app = https_app()
    var child = _serve(
        Server.bind("127.0.0.1", 0, max_body_bytes=LIMIT, tls=_tls()), app
    )
    try:
        var raw = _h1_post(child.port, LIMIT)
        assert_true(raw.startswith("HTTP/1.1 200"), raw)
        assert_true(raw.endswith("\r\n\r\n" + String(LIMIT)), raw)
        raw = _h1_post(child.port, LIMIT + 1)
        assert_true(raw.startswith("HTTP/1.1 413"), raw)

        var stream = _connect(child.port, "h2")
        var frames = _h2_headers(1, "POST", "/length", False)
        frames.extend(
            Span(
                _h2_frame(
                    FrameType.DATA(),
                    FrameFlags.END_STREAM(),
                    1,
                    List[UInt8](length=LIMIT + 1, fill=UInt8(ord("x"))),
                )
            )
        )
        frames.extend(Span(_h2_headers(3, "GET", "/hello", True)))
        var answers = _h2_exchange(stream, frames^)
        assert_equal(answers[0].reset_code, 0xB)
        assert_equal(answers[0].status, "")
        assert_equal(answers[1].status, "200")
        assert_equal(answers[1].body, "hello")
    finally:
        _stop(child.pid)


def _closed_after(mut stream: TcpStream) -> Int:
    var start = monotonic_now_ms()
    var buf = List[UInt8](length=64, fill=0)
    try:
        while stream.read(buf.unsafe_ptr(), len(buf)) > 0:
            pass
    except:
        pass
    return monotonic_now_ms() - start


def test_idle_timeout_over_https() raises:
    """`idle_timeout_ms` closes a connection that never starts its TLS
    handshake, and a handshaken one that sends no request, after the value
    given, not Flare's 500 ms default."""
    var app = https_app()
    var child = _serve(
        Server.bind("127.0.0.1", 0, idle_timeout_ms=IDLE_MS, tls=_tls()), app
    )
    try:
        var silent = TcpStream.connect(SocketAddr.localhost(UInt16(child.port)))
        silent.set_recv_timeout(READ_MS)
        var before = _closed_after(silent)
        var stream = _connect(child.port, "http/1.1")
        var start = monotonic_now_ms()
        var ended = _read_all(stream)
        var after = monotonic_now_ms() - start
        print(
            "observed: idle TLS connections closed after",
            before,
            "ms (no handshake) and",
            after,
            "ms (handshaken),",
            ended[1],
        )
        assert_equal(ended[0], "")
        assert_true(before >= IDLE_MS - 100 and before < IDLE_MS + 1000)
        assert_true(after >= IDLE_MS - 100 and after < IDLE_MS + 1000)
    finally:
        _stop(child.pid)


def test_graceful_stop_over_https() raises:
    """On SIGTERM a TLS `Server` refuses new connections, answers the
    request whose handler is running, and `serve` returns within the window
    and the bound."""
    var app = https_app()
    var pipes = _held_pipes()
    var child = _serve(
        Server.bind("127.0.0.1", 0, shutdown_grace_ms=GRACE_MS, tls=_tls()),
        app,
    )
    _close(pipes[1])
    _close(pipes[2])
    var held = pipes[0].copy()
    var reaped = False
    try:
        var stream = _connect(child.port, "http/1.1")
        stream.write_all(
            (
                "GET "
                + held.path
                + " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
            ).as_bytes()
        )
        assert_equal(_read_byte(held.started), 1, "the handler never started")
        assert_equal(kill(child.pid, SIGTERM), 0)
        var refused = _refused_within(child.port, 1000)
        _write_byte(held.release)
        var answer = _read_all(stream)
        var ended = _reap_within(child.pid, GRACE_MS + STOP_BOUND_MS + 500)
        reaped = ended[0] >= 0
        print(
            "observed: TLS stop refused new connections after",
            refused,
            "ms; serve returned after",
            ended[1],
            "ms",
        )
        assert_true(refused >= 0, "a new connection was accepted")
        assert_true(answer[0].startswith("HTTP/1.1 200"), answer[0])
        assert_true(
            answer[0].endswith("\r\n\r\nreleased after the stop"), answer[0]
        )
        assert_equal(_exit_code(ended[0]), 0)
    finally:
        if not reaped:
            _stop(child.pid)
        _close(held.started)
        _close(held.release)


def main() raises:
    _ = external_call["signal", Int](c_int(13), Int(1))  # SIGPIPE: SIG_IGN
    TestSuite.discover_tests[__functions_in_module()]().run()
