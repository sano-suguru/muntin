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

M3-007 registers the stateful raw `GET /keyed` and `POST /keyed` ->
`keyed(signer: State[Signer], req: Request) raises Unsigned -> Response` on
`headers_app()`, with `Signer` defined here and its `State` built inside
`headers_app()`. The handler compares `X-Signature` with the state's secret
and echoes the secret with the whole request (method, path, a query a typed
route would answer 400, body, the repeated `X-A` count); it sets response
fields, one of which (`Keep-Alive`) the adapter omits. Over HTTP/1.1 status,
body and the kept fields equal `App.handle`; a missing signature (also
through `TestClient`) and a wrong one raise `Unsigned`, answered 401 by
`to_error_response` in Muntin. The adapter is unchanged.

M3-009 serves `json_app()`: the JSON body route `POST /greet` ->
`greet(var body: Json[Greeting]) -> Json[Greeting]` and its stateful twin
`POST /greet/{id}` (state `Greeter`). Over HTTP/1.1, `application/json; charset=utf-8` is
200 with `Content-Type: application/json` on the wire, a missing field
(the request built without one: Flare's `post(url, String)` adds
`application/json` itself) and `text/plain` are 415, a body over 1 MiB is
413, and malformed JSON is 400; each status, body and `Content-Type` equals
`App.handle` with the same fields. The adapter is unchanged.

M3-013 registers the stateful carrier route `POST /signed-greet` ->
`signed_greet(gate: State[Gate], input: WithHeaders[Json[Greeting]])
raises Unsigned -> Json[Greeting]` on `json_app()`, with `Gate` defined
here. The handler reads the credential and echoes the repeated `X-A`/`x-a`
fields, in order and with their casing, as Muntin received them (Flare's
client adds fields of its own, which the handler does not echo). Over
HTTP/1.1 the fields reach the handler, a missing credential is the
handler's 401 (`Unsigned`), and a missing `Content-Type` is 415 before the
handler, with 200 when it is sent; each status and body equals
`App.handle` with the test's fields. The adapter is unchanged.

M3-017 registers the stateful typed `GET /signed/{id}` ->
`signed_note(gate: State[Gate], id: Int, headers: Headers) raises Unsigned
-> String` on `headers_app()`. The handler reads the credential and echoes
the route value and the repeated `X-A`/`x-a` fields, in order and with their
casing. Over HTTP/1.1 the fields reach the handler (200), a missing
credential is the handler's 401 (`Unsigned`), and an invalid route value is
400 before the fields are rebuilt; each status and body equals `App.handle`
with the test's fields. The adapter is unchanged.

M3-021 registers `PUT /notes/{id}` -> `replace_note`, `PATCH /notes/{id}` ->
`patch_note` (each an `Int` then a `CreateUser` body), `DELETE /notes/{id}`
-> `delete_note(id: Int)` and the raw `DELETE /purge` -> `purge`, which
echoes the request, on `users_app()`. Flare delivers each method with its
body unchanged: `PUT` and `PATCH` with a body, `DELETE` without one and, to
the raw route, with one. Each status and body equals `TestClient`'s new
method, or `App.handle` for the `DELETE` with a body. A lowercase `delete` is
400 from Flare's parser before `App.handle`, which would answer it 404: a
current backend limit, not Muntin's matching. The adapter is unchanged.

M3-025 registers `GET /pages?{size}` -> `page_of(size: Optional[Int])` on
`users_app()`. Muntin reads an absent key, `size=` and `size` (no `=`) as
`None`, so the backend must pass the query as received, a bare key and a
trailing `=` included; each status and body equals `TestClient`'s. The
adapter is unchanged.

M3-027 sends `HEAD` to `headers_app()`, which gains the raw `GET /nm`
(304) and `GET /rc` (205), each answering with a 3-byte body. Over h2c
(the raw client takes the method), a typed route, the raw `GET /keyed`
(which sees `HEAD`), a route-value 400 and the adapter's own 400 (a field
named `x-user:admin`) go out with their status, a `content-length` equal to
`App.handle`'s body and no DATA frame, as does a 404; the 304 and 205 with no
`content-length` and no DATA frame. Over HTTP/1.1 the same routes give
their status and `Content-Length` (Flare's client reads no content for
`HEAD`, so its empty body is no evidence; `compat/flare/head/head_probe.mojo`
reads the raw bytes).
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
    FromJson,
    Json,
    JsonValue,
    JsonWriter,
    Request,
    Response,
    State,
    ToErrorResponse,
    ToJson,
    ToResponse,
    WithHeaders,
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


