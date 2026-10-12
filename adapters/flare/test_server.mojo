"""`Server`, the Flare adapter's serving entrypoint (M3-033, decided in
docs/history/architecture-decisions.md "Serving entrypoint decision
(M3-032)").

Runs only in the `flare` pixi environment (see scripts/check_flare.sh).
`Server.bind` binds and listens before it returns, so each serving test binds
in the parent, forks a child that calls `server.serve(app)` on a borrowed
`App`, and sends its first request right after `bind` returned, with no sleep
or retry. The child arms a 30-second `alarm(2)`; the parent SIGKILLs and reaps
it in `finally` unless the test has already reaped it. Requests are raw
HTTP/1.1 over `TcpStream` with `Connection: close`, read until the server
closes.

The receive body limit (M3-044, decided in docs/history/architecture-decisions.md
"Server receive body limit decision (M3-044)"): `Server.bind`'s keyword-only
`max_body_bytes` is checked (0 to 2^59 - 1) before anything is bound, and
`_server_config` writes it into both of Flare's fields; the `docs/DX.md`
section 1 example runs as written but on port 0. What a client sees on each
transport is in `adapters/flare/test_localhost_roundtrip.mojo`.

`Server.serve` refuses to start, on every system, when the environment sets
`FLARE_BUFRING_HANDLER` to `1`, which would select Flare's buffer-ring loop
(M3-044); any other value serves as usual. Each case sets the variable only in
a forked child.

Graceful shutdown (M3-045, decided in docs/history/architecture-decisions.md
"Graceful shutdown decision (M3-045)"): each stop test binds with
`shutdown_grace_ms`, forks a child whose `serve` returning exits 0, and sends
the signal from the parent. A request held in flight runs `held`, which
reports through one pipe that it started and waits on another until the test
releases it, so the stop is sent while a handler is running. The parent reaps
every child with `_reap_within`, which SIGKILLs a child that outlives its
bound and fails the test instead of hanging.

The `::1` case needs IPv6. It is skipped only where the host shows it has none
(`socket(AF_INET6, ...)` fails with `EAFNOSUPPORT`) and `CI` is unset; under
`CI` it always runs, so the CI runners keep binding `::1`.
"""

from std.ffi import c_int, c_uint, external_call, get_errno
from std.io.file_descriptor import FileDescriptor
from std.os import getenv, setenv
from std.sys import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from flare.http import ServerConfig
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
from flare.runtime import libc_nanosleep_ms, monotonic_now_ms
from flare.tcp import TcpStream
from flare.utils import SIGINT, SIGKILL, SIGTERM, exit, fork, kill, waitpid
from muntin import App, Request, Response
from muntin.testing import TestClient
from muntin_flare import Server, _server_config

comptime TIMEOUT_MS = 5_000
comptime CHILD_LIFETIME_S = 30
comptime SIGALRM = 14
comptime SIGPIPE = 13
comptime AF_INET6 = 30 if CompilationTarget.is_macos() else 10
comptime SOCK_STREAM = 1
comptime EAFNOSUPPORT = 47 if CompilationTarget.is_macos() else 97
comptime LARGEST_BODY_LIMIT = 576460752303423487  # 2^59 - 1
comptime REFUSAL_ALARM_S = 10
comptime WNOHANG = 1
comptime GRACE_MS = 1500
comptime SHORT_GRACE_MS = 300
comptime LONG_GRACE_MS = 10_000
comptime STOP_BOUND_MS = 1000
comptime LARGEST_GRACE_MS = 86_400_000


def hello() -> String:
    return "hello"


def get_user(id: Int) -> String:
    return "user " + String(id)


def not_modified(var req: Request) -> Response:
    """A raw 304 with a body: over HTTP/1.1 Flare frames a 304 with the
    body's length unless the adapter's `HEAD` step emptied it first."""
    return Response(304, "abc")


def borrowed_app() -> App:
    var app = App()
    app.get["/hello"](hello)
    app.get["/users/{id}"](get_user)
    app.get["/nm"](not_modified)
    return app^


@fieldwise_init
struct _Child(Copyable):
    var pid: Int
    var port: Int


def _serve_in_child(app: App, restore: Int) raises -> _Child:
    """Binds an ephemeral loopback port and forks a child that serves the
    borrowed `app` there with `server.serve(app)`. With `restore` > 0 the
    child first restores that signal's default disposition, so the test does
    not depend on what the runner's process inherited; this replaces the Mojo
    runtime's own handler, so the stop tests show the default action, not
    that handler's re-raise. The parent's copy of the listener is dropped
    when this returns, so only the child holds the port. The caller must
    reap `pid`."""
    var server = Server.bind("127.0.0.1", 0)
    var port = server.port()
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        if restore > 0:
            # signal(restore, SIG_DFL); SIG_DFL is 0 on Linux and macOS.
            _ = external_call["signal", Int](c_int(restore), Int(0))
        try:
            server.serve(app)
        except e:
            print("server child: serve failed:", e)
        exit(1)
    return _Child(pid, port)


