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

M2-006 registers the body-only `POST /users` -> `create_user(body: CreateUser)`
on that same server, with `CreateUser` defined here, and sends bodies with
Flare's raw-bytes `post` (no `Content-Type`): the adapter only copies the body
into Muntin's `Request`; `App.handle` converts it with `CreateUser.from_body`.
Valid and invalid bodies, a wrong method and a missing route must equal
`TestClient.post`.

M2-008 registers typed results on that same server: `GET /people/{id}` and
`POST /people` return `Person`, a move-only type defined here conforming to
`muntin.ToResponse`, and `GET /teapot` returns a `Response` with status 418.
`App.handle` converts the result; the adapter only carries the `Response`.
"""

from std.ffi import c_uint, external_call
from std.testing import assert_equal, TestSuite

from flare.http import HttpClient, HttpServer
from flare.net import SocketAddr
from flare.utils import SIGKILL, exit, fork, kill, waitpid
from muntin import App, FromBody, Response, ToResponse
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


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("expected name=<text>")
        return Self(String(body[byte=5:]))


def create_user(body: CreateUser) -> String:
    return "created " + body.name


struct RawText(FromBody):
    """Accepts any body, including an empty one, unchanged: a backend that
    rejected or rewrote a body itself would differ from `TestClient`."""

    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def echo(body: RawText) -> String:
    return "[" + body.text + "]"


struct Person(ToResponse):
    """A move-only handler result that converts itself (M2-008)."""

    var id: Int
    var name: String

    def __init__(out self, id: Int, var name: String):
        self.id = id
        self.name = name^

    def to_response(deinit self) -> Response:
        var name = self.name^
        return Response.text("Person(" + String(self.id) + ", " + name + ")")


def get_person(id: Int) -> Person:
    return Person(id, "Ada")


def create_person(body: CreateUser) -> Person:
    return Person(7, body.name)


def teapot() -> Response:
    return Response.text("short and stout", status=418)


def hello_app() -> App:
    var app = App()
    app.get["/hello"](hello)
    return app^


def users_app() -> App:
    var app = App()
    app.get["/hello"](hello)
    app.get["/users/{id}"](get_user)
    app.get["/items?{limit}"](list_items)
    app.post["/users"](create_user)
    app.post["/echo"](echo)
    app.get["/people/{id}"](get_person)
    app.post["/people"](create_person)
    app.get["/teapot"](teapot)
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
            # M2-008: "Person(42, Ada)" only if Muntin converted the typed
            # result; 418 only if the handler's Response kept its status.
            (String("/people/042"), 200, String("Person(42, Ada)")),
            (String("/people/abc"), 400, String("Bad Request")),
            (String("/teapot"), 418, String("short and stout")),
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

        # M2-006: "created Ada" only if Muntin converted the body; the raw
        # body is "name=Ada". GET /users above is the wrong method (404).
        var posts = [
            (String("/users"), String("name=Ada"), 200, String("created Ada")),
            (
                String("/users?name=Bob"),
                String("name=Ada"),
                200,
                String("created Ada"),
            ),
            (String("/users"), String("Ada"), 400, String("Bad Request")),
            (String("/users"), String(""), 400, String("Bad Request")),
            # Bodies any backend must deliver unchanged, empty included.
            (String("/echo"), String(""), 200, String("[]")),
            (
                String("/echo"),
                String(" a=b&c?d \n"),
                200,
                String("[ a=b&c?d \n]"),
            ),
            (String("/users/42"), String("name=Ada"), 404, String("Not Found")),
            (String("/hello"), String("name=Ada"), 404, String("Not Found")),
            (String("/missing"), String("name=Ada"), 404, String("Not Found")),
            # M2-008: typed result from a body handler.
            (
                String("/people"),
                String("name=Ada"),
                200,
                String("Person(7, Ada)"),
            ),
            (String("/people"), String("Ada"), 400, String("Bad Request")),
        ]
        for want in posts:
            var path = want[0]
            var body = want[1]
            var response = client.post(base + path, List(body.as_bytes()))
            print(
                "observed: POST",
                path,
                repr(body),
                response.status,
                repr(response.text()),
            )
            assert_equal(response.status, want[2], path + " " + body)
            assert_equal(response.text(), want[3], path + " " + body)

            var local = in_memory.post(path, body)
            assert_equal(response.status, local.status, path + " " + body)
            assert_equal(response.text(), local.body, path + " " + body)
    finally:
        _ = kill(child.pid, SIGKILL)
        waitpid(child.pid)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