def name_of(name: String) -> String:
    return "name " + name


def search(q: String) -> String:
    return "results for " + q


def pair_of(a: Int, b: String) -> String:
    return String("pair ", a, " ", b)


def field_of(id: Int, field: String) -> String:
    return String("field ", id, " ", field)


def page_of(size: Optional[Int]) -> String:
    return "page size " + String(size.or_else(20))


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


struct Signer(Movable):
    """Application state for `keyed`: the expected signature."""

    var secret: String

    def __init__(out self, secret: String):
        self.secret = secret


def keyed(signer: State[Signer], req: Request) raises Unsigned -> Response:
    """A stateful raw handler (M3-007): checks `X-Signature` against the
    state, echoes the whole request with the secret, and sets response
    fields, one of which the adapter omits on the wire."""
    var sig = req.headers.get("x-signature")
    if not sig or sig.value() != signer[].secret:
        raise Unsigned(req.query)
    var resp = Response.text(
        signer[].secret
        + "|"
        + req.method
        + "|"
        + req.path
        + "|"
        + req.query
        + "|"
        + req.body
        + "|"
        + String(len(req.headers.get_all("x-a"))),
        status=202,
    )
    try:
        resp.headers.add("X-Request-Id", "43")
        resp.headers.add("Set-Cookie", "s=1")
        resp.headers.add("Set-Cookie", "t=2")
        resp.headers.add("Keep-Alive", "timeout=5")
    except:
        pass
    return resp^


def replace_note(id: Int, body: CreateUser) -> String:
    return "replaced " + String(id) + " " + body.name


def patch_note(id: Int, body: CreateUser) -> String:
    return "patched " + String(id) + " " + body.name


def delete_note(id: Int) -> String:
    return "deleted " + String(id)


def purge(req: Request) -> Response:
    """A raw `delete` handler: a `DELETE` body reaches only a raw handler."""
    return Response.text(
        req.method + "|" + req.path + "|" + req.query + "|" + req.body,
        status=202,
    )


def not_modified(var req: Request) -> Response:
    """A raw 304 with a body Muntin does not define as the representation."""
    return Response(304, "abc")


def reset_content(var req: Request) -> Response:
    """A raw 205 with a body, which a 205 never carries."""
    return Response(205, "abc")