def _stop(pid: Int):
    _ = kill(pid, SIGKILL)
    waitpid(pid)


def _wait_status(pid: Int) -> Int:
    """Reaps `pid` and returns `waitpid`'s raw status (Flare's `waitpid`
    discards it), or -1 if `waitpid` failed. The status address is passed as
    an `Int`, as Flare declares `waitpid` (one module, one signature)."""
    var status = List[c_int]()
    status.append(0)
    var reaped = external_call["waitpid", c_int](
        c_int(pid), Int(status.unsafe_ptr()), c_int(0)
    )
    if Int(reaped) != pid:
        return -1
    return Int(status[0])


def _exchange(port: Int, request: String) raises -> String:
    """Sends `request` and returns every byte until the server closes."""
    var stream = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
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
    return String(from_utf8_lossy=Span(out))


def _request(method: String, target: String) -> String:
    return (
        method
        + " "
        + target
        + " HTTP/1.1\r\nHost: muntin\r\nConnection: close\r\n\r\n"
    )


def _status_line(raw: String) -> String:
    var end = raw.find("\r\n")
    if end < 0:
        return raw
    return String(raw[byte=:end])


def _content(raw: String) -> String:
    """What follows the header block."""
    var end = raw.find("\r\n\r\n")
    if end < 0:
        return raw
    return String(raw[byte = end + 4 :])


def _bind_error(host: String, port: Int) -> String:
    """The text `Server.bind(host, port)` raises, or what it bound."""
    try:
        var server = Server.bind(host, port)
        return "bound port " + String(server.port())
    except e:
        return String(e)


def test_bind_port_zero_reports_the_bound_port() raises:
    var server = Server.bind("127.0.0.1", 0)
    print("observed: bind 127.0.0.1:0 ->", server.port())
    assert_true(server.port() > 0)
    assert_true(server.port() <= 65535)


def test_serve_answers_right_after_bind() raises:
    var app = borrowed_app()
    var child = _serve_in_child(app, 0)
    try:
        # Sent as soon as `bind` returned: the listener queues it.
        var raw = _exchange(child.port, _request("GET", "/hello"))
        print("observed: GET /hello ->", repr(raw))
        assert_equal(_status_line(raw), "HTTP/1.1 200 OK")
        assert_equal(_content(raw), "hello")

        # The router and `App.handle`'s answers, not a fixed response.
        var expected = TestClient(app).get("/users/7")
        raw = _exchange(child.port, _request("GET", "/users/7"))
        assert_equal(_status_line(raw), "HTTP/1.1 200 OK")
        assert_equal(_content(raw), expected.text())
        raw = _exchange(child.port, _request("GET", "/users/abc"))
        assert_true(_status_line(raw).startswith("HTTP/1.1 400"), raw)
        assert_equal(_content(raw), "Bad Request")
        raw = _exchange(child.port, _request("GET", "/missing"))
        assert_true(_status_line(raw).startswith("HTTP/1.1 404"), raw)
        assert_equal(_content(raw), "Not Found")
        raw = _exchange(child.port, _request("POST", "/hello"))
        assert_true(_status_line(raw).startswith("HTTP/1.1 405"), raw)
        assert_true("\r\nAllow: GET, HEAD\r\n" in raw, raw)

        # `HEAD` through the borrowed handler: the GET answer's length, no
        # content. Flare alone would send the same bytes for this one.
        raw = _exchange(child.port, _request("HEAD", "/hello"))
        print("observed: HEAD /hello ->", repr(raw))
        assert_equal(_status_line(raw), "HTTP/1.1 200 OK")
        assert_true("\r\nContent-Length: 5\r\n" in raw, raw)
        assert_equal(_content(raw), "")
        # This one tells the adapter's `HEAD` step apart: with it the body is
        # gone before Flare frames the 304 (`Content-Length: 0`); without it
        # Flare declares the body's 3 bytes.
        raw = _exchange(child.port, _request("HEAD", "/nm"))
        print("observed: HEAD /nm ->", repr(raw))
        assert_equal(_status_line(raw), "HTTP/1.1 304 Not Modified")
        assert_true("\r\nContent-Length: 0\r\n" in raw, raw)
        assert_equal(_content(raw), "")
    finally:
        _stop(child.pid)


