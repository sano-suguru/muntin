"""Real localhost HTTP round trip through Flare and Muntin (M1-003).

Runs only in the `flare` pixi environment (see scripts/check_flare.sh). A real
HTTP/1.1 client sends `GET /hello` over a loopback TCP connection to Flare's
`HttpServer`, which serves `MuntinHandler`, which calls `App.handle`.

Lifecycle (test-only, not a Muntin API): `HttpServer.serve` owns the calling
thread, so the server runs in a forked child, as in Flare's own integration
tests. `HttpServer.bind` returns a listening socket (`listen(2)`, backlog 128)
on an ephemeral loopback port, so the kernel queues the client's connection
even before the child enters `serve`: readiness is `bind` returning, with no
sleep. The client has connect and read timeouts; the parent SIGKILLs and reaps
the child in `finally`, and the child also arms a 30-second `alarm(2)` so it
cannot outlive a parent killed from outside.
"""

from std.ffi import c_uint, external_call
from std.testing import assert_equal, TestSuite

from flare.http import HttpClient, HttpServer
from flare.net import SocketAddr
from flare.utils import SIGKILL, exit, fork, kill, waitpid
from muntin import App
from muntin.testing import TestClient
from muntin_flare import MuntinHandler

comptime TIMEOUT_MS = 5_000
comptime CHILD_LIFETIME_S = 30


def hello() -> String:
    return "hello"


def hello_app() -> App:
    var app = App()
    app.get["/hello"](hello)
    return app^


def test_get_hello_over_localhost_matches_test_client() raises:
    var server = HttpServer.bind(SocketAddr.localhost(0))
    var port = Int(server.local_addr().port)

    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        try:
            server.serve(MuntinHandler(hello_app()))
        except e:
            print("server child: serve failed:", e)
        exit(1)

    var base = String("http://127.0.0.1:", port)
    try:
        var client = HttpClient(timeout_ms=TIMEOUT_MS).with_read_timeout(
            TIMEOUT_MS
        )
        var response = client.get(base + "/hello")
        print(
            "observed:",
            response.version,
            response.status,
            repr(response.reason),
            "content-type:",
            repr(response.headers.get("content-type")),
            "content-length:",
            repr(response.headers.get("content-length")),
            "body:",
            repr(response.text()),
        )

        assert_equal(response.status, 200)
        assert_equal(response.text(), "hello")

        var app = hello_app()
        var expected = TestClient(app).get("/hello")
        assert_equal(response.status, expected.status)
        assert_equal(response.text(), expected.body)

        # A constant response that skipped App.handle would also say "hello";
        # an unregistered path must reach the router and come back 404.
        var missing = client.get(base + "/missing")
        assert_equal(missing.status, 404)
        assert_equal(missing.text(), "Not Found")
    finally:
        _ = kill(pid, SIGKILL)
        waitpid(pid)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