def headers_app() -> App:
    var app = App()
    app.get["/hello"](hello)
    app.post["/signed"](signed)
    app.get["/signed"](signed)
    app.get["/inject"](inject_header)
    var signer = State(Signer("sha256=k"))
    app.get["/keyed"](keyed, signer)
    app.post["/keyed"](keyed, signer)
    app.get["/signed/{id}"](signed_note, State(Gate("t0k")))
    app.get["/nm"](not_modified)
    app.get["/rc"](reset_content)
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
    app.get["/names/{name}"](name_of)
    app.get["/search?{q}"](search)
    app.get["/pairs/{a}/{b}"](pair_of)
    app.get["/fields/{id}?{field}"](field_of)
    app.get["/pages?{size}"](page_of)
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
    app.put["/notes/{id}"](replace_note)
    app.patch["/notes/{id}"](patch_note)
    app.delete["/notes/{id}"](delete_note)
    app.delete["/purge"](purge)
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
            # M3-019: Muntin decodes a route value once, so the backend must
            # pass the target encoded. Decoded twice, "%2541" would be "A",
            # "a%2Fb" would split a segment (404), and "%2534" would be 4.
            (String("/names/%2541"), 200, String("name %41")),
            (String("/names/a%2Fb"), 200, String("name a/b")),
            (String("/names/a+b"), 200, String("name a+b")),
            (String("/search?q=a+b%2B"), 200, String("results for a b+")),
            (String("/users/%34%32"), 200, String("42")),
            (String("/users/%2534"), 400, String("Bad Request")),
            # M3-023: two route values, each decoded once. Decoded twice, the
            # second "%2541" would be "A"; "%zz" and "%FF" in the second
            # value are 400 after a valid first one.
            (String("/pairs/042/%2541"), 200, String("pair 42 %41")),
            (String("/pairs/1/a%2Fb"), 200, String("pair 1 a/b")),
            (String("/pairs/1/%zz"), 400, String("Bad Request")),
            (String("/pairs/x/a"), 400, String("Bad Request")),
            (
                String("/fields/7?x=1&field=%2541+b"),
                200,
                String("field 7 %41 b"),
            ),
            (String("/fields/7?field=%FF"), 400, String("Bad Request")),
            (String("/fields/7"), 400, String("Bad Request")),
            # M3-025: an optional value is `None` for an absent key, `size=`
            # and a bare `size`, so "page size 20" for each; "page size 5"
            # only if the present value reached the handler.
            (String("/pages"), 200, String("page size 20")),
            (String("/pages?size="), 200, String("page size 20")),
            (String("/pages?size"), 200, String("page size 20")),
            (String("/pages?size=5"), 200, String("page size 5")),
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

        # M3-021: Flare delivers `PUT`, `PATCH` and `DELETE`, with and
        # without a body, to `App.handle` with the method and body
        # unchanged; "replaced 42 Ada" only if the route value and the body
        # were converted, and the raw route echoes the `DELETE` body.
        var methods = [
            (
                String("PUT"),
                String("/notes/042"),
                String("name=Ada"),
                200,
                String("replaced 42 Ada"),
            ),
            (
                String("PUT"),
                String("/notes/x"),
                String("name=Ada"),
                400,
                String("Bad Request"),
            ),
            (
                String("PUT"),
                String("/notes/1"),
                String("Ada"),
                400,
                String("Bad Request"),
            ),
            (
                String("PATCH"),
                String("/notes/7"),
                String("name=Bo"),
                200,
                String("patched 7 Bo"),
            ),
            (
                String("DELETE"),
                String("/notes/7"),
                String(""),
                200,
                String("deleted 7"),
            ),
            (
                String("DELETE"),
                String("/notes/x"),
                String(""),
                400,
                String("Bad Request"),
            ),
            (
                String("DELETE"),
                String("/purge?k=v"),
                String(""),
                202,
                String("DELETE|/purge|k=v|"),
            ),
            (
                String("DELETE"),
                String("/purge"),
                String(" a=b&c?d \n"),
                202,
                String("DELETE|/purge|| a=b&c?d \n"),
            ),
            (
                String("POST"),
                String("/notes/7"),
                String("name=Ada"),
                404,
                String("Not Found"),
            ),
        ]
        for want in methods:
            var method = want[0]
            var path = want[1]
            var body = want[2]
            var at = method + " " + path + " " + body
            var response = client.send(
                FlareRequest(method, base + path, List(body.as_bytes()))
            )
            print("observed:", at, response.status, repr(response.text()))
            assert_equal(response.status, want[3], at)
            assert_equal(response.text(), want[4], at)

            var local: Response
            if method == "PUT":
                local = in_memory.put(path, body)
            elif method == "PATCH":
                local = in_memory.patch(path, body)
            elif method == "POST":
                local = in_memory.post(path, body)
            elif body:
                local = app.handle(Request(method, path, body))
            else:
                local = in_memory.delete(path)
            assert_equal(response.status, local.status, at)
            assert_equal(response.text(), local.body, at)

        # A current Flare limit: its HTTP/1.1 parser answers a method with a
        # lowercase letter 400 before `App.handle`, which matches methods
        # byte for byte and would answer 404.
        var lowercase = client.send(
            FlareRequest("delete", base + "/notes/7", List[UInt8]())
        )
        print("observed: delete /notes/7", lowercase.status)
        assert_equal(lowercase.status, 400)
        assert_equal(app.handle(Request("delete", "/notes/7")).status, 404)
    finally:
        _ = kill(child.pid, SIGKILL)
        waitpid(child.pid)


def test_headers_over_localhost_match_app_handle() raises:
    var child = _serve_in_child(headers_app())
    var base = String("http://127.0.0.1:", child.port)
    try:
        var client = _client()
        var app = headers_app()
        # Existing responses: only Flare's own fields.
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


