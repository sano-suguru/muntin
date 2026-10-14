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

Head-of-line blocking (M3-046, decided in docs/history/architecture-decisions.md
"Head-of-line blocking decision (M3-046)"): with one handler held, a light
request on another HTTP/1.1 connection, another stream of the same h2c
connection or another h2c connection is not handled until the held one
returns; the order in which the handlers ran is read from a pipe after the
child ended. The same cases run on Flare's own `HttpServer` with a handler that
has no Muntin code, with its default configuration (where waiting keep-alive
and h2c requests are dropped once a hold outlasts the idle timeout) and with a
long idle timeout (where they are only serialized).

Workers (M3-049, decided in docs/history/architecture-decisions.md
"Multi-worker serving decision (M3-049)"): children serve with
`server.serve[make](workers=n)`; with one worker's handler held, a connection
opened meanwhile is answered by another (the order pipe reads `b` before `a`),
while the held h2c connection's other streams still wait; each worker builds
its own `App`; the stop, the range, a raising `make` and the buffer-ring
refusal are as for `serve(app)`. A raising `make` with another worker that
does not stop ends the process; a stop signal delivered before the watcher
sees it keeps its window; a process a handler starts does not keep the port;
a listener copy that cannot be parked stays open; a TLS server is refused.

Idle timeout (M3-047, decided in docs/history/architecture-decisions.md
"Server idle timeout decision (M3-047)"): the head-of-line blocking cases run
again on a `Server` bound with a long `idle_timeout_ms`, where the waiting
requests are answered after the held handler instead of dropped; the range is
checked before anything is bound; two `Server`s in one process keep their
own values; and a stop still ends within its window and bound.

The `::1` case needs IPv6. It is skipped only where the host shows it has none
(`socket(AF_INET6, ...)` fails with `EAFNOSUPPORT`) and `CI` is unset; under
`CI` it always runs, so the CI runners keep binding `::1`.
"""

from std.ffi import c_int, c_uint, external_call, get_errno
from std.io.file_descriptor import FileDescriptor
from std.os import getenv, setenv
from std.sys import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from flare.http import (
    Handler,
    HttpServer,
    Request as FlareRequest,
    Response as FlareResponse,
    ServerConfig,
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
from flare.net._libc_event import _pipe as _flare_pipe
from flare.runtime import libc_nanosleep_ms, monotonic_now_ms
from flare.runtime._thread import current_thread_id
from flare.tcp import TcpStream
from flare.utils import SIGINT, SIGKILL, SIGTERM, exit, fork, kill, waitpid
from muntin import App, Request, Response, State
from muntin.testing import TestClient
from flare.tls._server_ffi import ServerCtx
from muntin_flare import (
    Server,
    _CB_GRACE,
    _CB_LEN,
    _CB_NWORKERS,
    _CB_PARKED,
    _CB_WORKERS,
    _STAGE_INSTALLED,
    _STAGE_JOINED,
    _STAGE_RESTORED,
    _STAGE_SERVED,
    _STAGE_WATCHING,
    _STAGE_WORKER_ENDED,
    _W_FD,
    _W_LEN,
    _W_STOP,
    _drain_workers,
    _server_config,
    _serving_held,
)

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
comptime DRIVER = "./build/stop_driver"
comptime GRACE_MS = 1500
comptime SHORT_GRACE_MS = 300
comptime LONG_GRACE_MS = 10_000
comptime STOP_BOUND_MS = 1000
comptime LARGEST_GRACE_MS = 86_400_000
comptime ALREADY_SERVING = "Server.serve is already serving in this process"


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
        _default_sigpipe()
        if restore > 0:
            # signal(restore, SIG_DFL); SIG_DFL is 0 on Linux and macOS.
            _ = external_call["signal", Int](c_int(restore), Int(0))
        try:
            server.serve(app)
        except e:
            print("server child: serve failed:", e)
        exit(1)
    return _Child(pid, port)


def _default_sigpipe():
    """Gives a forked serving child SIGPIPE's default disposition back: the
    runner ignores it (`main`), and a child must not inherit that."""
    _ = external_call["signal", Int](c_int(SIGPIPE), Int(0))


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
        _default_sigpipe()
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
        _default_sigpipe()
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
    # Flare's own wrapper: its declaration of `pipe` (used for the macOS
    # reactor's wakeup) is the one a program may have.
    if Int(_flare_pipe(fds.unsafe_ptr())) != 0:
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
    child exits 0 when `serve` returns with the SIGTERM and SIGINT
    dispositions it had before (the runtime's handler) and a second `serve`
    on the closed listener raises with them back too; 1 when the first
    raises, 4 or 6 when the dispositions differ after the first or the
    second, 5 when the second returns, and 7 when the second is refused as
    already serving (the first did not release the process's claim)."""
    return _fork_stoppable(
        Server.bind("127.0.0.1", 0, shutdown_grace_ms=grace_ms), app
    )


def _fork_stoppable(var server: Server, app: App) raises -> _Child:
    """`_serve_stoppable`'s child, for a `Server` the caller bound; the
    parent's copy of the listener is dropped when this returns."""
    var port = server.port()
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        _default_sigpipe()
        var term = _handler_word(SIGTERM)
        var int = _handler_word(SIGINT)
        try:
            server.serve(app)
        except e:
            print("server child: serve failed:", e)
            exit(1)
        if _handler_word(SIGTERM) != term or _handler_word(SIGINT) != int:
            exit(4)
        # The listener is closed now, so serving again raises; the
        # dispositions must be back after that path too.
        try:
            server.serve(app)
            exit(5)
        except e:
            if String(e) == ALREADY_SERVING:
                exit(7)
        if _handler_word(SIGTERM) != term or _handler_word(SIGINT) != int:
            exit(6)
        exit(0)
    return _Child(pid, port)


def _handler_word(sig: Int) -> Int:
    """The handler of `sig`'s current disposition, as `sigaction` reports it
    (the first word of `struct sigaction` on Linux and macOS)."""
    var action = List[UInt8](length=256, fill=0)
    _ = external_call["sigaction", c_int](
        c_int(sig), 0, Int(action.unsafe_ptr())
    )
    var word = action.unsafe_ptr().unsafe_bitcast[Int]()[]
    _ = action^
    return word


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
        assert_true(dropped[1] == "reset" or dropped[1] == "eof", dropped[1])
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