def test_bind_raises_for_a_port_a_child_serves() raises:
    var app = borrowed_app()
    var child = _serve_in_child(app, 0)
    try:
        var raw = _exchange(child.port, _request("GET", "/hello"))
        assert_equal(_content(raw), "hello")
        var error = _bind_error("127.0.0.1", child.port)
        print("observed: bind a served port ->", error)
        assert_true(not error.startswith("bound port"), error)
        # The parent's `App` still answers after the bind raise (`bind` does
        # not borrow it).
        assert_equal(TestClient(app).get("/hello").text(), "hello")
    finally:
        _stop(child.pid)


def test_bind_raises_for_a_port_out_of_range() raises:
    var low = _bind_error("127.0.0.1", -1)
    var high = _bind_error("127.0.0.1", 65536)
    print("observed:", low, "/", high)
    assert_equal(low, "port out of range: -1")
    assert_equal(high, "port out of range: 65536")
    # The range check runs before the host is parsed.
    assert_equal(_bind_error("localhost", 65536), "port out of range: 65536")


def test_bind_raises_for_a_host_name() raises:
    var error = _bind_error("localhost", 0)
    print("observed: bind localhost ->", error)
    assert_true(not error.startswith("bound port"), error)


def test_bind_ipv4_any() raises:
    var v4_any = Server.bind("0.0.0.0", 0)
    print("observed: 0.0.0.0 ->", v4_any.port())
    assert_true(v4_any.port() > 0)


def test_bind_ipv6_loopback() raises:
    var v6 = Server.bind("::1", 0)
    print("observed: ::1 ->", v6.port())
    assert_true(v6.port() > 0)


def _host_has_no_ipv6() -> Bool:
    """True only when the OS refuses an IPv6 socket as an unsupported address
    family; any other result, an IPv6 socket or another errno, is False, so
    `test_bind_ipv6_loopback` runs."""
    var fd = external_call["socket", c_int](
        c_int(AF_INET6), c_int(SOCK_STREAM), c_int(0)
    )
    if fd >= 0:
        _ = external_call["close", c_int](fd)
        return False
    return Int(get_errno().value) == EAFNOSUPPORT


def test_dropping_a_server_releases_its_port() raises:
    var first = Server.bind("127.0.0.1", 0)
    var port = first.port()
    assert_true(_bind_error("127.0.0.1", port) != "bound port " + String(port))
    _ = first^
    var again = Server.bind("127.0.0.1", port)
    assert_equal(again.port(), port)


def _bind_limit_error(host: String, port: Int, limit: Int) -> String:
    """The text `Server.bind(host, port, max_body_bytes=limit)` raises, or
    what it bound."""
    try:
        var server = Server.bind(host, port, max_body_bytes=limit)
        return "bound port " + String(server.port())
    except e:
        return String(e)


def test_bind_raises_for_a_body_limit_out_of_range() raises:
    """Below 0 and above 2^59 - 1 (where Flare's chunk-size scanner can
    overflow) `bind` raises Muntin's message, after the port check and before
    the host is parsed or anything is bound: on a port a child serves, the
    raise is the range's, not `AddressInUse`."""
    var app = borrowed_app()
    var child = _serve_in_child(app, 0)
    try:
        for limit in [-1, LARGEST_BODY_LIMIT + 1, Int.MAX, -Int.MAX]:
            var error = _bind_limit_error("127.0.0.1", child.port, limit)
            print("observed: max_body_bytes", limit, "->", error)
            assert_equal(error, "max_body_bytes out of range: " + String(limit))
        assert_equal(
            _bind_limit_error("localhost", 0, -1),
            "max_body_bytes out of range: -1",
        )
        assert_equal(
            _bind_limit_error("127.0.0.1", 65536, -1),
            "port out of range: 65536",
        )
        # The child still serves: nothing was bound over its port.
        var raw = _exchange(child.port, _request("GET", "/hello"))
        assert_equal(_content(raw), "hello")
    finally:
        _stop(child.pid)


def test_bind_accepts_the_body_limit_range_ends() raises:
    for limit in [0, 1, LARGEST_BODY_LIMIT]:
        var error = _bind_limit_error("127.0.0.1", 0, limit)
        print("observed: max_body_bytes", limit, "->", error)
        assert_true(error.startswith("bound port "), error)


