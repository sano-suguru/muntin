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
"""

from std.ffi import c_int, c_uint, external_call
from std.testing import assert_equal, assert_true, TestSuite

from flare.net import SocketAddr
from flare.tcp import TcpStream
from flare.utils import SIGINT, SIGKILL, SIGTERM, exit, fork, kill, waitpid
from muntin import App, Request, Response
from muntin.testing import TestClient
from muntin_flare import Server

comptime TIMEOUT_MS = 5_000
comptime CHILD_LIFETIME_S = 30
comptime SIGALRM = 14


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
    not depend on what the runner's process inherited. The parent's copy of
    the listener is dropped when this returns, so only the child holds the
    port. The caller must reap `pid`."""
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
    discards it), or -1 if `waitpid` failed."""
    var status = List[c_int]()
    status.append(0)
    var reaped = external_call["waitpid", c_int](
        c_int(pid), status.unsafe_ptr(), c_int(0)
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
        assert_equal(_content(raw), expected.body)
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
        # A bind raise leaves the parent's `App` usable.
        assert_equal(TestClient(app).get("/hello").body, "hello")
    finally:
        _stop(child.pid)


def test_bind_raises_for_a_port_out_of_range() raises:
    var low = _bind_error("127.0.0.1", -1)
    var high = _bind_error("127.0.0.1", 65536)
    print("observed:", low, "/", high)
    assert_equal(low, "port out of range: -1")
    assert_equal(high, "port out of range: 65536")


def test_bind_raises_for_a_host_name() raises:
    var error = _bind_error("localhost", 0)
    print("observed: bind localhost ->", error)
    assert_true(not error.startswith("bound port"), error)


def test_bind_ipv6_loopback_and_ipv4_any() raises:
    var v6 = Server.bind("::1", 0)
    var v4_any = Server.bind("0.0.0.0", 0)
    print("observed: ::1 ->", v6.port(), "0.0.0.0 ->", v4_any.port())
    assert_true(v6.port() > 0)
    assert_true(v4_any.port() > 0)


def test_dropping_a_server_releases_its_port() raises:
    var first = Server.bind("127.0.0.1", 0)
    var port = first.port()
    assert_true(_bind_error("127.0.0.1", port) != "bound port " + String(port))
    _ = first^
    var again = Server.bind("127.0.0.1", port)
    assert_equal(again.port(), port)


def _ended_by(sig: Int) raises:
    """A serving child that restored `sig`'s default disposition and is sent
    `sig` is reaped as terminated by `sig`, before its alarm."""
    var app = borrowed_app()
    var child = _serve_in_child(app, sig)
    var reaped = False
    try:
        # One answer shows the child is in `serve`, past the restore.
        var raw = _exchange(child.port, _request("GET", "/hello"))
        assert_equal(_content(raw), "hello")
        assert_equal(kill(child.pid, sig), 0)
        var status = _wait_status(child.pid)
        reaped = status >= 0
        var signaled = (status & 0x7F) != 0 and (status & 0x7F) != 0x7F
        print("observed: signal", sig, "-> waitpid status", status)
        assert_true(reaped, "waitpid failed")
        assert_true(signaled, "the child exited instead of being signaled")
        assert_true((status & 0x7F) != SIGALRM, "the child outlived the signal")
        assert_equal(status & 0x7F, sig)
    finally:
        if not reaped:
            _stop(child.pid)


def test_sigterm_ends_a_serving_child() raises:
    _ended_by(SIGTERM)


def test_sigint_ends_a_serving_child() raises:
    _ended_by(SIGINT)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
