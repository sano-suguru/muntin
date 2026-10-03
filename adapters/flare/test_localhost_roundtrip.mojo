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

M2-009 registers one route value then the body on that same server:
`POST /accounts/{id}` and `POST /accounts?{id}` -> `update_account(id: Int,
body: CreateUser) -> String`, and `POST /profiles/{id}` -> `update_person`
returning `Person`. Valid path and query values, an invalid value, an invalid
body and the typed result must equal `TestClient.post`.

M2-011 registers raising handlers on that same server: `GET /orders/{id}` ->
`find_order(id: Int) raises -> String` and `POST /orders` ->
`place_order(body: CreateUser) raises Rejected -> Person`, with `Rejected`
defined here. A handler that raises is the fixed 500 `Internal Server Error`
(the error's text is not sent); one that returns answers as before; an
invalid value is still 400. Muntin chooses the 500; the adapter only carries
the `Response`. Each must equal `TestClient`.

M2-013 registers `GET /stock/{id}` -> `reserve(id: Int) raises OutOfStock ->
String`, with `OutOfStock` defined here and declaring `muntin.ToErrorResponse`:
its raise is answered 409 by `to_error_response`, in Muntin; the adapter only
carries the final `Response`. A return and an invalid value are unchanged.
Each must equal `TestClient`.

M2-015 registers the raw `POST /webhook` -> `webhook(req: Request) raises
Unsigned -> Response`, with `Unsigned` defined here and declaring
`muntin.ToErrorResponse`: the handler echoes the request's method, path,
query and body as Muntin received them (an empty body and a query a typed
route would answer 400 included), or raises `Unsigned`, answered 401 by
`to_error_response` in Muntin. `GET /webhook` is 404. The adapter only
carries the request and the final `Response`. Each must equal `TestClient`.

M3-003 registers the stateful `GET /staff/{id}` -> `find_staff(staff:
State[Staff], id: Int) raises OutOfStock -> Person`, with `Staff` defined
here and its `State` built inside `users_app()`, so the child's `App` and
the in-memory one each own a value, moved with its `App` into
`MuntinHandler`. The handler reads the state, receives the converted `Int`
or is not called (400), and an out-of-range id raises `OutOfStock` (409).
Each must equal `TestClient`.

M3-006 registers stateful `POST /staff` -> `hire(staff: State[Staff], body:
CreateUser) raises OutOfStock -> Person` and `POST /staff/{id}` ->
`assign(staff: State[Staff], id: Int, body: CreateUser) raises OutOfStock ->
String` on the same `State[Staff]` as `GET /staff/{id}`. Success, a bad body
(400), a bad route value (400) and the application error (409) must equal
`TestClient`. The child's call order is not observable here; that the
route value and body fail before the handler is proven through
`TestClient` in `tests/test_state_post.mojo`.

M3-005 serves `headers_app()`: a raw `POST /signed` reads `X-Signature` and
repeated `X-A`, and answers with `X-Request-Id`, two `Set-Cookie`, an empty
value, and connection-specific fields (`Transfer-Encoding`, `Keep-Alive`,
`Upgrade`, `Connection: X-Hop` with `X-Hop`) that the adapter omits. Over
HTTP/1.1 (Flare's client) status, body and the kept fields equal
`App.handle`; `GET /hello` carries only Flare's own fields; an invalid
header from a handler is 500. Over cleartext HTTP/2 (a raw client using
Flare's public HPACK encoder and decoder) the same route keeps the fields
in order (lowercased by the protocol) without the omitted ones, and a
request field named `x-user:admin`, which HTTP/2 admits, is answered 400.
"""

from std.ffi import c_uint, external_call
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from flare.http import HttpClient, HttpServer
from flare.http import Request as FlareRequest
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
from flare.tcp import TcpStream
from flare.net import SocketAddr
from flare.utils import SIGKILL, exit, fork, kill, waitpid
from muntin import (
    App,
    Headers,
    FromBody,
    Request,
    Response,
    State,
    ToErrorResponse,
    ToResponse,
)
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


def update_account(id: Int, body: CreateUser) -> String:
    return "account " + String(id) + " " + body.name


def update_person(id: Int, var body: CreateUser) -> Person:
    return Person(id, body.name)


def find_order(id: Int) raises -> String:
    if id == 0:
        raise Error("database password is hunter2")
    return "order " + String(id)


@fieldwise_init
struct Rejected(Movable):
    """An application-defined error type, raised by `place_order`."""

    var reason: String


def place_order(body: CreateUser) raises Rejected -> Person:
    if body.name == "Mallory":
        raise Rejected("blocked customer Mallory")
    return Person(9, body.name)


@fieldwise_init
struct OutOfStock(Movable, ToErrorResponse):
    """An application-defined error type that opts into its own response."""

    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("out of stock " + String(self.id), status=409)


def reserve(id: Int) raises OutOfStock -> String:
    if id == 0:
        raise OutOfStock(id)
    return "reserved " + String(id)


@fieldwise_init
struct Unsigned(Movable, ToErrorResponse):
    """Raised by the raw `webhook`; opts into its own response."""

    var query: String

    def to_error_response(var self) -> Response:
        return Response.text("unsigned " + self.query, status=401)


def webhook(req: Request) raises Unsigned -> Response:
    """A raw handler: the whole request, no typed extraction (M2-015)."""
    if not req.body.startswith("signed"):
        raise Unsigned(req.query)
    return Response.text(
        req.method + "|" + req.path + "|" + req.query + "|" + req.body,
        status=202,
    )


struct Staff(Movable):
    """Application state for `find_staff`: a move-only list of names."""

    var names: List[String]

    def __init__(out self, var names: List[String]):
        self.names = names^


def find_staff(staff: State[Staff], id: Int) raises OutOfStock -> Person:
    """A stateful handler (M3-003): reads the route's `State[Staff]`."""
    if id < 0 or id >= len(staff[].names):
        raise OutOfStock(id)
    return Person(id, staff[].names[id])


def hire(staff: State[Staff], body: CreateUser) raises OutOfStock -> Person:
    """A stateful body-only POST handler (M3-006): a name already on the
    staff raises `OutOfStock` with its index (409)."""
    for i in range(len(staff[].names)):
        if staff[].names[i] == body.name:
            raise OutOfStock(i)
    return Person(len(staff[].names), body.name)


def assign(
    staff: State[Staff], id: Int, body: CreateUser
) raises OutOfStock -> String:
    """A stateful route-value-then-body POST handler (M3-006)."""
    if id < 0 or id >= len(staff[].names):
        raise OutOfStock(id)
    return staff[].names[id] + " -> " + body.name


def signed(req: Request) raises -> Response:
    var sig = req.headers.get("x-signature")
    if not sig:
        return Response.text("unsigned", status=401)
    var resp = Response.text(
        sig.value() + "|" + String(len(req.headers.get_all("x-a"))),
        status=202,
    )
    resp.headers.add("X-Request-Id", "42")
    resp.headers.add("Set-Cookie", "a=1")
    resp.headers.add("Set-Cookie", "b=2")
    resp.headers.add("X-Empty", "")
    resp.headers.add("Transfer-Encoding", "chunked")
    resp.headers.add("Keep-Alive", "timeout=5")
    resp.headers.add("Upgrade", "websocket")
    resp.headers.add("Connection", "X-Hop")
    resp.headers.add("X-Hop", "secret")
    return resp^


def inject_header(req: Request) raises -> Response:
    var resp = Response.text("never")
    resp.headers.add("X-Bad", "a\r\nSet-Cookie: evil=1")
    return resp^


def headers_app() -> App:
    var app = App()
    app.get["/hello"](hello)
    app.post["/signed"](signed)
    app.get["/signed"](signed)
    app.get["/inject"](inject_header)
    return app^


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
    app.post["/accounts/{id}"](update_account)
    app.post["/accounts?{id}"](update_account)
    app.post["/profiles/{id}"](update_person)
    app.get["/orders/{id}"](find_order)
    app.post["/orders"](place_order)
    app.get["/stock/{id}"](reserve)
    app.post["/webhook"](webhook)
    var names = List[String]()
    names.append("Ada")
    names.append("Grace")
    var staff = State(Staff(names^))
    app.get["/staff/{id}"](find_staff, staff)
    app.post["/staff"](hire, staff)
    app.post["/staff/{id}"](assign, staff)
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
            # M2-011: a raising handler that raises is the fixed 500, never
            # its error text; one that returns, or a bad value, is unchanged.
            (String("/orders/0"), 500, String("Internal Server Error")),
            (String("/orders/7"), 200, String("order 7")),
            (String("/orders/abc"), 400, String("Bad Request")),
            # M2-013: an opted-in error answers with its own response.
            (String("/stock/0"), 409, String("out of stock 0")),
            (String("/stock/3"), 200, String("reserved 3")),
            (String("/stock/abc"), 400, String("Bad Request")),
            # M2-015: the raw route is POST only.
            (String("/webhook"), 404, String("Not Found")),
            # M3-003: "Person(1, Grace)" only if the handler read its state
            # and got Int(1) from "01"; the 409 is its raise, the 400 a
            # value it never saw.
            (String("/staff/01"), 200, String("Person(1, Grace)")),
            (String("/staff/0"), 200, String("Person(0, Ada)")),
            (String("/staff/2"), 409, String("out of stock 2")),
            (String("/staff/x"), 400, String("Bad Request")),
            (String("/staff"), 404, String("Not Found")),
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
            # M2-009: "account 42 Ada" only if the route value reached the
            # handler as Int(42) and the body as a converted CreateUser.
            (
                String("/accounts/042"),
                String("name=Ada"),
                200,
                String("account 42 Ada"),
            ),
            (
                String("/accounts?id=042"),
                String("name=Ada"),
                200,
                String("account 42 Ada"),
            ),
            (
                String("/accounts/abc"),
                String("name=Ada"),
                400,
                String("Bad Request"),
            ),
            (
                String("/accounts?id=abc"),
                String("name=Ada"),
                400,
                String("Bad Request"),
            ),
            (
                String("/accounts"),
                String("name=Ada"),
                400,
                String("Bad Request"),
            ),
            (String("/accounts/1"), String("Ada"), 400, String("Bad Request")),
            (String("/accounts?id=1"), String(""), 400, String("Bad Request")),
            (
                String("/profiles/5"),
                String("name=Ada"),
                200,
                String("Person(5, Ada)"),
            ),
            (
                String("/profiles/x"),
                String("name=Ada"),
                400,
                String("Bad Request"),
            ),
            # M2-011: `raises Rejected` with a typed result.
            (
                String("/orders"),
                String("name=Mallory"),
                500,
                String("Internal Server Error"),
            ),
            (
                String("/orders"),
                String("name=Ada"),
                200,
                String("Person(9, Ada)"),
            ),
            (String("/orders"), String("Ada"), 400, String("Bad Request")),
            # M2-015: the raw handler sees the request as Muntin received
            # it; a query a typed route would answer 400 reaches it.
            (
                String("/webhook?id=abc&id=2"),
                String("signed a=b&c?d \n"),
                202,
                String("POST|/webhook|id=abc&id=2|signed a=b&c?d \n"),
            ),
            (
                String("/webhook"),
                String("signed"),
                202,
                String("POST|/webhook||signed"),
            ),
            (String("/webhook?k"), String(""), 401, String("unsigned k")),
            (String("/webhook/x"), String("signed"), 404, String("Not Found")),
            # M3-006: "Person(2, Lin)" only if the handler read its state
            # (two names) and got the converted body; "Grace -> Lin" only if
            # it also got Int(1) from "01". The 409s are its raises; the
            # 400s are a body or a route value it never saw.
            (
                String("/staff"),
                String("name=Lin"),
                200,
                String("Person(2, Lin)"),
            ),
            (
                String("/staff"),
                String("name=Ada"),
                409,
                String("out of stock 0"),
            ),
            (String("/staff"), String("Lin"), 400, String("Bad Request")),
            (
                String("/staff/01"),
                String("name=Lin"),
                200,
                String("Grace -> Lin"),
            ),
            (
                String("/staff/5"),
                String("name=Lin"),
                409,
                String("out of stock 5"),
            ),
            (
                String("/staff/x"),
                String("name=Lin"),
                400,
                String("Bad Request"),
            ),
            (String("/staff/1"), String(""), 400, String("Bad Request")),
            (
                String("/staff/1/x"),
                String("name=Lin"),
                404,
                String("Not Found"),
            ),
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


def test_headers_over_localhost_match_app_handle() raises:
    var child = _serve_in_child(headers_app())
    var base = String("http://127.0.0.1:", child.port)
    try:
        var client = _client()
        var app = headers_app()
        # Existing responses: only Flare's own fields, as before M3-005.
        var hello_resp = client.get(base + "/hello")
        assert_equal(hello_resp.text(), "hello")
        assert_equal(hello_resp.headers.len(), 3)
        assert_true(hello_resp.headers.contains("content-length"))
        assert_true(hello_resp.headers.contains("date"))
        assert_true(hello_resp.headers.contains("connection"))
        # A raw route reads request fields and writes response fields.
        var req = FlareRequest("POST", base + "/signed", List("b".as_bytes()))
        req.headers.append("X-Signature", "sha256=abc")
        req.headers.append("X-A", "1")
        req.headers.append("x-a", "2")
        var resp = client.send(req)
        var mh = Headers()
        mh.add("X-Signature", "sha256=abc")
        mh.add("X-A", "1")
        mh.add("x-a", "2")
        var local = app.handle(Request("POST", "/signed", "b", mh^))
        assert_equal(resp.status, 202)
        assert_equal(resp.status, local.status)
        assert_equal(resp.text(), local.body)
        assert_equal(resp.text(), "sha256=abc|2")
        assert_equal(resp.headers.get("x-request-id"), "42")
        assert_equal(len(resp.headers.get_all("set-cookie")), 2)
        assert_equal(resp.headers.get_all("set-cookie")[1], "b=2")
        assert_true(resp.headers.contains("x-empty"))
        # Omitted on the wire, kept in memory.
        for name in ["transfer-encoding", "keep-alive", "upgrade", "x-hop"]:
            assert_false(resp.headers.contains(name), name)
            assert_true(Bool(local.headers.get(name)), name)
        assert_equal(resp.headers.get("connection"), "close")
        # The whole kept list: App.handle's fields in order, minus the
        # omitted ones, then Flare's own three.
        var wire = List[UInt8]()
        resp.headers.encode_to(wire)
        var kept = String()
        for line in String(from_utf8_lossy=Span(wire)).split("\r\n"):
            if line.byte_length() == 0 or line.startswith("Date: "):
                continue
            kept += String(line) + ";"
        var expected = String()
        for i in range(len(local.headers)):
            var lower = local.headers.name(i).lower()
            if lower in [
                "transfer-encoding",
                "keep-alive",
                "upgrade",
                "connection",
                "x-hop",
            ]:
                continue
            expected += (
                local.headers.name(i) + ": " + local.headers.value(i) + ";"
            )
        expected += "Content-Length: 12;Connection: close;"
        assert_equal(kept, expected)
        assert_equal(client.post(base + "/signed", "b").status, 401)
        var inj = client.get(base + "/inject")
        assert_equal(inj.status, 500)
        assert_equal(inj.status, app.handle(Request("GET", "/inject")).status)
        assert_false(inj.headers.contains("set-cookie"))
    finally:
        _ = kill(child.pid, SIGKILL)
        waitpid(child.pid)


def _h2_frame(
    typ: FrameType, flags: UInt8, sid: Int, var payload: List[UInt8]
) -> List[UInt8]:
    var f = Frame()
    f.header.type = typ.copy()
    f.header.flags = FrameFlags(flags)
    f.header.stream_id = sid
    f.payload = payload^
    return encode_frame(f)


def h2_get(
    port: Int, path: String, fields: List[Tuple[String, String]]
) raises -> Tuple[List[HpackHeader], String]:
    """One GET over cleartext HTTP/2 (prior knowledge) on stream 1: the
    response's decoded header fields (`:status` first) and its body."""
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(":method", "GET"))
    hdrs.append(HpackHeader(":scheme", "http"))
    hdrs.append(HpackHeader(":path", path))
    hdrs.append(HpackHeader(":authority", "localhost"))
    for f in fields:
        hdrs.append(HpackHeader(f[0], f[1]))
    var block = HpackEncoder().encode(Span[HpackHeader, _](hdrs))
    var wire = List(H2_PREFACE.as_bytes())
    wire.extend(Span(_h2_frame(FrameType.SETTINGS(), 0, 0, List[UInt8]())))
    wire.extend(
        Span(
            _h2_frame(
                FrameType.HEADERS(),
                FrameFlags.END_HEADERS() | FrameFlags.END_STREAM(),
                1,
                block^,
            )
        )
    )
    var stream = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    stream.set_recv_timeout(TIMEOUT_MS)
    stream.write_all(Span[UInt8, _](wire))
    var decoder = HpackDecoder()
    var acc = List[UInt8]()
    var buf = List[UInt8]()
    buf.resize(4096, 0)
    var pos = 0
    var fields_out = List[HpackHeader]()
    var body = List[UInt8]()
    while True:
        var maybe = parse_frame(Span[UInt8, _](acc)[pos:])
        if not maybe:
            var n = stream.read(buf.unsafe_ptr(), len(buf))
            if n == 0:
                raise Error("connection closed before the response ended")
            for k in range(n):
                acc.append(buf[k])
            continue
        var f = maybe.value().copy()
        pos += 9 + f.header.length
        if f.header.stream_id != 1:
            if f.header.type.value == FrameType.GOAWAY().value:
                raise Error("GOAWAY")
            continue
        if f.header.type.value == FrameType.HEADERS().value:
            fields_out = decoder.decode(Span[UInt8, _](f.payload))
        elif f.header.type.value == FrameType.DATA().value:
            body.extend(Span[UInt8, _](f.payload))
        elif f.header.type.value == FrameType.RST_STREAM().value:
            raise Error("RST_STREAM")
        if f.header.flags.has(FrameFlags.END_STREAM()):
            break
    return (fields_out^, String(from_utf8_lossy=Span(body)))


def _h2_fields(fields: List[HpackHeader]) -> String:
    var out = String()
    for f in fields:
        if f.name == "date":
            continue
        out += f.name + "=" + f.value + ";"
    return out^


def test_headers_over_h2c_follow_the_same_rules() raises:
    var child = _serve_in_child(headers_app())
    try:
        var ok = h2_get(
            child.port,
            "/signed",
            [
                (String("x-signature"), String("sha256=abc")),
                (String("x-a"), String("1")),
                (String("x-a"), String("2")),
            ],
        )
        print("observed h2c /signed:", _h2_fields(ok[0]), ok[1])
        assert_equal(
            _h2_fields(ok[0]),
            ":status=202;x-request-id=42;set-cookie=a=1;set-cookie=b=2;x-empty=;",
        )
        assert_equal(ok[1], "sha256=abc|2")
        # HTTP/2 admits `:` inside a name; Muntin cannot represent it.
        var forged = h2_get(
            child.port,
            "/signed",
            [
                (String("x-signature"), String("sha256=abc")),
                (String("x-user:admin"), String("zzz")),
            ],
        )
        print("observed h2c forged:", _h2_fields(forged[0]), forged[1])
        assert_equal(forged[0][0].value, "400")
        assert_equal(forged[1], "Bad Request")
    finally:
        _ = kill(child.pid, SIGKILL)
        waitpid(child.pid)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