def _kept_on_wire(resp: Response) -> String:
    """`resp`'s fields as the adapter writes them, in order: the omitted
    connection-specific ones dropped."""
    var out = String()
    for i in range(len(resp.headers)):
        var lower = resp.headers.name(i).lower()
        if lower in ["transfer-encoding", "keep-alive", "upgrade"]:
            continue
        out += resp.headers.name(i) + ": " + resp.headers.value(i) + ";"
    return out^


def test_stateful_raw_over_localhost_matches_app_handle() raises:
    # M3-007: stateful raw GET and POST /keyed read the state and the whole
    # request, headers included, and set response fields (M3-005 composes
    # with State); a missing or wrong signature raises `Unsigned` (401).
    var child = _serve_in_child(headers_app())
    var base = String("http://127.0.0.1:", child.port)
    try:
        var client = _client()
        var app = headers_app()
        var in_memory = TestClient(app)
        for method in ["GET", "POST"]:
            var body = String("b?=&") if method == "POST" else String()
            var req = FlareRequest(
                method, base + "/keyed?id=x&id=2", List(body.as_bytes())
            )
            req.headers.append("X-Signature", "sha256=k")
            req.headers.append("X-A", "1")
            req.headers.append("x-a", "2")
            var resp = client.send(req)
            var mh = Headers()
            mh.add("X-Signature", "sha256=k")
            mh.add("X-A", "1")
            mh.add("x-a", "2")
            var local = app.handle(
                Request(method, "/keyed?id=x&id=2", body, mh^)
            )
            print("observed:", method, "/keyed", resp.status, repr(resp.text()))
            assert_equal(resp.status, 202, method)
            assert_equal(resp.status, local.status, method)
            assert_equal(resp.text(), local.body, method)
            assert_equal(
                resp.text(),
                "sha256=k|" + method + "|/keyed|id=x&id=2|" + body + "|2",
            )
            # The handler's fields in order, minus the omitted Keep-Alive
            # (kept in memory), then Flare's own.
            var wire = List[UInt8]()
            resp.headers.encode_to(wire)
            var kept = String()
            for line in String(from_utf8_lossy=Span(wire)).split("\r\n"):
                if line.byte_length() == 0 or line.startswith("Date: "):
                    continue
                kept += String(line) + ";"
            assert_equal(
                kept,
                _kept_on_wire(local)
                + "Content-Length: "
                + String(local.body.byte_length())
                + ";Connection: close;",
                method,
            )
            assert_false(resp.headers.contains("keep-alive"), method)
            assert_true(Bool(local.headers.get("keep-alive")), method)

            # The application error, decided from the state: no signature
            # (TestClient sends none) and a wrong one.
            var unsigned = client.send(
                FlareRequest(method, base + "/keyed?k", List(body.as_bytes()))
            )
            var local_unsigned = in_memory.get(
                "/keyed?k"
            ) if method == "GET" else in_memory.post("/keyed?k", body)
            assert_equal(unsigned.status, 401, method)
            assert_equal(unsigned.text(), "unsigned k", method)
            assert_equal(unsigned.status, local_unsigned.status, method)
            assert_equal(unsigned.text(), local_unsigned.body, method)
            assert_equal(len(local_unsigned.headers), 0)
            var forged = FlareRequest(method, base + "/keyed", List[UInt8]())
            forged.headers.append("X-Signature", "sha256=forged")
            var forged_resp = client.send(forged)
            var fh = Headers()
            fh.add("X-Signature", "sha256=forged")
            var local_forged = app.handle(Request(method, "/keyed", "", fh^))
            assert_equal(forged_resp.status, 401, method)
            assert_equal(forged_resp.status, local_forged.status, method)
            assert_equal(forged_resp.text(), local_forged.body, method)
        # The route is GET and POST only; no other path reaches it.
        assert_equal(
            client.send(
                FlareRequest("PUT", base + "/keyed", List[UInt8]())
            ).status,
            404,
        )
        assert_equal(client.get(base + "/keyed/x").status, 404)
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