def test_server_config_sets_both_body_limits() raises:
    """One value reaches both of Flare's fields (HTTP/1.1 and HTTP/2); every
    other field keeps Flare's default. Muntin's default equals Flare
    v0.12.0's for both."""
    var flare = ServerConfig()
    assert_equal(flare.max_body_size, 10 * 1024 * 1024)
    assert_equal(flare.h2.max_body_size, 10 * 1024 * 1024)
    for limit in [0, 64, 10 * 1024 * 1024, LARGEST_BODY_LIMIT]:
        var config = _server_config(limit)
        assert_equal(config.max_body_size, limit)
        assert_equal(config.h2.max_body_size, limit)
        assert_equal(config.max_header_size, flare.max_header_size)
        assert_equal(config.max_uri_length, flare.max_uri_length)
        assert_equal(config.keep_alive, flare.keep_alive)
        assert_equal(config.idle_timeout_ms, flare.idle_timeout_ms)
        assert_equal(config.request_timeout_ms, flare.request_timeout_ms)
        assert_false(config.use_bufring, "the buffer-ring loop selected")
        assert_equal(
            config.h2.max_concurrent_streams, flare.h2.max_concurrent_streams
        )
        assert_equal(
            config.h2.initial_window_size, flare.h2.initial_window_size
        )
    for limit in [-1, LARGEST_BODY_LIMIT + 1]:
        try:
            _ = _server_config(limit)
            assert_true(False, "no raise for " + String(limit))
        except e:
            assert_equal(
                String(e), "max_body_bytes out of range: " + String(limit)
            )


def welcome() -> String:
    return "Hello, Mojo!"


def test_docs_receive_limit_example() raises:
    """The `docs/DX.md` section 1 receive limit example as written, on port 0
    instead of 8080: 64 KiB is received, a head declaring one byte more is
    Flare's 413 before any body is sent."""
    var app = App()
    app.get["/"](welcome)
    var server = Server.bind("127.0.0.1", 0, max_body_bytes=64 * 1024)
    var port = server.port()
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        try:
            server.serve(app)
        except e:
            print("server child: serve failed:", e)
        exit(1)
    _ = server^
    try:
        var within = String(
            "POST / HTTP/1.1\r\nHost: muntin\r\nContent-Length: 65536\r\n",
            "Connection: close\r\n\r\n",
        )
        for _ in range(65536):
            within += "a"
        var raw = _exchange(port, within)
        # Received, then App.handle: no POST route on `/`.
        assert_equal(_status_line(raw), "HTTP/1.1 405 Method Not Allowed")
        raw = _exchange(
            port,
            String(
                "POST / HTTP/1.1\r\nHost: muntin\r\nContent-Length: 65537",
                "\r\nConnection: close\r\n\r\n",
            ),
        )
        print("observed: 65537 declared ->", _status_line(raw))
        assert_equal(_status_line(raw), "HTTP/1.1 413 Content Too Large")
        assert_equal(_content(raw), "413 Content Too Large")
        raw = _exchange(port, _request("GET", "/"))
        assert_equal(_content(raw), "Hello, Mojo!")
    finally:
        _stop(pid)


def _serve_with_bufring_env(value: String) raises -> _Child:
    """As `_serve_in_child(borrowed_app(), 0)`, but the child sets
    `FLARE_BUFRING_HANDLER` to `value` before `server.serve(app)` and arms a
    `REFUSAL_ALARM_S` alarm. If `serve` raises, the child prints the error and exits
    7 when it is M3-044's refusal, 8 otherwise; if it returns, it exits 9."""
    var app = borrowed_app()
    var server = Server.bind("127.0.0.1", 0)
    var port = server.port()
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(REFUSAL_ALARM_S))
        _ = setenv("FLARE_BUFRING_HANDLER", value)
        try:
            server.serve(app)
        except e:
            print("observed: FLARE_BUFRING_HANDLER=" + value, "->", e)
            if (
                String(e)
                == "FLARE_BUFRING_HANDLER=1 is unsupported by Muntin with Flare"
                " v0.12.0"
            ):
                exit(7)
            exit(8)
        exit(9)
    return _Child(pid, port)


def test_serve_refuses_flare_bufring_handler() raises:
    """With `FLARE_BUFRING_HANDLER=1` in the environment, `serve` raises
    M3-044's message before serving (the child exits 7, not killed by its
    alarm); with `0` it serves."""
    var refused = _serve_with_bufring_env("1")
    var status = _wait_status(refused.pid)
    print("observed: FLARE_BUFRING_HANDLER=1 -> waitpid status", status)
    assert_true(status >= 0, "waitpid failed")
    assert_equal(status & 0x7F, 0, "the child was killed, not refused")
    assert_equal((status >> 8) & 0xFF, 7, "serve did not raise the refusal")
    var served = _serve_with_bufring_env("0")
    try:
        var raw = _exchange(served.port, _request("GET", "/hello"))
        assert_equal(_status_line(raw), "HTTP/1.1 200 OK")
        assert_equal(_content(raw), "hello")
    finally:
        _stop(served.pid)


# ── Graceful shutdown (M3-045) ─────────────────────────────────────────────


def held(started: Int, release: Int) raises -> String:
    """Writes one byte to the pipe `started` and waits for one on the pipe
    `release` (both inherited from the parent through `fork`), so the test
    decides when this request finishes. Only a released handler answers."""
    var out = FileDescriptor(started)
    out.write_bytes("s".as_bytes())
    var byte = List[UInt8](length=1, fill=0)
    var source = FileDescriptor(release)
    if source.read_bytes(byte) != 1:
        raise Error("held: not released")
    return "released after the stop"