def _stops_idle(sig: Int, grace_ms: Int = SHORT_GRACE_MS) raises:
    """With no request in flight, `sig` ends the serving child with status 0
    after the grace window and within the bound."""
    var app = borrowed_app()
    var child = _serve_stoppable(app, grace_ms)
    var reaped = False
    try:
        # One answer shows the child is in `serve`.
        var raw = _exchange(child.port, _request("GET", "/hello"))
        assert_equal(_content(raw), "hello")
        var signaled_at = monotonic_now_ms()
        assert_equal(kill(child.pid, sig), 0)
        var ended = _reap_within(child.pid, grace_ms + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        var after = monotonic_now_ms() - signaled_at
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
        assert_true(after >= grace_ms, "ended before the window")
    finally:
        if not reaped:
            _stop(child.pid)


def test_sigterm_stops_an_idle_server() raises:
    _stops_idle(SIGTERM)


def test_sigint_stops_an_idle_server() raises:
    _stops_idle(SIGINT)


def test_zero_grace_stops_at_the_next_turn() raises:
    """`shutdown_grace_ms=0`: no window; the reactor leaves its loop within
    its 100 ms poll."""
    _stops_idle(SIGTERM, 0)


def stop_self() raises -> String:
    """Asks its own server to stop, as an application can without a stop
    call."""
    var pid = external_call["getpid", c_int]()
    if Int(external_call["kill", c_int](pid, c_int(SIGTERM))) != 0:
        raise Error("kill failed")
    return "stopping"


def test_a_handler_can_stop_its_own_server() raises:
    """A handler that sends its own process SIGTERM is answered, and the
    server then stops as for an outside SIGTERM."""
    var app = borrowed_app()
    app.get["/stop"](stop_self)
    var child = _serve_stoppable(app, SHORT_GRACE_MS)
    var reaped = False
    try:
        var raw = _exchange(child.port, _request("GET", "/stop"))
        assert_equal(_status_line(raw), "HTTP/1.1 200 OK")
        assert_equal(_content(raw), "stopping")
        assert_true(_refused_within(child.port, 1000) >= 0)
        var ended = _reap_within(child.pid, SHORT_GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        print(
            "observed: self stop -> status", ended[0], "after", ended[1], "ms"
        )
        assert_equal(_exit_code(ended[0]), 0, "serve did not return")
    finally:
        if not reaped:
            _stop(child.pid)


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
        var signaled_at = monotonic_now_ms()
        assert_equal(kill(child.pid, SIGTERM), 0)
        var ended = _reap_within(
            child.pid, SHORT_GRACE_MS + STOP_BOUND_MS + 1000
        )
        reaped = ended[0] >= 0
        var after = monotonic_now_ms() - signaled_at
        print(
            "observed: stuck handler -> status",
            ended[0],
            "after",
            ended[1],
            "ms",
        )
        assert_equal(_exit_code(ended[0]), 128 + SIGTERM)
        assert_true(
            after >= SHORT_GRACE_MS + STOP_BOUND_MS, "ended before the bound"
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
    during the window is answered too (observed). The client acknowledges
    the server's SETTINGS (RFC 9113 section 6.5.3), and the connection must
    end by a close or a reset within the window plus the bound, not by the
    read timing out."""
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
        stream.write_all(Span[UInt8, _](wire))
        # Read and acknowledge the server's SETTINGS before opening stream 1:
        # once its handler holds the reactor, Flare writes nothing more.
        var acc = List[UInt8]()
        var buf = List[UInt8](length=4096, fill=0)
        var acked = False
        var scan = 0
        while not acked:
            var maybe = parse_frame(Span[UInt8, _](acc)[scan:])
            if not maybe:
                var n = stream.read(buf.unsafe_ptr(), len(buf))
                if n == 0:
                    raise Error("closed before the server's SETTINGS")
                for i in range(n):
                    acc.append(buf[i])
                continue
            var f = maybe.value().copy()
            scan += 9 + f.header.length
            if (
                f.header.type.value == FrameType.SETTINGS().value
                and f.header.stream_id == 0
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
                acked = True
        stream.write_all(Span[UInt8, _](_h2_get(1, held.path)))
        assert_equal(_read_byte(held.started), 1, "the handler never started")
        var signaled_at = monotonic_now_ms()
        assert_equal(kill(child.pid, SIGTERM), 0)
        assert_true(_refused_within(child.port, 1000) >= 0)
        stream.write_all(Span[UInt8, _](_h2_get(3, "/hello")))
        _write_byte(held.release)
        var how = String("eof")
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
            # Every complete frame so far (the SETTINGS were acked above).
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
            try:
                var n = stream.read(buf.unsafe_ptr(), len(buf))
                if n == 0:
                    break
                for i in range(n):
                    acc.append(buf[i])
            except e:
                how = "reset" if _is_reset(String(e)) else String(e)
                break
        var closed_after = monotonic_now_ms() - signaled_at
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
        assert_true(how == "eof" or how == "reset", how)
        assert_true(
            closed_after <= GRACE_MS + STOP_BOUND_MS,
            "the h2c connection outlived the window and the bound",
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


def _cstr(s: String) -> List[UInt8]:
    var out = List[UInt8](s.as_bytes())
    out.append(0)
    return out^


def _exec_driver(grace_ms: Int, ignore_sigint: Bool) raises -> _Child:
    """Forks and `execv`s `build/stop_driver <grace_ms>` (built by
    scripts/check_flare.sh), a whole Mojo program with the runtime's worker
    threads and handlers, and reads the port it prints. With
    `ignore_sigint` the program starts with SIGINT ignored, as a background
    job of a non-interactive shell does. The caller must reap `pid`."""
    var out = _pipe()
    var path = _cstr(DRIVER)
    var grace = _cstr(String(grace_ms))
    var args = List[Int]()
    args.append(Int(path.unsafe_ptr()))
    args.append(Int(grace.unsafe_ptr()))
    args.append(0)
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["dup2", c_int](c_int(out[1]), c_int(1))
        _close(out[0])
        _default_sigpipe()
        # Survives execve: a driver that stalls before printing its port, or
        # outlives the runner, still ends.
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        if ignore_sigint:
            _ = external_call["signal", Int](c_int(SIGINT), Int(1))  # SIG_IGN
        _ = external_call["execv", c_int](
            Int(path.unsafe_ptr()), Int(args.unsafe_ptr())
        )
        _ = path^
        _ = grace^
        _ = args^
        exit(127)
    _close(out[1])
    var line = String()
    try:
        while True:
            var byte = List[UInt8](length=1, fill=0)
            var source = FileDescriptor(out[0])
            if source.read_bytes(byte) != 1 or byte[0] == UInt8(ord("\n")):
                break
            line += chr(Int(byte[0]))
        _close(out[0])
        if line == "":
            raise Error("build/stop_driver printed no port")
        return _Child(pid, atol(line))
    except e:
        _close(out[0])
        _stop(pid)
        raise e^


def test_a_built_program_finishes_the_request_in_flight() raises:
    """The stop as an application gets it: an `execv`d program, with the
    runtime's threads (any of which may take the signal) and its handlers,
    answers a request held when SIGTERM arrives and ends by returning from
    `main`, with status 0."""
    var pipes = _held_pipes()
    var held = pipes[0].copy()
    var child: _Child
    try:
        child = _exec_driver(GRACE_MS, False)
    finally:
        _close(pipes[1])
        _close(pipes[2])
    var reaped = False
    try:
        var in_flight = _send(child.port, _request("GET", held.path))
        assert_equal(_read_byte(held.started), 1, "the handler never started")
        assert_equal(kill(child.pid, SIGTERM), 0)
        assert_true(_refused_within(child.port, 1000) >= 0)
        _write_byte(held.release)
        var got = _read_all(in_flight)
        assert_equal(_status_line(got[0]), "HTTP/1.1 200 OK")
        assert_equal(_content(got[0]), "released after the stop")
        var ended = _reap_within(child.pid, GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        print(
            "observed: built program, SIGTERM -> status",
            ended[0],
            "after",
            ended[1],
            "ms",
        )
        assert_equal(_exit_code(ended[0]), 0, "main did not return")
    finally:
        if not reaped:
            _stop(child.pid)
        _close(held.started)
        _close(held.release)


def test_a_built_program_stops_on_an_inherited_ignored_sigint() raises:
    """A program started with SIGINT ignored still stops on SIGINT while it
    serves (`serve` installs its handler whatever the disposition was)."""
    var child = _exec_driver(SHORT_GRACE_MS, True)
    var reaped = False
    try:
        var raw = _exchange(child.port, _request("GET", "/hello"))
        assert_equal(_content(raw), "hello")
        assert_equal(kill(child.pid, SIGINT), 0)
        var ended = _reap_within(child.pid, SHORT_GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        print(
            "observed: built program, inherited SIG_IGN, SIGINT -> status",
            ended[0],
        )
        assert_equal(_exit_code(ended[0]), 0, "main did not return")
    finally:
        if not reaped:
            _stop(child.pid)


def serve_again() raises -> String:
    """Binds a second `Server` and serves it from inside a handler of the
    first, which is serving: the text `serve` raises, or `served`."""
    var inner = App()
    inner.get["/"](hello)
    var second = Server.bind("127.0.0.1", 0)
    try:
        second.serve(inner)
    except e:
        return String(e)
    return "served"


def test_a_second_serve_in_the_process_is_refused() raises:
    """SIGTERM and SIGINT dispositions are process-wide, so while one `serve`
    runs, another `serve` in the same process (here from inside one of its
    handlers) raises `Server.serve is already serving in this process`
    before touching them; the first one then still stops on SIGTERM with
    the dispositions it replaced put back (`_serve_stoppable` exits 0)."""
    var app = borrowed_app()
    app.get["/again"](serve_again)
    var child = _serve_stoppable(app, SHORT_GRACE_MS)
    var reaped = False
    try:
        var raw = _exchange(child.port, _request("GET", "/again"))
        print("observed: serve inside serve ->", repr(_content(raw)))
        assert_equal(_status_line(raw), "HTTP/1.1 200 OK")
        assert_equal(_content(raw), ALREADY_SERVING)
        assert_equal(kill(child.pid, SIGTERM), 0)
        var ended = _reap_within(child.pid, SHORT_GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        assert_equal(_exit_code(ended[0]), 0, "the first serve did not stop")
    finally:
        if not reaped:
            _stop(child.pid)


def _no_stage(stage: Int):
    pass


def _term_when_installed(stage: Int):
    """SIGTERM to this process once both stop handlers are installed, before
    the watcher starts."""
    if stage == _STAGE_INSTALLED:
        _ = external_call["kill", c_int](
            external_call["getpid", c_int](), c_int(SIGTERM)
        )


def _term_before_flare_serves(stage: Int):
    """SIGTERM once the watcher runs, before Flare's `serve` is called, then
    waits (up to 2 s) until the watcher has acted: it resets SIGINT to
    `SIG_DFL` right before `drain`, whose first step closes the listener, so
    50 ms after that reset Flare's `serve` meets a closed listener and
    raises."""
    if stage == _STAGE_WATCHING:
        _ = external_call["kill", c_int](
            external_call["getpid", c_int](), c_int(SIGTERM)
        )
        var start = monotonic_now_ms()
        while _handler_word(SIGINT) != 0 and monotonic_now_ms() - start < 2000:
            _ = libc_nanosleep_ms(5)
        _ = libc_nanosleep_ms(50)


def _term_after_flare_served(stage: Int):
    """SIGTERM after Flare's `serve` ended, while the watcher still runs."""
    if stage == _STAGE_SERVED:
        _ = external_call["kill", c_int](
            external_call["getpid", c_int](), c_int(SIGTERM)
        )


def _term_after_join(stage: Int):
    """SIGTERM after the watcher was joined, before the restore."""
    if stage == _STAGE_JOINED:
        _ = external_call["kill", c_int](
            external_call["getpid", c_int](), c_int(SIGTERM)
        )


def _serve_twice_with_stages(
    first: def(Int) thin -> None, second: def(Int) thin -> None
) raises -> _Child:
    """A forked child that serves `borrowed_app()` with `first` as `serve`'s
    `_stage` hook, then serves the same `Server` again (its listener is
    closed, so Flare's `serve` raises at once) with `second`. Exits 11 if
    the first raises, 4 if the dispositions differ after it, 20 if the
    second returns, 22 if the second is refused as already serving, 6 if
    the dispositions differ after it, else 21. The caller must reap `pid`.
    """
    var app = borrowed_app()
    var server = Server.bind("127.0.0.1", 0, shutdown_grace_ms=SHORT_GRACE_MS)
    var port = server.port()
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        _default_sigpipe()
        var term = _handler_word(SIGTERM)
        var int = _handler_word(SIGINT)
        try:
            server.serve(app, _stage=first)
        except e:
            print("stage child: first serve raised:", e)
            exit(11)
        if _handler_word(SIGTERM) != term or _handler_word(SIGINT) != int:
            exit(4)
        try:
            server.serve(app, _stage=second)
            exit(20)
        except e:
            if String(e) == ALREADY_SERVING:
                exit(22)
        if _handler_word(SIGTERM) != term or _handler_word(SIGINT) != int:
            exit(6)
        exit(21)
    return _Child(pid, port)


def _stage_outcome(
    first: def(Int) thin -> None, second: def(Int) thin -> None
) raises -> Int:
    """`_serve_twice_with_stages`'s raw `waitpid` status, or -1 if the child
    outlived its bound (and was killed)."""
    var child = _serve_twice_with_stages(first, second)
    return _reap_within(child.pid, 2 * (SHORT_GRACE_MS + STOP_BOUND_MS))[0]


def test_a_stop_before_the_watcher_starts_is_acted_on() raises:
    """A SIGTERM delivered between the handlers' install and the watcher's
    start is seen by the watcher: the first `serve` returns, with the
    dispositions back and the process's claim released (the second `serve`
    raises on the closed listener, not as already serving)."""
    var status = _stage_outcome(_term_when_installed, _no_stage)
    print("observed: SIGTERM at stage installed -> status", status)
    assert_equal(_exit_code(status), 21)


def test_a_stop_before_flare_serves_returns() raises:
    """A stop acted on before Flare's `serve` runs closes the listener under
    it, so Flare's `serve` raises; `serve` returns as for any stop."""
    var status = _stage_outcome(_term_before_flare_serves, _no_stage)
    print("observed: SIGTERM at stage watching -> status", status)
    assert_equal(_exit_code(status), 21)


def test_a_stop_as_flare_serve_ends_is_not_lost() raises:
    """A SIGTERM after Flare's `serve` ended for another reason (it raised on
    the closed listener), while the watcher still runs: either the watcher
    acts on it and `serve` returns, or it is sent again once the previous
    dispositions are back and ends the process. Never a hang, a crash or a
    lost signal."""
    var status = _stage_outcome(_term_when_installed, _term_after_flare_served)
    print("observed: SIGTERM at stage served -> status", status)
    assert_true(
        _exit_code(status) == 20 or (status >= 0 and status & 0x7F == SIGTERM),
        String(status),
    )


def test_a_stop_after_the_watcher_is_joined_is_sent_again() raises:
    """A SIGTERM after the watcher was joined, before the restore, is
    absorbed by the stop handler; `serve` sends it again once the previous
    dispositions (the runtime's handler) are back, and it ends the
    process."""
    var status = _stage_outcome(_term_when_installed, _term_after_join)
    print("observed: SIGTERM at stage joined -> status", status)
    assert_true(status >= 0, "the child outlived its bound")
    assert_equal(status & 0x7F, SIGTERM, "the signal was lost")


def _reset_on_delivery(sig: c_int) abi("C"):
    """A handler that sets its signal back to `SIG_DFL` itself (`signal` is
    async-signal-safe), so a delivery shows in the disposition. Not
    `SA_RESETHAND`: macOS does not report that flag in the disposition
    `serve` saves, so putting it back drops the flag."""
    _ = external_call["signal", Int](sig, Int(0))


def _install_reset_on_delivery(sig: Int) -> Int:
    """Gives `sig` the `_reset_on_delivery` handler. Returns `signal`'s
    result (-1 on failure)."""
    var handler: def(c_int) thin abi("C") -> None = _reset_on_delivery
    return Int(
        external_call["signal", Int](
            c_int(sig), Pointer(to=handler).unsafe_bitcast[Int]()[]
        )
    )


def _term_after_join_then_check_order(stage: Int):
    """SIGTERM after the join, as `_term_after_join`; then, at the stage
    after the restore and the resend, exits 30 if the serving claim is
    already released, or 32 if the resent SIGTERM has not reached the
    previous disposition (it resets to `SIG_DFL` on delivery) within 1 s:
    the resend reaches this thread before `raise` returns, so the wait is
    only a margin inside the reap bound.
    """
    if stage == _STAGE_JOINED:
        _ = external_call["kill", c_int](
            external_call["getpid", c_int](), c_int(SIGTERM)
        )
    if stage == _STAGE_RESTORED:
        if not _serving_held():
            exit(30)
        var start = monotonic_now_ms()
        while _handler_word(SIGTERM) != 0:
            if monotonic_now_ms() - start >= 1000:
                exit(32)
            _ = libc_nanosleep_ms(5)


def test_a_stop_sent_again_is_sent_before_the_claim_is_released() raises:
    """The resend of a late SIGTERM happens while this `serve` still holds
    the process's claim, so no later `serve` can have installed its handler
    when it is sent. The child gives SIGTERM a handler that resets itself
    on delivery, so the resend is seen and does not end it; after `serve`
    raises (the listener is closed) the claim must be released."""
    var app = borrowed_app()
    var server = Server.bind("127.0.0.1", 0, shutdown_grace_ms=SHORT_GRACE_MS)
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        _default_sigpipe()
        if _install_reset_on_delivery(SIGTERM) == -1:
            exit(33)
        try:
            server.serve(app, _stage=_term_when_installed)
        except e:
            print("order child: first serve raised:", e)
            exit(11)
        try:
            server.serve(app, _stage=_term_after_join_then_check_order)
            exit(20)
        except e:
            if String(e) == ALREADY_SERVING:
                exit(22)
        if _serving_held():
            exit(31)
        exit(21)
    var status = _reap_within(pid, 2 * (SHORT_GRACE_MS + STOP_BOUND_MS))[0]
    print("observed: resend before release -> status", status)
    assert_equal(_exit_code(status), 21)


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


# ── Head-of-line blocking (M3-046) ─────────────────────────────────────────


comptime HOLD_PROBE_MS = 1000
"""How long a blocking test keeps the first request's handler held after the
second request was sent, waiting for the second one's answer. It is longer
than Flare v0.12.0's default `idle_timeout_ms` (500), on purpose: the tests
with the default configuration pin what a hold that long does to connections
that wait meanwhile. What each test asserts about progress is the order in
which the handlers ran (a pipe they all write to, read after the child
ended), which does not depend on time; the wait is how long a server that
did serve the second request meanwhile has to show it on the wire."""

comptime PATIENT_IDLE_MS = 60_000
"""`idle_timeout_ms` of `_FLARE_PATIENT` and `_MUNTIN_PATIENT`: far longer
than any test's hold, so Flare's idle timer closes no connection during it."""


def held_in_order(started: Int, release: Int) raises -> String:
    """As `held`, and writes `a` to the pipe `started` once released, just
    before it returns."""
    var out = FileDescriptor(started)
    out.write_bytes("s".as_bytes())
    var byte = List[UInt8](length=1, fill=0)
    var source = FileDescriptor(release)
    if source.read_bytes(byte) != 1:
        raise Error("held_in_order: not released")
    out.write_bytes("a".as_bytes())
    return "released"


def mark(order: Int) raises -> String:
    """Writes `b` to the pipe `order`: the second request's handler ran."""
    var out = FileDescriptor(order)
    out.write_bytes("b".as_bytes())
    return "marked"


def blocking_app() -> App:
    var app = App()
    app.get["/hello"](hello)
    app.get["/hold/{started}/{release}"](held_in_order)
    app.get["/mark/{order}"](mark)
    return app^


struct _FlareHold(Handler):
    """The routes of `blocking_app` as a Flare handler with no Muntin code,
    to tell Flare's behavior apart from Muntin's."""

    def __init__(out self):
        pass

    def serve(self, request: FlareRequest) raises -> FlareResponse:
        var parts = request.url.split("/")
        var body = String("hello")
        if len(parts) == 4 and parts[1] == "hold":
            body = held_in_order(Int(parts[2]), Int(parts[3]))
        elif len(parts) == 3 and parts[1] == "mark":
            body = mark(Int(parts[2]))
        return FlareResponse(status=200, body=List(body.as_bytes()))


comptime _MUNTIN = 0
"""`_serve_blocking`: the adapter's `Server` serving `blocking_app`, as an
application gets it (Flare's default `idle_timeout_ms`)."""
comptime _FLARE = 1
"""`_serve_blocking`: Flare's own single-worker `HttpServer` serving
`_FlareHold`, with Flare's default configuration."""
comptime _FLARE_PATIENT = 2
"""`_serve_blocking`: as `_FLARE`, with `idle_timeout_ms` set to
`PATIENT_IDLE_MS`, so only the serial dispatch shows."""
comptime _MUNTIN_PATIENT = 3
"""`_serve_blocking`: the adapter's `Server` bound with
`idle_timeout_ms=PATIENT_IDLE_MS` (M3-047), served as `_MUNTIN`."""
comptime _WORKERS = 4
"""`_serve_blocking`: the adapter's `Server` with Flare's default
`idle_timeout_ms`, served by `serve[blocking_app](workers=WORKERS)`
(M3-049)."""
comptime _WORKERS_PATIENT = 5
"""`_serve_blocking`: as `_WORKERS`, bound with
`idle_timeout_ms=PATIENT_IDLE_MS`."""


def _serve_blocking(kind: Int) raises -> _Child:
    """A child serving the blocking routes on an ephemeral loopback port:
    with `_MUNTIN` or `_MUNTIN_PATIENT`, as `_serve_stoppable` (it exits 0
    after a graceful stop); with `_WORKERS` or `_WORKERS_PATIENT`, as
    `_fork_workers`; otherwise Flare's single-worker `serve` (ended by
    `_end_blocking`)."""
    if kind == _MUNTIN:
        return _serve_stoppable(blocking_app(), SHORT_GRACE_MS)
    if kind == _MUNTIN_PATIENT:
        return _fork_stoppable(
            Server.bind(
                "127.0.0.1",
                0,
                shutdown_grace_ms=SHORT_GRACE_MS,
                idle_timeout_ms=PATIENT_IDLE_MS,
            ),
            blocking_app(),
        )
    if kind == _WORKERS:
        return _fork_workers[blocking_app](
            Server.bind("127.0.0.1", 0, shutdown_grace_ms=SHORT_GRACE_MS),
            WORKERS,
        )
    if kind == _WORKERS_PATIENT:
        return _fork_workers[blocking_app](
            Server.bind(
                "127.0.0.1",
                0,
                shutdown_grace_ms=SHORT_GRACE_MS,
                idle_timeout_ms=PATIENT_IDLE_MS,
            ),
            WORKERS,
        )
    var config = ServerConfig()
    if kind == _FLARE_PATIENT:
        config.idle_timeout_ms = PATIENT_IDLE_MS
    var server = HttpServer.bind(SocketAddr.localhost(0), config^)
    var port = Int(server.local_addr().port)
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        _default_sigpipe()
        try:
            server.serve(_FlareHold())
        except e:
            print("flare child: serve failed:", e)
        exit(1)
    return _Child(pid, port)


def _end_blocking(kind: Int, pid: Int) raises -> Bool:
    """Ends a `_serve_blocking` child within a bound and says whether it was
    reaped: a `Server` child by SIGTERM, which must end it
    with status 0 (it was still serving normally); Flare's own server, which
    has no graceful stop here, by SIGKILL, which must end it by that
    signal."""
    if kind != _FLARE and kind != _FLARE_PATIENT:
        assert_equal(kill(pid, SIGTERM), 0)
        var ended = _reap_within(pid, SHORT_GRACE_MS + STOP_BOUND_MS)
        assert_equal(_exit_code(ended[0]), 0, "the server did not stop")
        return ended[0] >= 0
    assert_equal(kill(pid, SIGKILL), 0)
    var ended = _reap_within(pid, STOP_BOUND_MS)
    assert_true(ended[0] >= 0, "the Flare child was not reaped")
    assert_equal(ended[0] & 0x7F, SIGKILL, "the Flare child was not killed")
    return True


def _rest_of_pipe(fd: Int) raises -> String:
    """Every byte left in the pipe `fd` until EOF. Call it only once the
    child, the only other writer, has ended, so the read cannot block."""
    var out = String()
    var byte = List[UInt8](length=1, fill=0)
    var source = FileDescriptor(fd)
    while source.read_bytes(byte) == 1:
        out += chr(Int(byte[0]))
    return out^


def _answer_within(mut stream: TcpStream, ms: Int) raises -> String:
    """The bytes of one read that returns within `ms`, or `""` if the read
    timed out. A close or a reset raises: the connection must stay open
    while the first request is held."""
    stream.set_recv_timeout(ms)
    var buf = List[UInt8](length=4096, fill=0)
    var got = String()
    try:
        var n = stream.read(buf.unsafe_ptr(), len(buf))
        if n == 0:
            raise Error("closed while the first request was held")
        got = String(from_utf8_lossy=Span(buf)[:n])
    except e:
        if not String(e).startswith("Timeout"):
            raise e^
    stream.set_recv_timeout(TIMEOUT_MS)
    return got^


def _one_response(mut stream: TcpStream) raises -> String:
    """One HTTP/1.1 response that declares its content length, read from a
    connection that stays open after it."""
    var out = List[UInt8]()
    var buf = List[UInt8](length=1, fill=0)
    while True:
        var n = stream.read(buf.unsafe_ptr(), 1)
        if n == 0:
            raise Error("closed before a whole response")
        out.append(buf[0])
        var text = String(from_utf8_lossy=Span(out))
        var end = text.find("\r\n\r\n")
        if end < 0:
            continue
        var at = text.find("Content-Length: ")
        if at < 0:
            raise Error("no Content-Length: " + text)
        var stop = text.find("\r\n", at)
        var declared = Int(String(text[byte = at + 16 : stop]))
        if text.byte_length() - (end + 4) == declared:
            return text^


def _h1_blocks_other_connections(kind: Int) raises:
    """Over HTTP/1.1, while connection A's handler is held, a light request
    is not answered, neither on a keep-alive connection Flare accepted and
    answered before the hold nor on one opened during it. With a hold longer
    than Flare's idle timeout, once A's handler returns the keep-alive
    connection is closed with its request unread (no answer; its handler
    never runs), A's own keep-alive connection is closed right after its
    answer, and the new connection, still queued by the system, is
    answered; with `_FLARE_PATIENT` or `_MUNTIN_PATIENT` both are answered.
    Either way no handler runs before A's returned: the order pipe reads `a`
    first."""
    var patient = (
        kind == _FLARE_PATIENT
        or kind == _MUNTIN_PATIENT
        or kind == _WORKERS_PATIENT
    )
    var pipes = _held_pipes()
    var child = _serve_blocking(kind)
    _close(pipes[1])
    _close(pipes[2])
    var held = pipes[0].copy()
    var reaped = False
    try:
        var mark_path = "/mark/" + String(pipes[1])
        var hold_path = held.path.replace("/held/", "/hold/")
        var open = TcpStream.connect(SocketAddr.localhost(UInt16(child.port)))
        open.set_recv_timeout(TIMEOUT_MS)
        open.write_all("GET /hello HTTP/1.1\r\nHost: muntin\r\n\r\n".as_bytes())
        assert_equal(_content(_one_response(open)), "hello")
        # Keep-alive, so how the held connection ends after its answer shows.
        var a = _send(
            child.port,
            "GET " + hold_path + " HTTP/1.1\r\nHost: muntin\r\n\r\n",
        )
        assert_equal(_read_byte(held.started), 1, "the handler never started")
        open.write_all(_request("GET", mark_path).as_bytes())
        var fresh = _send(child.port, _request("GET", mark_path))
        var early_open = _answer_within(open, HOLD_PROBE_MS)
        var early_fresh = _answer_within(fresh, HOLD_PROBE_MS)
        _write_byte(held.release)
        var got_a = _one_response(a)
        var a_after = String("open")
        if not patient:
            a_after = _read_all(a)[1]
        var got_open = _read_all(open)
        var got_fresh = _read_all(fresh)
        reaped = _end_blocking(kind, child.pid)
        var order = _rest_of_pipe(held.started)
        print(
            "observed: kind",
            kind,
            "h1 while held: keep-alive",
            repr(early_open),
            "new",
            repr(early_fresh),
            "| after: held",
            repr(_content(got_a)),
            "then",
            a_after,
            "keep-alive",
            repr(_content(got_open[0])),
            got_open[1],
            "new",
            repr(_content(got_fresh[0])),
            "| handler order",
            repr(order),
        )
        assert_equal(early_open, "", "a keep-alive connection was answered")
        assert_equal(early_fresh, "", "a new connection was answered")
        assert_equal(_content(got_a), "released")
        assert_equal(_content(got_fresh[0]), "marked")
        if patient:
            assert_equal(_content(got_open[0]), "marked")
            assert_equal(order, "abb")
        else:
            # The held connection's idle timer was armed from the clock as
            # it was before the hold, so it is closed right after its answer.
            assert_true(a_after == "reset" or a_after == "eof", a_after)
            assert_equal(got_open[0], "", "the keep-alive request was answered")
            assert_true(
                got_open[1] == "reset" or got_open[1] == "eof", got_open[1]
            )
            assert_equal(order, "ab")
    finally:
        if not reaped:
            _stop(child.pid)
        _close(held.started)
        _close(held.release)


def test_h1_a_held_handler_blocks_other_connections() raises:
    _h1_blocks_other_connections(_MUNTIN)


def test_h1_flare_alone_blocks_other_connections() raises:
    _h1_blocks_other_connections(_FLARE)


def test_h1_flare_alone_serializes_handlers() raises:
    _h1_blocks_other_connections(_FLARE_PATIENT)


struct _H2Client(Movable):
    """A prior-knowledge h2c client connection that has exchanged SETTINGS
    with the server (each side's acknowledged), with what it has read so
    far and each stream's answer: `answers[(sid - 1) // 2]` is
    `"<status> <body>"` once that stream ended, else `""`."""

    var stream: TcpStream
    var acc: List[UInt8]
    var pos: Int
    var decoder: HpackDecoder
    var statuses: List[String]
    var bodies: List[String]
    var answers: List[String]

    def __init__(out self, port: Int) raises:
        self.stream = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
        self.stream.set_recv_timeout(TIMEOUT_MS)
        self.acc = List[UInt8]()
        self.pos = 0
        self.decoder = HpackDecoder()
        self.statuses = List[String](length=4, fill="")
        self.bodies = List[String](length=4, fill="")
        self.answers = List[String](length=4, fill="")
        var wire = List(H2_PREFACE.as_bytes())
        wire.extend(Span(_h2_frame(FrameType.SETTINGS(), 0, 0, List[UInt8]())))
        self.stream.write_all(Span[UInt8, _](wire))
        var buf = List[UInt8](length=4096, fill=0)
        while True:
            var maybe = parse_frame(Span[UInt8, _](self.acc)[self.pos :])
            if not maybe:
                var n = self.stream.read(buf.unsafe_ptr(), len(buf))
                if n == 0:
                    raise Error("closed before the server's SETTINGS")
                for i in range(n):
                    self.acc.append(buf[i])
                continue
            var f = maybe.value().copy()
            self.pos += 9 + f.header.length
            if (
                f.header.type.value == FrameType.SETTINGS().value
                and f.header.stream_id == 0
                and not f.header.flags.has(FrameFlags.ACK())
            ):
                self.stream.write_all(
                    Span[UInt8, _](
                        _h2_frame(
                            FrameType.SETTINGS(),
                            FrameFlags.ACK(),
                            0,
                            List[UInt8](),
                        )
                    )
                )
                return

    def get(mut self, sid: Int, path: String) raises:
        self.stream.write_all(Span[UInt8, _](_h2_get(sid, path)))

    def set_timeout(mut self, ms: Int) raises:
        """How long one read in `read_within` may wait. Set it only while the
        connection is open: on macOS `setsockopt` fails with `EINVAL` on a
        connection the server has reset."""
        self.stream.set_recv_timeout(ms)

    def read_within(mut self, until: Int) raises -> String:
        """Reads frames until `until` streams have ended (`"ended"`), a
        read waits longer than the timeout (`"timeout"`), or the server
        closes (`"eof"`) or resets (`"reset"`) the connection."""
        var buf = List[UInt8](length=4096, fill=0)
        var how = String("ended")
        while True:
            while True:
                var maybe = parse_frame(Span[UInt8, _](self.acc)[self.pos :])
                if not maybe:
                    break
                var f = maybe.value().copy()
                self.pos += 9 + f.header.length
                var sid = f.header.stream_id
                if sid == 0 or sid > 7:
                    continue
                var i = (sid - 1) // 2
                if f.header.type.value == FrameType.HEADERS().value:
                    var fields = self.decoder.decode(Span[UInt8, _](f.payload))
                    self.statuses[i] = fields[0].value
                elif f.header.type.value == FrameType.DATA().value:
                    self.bodies[i] += String(from_utf8_lossy=Span(f.payload))
                else:
                    continue
                if f.header.flags.has(FrameFlags.END_STREAM()):
                    self.answers[i] = self.statuses[i] + " " + self.bodies[i]
            var ended = 0
            for answer in self.answers:
                if answer != "":
                    ended += 1
            if ended >= until:
                break
            try:
                var n = self.stream.read(buf.unsafe_ptr(), len(buf))
                if n == 0:
                    how = "eof"
                    break
                for i in range(n):
                    self.acc.append(buf[i])
            except e:
                if String(e).startswith("Timeout"):
                    how = "timeout"
                elif _is_reset(String(e)):
                    how = "reset"
                else:
                    raise e^
                break
        return how^


def _h2c_blocks_streams(kind: Int, same_connection: Bool) raises:
    """Over prior-knowledge h2c, while stream 1's handler is held, a light
    stream is not answered: stream 3 on the same connection, or stream 1 on
    another connection whose SETTINGS were exchanged before the hold. With a
    hold longer than Flare's idle timeout, once stream 1's handler returns
    its answer is sent and then the connection that carries the light
    stream is closed with it unread (no answer; its handler never runs);
    with `_FLARE_PATIENT` or `_MUNTIN_PATIENT` the light stream is answered
    after stream 1. No handler runs before stream 1's returned: the order
    pipe reads `a` first."""
    var patient = (
        kind == _FLARE_PATIENT
        or kind == _MUNTIN_PATIENT
        or kind == _WORKERS_PATIENT
    )
    var pipes = _held_pipes()
    var child = _serve_blocking(kind)
    _close(pipes[1])
    _close(pipes[2])
    var held = pipes[0].copy()
    var reaped = False
    try:
        var mark_path = "/mark/" + String(pipes[1])
        var hold_path = held.path.replace("/held/", "/hold/")
        var first = _H2Client(child.port)
        var other = _H2Client(child.port)
        first.get(1, hold_path)
        assert_equal(_read_byte(held.started), 1, "the handler never started")
        var early: String
        if same_connection:
            first.get(3, mark_path)
            first.set_timeout(HOLD_PROBE_MS)
            early = first.read_within(1)
        else:
            other.get(1, mark_path)
            other.set_timeout(HOLD_PROBE_MS)
            early = other.read_within(1)
        # Both connections are still open while stream 1 is held.
        first.set_timeout(TIMEOUT_MS)
        other.set_timeout(TIMEOUT_MS)
        var early_first = first.answers[0]
        var early_light = first.answers[
            1
        ] if same_connection else other.answers[0]
        _write_byte(held.release)
        # On the same connection, read on after stream 1 until stream 3
        # ends or the connection does.
        var after_first = first.read_within(2 if same_connection else 1)
        var after_other = String("")
        if not same_connection:
            after_other = other.read_within(1)
        var light = first.answers[1] if same_connection else other.answers[0]
        reaped = _end_blocking(kind, child.pid)
        var order = _rest_of_pipe(held.started)
        print(
            "observed: kind",
            kind,
            "h2c",
            "same connection" if same_connection else "other connection",
            "while held:",
            early,
            repr(early_light),
            "| after: stream 1",
            repr(first.answers[0]),
            after_first,
            "light",
            repr(light),
            after_other,
            "| handler order",
            repr(order),
        )
        assert_equal(early, "timeout", "the connection ended during the hold")
        assert_equal(early_first, "", "the held stream was answered")
        assert_equal(early_light, "", "the light stream was answered")
        assert_equal(first.answers[0], "200 released")
        if patient:
            assert_equal(light, "200 marked")
            assert_equal(order, "ab")
        else:
            assert_equal(light, "", "the light stream was answered")
            var end = after_first if same_connection else after_other
            assert_true(end == "reset" or end == "eof", end)
            assert_equal(order, "a")
    finally:
        if not reaped:
            _stop(child.pid)
        _close(held.started)
        _close(held.release)


def test_h2c_a_held_stream_blocks_its_connection() raises:
    _h2c_blocks_streams(_MUNTIN, True)


def test_h2c_a_held_stream_blocks_other_connections() raises:
    _h2c_blocks_streams(_MUNTIN, False)


def test_h2c_flare_alone_blocks_its_connection() raises:
    _h2c_blocks_streams(_FLARE, True)


def test_h2c_flare_alone_blocks_other_connections() raises:
    _h2c_blocks_streams(_FLARE, False)


def test_h2c_flare_alone_serializes_streams() raises:
    _h2c_blocks_streams(_FLARE_PATIENT, True)


def test_h2c_flare_alone_serializes_connections() raises:
    _h2c_blocks_streams(_FLARE_PATIENT, False)


# ── Idle timeout (M3-047) ──────────────────────────────────────────────────


comptime DEFAULT_IDLE_MS = 500
comptime LARGEST_IDLE_MS = 86_400_000
comptime LONGER_IDLE_MS = 3000
"""The idle timeout of the `Server` that `test_servers_keep_their_own_idle_timeouts`
binds beside one bound with none."""


def test_h1_a_longer_idle_timeout_answers_waiting_requests_after_the_hold() raises:
    """With `idle_timeout_ms` longer than the hold, the keep-alive request
    that waited behind the held handler is answered after it, never during
    it; with none given it is dropped
    (`test_h1_a_held_handler_blocks_other_connections`)."""
    _h1_blocks_other_connections(_MUNTIN_PATIENT)


def test_h2c_a_longer_idle_timeout_answers_its_connection_after_the_hold() raises:
    _h2c_blocks_streams(_MUNTIN_PATIENT, True)


def test_h2c_a_longer_idle_timeout_answers_other_connections_after_the_hold() raises:
    _h2c_blocks_streams(_MUNTIN_PATIENT, False)


def _bind_idle_error(host: String, port: Int, idle: Int) -> String:
    """The text `Server.bind(host, port, idle_timeout_ms=idle)` raises, or
    what it bound."""
    try:
        var server = Server.bind(host, port, idle_timeout_ms=idle)
        return "bound port " + String(server.port())
    except e:
        return String(e)


def test_bind_raises_for_an_idle_timeout_out_of_range() raises:
    """0 (Flare's "no idle timer"), negative values and values above one day
    raise before anything is bound: on a port a child serves the raise is
    the range, not `AddressInUse`, and on a host name it is the range, not
    the host. 1 and the largest value bind, and the bound `Server` holds
    the value."""
    var app = borrowed_app()
    var child = _serve_in_child(app, 0)
    try:
        for idle in [Int.MIN, -1, 0, LARGEST_IDLE_MS + 1, Int.MAX]:
            var error = _bind_idle_error("127.0.0.1", child.port, idle)
            print("observed: idle_timeout_ms", idle, "->", error)
            assert_equal(error, "idle_timeout_ms out of range: " + String(idle))
        assert_equal(
            _bind_idle_error("localhost", 0, 0),
            "idle_timeout_ms out of range: 0",
        )
    finally:
        _stop(child.pid)
    # Checked after the grace window.
    var error: String
    try:
        var server = Server.bind(
            "127.0.0.1", 0, shutdown_grace_ms=-1, idle_timeout_ms=0
        )
        error = "bound port " + String(server.port())
    except e:
        error = String(e)
    assert_equal(error, "shutdown_grace_ms out of range: -1")
    for idle in [1, LARGEST_IDLE_MS]:
        var server = Server.bind("127.0.0.1", 0, idle_timeout_ms=idle)
        assert_true(server.port() > 0)
        assert_equal(server._server.config.idle_timeout_ms, idle)


def test_server_config_sets_the_idle_timeout() raises:
    """`_server_config` writes the idle timeout into Flare's one field, which
    both protocols read, and changes nothing else; with none given the
    bound `Server` holds 500, Flare v0.12.0's default."""
    var flare = ServerConfig()
    assert_equal(flare.idle_timeout_ms, DEFAULT_IDLE_MS)
    assert_equal(_server_config(64).idle_timeout_ms, DEFAULT_IDLE_MS)
    var config = _server_config(64, 1234, 4321)
    assert_equal(config.idle_timeout_ms, 4321)
    assert_equal(config.max_body_size, 64)
    assert_equal(config.h2.max_body_size, 64)
    assert_equal(config.shutdown_timeout_ms, 1234)
    assert_equal(config.write_timeout_ms, flare.write_timeout_ms)
    assert_equal(config.read_body_timeout_ms, flare.read_body_timeout_ms)
    assert_equal(config.request_timeout_ms, flare.request_timeout_ms)
    var plain = Server.bind("127.0.0.1", 0)
    assert_equal(plain._server.config.idle_timeout_ms, DEFAULT_IDLE_MS)
    var set = Server.bind("127.0.0.1", 0, idle_timeout_ms=4321)
    assert_equal(set._server.config.idle_timeout_ms, 4321)


def _closed_after(mut stream: TcpStream, opened: Int) -> Tuple[Int, String]:
    """Milliseconds from `opened` until the server closed `stream`, and how
    the read ended (`eof`, `reset`, or the raise's text, a timeout
    included). Nothing may arrive on it first."""
    var got = _read_all(stream)
    if got[0] != "":
        return (-1, "answered: " + got[0])
    return (monotonic_now_ms() - opened, got[1])


def test_idle_timeout_closes_silent_partial_and_h2c_connections() raises:
    """With `idle_timeout_ms` 1,000, a connection that sends nothing, one that
    stops inside its HTTP/1.1 head, and an h2c connection idle after the
    SETTINGS exchange are each closed, with no answer, about 1,000 ms after
    their last bytes, not at the default's 500 (each opened and timed on its
    own), and so is an h2c stream that stops inside its body (h2c has no
    body timer). An HTTP/1.1 request that stops inside its body is not
    closed by it (Flare's body timer applies): that connection, opened
    first, is still open after the others closed."""
    var app = borrowed_app()
    var idle = 1000
    var child = _fork_stoppable(
        Server.bind(
            "127.0.0.1",
            0,
            shutdown_grace_ms=SHORT_GRACE_MS,
            idle_timeout_ms=idle,
        ),
        app,
    )
    var reaped = False
    try:
        var body = _send(
            child.port,
            (
                "POST /hello HTTP/1.1\r\nHost: muntin\r\nContent-Length:"
                " 100\r\n\r\n0123456789"
            ),
        )
        var body_at = monotonic_now_ms()
        var closed = List[Tuple[Int, String]]()
        var silent = TcpStream.connect(SocketAddr.localhost(UInt16(child.port)))
        silent.set_recv_timeout(TIMEOUT_MS)
        closed.append(_closed_after(silent, monotonic_now_ms()))
        var partial = _send(child.port, "GET /hello HTTP/1.1\r\nHost: mu")
        closed.append(_closed_after(partial, monotonic_now_ms()))
        var h2 = _H2Client(child.port)
        var h2_at = monotonic_now_ms()
        var h2_end = h2.read_within(1)
        closed.append((monotonic_now_ms() - h2_at, h2_end))
        var h2_body = _H2Client(child.port)
        var hdrs = List[HpackHeader]()
        hdrs.append(HpackHeader(":method", "POST"))
        hdrs.append(HpackHeader(":scheme", "http"))
        hdrs.append(HpackHeader(":path", "/hello"))
        hdrs.append(HpackHeader(":authority", "localhost"))
        hdrs.append(HpackHeader("content-length", "100"))
        var wire = _h2_frame(
            FrameType.HEADERS(),
            FrameFlags.END_HEADERS(),
            1,
            HpackEncoder().encode(Span[HpackHeader, _](hdrs)),
        )
        wire.extend(
            Span(
                _h2_frame(FrameType.DATA(), 0, 1, List("0123456789".as_bytes()))
            )
        )
        h2_body.stream.write_all(Span[UInt8, _](wire))
        var h2_body_at = monotonic_now_ms()
        var h2_body_end = h2_body.read_within(1)
        closed.append((monotonic_now_ms() - h2_body_at, h2_body_end))
        var body_open_for = monotonic_now_ms() - body_at
        var body_now: String
        try:
            body_now = _answer_within(body, 200)
        except e:
            body_now = "closed: " + String(e)
        print(
            "observed: idle_timeout_ms",
            idle,
            "-> silent closed",
            closed[0][1],
            "after",
            closed[0][0],
            "ms; partial head",
            closed[1][1],
            "after",
            closed[1][0],
            "ms; h2c",
            closed[2][1],
            "after",
            closed[2][0],
            "ms; h2c stalled body",
            closed[3][1],
            "after",
            closed[3][0],
            "ms; HTTP/1.1 stalled body after",
            body_open_for,
            "ms:",
            repr(body_now),
        )
        for c in closed:
            assert_true(c[1] == "eof" or c[1] == "reset", c[1])
            assert_true(c[0] >= idle - 100 and c[0] <= idle + 500, String(c[0]))
        assert_equal(
            h2_body.answers[0], "", "the stalled h2c stream was answered"
        )
        assert_equal(body_now, "", "the stalled HTTP/1.1 body was closed")
        assert_equal(kill(child.pid, SIGTERM), 0)
        var ended = _reap_within(child.pid, SHORT_GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        assert_equal(_exit_code(ended[0]), 0)
    finally:
        if not reaped:
            _stop(child.pid)


def _idle_close_ms(port: Int) raises -> Int:
    """Opens an HTTP/1.1 keep-alive connection, reads one answer, and
    returns how many milliseconds later the server closed it, or -1 if it
    was still open after `TIMEOUT_MS`."""
    var stream = _send(port, "GET /hello HTTP/1.1\r\nHost: muntin\r\n\r\n")
    assert_equal(_content(_one_response(stream)), "hello")
    var start = monotonic_now_ms()
    var got = _read_all(stream)
    var after = monotonic_now_ms() - start
    if got[1] != "eof" and got[1] != "reset":
        return -1
    assert_equal(got[0], "", "an answer after the first")
    return after


def test_servers_keep_their_own_idle_timeouts() raises:
    """Two `Server`s bound in one process, one with `LONGER_IDLE_MS` and one
    with none, each close an idle keep-alive connection after their own
    timeout (each serves in its own child; the first child also inherits the
    second's listener, which it never serves)."""
    var longer = Server.bind(
        "127.0.0.1",
        0,
        shutdown_grace_ms=SHORT_GRACE_MS,
        idle_timeout_ms=LONGER_IDLE_MS,
    )
    var plain = Server.bind("127.0.0.1", 0, shutdown_grace_ms=SHORT_GRACE_MS)
    assert_equal(longer._server.config.idle_timeout_ms, LONGER_IDLE_MS)
    assert_equal(plain._server.config.idle_timeout_ms, DEFAULT_IDLE_MS)
    var app = borrowed_app()
    var a = _fork_stoppable(longer^, app)
    var b = _Child(0, 0)
    var reaped_a = False
    var reaped_b = False
    try:
        b = _fork_stoppable(plain^, app)
        var closed_a = _idle_close_ms(a.port)
        var closed_b = _idle_close_ms(b.port)
        print(
            "observed: idle keep-alive closed after",
            closed_a,
            "ms (idle_timeout_ms",
            LONGER_IDLE_MS,
            ") and",
            closed_b,
            "ms (none given)",
        )
        assert_true(
            closed_a >= LONGER_IDLE_MS - 100
            and closed_a <= LONGER_IDLE_MS + 1000,
            String(closed_a),
        )
        assert_true(
            closed_b >= DEFAULT_IDLE_MS - 100
            and closed_b <= DEFAULT_IDLE_MS + 400,
            String(closed_b),
        )
        assert_equal(kill(a.pid, SIGTERM), 0)
        assert_equal(kill(b.pid, SIGTERM), 0)
        var ended_a = _reap_within(a.pid, SHORT_GRACE_MS + STOP_BOUND_MS)
        reaped_a = ended_a[0] >= 0
        var ended_b = _reap_within(b.pid, SHORT_GRACE_MS + STOP_BOUND_MS)
        reaped_b = ended_b[0] >= 0
        assert_equal(_exit_code(ended_a[0]), 0)
        assert_equal(_exit_code(ended_b[0]), 0)
    finally:
        if not reaped_a:
            _stop(a.pid)
        if not reaped_b and b.pid > 0:
            _stop(b.pid)


def test_sigterm_drains_within_its_window_with_a_longer_idle_timeout() raises:
    """With `idle_timeout_ms` far longer than `shutdown_grace_ms`, an idle
    HTTP/1.1 keep-alive connection and an idle h2c connection opened before
    SIGTERM stay open through the window (the idle timer does not close
    them) and are closed at its end; the child exits 0 within the time to
    see the signal, the window and the bound, as with the default."""
    var app = borrowed_app()
    var child = _fork_stoppable(
        Server.bind(
            "127.0.0.1",
            0,
            shutdown_grace_ms=GRACE_MS,
            idle_timeout_ms=PATIENT_IDLE_MS,
        ),
        app,
    )
    var reaped = False
    try:
        var ka = _send(
            child.port, "GET /hello HTTP/1.1\r\nHost: muntin\r\n\r\n"
        )
        assert_equal(_content(_one_response(ka)), "hello")
        var h2 = _H2Client(child.port)
        var signaled_at = monotonic_now_ms()
        assert_equal(kill(child.pid, SIGTERM), 0)
        var refused = _refused_within(child.port, 1000)
        assert_true(refused >= 0, "a new connection was still accepted")
        var got = _read_all(ka)
        var ka_closed = monotonic_now_ms() - signaled_at
        var h2_end = h2.read_within(1)
        var h2_closed = monotonic_now_ms() - signaled_at
        var ended = _reap_within(child.pid, GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        var after = monotonic_now_ms() - signaled_at
        print(
            "observed: idle_timeout_ms",
            PATIENT_IDLE_MS,
            "grace",
            GRACE_MS,
            "-> refused after",
            refused,
            "ms; keep-alive closed",
            got[1],
            "after",
            ka_closed,
            "ms; h2c",
            h2_end,
            "after",
            h2_closed,
            "ms; status",
            ended[0],
            "after",
            after,
            "ms",
        )
        assert_equal(got[0], "", "an answer after the first")
        assert_true(got[1] == "eof" or got[1] == "reset", got[1])
        assert_true(h2_end == "eof" or h2_end == "reset", h2_end)
        assert_true(ka_closed >= GRACE_MS, "closed before the window ended")
        assert_true(h2_closed >= GRACE_MS, "closed before the window ended")
        assert_equal(_exit_code(ended[0]), 0, "serve did not return")
        assert_true(after >= GRACE_MS, "ended before the window")
        assert_true(
            after <= _WATCH_SLACK_MS + GRACE_MS + STOP_BOUND_MS,
            "ended after the bound",
        )
    finally:
        if not reaped:
            _stop(child.pid)


comptime _WATCH_SLACK_MS = 100
"""The watcher's 50 ms poll and the parent's 5 ms reap poll, with room."""


# ── Workers (M3-049) ───────────────────────────────────────────────────────


comptime WORKERS = 2
"""The worker count of the head-of-line cases: one worker is held, the other
is free."""


def _fork_workers[
    make: def() thin raises -> App
](var server: Server, workers: Int, built_fd: Int = -1) raises -> _Child:
    """A child that serves with `server.serve[make](workers=workers)`. With
    `built_fd` >= 0 it first sets `MUNTIN_TEST_BUILT_FD` to it, for
    `who_app`. It exits 0 when `serve` returns with the SIGTERM and SIGINT
    dispositions it had before, 1 when `serve` raises (the error is
    printed), 4 when the dispositions differ. The parent's copy of the
    listener is dropped when this returns."""
    var port = server.port()
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        _default_sigpipe()
        if built_fd >= 0:
            _ = setenv("MUNTIN_TEST_BUILT_FD", String(built_fd))
        var term = _handler_word(SIGTERM)
        var int = _handler_word(SIGINT)
        try:
            server.serve[make](workers=workers)
        except e:
            print("workers child: serve failed:", e)
            exit(1)
        if _handler_word(SIGTERM) != term or _handler_word(SIGINT) != int:
            exit(4)
        exit(0)
    return _Child(pid, port)


def _workers_answer_during_a_hold(h2: Bool) raises:
    """With `WORKERS` workers, while one handler is held, a light request on
    a connection opened during the hold is answered before the held handler
    returns: over HTTP/1.1 a new connection, over h2c a new connection whose
    SETTINGS are exchanged during the hold. The held worker does not poll,
    so the free one accepts it. The order pipe reads `b` before `a`, where
    `serve(app)` reads `a` first (M3-046)."""
    var pipes = _held_pipes()
    var child = _serve_blocking(_WORKERS)
    _close(pipes[1])
    _close(pipes[2])
    var held = pipes[0].copy()
    var reaped = False
    try:
        var mark_path = "/mark/" + String(pipes[1])
        var hold_path = held.path.replace("/held/", "/hold/")
        var early: String
        var light: String
        var first_answer: String
        if h2:
            var first = _H2Client(child.port)
            first.get(1, hold_path)
            assert_equal(
                _read_byte(held.started), 1, "the handler never started"
            )
            var other = _H2Client(child.port)
            other.get(1, mark_path)
            other.set_timeout(HOLD_PROBE_MS)
            early = other.read_within(1)
            light = other.answers[0]
            other.set_timeout(TIMEOUT_MS)
            _write_byte(held.release)
            _ = first.read_within(1)
            first_answer = first.answers[0]
        else:
            var a = _send(child.port, _request("GET", hold_path))
            assert_equal(
                _read_byte(held.started), 1, "the handler never started"
            )
            var fresh = _send(child.port, _request("GET", mark_path))
            fresh.set_recv_timeout(HOLD_PROBE_MS)
            var got = _read_all(fresh)
            early = got[1]
            light = _content(got[0])
            _write_byte(held.release)
            first_answer = _content(_read_all(a)[0])
        reaped = _end_blocking(_WORKERS, child.pid)
        var order = _rest_of_pipe(held.started)
        print(
            "observed: workers",
            WORKERS,
            "h2c" if h2 else "h1",
            "new connection while held:",
            early,
            repr(light),
            "| held:",
            repr(first_answer),
            "| handler order",
            repr(order),
        )
        assert_equal(early, "ended" if h2 else "eof")
        assert_equal(light, "200 marked" if h2 else "marked")
        assert_equal(first_answer, "200 released" if h2 else "released")
        assert_equal(order, "ba")
    finally:
        if not reaped:
            _stop(child.pid)
        _close(held.started)
        _close(held.release)


def test_h1_workers_answer_a_new_connection_during_a_hold() raises:
    _workers_answer_during_a_hold(False)


def test_h2c_workers_answer_a_new_connection_during_a_hold() raises:
    _workers_answer_during_a_hold(True)


def test_h2c_workers_still_serialize_streams_of_one_connection() raises:
    """All streams of an h2c connection run on the worker that accepted it,
    one at a time: more workers do not change M3-046's case."""
    _h2c_blocks_streams(_WORKERS_PATIENT, True)


def test_h2c_workers_still_drop_a_waiting_stream_after_a_long_hold() raises:
    """With Flare's default idle timeout, the held worker's idle timer still
    closes the held stream's connection after its answer (M3-046)."""
    _h2c_blocks_streams(_WORKERS, True)


@fieldwise_init
struct BuiltOn(Movable):
    """The thread `who_app` built its `App` on."""

    var thread: UInt64


def who(state: State[BuiltOn]) -> String:
    """`<thread the App was built on> <thread serving this request>`."""
    return String(state[].thread) + " " + String(current_thread_id())


def who_app() raises -> App:
    """Writes `m` to the pipe `MUNTIN_TEST_BUILT_FD` names (one byte per
    `App` built), then builds an `App` whose state is the building thread."""
    var out = FileDescriptor(Int(getenv("MUNTIN_TEST_BUILT_FD")))
    out.write_bytes("m".as_bytes())
    var app = App()
    app.get["/who"](who, State(BuiltOn(current_thread_id())))
    return app^


def test_workers_each_build_and_serve_their_own_app() raises:
    """`serve[who_app](workers=3)` calls `who_app` once per worker, and
    every request is answered on the thread that built the `App` (and the
    `State`) answering it."""
    var built = _pipe()
    var child = _fork_workers[who_app](
        Server.bind("127.0.0.1", 0, shutdown_grace_ms=SHORT_GRACE_MS),
        3,
        built[1],
    )
    _close(built[1])
    var reaped = False
    try:
        var streams = List[TcpStream]()
        for _ in range(6):
            streams.append(_send(child.port, _request("GET", "/who")))
        for i in range(len(streams)):
            var answer = _content(_read_all(streams[i])[0])
            var parts = answer.split(" ")
            assert_equal(len(parts), 2, answer)
            assert_equal(parts[0], parts[1], "answered off its App's thread")
        assert_equal(kill(child.pid, SIGTERM), 0)
        var ended = _reap_within(child.pid, SHORT_GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        assert_equal(_exit_code(ended[0]), 0, "serve did not return")
        var builds = _rest_of_pipe(built[0])
        print("observed: workers 3 -> builds", repr(builds))
        assert_equal(builds, "mmm")
    finally:
        if not reaped:
            _stop(child.pid)
        _close(built[0])


def test_workers_stop_gracefully() raises:
    """SIGTERM stops `serve[make]` as it stops `serve(app)` (M3-045): new
    connections are refused at once, a request whose handler is held is
    answered after the stop began, an idle keep-alive connection stays open
    through the window (the idle timeout is longer) and is closed at its end, and the child exits 0 after
    the window and within the bound; the port can be bound again."""
    var pipes = _held_pipes()
    var child = _fork_workers[stoppable_app](
        Server.bind(
            "127.0.0.1",
            0,
            shutdown_grace_ms=GRACE_MS,
            idle_timeout_ms=PATIENT_IDLE_MS,
        ),
        WORKERS,
    )
    _close(pipes[1])
    _close(pipes[2])
    var held = pipes[0].copy()
    var reaped = False
    try:
        var ka = _send(
            child.port, "GET /hello HTTP/1.1\r\nHost: muntin\r\n\r\n"
        )
        assert_equal(_content(_one_response(ka)), "hello")
        var in_flight = _send(child.port, _request("GET", held.path))
        assert_equal(_read_byte(held.started), 1, "the handler never started")
        var signaled_at = monotonic_now_ms()
        assert_equal(kill(child.pid, SIGTERM), 0)
        var refused = _refused_within(child.port, 1000)
        assert_true(refused >= 0, "a new connection was still accepted")
        _write_byte(held.release)
        var got = _read_all(in_flight)
        var idle = _read_all(ka)
        var idle_closed = monotonic_now_ms() - signaled_at
        var ended = _reap_within(child.pid, GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        var after = monotonic_now_ms() - signaled_at
        print(
            "observed: workers",
            WORKERS,
            "SIGTERM -> refused after",
            refused,
            "ms; in flight",
            repr(_content(got[0])),
            got[1],
            "; idle keep-alive",
            idle[1],
            "after",
            idle_closed,
            "ms; status",
            ended[0],
            "after",
            after,
            "ms",
        )
        assert_equal(_status_line(got[0]), "HTTP/1.1 200 OK")
        assert_equal(_content(got[0]), "released after the stop")
        assert_equal(idle[0], "", "an answer after the first")
        assert_true(idle[1] == "eof" or idle[1] == "reset", idle[1])
        assert_true(idle_closed >= GRACE_MS, "closed before the window ended")
        assert_equal(_exit_code(ended[0]), 0, "serve did not return")
        assert_true(after >= GRACE_MS, "ended before the window")
        assert_true(
            after <= _WATCH_SLACK_MS + GRACE_MS + STOP_BOUND_MS,
            "ended after the bound",
        )
        var again = Server.bind("127.0.0.1", child.port)
        assert_equal(again.port(), child.port)
    finally:
        if not reaped:
            _stop(child.pid)
        _close(held.started)
        _close(held.release)


def test_serve_workers_raises_for_a_count_out_of_range() raises:
    """`workers` outside 1 to 256 raises before anything is served or any
    signal is touched; the process's serving claim stays free."""
    var server = Server.bind("127.0.0.1", 0)
    for n in [0, -1, 257]:
        var got = String("served")
        try:
            server.serve[borrowed_app](workers=n)
        except e:
            got = String(e)
        assert_equal(got, "workers out of range: " + String(n))
        assert_false(_serving_held(), "the serving claim was taken")


def no_app() raises -> App:
    raise Error("no app")


def test_a_raising_make_stops_every_worker() raises:
    """When `make` raises on the workers, `serve[make]` stops them all and
    raises the error, with both stop dispositions back."""
    var server = Server.bind("127.0.0.1", 0)
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(REFUSAL_ALARM_S))
        _default_sigpipe()
        var term = _handler_word(SIGTERM)
        var int = _handler_word(SIGINT)
        try:
            server.serve[no_app](workers=WORKERS)
            exit(9)
        except e:
            print("observed: raising make ->", e)
            if _handler_word(SIGTERM) != term or _handler_word(SIGINT) != int:
                exit(4)
            if String(e) == "serve: a worker's make raised: no app":
                exit(7)
            exit(8)
    _ = server^
    var ended = _reap_within(pid, STOP_BOUND_MS * 5)
    assert_equal(_exit_code(ended[0]), 7, "serve did not raise make's error")


def test_serve_workers_refuses_flare_bufring_handler() raises:
    """`serve[make]` refuses `FLARE_BUFRING_HANDLER=1` as `serve(app)` does,
    before serving."""
    var server = Server.bind("127.0.0.1", 0)
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(REFUSAL_ALARM_S))
        _default_sigpipe()
        _ = setenv("FLARE_BUFRING_HANDLER", "1")
        try:
            server.serve[borrowed_app](workers=WORKERS)
        except e:
            if (
                String(e)
                == "FLARE_BUFRING_HANDLER=1 is unsupported by Muntin with Flare"
                " v0.12.0"
            ):
                exit(7)
            exit(8)
        exit(9)
    _ = server^
    var ended = _reap_within(pid, STOP_BOUND_MS * 5)
    assert_equal(_exit_code(ended[0]), 7, "serve did not refuse")


def gated_app() raises -> App:
    """`stoppable_app`, built once a byte arrives on the pipe
    `MUNTIN_TEST_GATE_FD` names: `r` builds it, any other byte raises. Each
    worker reads its own byte, so the test decides when, and whether, each
    one starts serving."""
    var gate = FileDescriptor(Int(getenv("MUNTIN_TEST_GATE_FD")))
    var byte = List[UInt8](length=1, fill=0)
    if gate.read_bytes(byte) != 1 or Int(byte[0]) != ord("r"):
        raise Error("not built")
    return stoppable_app()


def test_a_make_ending_after_the_stop_keeps_the_window() raises:
    """With one worker serving an idle keep-alive connection and the other
    still in `make` when SIGTERM arrives, `make` raising during the window
    does not cut the stop short: the connection stays open until the window
    ends, and `serve` returns (exit 0) after it."""
    var gate = _pipe()
    var server = Server.bind(
        "127.0.0.1",
        0,
        shutdown_grace_ms=GRACE_MS,
        idle_timeout_ms=PATIENT_IDLE_MS,
    )
    var port = server.port()
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        _default_sigpipe()
        _ = setenv("MUNTIN_TEST_GATE_FD", String(gate[0]))
        try:
            server.serve[gated_app](workers=WORKERS)
        except e:
            print("workers child: serve failed:", e)
            exit(1)
        exit(0)
    _ = server^
    _close(gate[0])
    var reaped = False
    try:
        # One worker builds its App; the other waits in `make`.
        _write_byte_of(gate[1], "r")
        var ka = _send(port, "GET /hello HTTP/1.1\r\nHost: muntin\r\n\r\n")
        assert_equal(_content(_one_response(ka)), "hello")
        var signaled_at = monotonic_now_ms()
        assert_equal(kill(pid, SIGTERM), 0)
        assert_true(_refused_within(port, 1000) >= 0, "still accepting")
        # The waiting worker's `make` now raises, inside the window.
        _write_byte_of(gate[1], "x")
        var idle = _read_all(ka)
        var closed = monotonic_now_ms() - signaled_at
        var ended = _reap_within(pid, GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        var after = monotonic_now_ms() - signaled_at
        print(
            "observed: make raising after the stop -> keep-alive",
            idle[1],
            "after",
            closed,
            "ms; status",
            ended[0],
            "after",
            after,
            "ms",
        )
        assert_true(idle[1] == "eof" or idle[1] == "reset", idle[1])
        assert_true(closed >= GRACE_MS, "closed before the window ended")
        assert_equal(_exit_code(ended[0]), 0, "serve did not return")
        assert_true(after >= GRACE_MS, "ended before the window")
    finally:
        if not reaped:
            _stop(pid)
        _close(gate[1])


def _serve_gated(
    var server: Server, gate: Int, stage: def(Int) thin -> None
) raises -> Int:
    """A child that serves `server.serve[gated_app](workers=WORKERS)`, with
    `gate` as `MUNTIN_TEST_GATE_FD` and `stage` as the `_stage` hook. It
    exits 0 when `serve` returns, 7 when it raises a worker's `make` error,
    1 when it raises anything else. Returns its pid."""
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        _default_sigpipe()
        _ = setenv("MUNTIN_TEST_GATE_FD", String(gate))
        try:
            server.serve[gated_app](workers=WORKERS, _stage=stage)
        except e:
            print("workers child: serve failed:", e)
            if String(e) == "serve: a worker's make raised: not built":
                exit(7)
            exit(1)
        exit(0)
    _ = server^
    return pid


def _a_raising_make_with_a_worker_that_does_not_stop(in_handler: Bool) raises:
    """With one worker that does not return (still in `make`, or in a held
    handler) and the other's `make` raising, `serve` cannot raise: the
    process ends with status 1, `_REACTOR_STOP_MS` after the hard stop
    began, instead of waiting for that worker forever."""
    var gate = _pipe()
    var pipes = _held_pipes()
    var server = Server.bind("127.0.0.1", 0)
    var port = server.port()
    var pid = _serve_gated(server^, gate[0], _no_stage)
    _close(gate[0])
    _close(pipes[1])
    _close(pipes[2])
    var held = pipes[0].copy()
    try:
        if in_handler:
            _write_byte_of(gate[1], "r")
            var in_flight = _send(port, _request("GET", held.path))
            assert_equal(
                _read_byte(held.started), 1, "the handler never started"
            )
            _ = in_flight^
        # The other worker's `make` raises; one worker never returns.
        var raised_at = monotonic_now_ms()
        _write_byte_of(gate[1], "x")
        var ended = _reap_within(pid, 3 * STOP_BOUND_MS)
        var after = monotonic_now_ms() - raised_at
        print(
            "observed: raising make, other worker stuck in",
            "a handler" if in_handler else "make",
            "-> status",
            ended[0],
            "after",
            after,
            "ms",
        )
        assert_equal(_exit_code(ended[0]), 1, "the process did not end")
        assert_true(after >= STOP_BOUND_MS, "ended before the bound")
    finally:
        _close(gate[1])
        _close(held.started)
        _close(held.release)


def test_a_raising_make_ends_the_process_with_a_worker_stuck_in_make() raises:
    _a_raising_make_with_a_worker_that_does_not_stop(False)


def test_a_raising_make_ends_the_process_with_a_worker_stuck_in_a_handler() raises:
    _a_raising_make_with_a_worker_that_does_not_stop(True)


def _raise_term_when_a_worker_ended(stage: Int):
    """SIGTERM to the serving thread (`raise`, so it is delivered before
    this returns) once that thread saw a worker end, before it looks for a
    delivered stop signal: the watcher, which looks every 50 ms, has not
    seen it yet."""
    if stage == _STAGE_WORKER_ENDED:
        _ = external_call["raise", c_int](c_int(SIGTERM))


def test_a_stop_delivered_before_the_watcher_sees_it_keeps_the_window() raises:
    """A worker's `make` raising after SIGTERM was delivered, but before the
    watcher saw it, is part of that graceful stop: the other worker's idle
    keep-alive connection stays open for the whole window, and `serve`
    returns (exit 0)."""
    var gate = _pipe()
    var server = Server.bind(
        "127.0.0.1",
        0,
        shutdown_grace_ms=GRACE_MS,
        idle_timeout_ms=PATIENT_IDLE_MS,
    )
    var port = server.port()
    var pid = _serve_gated(server^, gate[0], _raise_term_when_a_worker_ended)
    _close(gate[0])
    var reaped = False
    try:
        _write_byte_of(gate[1], "r")
        var ka = _send(port, "GET /hello HTTP/1.1\r\nHost: muntin\r\n\r\n")
        assert_equal(_content(_one_response(ka)), "hello")
        var raised_at = monotonic_now_ms()
        # The other worker's `make` raises; the hook then sends SIGTERM.
        _write_byte_of(gate[1], "x")
        var idle = _read_all(ka)
        var closed = monotonic_now_ms() - raised_at
        var ended = _reap_within(pid, GRACE_MS + STOP_BOUND_MS + 500)
        reaped = ended[0] >= 0
        print(
            (
                "observed: SIGTERM before the watcher saw it, then a worker"
                " ended -> keep-alive"
            ),
            idle[1],
            "after",
            closed,
            "ms; status",
            ended[0],
        )
        assert_true(idle[1] == "eof" or idle[1] == "reset", idle[1])
        assert_true(closed >= GRACE_MS, "closed before the window ended")
        assert_equal(_exit_code(ended[0]), 0, "serve did not return")
    finally:
        if not reaped:
            _stop(pid)
        _close(gate[1])


def spawn() raises -> String:
    """Starts `sleep 5` in the background through the shell, a process that
    inherits every descriptor of this one not marked close-on-exec."""
    var command = _cstr("sleep 5 </dev/null >/dev/null 2>&1 &")
    if Int(external_call["system", c_int](command.unsafe_ptr())) != 0:
        raise Error("system() failed")
    return "spawned"


def spawning_app() -> App:
    var app = App()
    app.get["/spawn"](spawn)
    return app^


def test_a_process_a_worker_starts_does_not_keep_the_port() raises:
    """A process a handler starts (and that outlives `serve`) inherits no
    worker's copy of the listener: once `serve` returned on SIGTERM, the
    port can be bound again at once."""
    var child = _fork_workers[spawning_app](
        Server.bind("127.0.0.1", 0, shutdown_grace_ms=SHORT_GRACE_MS),
        WORKERS,
    )
    var reaped = False
    try:
        assert_equal(
            _content(_exchange(child.port, _request("GET", "/spawn"))),
            "spawned",
        )
        assert_equal(kill(child.pid, SIGTERM), 0)
        var ended = _reap_within(child.pid, SHORT_GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        assert_equal(_exit_code(ended[0]), 0, "serve did not return")
        var got = String("bound")
        try:
            var again = Server.bind("127.0.0.1", child.port)
            _ = again^
        except e:
            got = String(e)
        print("observed: bind after a spawned process outlived serve ->", got)
        assert_equal(got, "bound")
    finally:
        if not reaped:
            _stop(child.pid)


def test_a_listener_copy_that_cannot_be_parked_stays_open() raises:
    """When `dup2` cannot park a worker's copy of the listener (here the
    parking descriptor is invalid), the watcher's drain does not close that
    number, which the worker's reactor may still have registered: the copy
    stays open (the socket still accepts), every stop byte is set at once,
    and it raises, so `serve` reports a hard stop."""
    var server = Server.bind("127.0.0.1", 0)
    var port = server.port()
    var copy = Int(
        external_call["dup", c_int](
            c_int(Int(server._server._listener.as_raw_fd()))
        )
    )
    assert_true(copy >= 0, "dup failed")
    var stop = List[Bool](length=1, fill=False)
    var table = List[Int64](length=_W_LEN, fill=0)
    table[_W_FD] = Int64(copy)
    table[_W_STOP] = Int64(Int(stop.unsafe_ptr()))
    var block = List[Int64](length=_CB_LEN, fill=0)
    block[_CB_GRACE] = 0
    block[_CB_WORKERS] = Int64(Int(table.unsafe_ptr()))
    block[_CB_NWORKERS] = 1
    block[_CB_PARKED] = -1
    var got = String("returned")
    try:
        _drain_workers(Int(block.unsafe_ptr()), server._server)
    except e:
        got = String(e)
    print("observed: unparkable copy ->", got)
    assert_true(
        got.startswith("parking worker 0's copy of the listener failed (dup2:"),
        got,
    )
    assert_true(stop[0], "the worker's stop byte is not set")
    assert_equal(Int(table[_W_FD]), copy, "the copy was given up")
    var probe = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    _ = probe^
    _close(copy)
    _ = table^
    _ = stop^
    _ = block^


def test_serve_workers_refuses_a_tls_server() raises:
    """`serve[make]` refuses a `Server` with a TLS context before serving or
    taking the serving claim: its workers' reactor loop is not given the
    context. The certificate is a throwaway self-signed one; the child
    serves, so a missing refusal fails the test instead of hanging it."""
    var command = _cstr(
        "openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=muntin"
        " -keyout build/test_workers_key.pem -out build/test_workers_cert.pem"
        " >/dev/null 2>&1"
    )
    assert_equal(
        Int(external_call["system", c_int](command.unsafe_ptr())),
        0,
        "openssl could not write a certificate",
    )
    var server = Server.bind("127.0.0.1", 0)
    server._server._tls_ctx = Optional[ServerCtx](
        ServerCtx.new(
            "build/test_workers_cert.pem", "build/test_workers_key.pem"
        )
    )
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(REFUSAL_ALARM_S))
        _default_sigpipe()
        try:
            server.serve[borrowed_app](workers=WORKERS)
        except e:
            print("observed: workers on a TLS server ->", e)
            if _serving_held():
                exit(4)
            if String(e) == "serve: workers are unsupported on a TLS server":
                exit(7)
            exit(8)
        exit(9)
    _ = server^
    var ended = _reap_within(pid, STOP_BOUND_MS * 5)
    assert_equal(_exit_code(ended[0]), 7, "serve did not refuse")


def test_workers_stop_gracefully_while_connections_keep_arriving() raises:
    """SIGTERM while another process keeps opening connections, so the
    workers' listener copies are parked while their reactors may be
    accepting: an idle keep-alive connection still stays open for the whole
    window, the child exits 0, and the port can be bound again."""
    var child = _fork_workers[stoppable_app](
        Server.bind(
            "127.0.0.1",
            0,
            shutdown_grace_ms=GRACE_MS,
            idle_timeout_ms=PATIENT_IDLE_MS,
        ),
        WORKERS,
    )
    var reaped = False
    var hammer = -1
    try:
        var ka = _send(
            child.port, "GET /hello HTTP/1.1\r\nHost: muntin\r\n\r\n"
        )
        assert_equal(_content(_one_response(ka)), "hello")
        hammer = fork()
        if hammer < 0:
            raise Error("fork() failed")
        if hammer == 0:
            # Connects (and closes) without pause for 1.5 s.
            _ = external_call["alarm", c_uint](c_uint(REFUSAL_ALARM_S))
            var start = monotonic_now_ms()
            var opened = 0
            while monotonic_now_ms() - start < 1500:
                try:
                    var probe = TcpStream.connect(
                        SocketAddr.localhost(UInt16(child.port))
                    )
                    _ = probe^
                    opened += 1
                except:
                    pass
            print("observed: the other process opened", opened, "connections")
            exit(0)
        _ = libc_nanosleep_ms(200)
        var signaled_at = monotonic_now_ms()
        assert_equal(kill(child.pid, SIGTERM), 0)
        var idle = _read_all(ka)
        var closed = monotonic_now_ms() - signaled_at
        var ended = _reap_within(child.pid, GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        print(
            "observed: workers SIGTERM under connections -> keep-alive",
            idle[1],
            "after",
            closed,
            "ms; status",
            ended[0],
        )
        assert_true(idle[1] == "eof" or idle[1] == "reset", idle[1])
        assert_true(closed >= GRACE_MS, "closed before the window ended")
        assert_equal(_exit_code(ended[0]), 0, "serve did not return")
        var hammered = _reap_within(hammer, STOP_BOUND_MS * 3)
        hammer = -1
        assert_equal(_exit_code(hammered[0]), 0, "the other process failed")
        var again = Server.bind("127.0.0.1", child.port)
        assert_equal(again.port(), child.port)
    finally:
        if not reaped:
            _stop(child.pid)
        if hammer > 0:
            _stop(hammer)
            _ = _reap_within(hammer, STOP_BOUND_MS)


def test_the_largest_worker_count_serves_and_stops() raises:
    """`serve[make_app](workers=256)`, the largest count, builds every
    worker, answers, and stops on SIGTERM within the window and the bound
    with status 0."""
    var child = _fork_workers[make_app](
        Server.bind("127.0.0.1", 0, shutdown_grace_ms=SHORT_GRACE_MS), 256
    )
    var reaped = False
    try:
        var raw = _exchange(child.port, _request("GET", "/"))
        assert_equal(_content(raw), "hello")
        var signaled_at = monotonic_now_ms()
        assert_equal(kill(child.pid, SIGTERM), 0)
        var ended = _reap_within(child.pid, SHORT_GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        var after = monotonic_now_ms() - signaled_at
        print("observed: 256 workers -> status", ended[0], "after", after, "ms")
        assert_equal(_exit_code(ended[0]), 0, "serve did not return")
    finally:
        if not reaped:
            _stop(child.pid)


def _write_byte_of(fd: Int, byte: String) raises:
    var out = FileDescriptor(fd)
    out.write_bytes(byte.as_bytes())


def make_app() -> App:
    """`docs/DX.md` section 1's workers example, as written."""
    var app = App()
    app.get["/"](hello)
    return app^


def test_docs_workers_example() raises:
    """`docs/DX.md` section 1's `server.serve[make_app](workers=4)` serves,
    on port 0, and stops on SIGTERM with status 0."""
    var child = _fork_workers[make_app](
        Server.bind("127.0.0.1", 0, shutdown_grace_ms=SHORT_GRACE_MS), 4
    )
    var reaped = False
    try:
        var raw = _exchange(child.port, _request("GET", "/"))
        assert_equal(_status_line(raw), "HTTP/1.1 200 OK")
        assert_equal(_content(raw), "hello")
        assert_equal(kill(child.pid, SIGTERM), 0)
        var ended = _reap_within(child.pid, SHORT_GRACE_MS + STOP_BOUND_MS)
        reaped = ended[0] >= 0
        assert_equal(_exit_code(ended[0]), 0, "serve did not return")
    finally:
        if not reaped:
            _stop(child.pid)


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