def h2_request(
    port: Int,
    method: String,
    path: String,
    fields: List[Tuple[String, String]],
) raises -> Tuple[List[HpackHeader], String, Int]:
    """One request over cleartext HTTP/2 (prior knowledge) on stream 1: the
    response's decoded header fields (`:status` first), its body and the
    number of DATA frames it came in (an empty DATA frame counts)."""
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(":method", method))
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
    var data_frames = 0
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
            data_frames += 1
        elif f.header.type.value == FrameType.RST_STREAM().value:
            raise Error("RST_STREAM")
        if f.header.flags.has(FrameFlags.END_STREAM()):
            break
    return (fields_out^, String(from_utf8_lossy=Span(body)), data_frames)


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
        var ok = h2_request(
            child.port,
            "GET",
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
        var forged = h2_request(
            child.port,
            "GET",
            "/signed",
            [
                (String("x-signature"), String("sha256=abc")),
                (String("x-user:admin"), String("zzz")),
            ],
        )
        print("observed h2c forged:", _h2_fields(forged[0]), forged[1])
        assert_equal(forged[0][0].value, "400")
        assert_equal(forged[1], "Bad Request")

        # M3-027: HEAD at every exit of `MuntinHandler.serve`. (target,
        # fields, status, content-length or "" for none); each goes out
        # with no DATA frame.
        var app = headers_app()
        var sig = (String("x-signature"), String("sha256=k"))
        var auth = (String("authorization"), String("t0k"))
        var admin = (String("x-user:admin"), String("zzz"))
        var none = List[Tuple[String, String]]()
        var signed = none.copy()
        signed.append(sig)
        var authorized = none.copy()
        authorized.append(auth)
        var forged_name = none.copy()
        forged_name.append(admin)
        var cases = [
            (String("/hello"), none.copy(), 200, String("5")),
            # The raw handler sees HEAD: its own answer's length goes out.
            (String("/keyed?k"), signed^, 202, String("")),
            (String("/signed/x"), authorized^, 400, String("11")),
            (String("/hello"), forged_name^, 400, String("11")),
            (String("/missing"), none.copy(), 404, String("9")),
            (String("/nm"), none.copy(), 304, String("")),
            (String("/rc"), none.copy(), 205, String("")),
        ]
        for c in cases:
            var target = c[0]
            var head = h2_request(child.port, "HEAD", target, c[1])
            var label = String(target, " ", len(c[1]))
            print(
                "observed h2c HEAD",
                label,
                _h2_fields(head[0]),
                "DATA frames:",
                head[2],
            )
            assert_equal(head[0][0].value, String(c[2]), label)
            assert_equal(head[1], "", label)
            assert_equal(head[2], 0, label)
            var length = c[3]
            if target == "/keyed?k":
                var h = Headers()
                h.add("x-signature", "sha256=k")
                var local = app.handle(Request("HEAD", target, "", h^))
                assert_equal(local.body, "sha256=k|HEAD|/keyed|k||0")
                length = String(local.body.byte_length())
            var got = String("")
            for f in head[0]:
                if f.name == "content-length":
                    got = f.value
            assert_equal(got, length, label)
        # Status and fields are the GET's: the content-length is added last.
        var get = h2_request(child.port, "GET", "/hello", none)
        var head = h2_request(child.port, "HEAD", "/hello", none)
        assert_equal(get[1], "hello")
        assert_equal(
            _h2_fields(head[0]), _h2_fields(get[0]) + "content-length=5;"
        )
        var nm_get = h2_request(child.port, "GET", "/nm", none)
        assert_equal(nm_get[1], "abc")

        # Over HTTP/1.1, Flare's client reads no content for HEAD whatever
        # is sent, so only status and Content-Length are evidence here; the
        # no-content evidence is compat/flare/head/head_probe.mojo's raw
        # bytes.
        var base = String("http://127.0.0.1:", child.port)
        var client = _client()
        var h1_cases = [
            (String("/hello"), String(""), 200, String("5")),
            (String("/keyed?k"), String("sha256=k"), 202, String("25")),
            (String("/signed/x"), String(""), 400, String("11")),
        ]
        for c in h1_cases:
            var req = FlareRequest("HEAD", base + c[0], List[UInt8]())
            if c[1].byte_length() > 0:
                req.headers.append("X-Signature", c[1])
            var resp = client.send(req)
            print(
                "observed HTTP/1.1 HEAD",
                c[0],
                resp.status,
                repr(resp.headers.get("content-length")),
            )
            assert_equal(resp.status, c[2], c[0])
            assert_equal(resp.headers.get("content-length"), c[3], c[0])
        # Only the exact token maps: Flare answers `head` and `Head` 400
        # before `App.handle`, which would answer them 404.
        for method in ["head", "Head"]:
            var other = client.send(
                FlareRequest(method, base + "/hello", List[UInt8]())
            )
            print("observed:", method, "/hello", other.status)
            assert_equal(other.status, 400, method)
            assert_equal(app.handle(Request(method, "/hello")).status, 404)
    finally:
        _ = kill(child.pid, SIGKILL)
        waitpid(child.pid)


@fieldwise_init
struct Greeting(FromJson, ToJson):
    var name: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string())

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("hello")
        out.string(self.name)
        out.end_object()