def stoppable_app() -> App:
    var app = borrowed_app()
    app.get["/held/{started}/{release}"](held)
    return app^


def _pipe() raises -> Tuple[Int, Int]:
    var fds = List[c_int](length=2, fill=0)
    if Int(external_call["pipe", c_int](Int(fds.unsafe_ptr()))) != 0:
        raise Error("pipe() failed")
    return (Int(fds[0]), Int(fds[1]))


def _close(fd: Int):
    _ = external_call["close", c_int](c_int(fd))


def _write_byte(fd: Int) raises:
    var out = FileDescriptor(fd)
    out.write_bytes("r".as_bytes())


def _read_byte(fd: Int) raises -> Int:
    """Reads one byte: 1, or 0 when every write end is closed."""
    var byte = List[UInt8](length=1, fill=0)
    var source = FileDescriptor(fd)
    return source.read_bytes(byte)


@fieldwise_init
struct _Held(Copyable):
    """The pipes of one `held` request, parent side. `started` is read in
    the parent; `release` is written by it."""

    var started: Int
    var release: Int
    var path: String


def _held_pipes() raises -> Tuple[_Held, Int, Int]:
    """The parent's ends and the child's ends (started write, release
    read), which the parent closes after `fork`."""
    var started = _pipe()
    var release = _pipe()
    var path = "/held/" + String(started[1]) + "/" + String(release[0])
    return (_Held(started[0], release[1], path), started[1], release[0])


def _serve_stoppable(app: App, grace_ms: Int) raises -> _Child:
    """As `_serve_in_child`, bound with `shutdown_grace_ms=grace_ms`. The
    child exits 0 when `serve` returns and 1 when it raises."""
    var server = Server.bind("127.0.0.1", 0, shutdown_grace_ms=grace_ms)
    var port = server.port()
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        try:
            server.serve(app)
        except e:
            print("server child: serve failed:", e)
            exit(1)
        exit(0)
    return _Child(pid, port)


def _reap_within(pid: Int, bound_ms: Int) -> Tuple[Int, Int]:
    """Waits up to `bound_ms` for `pid` to end: its raw `waitpid` status and
    the milliseconds waited. If it outlives the bound it is SIGKILLed and
    reaped, and the status is -1, so a test that hangs fails instead."""
    var status = List[c_int](length=1, fill=0)
    var start = monotonic_now_ms()
    while True:
        var reaped = external_call["waitpid", c_int](
            c_int(pid), Int(status.unsafe_ptr()), c_int(WNOHANG)
        )
        var waited = monotonic_now_ms() - start
        if Int(reaped) == pid:
            return (Int(status[0]), waited)
        if Int(reaped) < 0:
            return (-1, waited)
        if waited > bound_ms:
            _stop(pid)
            return (-1, waited)
        _ = libc_nanosleep_ms(5)


def _exit_code(status: Int) -> Int:
    """The exit code of a child that exited, or -1 if it did not (killed by
    a signal, or not reaped)."""
    if status < 0 or (status & 0x7F) != 0:
        return -1
    return (status >> 8) & 0xFF


def _refused_within(port: Int, bound_ms: Int) -> Int:
    """Milliseconds until a new connection to `port` is refused, trying
    every 5 ms, or -1 if one still connects after `bound_ms`."""
    var start = monotonic_now_ms()
    while monotonic_now_ms() - start <= bound_ms:
        try:
            var probe = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
            _ = probe^
        except:
            return monotonic_now_ms() - start
        _ = libc_nanosleep_ms(5)
    return -1


def _read_all(mut stream: TcpStream) -> Tuple[String, String]:
    """Every byte until the server closes, and how the read ended: `eof`,
    `reset` or the raise's text (a timeout included)."""
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


def _is_reset(error: String) -> Bool:
    return "ConnectionReset" in error or "BrokenPipe" in error


def _send(port: Int, request: String) raises -> TcpStream:
    var stream = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    stream.set_recv_timeout(TIMEOUT_MS)
    stream.write_all(request.as_bytes())
    return stream^


