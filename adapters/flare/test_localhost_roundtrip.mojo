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

M2-001 adds a second server whose `App` has the typed route
`/users/{id}` -> `get_user(id: Int)`: the same registration and handler, driven
over loopback and through `TestClient`, must give the same status and body.
Flare and the adapter only carry the request target; `{id}` matching and
`Int` conversion happen in `App.handle`.

M2-002 registers `/items?{limit}` -> `list_items(limit: Int)` on that same
server and sends targets with queries: Muntin's `Request` splits path from
query, `App.handle` extracts and converts `limit`, and the results must equal
`TestClient`'s for the same targets.
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


def get_user(id: Int) -> String:
    return String(id)


def list_items(limit: Int) -> String:
    return "items " + String(limit)


def hello_app() -> App:
    var app = App()
    app.get["/hello"](hello)
    return app^


def users_app() -> App:
    var app = App()
    app.get["/hello"](hello)
    app.get["/users/{id}"](get_user)
    app.get["/items?{limit}"](list_items)
    return app^


@fieldwise_init
struct _Child(Copyable):
    var pid: Int
    var port: Int


def _serve_in_child(var app: App) raises -> _Child:
    """Binds an ephemeral loopback port and forks a child serving `app` there
    through `MuntinHandler`. The caller must SIGKILL and reap `pid`."""
    var server = HttpServer.bind(SocketAddr.localhost(0))
    var port = Int(server.local_addr().port)

    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        try:
            server.serve(MuntinHandler(app^))
        except e:
            print("server child: serve failed:", e)
        exit(1)
    return _Child(pid, port)


def _client() raises -> HttpClient:
    return HttpClient(timeout_ms=TIMEOUT_MS).with_read_timeout(TIMEOUT_MS)


def test_get_hello_over_localhost_matches_test_client() raises:
    var child = _serve_in_child(hello_app())
    var pid = child.pid
    var base = String("http://127.0.0.1:", child.port)
    try:
        var client = _client()
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


def test_typed_route_over_localhost_matches_test_client() raises:
    var child = _serve_in_child(users_app())
    var base = String("http://127.0.0.1:", child.port)
    try:
        var client = _client()
        var app = users_app()
        var in_memory = TestClient(app)

        # /users/042 -> "42": only a handler that received Int(42) says that;
        # forwarding or echoing the raw segment would say "042".
        var expected = [
            (String("/users/42"), 200, String("42")),
            (String("/users/042"), 200, String("42")),
            (String("/users/-7"), 200, String("-7")),
            (String("/users/abc"), 400, String("Bad Request")),
            (String("/users"), 404, String("Not Found")),
            (String("/hello"), 200, String("hello")),
            # M2-002: routing sees the path only; the query is extracted by
            # Muntin. "010" -> "items 10" only if the handler got an Int.
            (String("/hello?x=1"), 200, String("hello")),
            (String("/users/42?x=1"), 200, String("42")),
            (String("/items?limit=010"), 200, String("items 10")),
            (String("/items?other=z&limit=10"), 200, String("items 10")),
            (String("/items"), 400, String("Bad Request")),
            (String("/items?limit=abc"), 400, String("Bad Request")),
            (String("/items?limit=1&limit=2"), 400, String("Bad Request")),
            (String("/missing?limit=1"), 404, String("Not Found")),
        ]
        for want in expected:
            var path = want[0]
            var response = client.get(base + path)
            print("observed:", path, response.status, repr(response.text()))
            assert_equal(response.status, want[1], path)
            assert_equal(response.text(), want[2], path)

            var local = in_memory.get(path)
            assert_equal(response.status, local.status, path)
            assert_equal(response.text(), local.body, path)
    finally:
        _ = kill(child.pid, SIGKILL)
        waitpid(child.pid)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