def greet(var body: Json[Greeting]) -> Json[Greeting]:
    return Json(body^.take())


@fieldwise_init
struct Greeter(Movable):
    var title: String


def greet_staff(
    greeter: State[Greeter], id: Int, var body: Json[Greeting]
) -> Json[Greeting]:
    var g = body^.take()
    return Json(Greeting(greeter[].title + g.name + " #" + String(id)))


@fieldwise_init
struct Gate(Movable):
    var token: String


def signed_greet(
    gate: State[Gate], input: WithHeaders[Json[Greeting]]
) raises Unsigned -> Json[Greeting]:
    var token = input.headers.get("authorization")
    if not token or token.value() != gate[].token:
        raise Unsigned("no credential")
    var seen = String()
    for i in range(len(input.headers)):
        if input.headers.name(i).lower() == "x-a":
            seen += " " + input.headers.name(i) + "=" + input.headers.value(i)
    return Json(Greeting(input.body.value.name + seen))


def signed_note(
    gate: State[Gate], id: Int, headers: Headers
) raises Unsigned -> String:
    """A stateful typed `get` handler with a `Headers` slot (M3-017)."""
    var token = headers.get("authorization")
    if not token or token.value() != gate[].token:
        raise Unsigned("no credential")
    var seen = String("note ", id)
    for i in range(len(headers)):
        if headers.name(i).lower() == "x-a":
            seen += " " + headers.name(i) + "=" + headers.value(i)
    return seen


def json_app() -> App:
    var app = App()
    app.post["/greet"](greet)
    app.post["/greet/{id}"](greet_staff, State(Greeter("Dr. ")))
    app.post["/signed-greet"](signed_greet, State(Gate("t0k")))
    return app^


def _json_request(url: String, body: String, ct: String) raises -> FlareRequest:
    var req = FlareRequest("POST", url, List(body.as_bytes()))
    if ct.byte_length() > 0:
        req.headers.append("Content-Type", ct)
    return req^


def test_json_over_localhost_matches_app_handle() raises:
    var child = _serve_in_child(json_app())
    var base = String("http://127.0.0.1:", child.port)
    try:
        var client = _client()
        var app = json_app()
        var good = '{"name":"Ad\\u00e9 \\"x\\""}'
        var big = '{"name":"b"}' + String(" ") * 1_048_565
        var cases = [
            (String(""), good, String("application/json; charset=utf-8"), 200),
            (String(""), good, String(""), 415),
            (String(""), good, String("text/plain"), 415),
            (String(""), big, String("application/json"), 413),
            (String(""), String('{"name":'), String("application/json"), 400),
            (String("/7"), good, String("application/json"), 200),
            (String("/7"), good, String(""), 415),
            (String("/7"), big, String("application/json"), 413),
            (String("/x"), big, String("text/plain"), 400),
        ]
        for c in cases:
            var path = "/greet" + c[0]
            var body = c[1]
            var ct = c[2]
            var resp = client.send(_json_request(base + path, body, ct))
            var h = Headers()
            if ct.byte_length() > 0:
                h.add("Content-Type", ct)
            var local = app.handle(Request("POST", path, body, h^))
            var label = path + " " + ct + " " + String(body.byte_length())
            print("observed: POST", label, resp.status, repr(resp.text()))
            assert_equal(resp.status, c[3], label)
            assert_equal(resp.status, local.status, label)
            assert_equal(resp.text(), local.body, label)
            if c[3] == 200:
                assert_equal(
                    resp.headers.get("content-type"), "application/json"
                )
                assert_equal(
                    local.headers.get("content-type").value(),
                    "application/json",
                )
            else:
                assert_false(resp.headers.contains("content-type"), label)
                assert_equal(len(local.headers), 0, label)
        assert_equal(
            client.send(
                _json_request(base + "/greet", good, "application/json")
            ).text(),
            '{"hello":"Adé \\"x\\""}',
        )
        assert_equal(big.byte_length(), 1_048_577)
    finally:
        _ = kill(child.pid, SIGKILL)
        waitpid(child.pid)