def _stops_gracefully(sig: Int) raises:
    """A request whose handler is waiting when `sig` arrives is answered by
    that handler after the stop began; new connections are refused at
    once; the child exits 0 once the grace window has passed, and the port
    can be bound again."""
    var app = stoppable_app()
    var pipes = _held_pipes()
    var child = _serve_stoppable(app, GRACE_MS)
    _close(pipes[1])
    _close(pipes[2])
    var held = pipes[0].copy()
    var reaped = False
    try:
        var answered = _exchange(child.port, _request("GET", "/hello"))
        assert_equal(_content(answered), "hello")
        var in_flight = _send(child.port, _request("GET", held.path))
        assert_equal(_read_byte(held.started), 1, "the handler never started")
        # Connected while the reactor is inside the handler: the kernel
        # queues it, and Flare has not accepted it when the stop begins.
        var queued = _send(child.port, _request("GET", "/hello"))
        var signaled_at = monotonic_now_ms()
        assert_equal(kill(child.pid, sig), 0)
        var refused = _refused_within(child.port, 1000)
        print(
            "observed: signal",
            sig,
            "-> new connection refused after",
            refused,
            "ms",
        )
        assert_true(refused >= 0, "a new connection was still accepted")
        _write_byte(held.release)
        var got = _read_all(in_flight)
        print("observed: in-flight response ->", repr(got[0]), got[1])
        assert_equal(_status_line(got[0]), "HTTP/1.1 200 OK")
        assert_equal(_content(got[0]), "released after the stop")
        assert_equal(got[1], "eof")
        var dropped = _read_all(queued)
        print(
            "observed: connection queued before the stop ->",
            repr(dropped[0]),
            dropped[1],
        )
        assert_equal(dropped[0], "", "a queued connection was answered")
        var ended = _reap_within(child.pid, GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        var after = monotonic_now_ms() - signaled_at
        print(
            "observed: signal", sig, "-> status", ended[0], "after", after, "ms"
        )
        assert_equal(_exit_code(ended[0]), 0, "serve did not return")
        assert_true(after >= GRACE_MS, "ended before the grace window")
        var again = Server.bind("127.0.0.1", child.port)
        assert_equal(again.port(), child.port)
    finally:
        if not reaped:
            _stop(child.pid)
        _close(held.started)
        _close(held.release)


def test_sigterm_finishes_the_request_in_flight() raises:
    _stops_gracefully(SIGTERM)


def test_sigint_finishes_the_request_in_flight() raises:
    _stops_gracefully(SIGINT)


def _stops_idle(sig: Int) raises:
    """With no request in flight, `sig` ends the serving child with status 0
    after the grace window and within the bound."""
    var app = borrowed_app()
    var child = _serve_stoppable(app, SHORT_GRACE_MS)
    var reaped = False
    try:
        # One answer shows the child is in `serve`.
        var raw = _exchange(child.port, _request("GET", "/hello"))
        assert_equal(_content(raw), "hello")
        assert_equal(kill(child.pid, sig), 0)
        var ended = _reap_within(child.pid, SHORT_GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        print(
            "observed: idle, signal",
            sig,
            "-> status",
            ended[0],
            "after",
            ended[1],
            "ms",
        )
        assert_equal(_exit_code(ended[0]), 0, "serve did not return")
        assert_true(ended[1] >= SHORT_GRACE_MS, "ended before the window")
    finally:
        if not reaped:
            _stop(child.pid)


def test_sigterm_stops_an_idle_server() raises:
    _stops_idle(SIGTERM)


def test_sigint_stops_an_idle_server() raises:
    _stops_idle(SIGINT)


def test_stop_is_bounded_with_a_stalled_client() raises:
    """A client that sent half a request and stalls does not hold the stop:
    the child exits 0 within the bound and the client gets no answer."""
    var app = borrowed_app()
    var child = _serve_stoppable(app, SHORT_GRACE_MS)
    var reaped = False
    try:
        var raw = _exchange(child.port, _request("GET", "/hello"))
        assert_equal(_content(raw), "hello")
        var stalled = _send(
            child.port,
            "POST /hello HTTP/1.1\r\nHost: muntin\r\nContent-Length:"
            " 100\r\n\r\n"
            + "0123456789",
        )
        assert_equal(kill(child.pid, SIGTERM), 0)
        var ended = _reap_within(child.pid, SHORT_GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        print(
            "observed: stalled client -> status",
            ended[0],
            "after",
            ended[1],
            "ms",
        )
        assert_equal(_exit_code(ended[0]), 0, "serve did not return")
        var got = _read_all(stalled)
        print("observed: stalled client got", repr(got[0]), got[1])
        assert_equal(got[0], "")
    finally:
        if not reaped:
            _stop(child.pid)


def test_stop_is_bounded_with_a_handler_that_does_not_return() raises:
    """A handler still running when the window and the reactor's bound have
    passed does not hold the process: it exits 128 + 15 within the bound,
    and the request gets no answer."""
    var app = stoppable_app()
    var pipes = _held_pipes()
    var child = _serve_stoppable(app, SHORT_GRACE_MS)
    _close(pipes[1])
    _close(pipes[2])
    var held = pipes[0].copy()
    var reaped = False
    try:
        var in_flight = _send(child.port, _request("GET", held.path))
        assert_equal(_read_byte(held.started), 1, "the handler never started")
        assert_equal(kill(child.pid, SIGTERM), 0)
        var ended = _reap_within(
            child.pid, SHORT_GRACE_MS + STOP_BOUND_MS + 1000
        )
        reaped = ended[0] >= 0
        print(
            "observed: stuck handler -> status",
            ended[0],
            "after",
            ended[1],
            "ms",
        )
        assert_equal(_exit_code(ended[0]), 128 + SIGTERM)
        assert_true(
            ended[1] >= SHORT_GRACE_MS + STOP_BOUND_MS, "ended before the bound"
        )
        var got = _read_all(in_flight)
        print("observed: stuck handler's client got", repr(got[0]), got[1])
        assert_equal(got[0], "")
    finally:
        if not reaped:
            _stop(child.pid)
        _close(held.started)
        _close(held.release)


def test_a_second_stop_signal_ends_the_process_at_once() raises:
    """During the window a second SIGTERM (or a SIGINT) takes the default
    action: the child is terminated by it, long before the window ends."""
    for second in [SIGTERM, SIGINT]:
        var app = borrowed_app()
        var child = _serve_stoppable(app, LONG_GRACE_MS)
        var reaped = False
        try:
            var raw = _exchange(child.port, _request("GET", "/hello"))
            assert_equal(_content(raw), "hello")
            assert_equal(kill(child.pid, SIGTERM), 0)
            # The listener is closed once the first stop is seen.
            assert_true(_refused_within(child.port, 1000) >= 0)
            assert_equal(kill(child.pid, second), 0)
            var ended = _reap_within(child.pid, 2000)
            reaped = ended[0] >= 0
            print(
                "observed: second signal",
                second,
                "-> status",
                ended[0],
                "after",
                ended[1],
                "ms",
            )
            assert_true(reaped, "the second signal did not end the child")
            assert_equal(ended[0] & 0x7F, second)
        finally:
            if not reaped:
                _stop(child.pid)


def test_keep_alive_connection_during_the_window() raises:
    """Observed, not promised beyond what is asserted: an HTTP/1.1
    keep-alive connection open before SIGTERM, used again during the
    window, and when it closes."""
    var app = borrowed_app()
    var child = _serve_stoppable(app, GRACE_MS)
    var reaped = False
    try:
        var ka = _send(
            child.port, "GET /hello HTTP/1.1\r\nHost: muntin\r\n\r\n"
        )
        var buf = List[UInt8](length=4096, fill=0)
        var n = ka.read(buf.unsafe_ptr(), len(buf))
        print(
            "observed: keep-alive first ->",
            repr(String(from_utf8_lossy=Span(buf)[:n])),
        )
        assert_equal(kill(child.pid, SIGTERM), 0)
        var refused = _refused_within(child.port, 1000)
        assert_true(refused >= 0)
        var sent_at = monotonic_now_ms()
        ka.write_all("GET /users/7 HTTP/1.1\r\nHost: muntin\r\n\r\n".as_bytes())
        var got = _read_all(ka)
        print(
            "observed: keep-alive during the window ->",
            repr(got[0]),
            got[1],
            "after",
            monotonic_now_ms() - sent_at,
            "ms",
        )
        assert_equal(_status_line(got[0]), "HTTP/1.1 200 OK")
        assert_equal(_content(got[0]), "user 7")
        assert_true(got[1] == "eof" or got[1] == "reset", got[1])
        var ended = _reap_within(child.pid, GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        assert_equal(_exit_code(ended[0]), 0)
    finally:
        if not reaped:
            _stop(child.pid)


def _h2_frame(
    typ: FrameType, flags: UInt8, sid: Int, var payload: List[UInt8]
) -> List[UInt8]:
    var f = Frame()
    f.header.type = typ.copy()
    f.header.flags = FrameFlags(flags)
    f.header.stream_id = sid
    f.payload = payload^
    return encode_frame(f)


def _h2_get(sid: Int, path: String) -> List[UInt8]:
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(":method", "GET"))
    hdrs.append(HpackHeader(":scheme", "http"))
    hdrs.append(HpackHeader(":path", path))
    hdrs.append(HpackHeader(":authority", "localhost"))
    return _h2_frame(
        FrameType.HEADERS(),
        FrameFlags.END_HEADERS() | FrameFlags.END_STREAM(),
        sid,
        HpackEncoder().encode(Span[HpackHeader, _](hdrs)),
    )


def test_h2c_request_in_flight_finishes() raises:
    """An h2c stream whose handler is waiting when SIGTERM arrives is
    answered after the stop began; a stream opened on the same connection
    during the window, and how the connection ends, are observed."""
    var app = stoppable_app()
    var pipes = _held_pipes()
    var child = _serve_stoppable(app, GRACE_MS)
    _close(pipes[1])
    _close(pipes[2])
    var held = pipes[0].copy()
    var reaped = False
    try:
        var stream = TcpStream.connect(SocketAddr.localhost(UInt16(child.port)))
        stream.set_recv_timeout(GRACE_MS + STOP_BOUND_MS + 2000)
        var wire = List(H2_PREFACE.as_bytes())
        wire.extend(Span(_h2_frame(FrameType.SETTINGS(), 0, 0, List[UInt8]())))
        wire.extend(Span(_h2_get(1, held.path)))
        stream.write_all(Span[UInt8, _](wire))
        assert_equal(_read_byte(held.started), 1, "the handler never started")
        var signaled_at = monotonic_now_ms()
        assert_equal(kill(child.pid, SIGTERM), 0)
        assert_true(_refused_within(child.port, 1000) >= 0)
        stream.write_all(Span[UInt8, _](_h2_get(3, "/hello")))
        _write_byte(held.release)
        var acc = List[UInt8]()
        var buf = List[UInt8](length=4096, fill=0)
        var how = String("eof")
        while True:
            try:
                var n = stream.read(buf.unsafe_ptr(), len(buf))
                if n == 0:
                    break
                for i in range(n):
                    acc.append(buf[i])
            except e:
                how = String(e)
                break
        var closed_after = monotonic_now_ms() - signaled_at
        var pos = 0
        var decoder = HpackDecoder()
        var bodies = List[String]()
        bodies.append("")
        bodies.append("")
        var statuses = List[String]()
        statuses.append("")
        statuses.append("")
        var goaway = False
        while True:
            var maybe = parse_frame(Span[UInt8, _](acc)[pos:])
            if not maybe:
                break
            var f = maybe.value().copy()
            pos += 9 + f.header.length
            var sid = f.header.stream_id
            if f.header.type.value == FrameType.GOAWAY().value:
                goaway = True
            elif sid == 1 or sid == 3:
                var i = (sid - 1) // 2
                if f.header.type.value == FrameType.HEADERS().value:
                    var fields = decoder.decode(Span[UInt8, _](f.payload))
                    statuses[i] = fields[0].value
                elif f.header.type.value == FrameType.DATA().value:
                    bodies[i] += String(from_utf8_lossy=Span(f.payload))
        print(
            "observed: h2c stream 1 ->",
            statuses[0],
            repr(bodies[0]),
            "stream 3 ->",
            statuses[1],
            repr(bodies[1]),
            "goaway",
            goaway,
            "end",
            how,
            "after",
            closed_after,
            "ms",
        )
        assert_equal(statuses[0], "200")
        assert_equal(bodies[0], "released after the stop")
        assert_equal(statuses[1], "200")
        assert_equal(bodies[1], "hello")
        # Flare v0.12.0 closes an h2c connection with no GOAWAY.
        assert_false(goaway, "Flare now sends GOAWAY: revisit docs/DX.md")
        var ended = _reap_within(child.pid, GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        assert_equal(_exit_code(ended[0]), 0)
    finally:
        if not reaped:
            _stop(child.pid)
        _close(held.started)
        _close(held.release)


def test_bind_raises_for_a_grace_out_of_range() raises:
    for grace in [-1, LARGEST_GRACE_MS + 1, Int.MAX]:
        var error: String
        try:
            var server = Server.bind("127.0.0.1", 0, shutdown_grace_ms=grace)
            error = "bound port " + String(server.port())
        except e:
            error = String(e)
        print("observed: shutdown_grace_ms", grace, "->", error)
        assert_equal(error, "shutdown_grace_ms out of range: " + String(grace))
    for grace in [0, LARGEST_GRACE_MS]:
        var server = Server.bind("127.0.0.1", 0, shutdown_grace_ms=grace)
        assert_true(server.port() > 0)


def test_server_config_sets_the_grace() raises:
    assert_equal(_server_config(64).shutdown_timeout_ms, 5000)
    assert_equal(_server_config(64, 1234).shutdown_timeout_ms, 1234)


def main() raises:
    # A stop test writes to a pipe whose reader may be a child that already
    # ended; that must fail the test (EPIPE), not end the runner.
    _ = external_call["signal", Int](c_int(SIGPIPE), Int(1))  # SIG_IGN
    var suite = TestSuite.discover_tests[__functions_in_module()]()
    if _host_has_no_ipv6():
        if getenv("CI") != "":
            print("observed: no IPv6 on this host; CI is set, so ::1 runs")
        else:
            print("observed: no IPv6 on this host (EAFNOSUPPORT); ::1 skipped")
            suite.skip[test_bind_ipv6_loopback]()
    suite^.run()