def test_with_headers_over_localhost_matches_app_handle() raises:
    var child = _serve_in_child(json_app())
    var base = String("http://127.0.0.1:", child.port)
    try:
        var client = _client()
        var app = json_app()
        var good = String('{"name":"Ada"}')
        var ct = String("application/json")
        # (Content-Type, credential, status): 200 with both, the handler's
        # 401 without the credential, 415 without Content-Type.
        var cases = [
            (ct, String("t0k"), 200),
            (ct, String(""), 401),
            (String(""), String("t0k"), 415),
        ]
        for c in cases:
            var req = FlareRequest(
                "POST", base + "/signed-greet", List(good.as_bytes())
            )
            var mh = Headers()
            req.headers.append("X-A", "1")
            mh.add("X-A", "1")
            if c[0].byte_length() > 0:
                req.headers.append("Content-Type", c[0])
                mh.add("Content-Type", c[0])
            if c[1].byte_length() > 0:
                req.headers.append("Authorization", c[1])
                mh.add("Authorization", c[1])
            req.headers.append("x-a", "2")
            mh.add("x-a", "2")
            var resp = client.send(req)
            var local = app.handle(Request("POST", "/signed-greet", good, mh^))
            var label = c[0] + " " + c[1]
            print(
                "observed: POST /signed-greet",
                label,
                resp.status,
                repr(resp.text()),
            )
            assert_equal(resp.status, c[2], label)
            assert_equal(resp.status, local.status, label)
            assert_equal(resp.text(), local.body, label)
            if c[2] == 200:
                # The fields in order, with their casing, over the wire.
                assert_equal(resp.text(), '{"hello":"Ada X-A=1 x-a=2"}')
    finally:
        _ = kill(child.pid, SIGKILL)
        waitpid(child.pid)


def test_get_headers_over_localhost_match_app_handle() raises:
    var child = _serve_in_child(headers_app())
    var base = String("http://127.0.0.1:", child.port)
    try:
        var client = _client()
        var app = headers_app()
        # (path, credential, status): 200 with the credential, the handler's
        # 401 without it, the route value's 400 before the fields.
        var cases = [
            (String("/signed/7"), String("t0k"), 200),
            (String("/signed/7"), String(""), 401),
            (String("/signed/x"), String("t0k"), 400),
        ]
        for c in cases:
            var req = FlareRequest("GET", base + c[0], List[UInt8]())
            var mh = Headers()
            req.headers.append("X-A", "1")
            mh.add("X-A", "1")
            if c[1].byte_length() > 0:
                req.headers.append("Authorization", c[1])
                mh.add("Authorization", c[1])
            req.headers.append("x-a", "2")
            mh.add("x-a", "2")
            var resp = client.send(req)
            var local = app.handle(Request("GET", c[0], "", mh^))
            var label = c[0] + " " + c[1]
            print("observed: GET", label, resp.status, repr(resp.text()))
            assert_equal(resp.status, c[2], label)
            assert_equal(resp.status, local.status, label)
            assert_equal(resp.text(), local.body, label)
            if c[2] == 200:
                # The fields in order, with their casing, over the wire.
                assert_equal(resp.text(), "note 7 X-A=1 x-a=2")
    finally:
        _ = kill(child.pid, SIGKILL)
        waitpid(child.pid)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
