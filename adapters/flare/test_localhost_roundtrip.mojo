"""Real localhost HTTP round trip through Flare and Muntin (M1-003).

Runs only in the `flare` pixi environment (see scripts/check_flare.sh). A real
HTTP/1.1 client sends `GET /hello` over a loopback TCP connection to the
adapter's `Server`, which serves the `App` through Flare's `HttpServer` and
calls `App.handle`.

Lifecycle (M3-033): every server here is the supported one,
`Server.bind("127.0.0.1", 0)` in the parent and `server.serve(app)` in a
forked child, because `serve` owns the calling thread, as in Flare's own
integration tests. `Server.bind` returns a listening socket (`listen(2)`,
backlog 128) on an ephemeral loopback port, so the kernel queues the client's
connection even before the child enters `serve`: readiness is `bind`
returning, with no sleep. The client has connect and read timeouts; the parent SIGKILLs and reaps
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
`to_error_response` in Muntin. `GET /webhook` is 405 with `Allow: POST`
(M3-031). The adapter only
carries the request and the final `Response`. Each must equal `TestClient`.

M3-003 registers the stateful `GET /staff/{id}` -> `find_staff(staff:
State[Staff], id: Int) raises OutOfStock -> Person`, with `Staff` defined
here and its `State` built inside `users_app()`, so the child's `App` and
the in-memory one each own a value, served with its `App`. The handler reads the state, receives the converted `Int`
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
request field named `x-user/admin`, which Flare admits over HTTP/2 and
Muntin's `Headers` cannot represent (not a token), is answered 400, as is a
value that is not UTF-8, which Flare passes through byte for byte.

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
`App.handle` with the same fields. The adapter is unchanged. M3-029 adds
`POST /greet-created` (`Json(..., status=201)`): 201 with the same body and
`Content-Type` on the wire, 415 without the field.

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
400 from Flare's parser before `App.handle`, which would answer it 405: a
current backend limit, not Muntin's matching; an unknown uppercase method
(`FOO`) reaches `App.handle` and is 405 with `Allow`. The adapter is
unchanged.

M3-025 registers `GET /pages?{size}` -> `page_of(size: Optional[Int])` on
`users_app()`. Muntin reads an absent key, `size=` and `size` (no `=`) as
`None`, so the backend must pass the query as received, a bare key and a
trailing `=` included; each status and body equals `TestClient`'s. The
adapter is unchanged.

M3-027 sends `HEAD` to `headers_app()`, which gains the raw `GET /report`
(the same body and fields for `GET` and `HEAD`, as DX's raw rule asks), and
the raw `GET /nm` (304) and `GET /rc` (205), each answering with a 3-byte
body. Over h2c (the raw client takes the method), a typed route, the raw
`/report`, a route-value 400 and the adapter's own 400 (a field named
`x-user/admin`) go out with their status, a `content-length` equal to
`App.handle`'s body and no DATA frame, as does a 404; the 304 and 205 with no
`content-length` and no DATA frame. Over HTTP/1.1 the same routes give
their status and `Content-Length` (Flare's client reads no content for
`HEAD`, so its empty body is no evidence; `compat/flare/head/head_probe.mojo`
reads the raw bytes).

M3-031 answers a request whose path a route matches but whose method none
does 405 `Method Not Allowed` with `Allow`. Over HTTP/1.1 the typed, body,
method and stateful raw cases above that are now 405 compare `Allow` with
`App.handle`'s. `headers_app()` gains the raw `POST /form`, the only route on
its path: `HEAD /form` is 405 with `Allow: POST`, `Content-Length: 18` and no
content, over h2c (no DATA frame) and over HTTP/1.1 (read as raw bytes); over
h2c `POST /hello` is 405 with an `allow` equal to `App.handle`'s and the body
in DATA. A lowercase `head` is still Flare's 400. The adapter is unchanged.

M3-035 registers the middleware `tracing` on `hello_app()`, which adds
`X-Trace: 1` to every answer, so `Server` is shown to run middleware: over
HTTP/1.1 and over h2c, `GET /hello` and the 404 carry the field, and
`HEAD /hello` carries it with the GET's status and fields, a content length of
5 and no content (no DATA frame over h2c; over HTTP/1.1 read as raw bytes),
so the adapter's `HEAD` step applies to the middleware's answer. The adapter
is unchanged.

M3-038 serves `bodies_app()` (middleware adding `X-Seen: 1`, a raw
`POST /bytes` answering the hex of the body bytes it received, a raw
`POST /echo-raw` answering its body unchanged, the typed `POST /echo`, the
JSON `POST /greet` and `GET /hello`) and sends request bodies with raw
clients over HTTP/1.1 (`h1_exchange`) and h2c (`h2_exchange`, the body in
one DATA frame), reading the response bytes unparsed. A well-formed UTF-8
body (a U+FFFD the client sent, NUL, empty and an octet stream that happens
to be UTF-8 included) reaches `App.handle` byte for byte, equal to
`App.handle`'s answer, and comes back unchanged; a body that is not UTF-8
(`0x80`, `0xFF`, truncated, overlong, a surrogate, a sent U+FFFD then
`0xFF`, the PNG signature) is the adapter's 400 before `App.handle` on a
route, a 405 path and a 404 path, without the middleware's field, and
under the `HEAD` rule over h2c; the JSON route parses a sent U+FFFD and
answers 400 to a `0xFF` it parsed as U+FFFD before.

M3-039 serves `targets_app()` (`marked`, `GET /hello`, `GET /names/{name}`
and `GET /items?{limit}`) and sends methods and targets whose bytes are not
UTF-8 over h2c, where Flare v0.12.0 passes them to the adapter, with the raw
h2c client (`h2_streams` puts several requests on one connection). Each,
method or target (path, query, a byte where `Request` or `App.handle` would
slice), is the adapter's 400 `Bad Request` without the middleware's field
(under the `HEAD` rule for `HEAD`); after each, the same connection answers
a well-formed request on its next stream, a new connection answers one, and
the serving child is still running. Well-formed methods and targets (non-ASCII
UTF-8, a U+FFFD the client sent, percent-encoded bytes, an empty, unknown or
lowercase method, 404, 405 and `HEAD`) are answered as `App.handle` answers
them, through the middleware. Over HTTP/1.1 Flare refuses every such byte
itself, well-formed or not, with its own `400 Bad Request` body, and the
child keeps answering.
"""

from std.ffi import c_int, c_uint, external_call
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from flare.http import HttpClient
from flare.http import Request as FlareRequest
from flare.http.proto import ascii_unchecked_string
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
    Next,
    Request,
    Response,
    State,
    ToErrorResponse,
    ToJson,
    ToResponse,
    WithHeaders,
)
from muntin.testing import TestClient
from muntin_flare import Server

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
    var text: String
    try:
        text = req.text()
    except:
        raise Unsigned(req.query)
    if not text.startswith("signed"):
        raise Unsigned(req.query)
    return Response.text(
        req.method + "|" + req.path + "|" + req.query + "|" + text,
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
    var text: String
    try:
        text = req.text()
    except:
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
        + text
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


def purge(req: Request) raises -> Response:
    """A raw `delete` handler: a `DELETE` body reaches only a raw handler."""
    return Response.text(
        req.method + "|" + req.path + "|" + req.query + "|" + req.text(),
        status=202,
    )


def report(req: Request) raises -> Response:
    """A raw `get` handler that follows DX's raw rule: the `GET` body and
    fields for `HEAD` too."""
    var resp = Response.text("report")
    resp.headers.add("X-Report", "1")
    return resp^


def not_modified(var req: Request) -> Response:
    """A raw 304 with a body Muntin does not define as the representation."""
    return Response(304, "abc")


def reset_content(var req: Request) -> Response:
    """A raw 205 with a body, which a 205 never carries."""
    return Response(205, "abc")


def form(req: Request) -> Response:
    """A raw `post` route, the only route on its path (M3-031)."""
    return Response.text("form")


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
    app.get["/report"](report)
    app.get["/nm"](not_modified)
    app.get["/rc"](reset_content)
    app.post["/form"](form)
    return app^


def tracing(var request: Request, var next: Next) raises -> Response:
    """Adds `X-Trace: 1` to every answer (M3-035)."""
    var response = next^.run(request^)
    response.headers.add("X-Trace", "1")
    return response^


def hello_app() -> App:
    var app = App()
    app.use(tracing)
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


def _serve_in_child(app: App) raises -> _Child:
    """Binds an ephemeral loopback port and forks a child serving `app` there
    through `Server`. The caller must SIGKILL and reap `pid`."""
    var server = Server.bind("127.0.0.1", 0)
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
        assert_equal(response.text(), expected.text())

        # A constant response that skipped App.handle would also say "hello";
        # an unregistered path must reach the router and come back 404.
        var missing = client.get(base + "/missing")
        assert_equal(missing.status, 404)
        assert_equal(missing.text(), "Not Found")

        # M3-035: the App's middleware runs behind `Server`, for the route,
        # the 404 and `HEAD`, whose content the adapter still drops.
        assert_equal(expected.headers.get("X-Trace").value(), "1")
        assert_equal(response.headers.get("x-trace"), "1")
        assert_equal(missing.headers.get("x-trace"), "1")
        var head = client.head(base + "/hello")
        print(
            "observed HTTP/1.1 HEAD /hello:",
            head.status,
            repr(head.headers.get("x-trace")),
            repr(head.headers.get("content-length")),
        )
        assert_equal(head.status, 200)
        assert_equal(head.headers.get("x-trace"), "1")
        assert_equal(head.headers.get("content-length"), "5")
        var raw_head = h1_raw(child.port, "HEAD", "/hello")
        print("observed HTTP/1.1 HEAD /hello:", repr(raw_head))
        assert_true(raw_head.startswith("HTTP/1.1 200 OK\r\n"))
        assert_true("\r\nX-Trace: 1\r\n" in raw_head)
        assert_true("\r\nContent-Length: 5\r\n" in raw_head)
        assert_true(raw_head.endswith("\r\n\r\n"))
        assert_equal(raw_head.count("\r\n\r\n"), 1)
        var none = List[Tuple[String, String]]()
        var h2_get = h2_request(child.port, "GET", "/hello", none)
        var h2_head = h2_request(child.port, "HEAD", "/hello", none)
        var h2_missing = h2_request(child.port, "GET", "/missing", none)
        print("observed h2c GET /hello:", _h2_fields(h2_get[0]), h2_get[1])
        print(
            "observed h2c HEAD /hello:",
            _h2_fields(h2_head[0]),
            "DATA frames:",
            h2_head[2],
        )
        assert_equal(_h2_fields(h2_get[0]), ":status=200;x-trace=1;")
        assert_equal(h2_get[1], "hello")
        assert_true(h2_get[2] > 0)
        assert_equal(
            _h2_fields(h2_head[0]), ":status=200;x-trace=1;content-length=5;"
        )
        assert_equal(h2_head[1], "")
        assert_equal(h2_head[2], 0)
        assert_equal(_h2_fields(h2_missing[0]), ":status=404;x-trace=1;")
        assert_equal(h2_missing[1], "Not Found")
    finally:
        _ = kill(pid, SIGKILL)
        waitpid(pid)


def _same_allow(wire: List[String], local: Response, at: String) raises:
    """The `Allow` values on the wire equal `App.handle`'s, in order: one
    for a 405, none otherwise."""
    var want = local.headers.get_all("Allow")
    assert_equal(len(wire), len(want), at)
    for i in range(len(want)):
        assert_equal(wire[i], want[i], at)


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
            # M3-031: a path only routes of other methods match is 405; each
            # 405 below has `Allow: POST`.
            (String("/users"), 405, String("Method Not Allowed")),
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
            (String("/webhook"), 405, String("Method Not Allowed")),
            # M3-003: "Person(1, Grace)" only if the handler read its state
            # and got Int(1) from "01"; the 409 is its raise, the 400 a
            # value it never saw.
            (String("/staff/01"), 200, String("Person(1, Grace)")),
            (String("/staff/0"), 200, String("Person(0, Ada)")),
            (String("/staff/2"), 409, String("out of stock 2")),
            (String("/staff/x"), 400, String("Bad Request")),
            (String("/staff"), 405, String("Method Not Allowed")),
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
            assert_equal(response.text(), local.text(), path)
            _same_allow(response.headers.get_all("allow"), local, path)
            if want[1] == 405:
                assert_equal(response.headers.get("allow"), "POST", path)

        # M2-006: "created Ada" only if Muntin converted the body; the raw
        # body is "name=Ada". GET /users above is the wrong method (405).
        # Each 405 below has `Allow: GET, HEAD`.
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
            (
                String("/users/42"),
                String("name=Ada"),
                405,
                String("Method Not Allowed"),
            ),
            (
                String("/hello"),
                String("name=Ada"),
                405,
                String("Method Not Allowed"),
            ),
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
            assert_equal(response.text(), local.text(), path + " " + body)
            _same_allow(response.headers.get_all("allow"), local, path)
            if want[2] == 405:
                assert_equal(response.headers.get("allow"), "GET, HEAD", path)

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
            # M3-031: `Allow: PUT, PATCH, DELETE`.
            (
                String("POST"),
                String("/notes/7"),
                String("name=Ada"),
                405,
                String("Method Not Allowed"),
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
            assert_equal(response.text(), local.text(), at)
            _same_allow(response.headers.get_all("allow"), local, at)
            if want[3] == 405:
                assert_equal(
                    response.headers.get("allow"), "PUT, PATCH, DELETE", at
                )

        # A current Flare limit: its HTTP/1.1 parser answers a method with a
        # lowercase letter 400 before `App.handle`, which matches methods
        # byte for byte and would answer 405.
        var lowercase = client.send(
            FlareRequest("delete", base + "/notes/7", List[UInt8]())
        )
        print("observed: delete /notes/7", lowercase.status)
        assert_equal(lowercase.status, 400)
        assert_equal(app.handle(Request("delete", "/notes/7")).status, 405)
        # An unknown uppercase method reaches `App.handle`, which answers it
        # 405 with `Allow` as it does in memory.
        var unknown = client.send(
            FlareRequest("FOO", base + "/notes/7", List[UInt8]())
        )
        print("observed: FOO /notes/7", unknown.status, repr(unknown.text()))
        var local_unknown = app.handle(Request("FOO", "/notes/7"))
        assert_equal(local_unknown.status, 405)
        assert_equal(unknown.status, local_unknown.status)
        assert_equal(unknown.text(), local_unknown.text())
        _same_allow(unknown.headers.get_all("allow"), local_unknown, "FOO")
        assert_equal(unknown.headers.get("allow"), "PUT, PATCH, DELETE")
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
        assert_equal(resp.text(), local.text())
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
            assert_equal(resp.text(), local.text(), method)
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
            assert_equal(unsigned.text(), local_unsigned.text(), method)
            assert_equal(len(local_unsigned.headers), 0)
            var forged = FlareRequest(method, base + "/keyed", List[UInt8]())
            forged.headers.append("X-Signature", "sha256=forged")
            var forged_resp = client.send(forged)
            var fh = Headers()
            fh.add("X-Signature", "sha256=forged")
            var local_forged = app.handle(Request(method, "/keyed", "", fh^))
            assert_equal(forged_resp.status, 401, method)
            assert_equal(forged_resp.status, local_forged.status, method)
            assert_equal(forged_resp.text(), local_forged.text(), method)
        # The route is GET and POST only: another method on its path is 405
        # with `App.handle`'s `Allow`, and no other path reaches it.
        var put = client.send(
            FlareRequest("PUT", base + "/keyed", List[UInt8]())
        )
        var local_put = app.handle(Request("PUT", "/keyed"))
        assert_equal(put.status, 405)
        assert_equal(put.status, local_put.status)
        assert_equal(put.text(), local_put.text())
        _same_allow(put.headers.get_all("allow"), local_put, "PUT /keyed")
        assert_equal(put.headers.get("allow"), "GET, HEAD, POST")
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
    var got = h2_exchange(port, method, path, fields, List[UInt8]())
    return (got[0].copy(), String(from_utf8_lossy=Span(got[1])), got[2])


def _halves(body: List[UInt8]) -> List[List[UInt8]]:
    """`body` in two pieces, the first half and the rest; one piece for a
    single byte and none when empty."""
    var out = List[List[UInt8]]()
    var mid = len(body) // 2
    if mid > 0:
        out.append(List(Span(body)[:mid]))
    if len(body) > mid:
        out.append(List(Span(body)[mid:]))
    return out^


def h2_exchange(
    port: Int,
    method: String,
    path: String,
    fields: List[Tuple[String, String]],
    body: List[UInt8],
    split: Bool = False,
) raises -> Tuple[List[HpackHeader], List[UInt8], Int]:
    """As `h2_request`, with `body` sent in one DATA frame after the HEADERS
    frame (none when empty) and the response body returned as bytes. With
    `split`, the body goes out in two DATA frames (`_halves`), only the last
    ending the stream."""
    var wire = List(H2_PREFACE.as_bytes())
    wire.extend(Span(_h2_frame(FrameType.SETTINGS(), 0, 0, List[UInt8]())))
    var end = FrameFlags.END_STREAM() if len(body) == 0 else UInt8(0)
    wire.extend(
        Span(
            _h2_frame(
                FrameType.HEADERS(),
                FrameFlags.END_HEADERS() | end,
                1,
                _h2_block(method, path, fields),
            )
        )
    )
    var pieces = _halves(body) if split else [body.copy()]
    if len(body) > 0:
        for i in range(len(pieces)):
            var flags = FrameFlags.END_STREAM() if i == len(
                pieces
            ) - 1 else UInt8(0)
            wire.extend(
                Span(_h2_frame(FrameType.DATA(), flags, 1, pieces[i].copy()))
            )
    return _h2_answers(port, [wire^], 1)[0].copy()


def h2_streams(
    port: Int, requests: List[Tuple[String, String]]
) raises -> List[Tuple[List[HpackHeader], List[UInt8], Int]]:
    """Each `(method, path)` of `requests` on one cleartext HTTP/2
    connection, on streams 1, 3, 5 and so on, with no fields and no body:
    each response as `h2_exchange` returns it, in request order."""
    var wire = List(H2_PREFACE.as_bytes())
    wire.extend(Span(_h2_frame(FrameType.SETTINGS(), 0, 0, List[UInt8]())))
    var none = List[Tuple[String, String]]()
    for i in range(len(requests)):
        wire.extend(
            Span(
                _h2_frame(
                    FrameType.HEADERS(),
                    FrameFlags.END_HEADERS() | FrameFlags.END_STREAM(),
                    2 * i + 1,
                    _h2_block(requests[i][0], requests[i][1], none),
                )
            )
        )
    return _h2_answers(port, [wire^], len(requests))


def h2_in_turn(
    port: Int, requests: List[Tuple[String, String]]
) raises -> List[Tuple[List[HpackHeader], List[UInt8], Int]]:
    """As `h2_streams`, but each request is written only after the response
    to the one before it has ended, on the same connection: a request
    reaches the server after it answered the previous one."""
    var chunks = List[List[UInt8]]()
    var none = List[Tuple[String, String]]()
    for i in range(len(requests)):
        var chunk = List[UInt8]()
        if i == 0:
            chunk = List(H2_PREFACE.as_bytes())
            chunk.extend(
                Span(_h2_frame(FrameType.SETTINGS(), 0, 0, List[UInt8]()))
            )
        chunk.extend(
            Span(
                _h2_frame(
                    FrameType.HEADERS(),
                    FrameFlags.END_HEADERS() | FrameFlags.END_STREAM(),
                    2 * i + 1,
                    _h2_block(requests[i][0], requests[i][1], none),
                )
            )
        )
        chunks.append(chunk^)
    return _h2_answers(port, chunks, len(requests))


def _h2_block(
    method: String, path: String, fields: List[Tuple[String, String]]
) -> List[UInt8]:
    """A request header block: `method`'s and `path`'s bytes as given (a
    test may pass bytes that are not UTF-8), then `fields`."""
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(":method", method))
    hdrs.append(HpackHeader(":scheme", "http"))
    hdrs.append(HpackHeader(":path", path))
    hdrs.append(HpackHeader(":authority", "localhost"))
    for f in fields:
        hdrs.append(HpackHeader(f[0], f[1]))
    return HpackEncoder().encode(Span[HpackHeader, _](hdrs))


def _h2_answers(
    port: Int, chunks: List[List[UInt8]], streams: Int
) raises -> List[Tuple[List[HpackHeader], List[UInt8], Int]]:
    """Writes `chunks[0]` on a new connection and reads until streams 1, 3,
    ... (`streams` of them) have each ended. With one chunk, every request is
    in it and is sent at once (`h2_streams`); with one chunk per request,
    each next chunk is written only when a stream has ended (`h2_in_turn`).
    Per stream: the response's decoded header fields, its body and the
    number of DATA frames it came in (an empty DATA frame counts). A GOAWAY,
    an RST_STREAM on one of them or a close before they end raises."""
    var stream = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    stream.set_recv_timeout(TIMEOUT_MS)
    stream.write_all(Span[UInt8, _](chunks[0]))
    var written = 1
    var decoder = HpackDecoder()
    var acc = List[UInt8]()
    var buf = List[UInt8]()
    buf.resize(4096, 0)
    var pos = 0
    var out = List[Tuple[List[HpackHeader], List[UInt8], Int]]()
    var ended = List[Bool]()
    for _ in range(streams):
        out.append((List[HpackHeader](), List[UInt8](), 0))
        ended.append(False)
    var open = streams
    while open > 0:
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
        if f.header.type.value == FrameType.GOAWAY().value:
            raise Error("GOAWAY")
        var sid = f.header.stream_id
        if sid % 2 == 0 or sid > 2 * streams - 1:
            continue
        var i = (sid - 1) // 2
        if f.header.type.value == FrameType.HEADERS().value:
            out[i][0] = decoder.decode(Span[UInt8, _](f.payload))
        elif f.header.type.value == FrameType.DATA().value:
            out[i][1].extend(Span[UInt8, _](f.payload))
            out[i][2] += 1
        elif f.header.type.value == FrameType.RST_STREAM().value:
            raise Error("RST_STREAM")
        if f.header.flags.has(FrameFlags.END_STREAM()) and not ended[i]:
            ended[i] = True
            open -= 1
            if written < len(chunks):
                stream.write_all(Span[UInt8, _](chunks[written]))
                written += 1
    return out^


def h1_raw(port: Int, method: String, path: String) raises -> String:
    """One HTTP/1.1 request with `Connection: close` and no body; every byte
    of the response until the server closes the connection."""
    var wire = String(
        method,
        " ",
        path,
        " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
    )
    var stream = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    stream.set_recv_timeout(TIMEOUT_MS)
    stream.write_all(wire.as_bytes())
    var acc = List[UInt8]()
    var buf = List[UInt8]()
    buf.resize(4096, 0)
    while True:
        var n = stream.read(buf.unsafe_ptr(), len(buf))
        if n == 0:
            break
        for k in range(n):
            acc.append(buf[k])
    return String(from_utf8_lossy=Span(acc))


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
        # Flare admits a name that is not a token over HTTP/2; Muntin cannot
        # represent it.
        var invalid = h2_request(
            child.port,
            "GET",
            "/signed",
            [
                (String("x-signature"), String("sha256=abc")),
                (String("x-user/admin"), String("zzz")),
            ],
        )
        print("observed h2c invalid:", _h2_fields(invalid[0]), invalid[1])
        assert_equal(invalid[0][0].value, "400")
        assert_equal(invalid[1], "Bad Request")
        # Flare passes a value's bytes through unchanged over HTTP/2; one that
        # is not UTF-8 is not text, so Muntin cannot represent it either.
        var not_utf8 = [UInt8(ord("a")), UInt8(0xFF), UInt8(ord("b"))]
        var binary = h2_request(
            child.port,
            "GET",
            "/signed",
            [
                (String("x-signature"), String("sha256=abc")),
                (
                    String("x-bin"),
                    ascii_unchecked_string(Span[UInt8, _](not_utf8)),
                ),
            ],
        )
        print("observed h2c not UTF-8:", _h2_fields(binary[0]), binary[1])
        assert_equal(binary[0][0].value, "400")
        assert_equal(binary[1], "Bad Request")

        # M3-027: HEAD at every exit of the adapter's answer. (target,
        # fields, status, content-length or "" for none); each goes out
        # with no DATA frame.
        var app = headers_app()
        assert_equal(app.handle(Request("HEAD", "/report")).text(), "report")
        var auth = (String("authorization"), String("t0k"))
        var admin = (String("x-user/admin"), String("zzz"))
        var none = List[Tuple[String, String]]()
        var authorized = none.copy()
        authorized.append(auth)
        var invalid_name = none.copy()
        invalid_name.append(admin)
        var cases = [
            (String("/hello"), none.copy(), 200, String("5")),
            (String("/report"), none.copy(), 200, String("6")),
            (String("/signed/x"), authorized^, 400, String("11")),
            (String("/hello"), invalid_name^, 400, String("11")),
            (String("/missing"), none.copy(), 404, String("9")),
            (String("/form"), none.copy(), 405, String("18")),
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
            var got = String("")
            for f in head[0]:
                if f.name == "content-length":
                    got = f.value
            assert_equal(got, c[3], label)
        # Status and fields are the GET's, typed and raw: the content-length
        # is added last.
        for want in [
            (String("/hello"), String("hello")),
            (String("/report"), String("report")),
        ]:
            var get = h2_request(child.port, "GET", want[0], none)
            var head = h2_request(child.port, "HEAD", want[0], none)
            assert_equal(get[1], want[1])
            assert_equal(
                _h2_fields(head[0]),
                _h2_fields(get[0])
                + "content-length="
                + String(want[1].byte_length())
                + ";",
                want[0],
            )
        var nm_get = h2_request(child.port, "GET", "/nm", none)
        assert_equal(nm_get[1], "abc")

        # M3-031: a method mismatch is 405 with `App.handle`'s `allow`, the
        # body in DATA; `HEAD` on a path only a `post` route serves is 405
        # with `allow`, a content-length and no DATA frame.
        var mismatch = h2_request(child.port, "POST", "/hello", none)
        var local_mismatch = app.handle(Request("POST", "/hello"))
        print("observed h2c POST /hello", _h2_fields(mismatch[0]), mismatch[1])
        assert_equal(local_mismatch.status, 405)
        assert_equal(
            _h2_fields(mismatch[0]),
            ":status=405;allow="
            + local_mismatch.headers.get("Allow").value()
            + ";",
        )
        assert_equal(_h2_fields(mismatch[0]), ":status=405;allow=GET, HEAD;")
        assert_equal(mismatch[1], local_mismatch.text())
        assert_true(mismatch[2] > 0)
        var head_form = h2_request(child.port, "HEAD", "/form", none)
        var local_form = app.handle(Request("HEAD", "/form"))
        assert_equal(local_form.headers.get("Allow").value(), "POST")
        assert_equal(
            _h2_fields(head_form[0]),
            ":status=405;allow=POST;content-length=18;",
        )
        assert_equal(head_form[2], 0)

        # Over HTTP/1.1, Flare's client reads no content for HEAD whatever
        # is sent, so only status and Content-Length are evidence here; the
        # no-content evidence is compat/flare/head/head_probe.mojo's raw
        # bytes.
        var base = String("http://127.0.0.1:", child.port)
        var client = _client()
        var h1_cases = [
            (String("/hello"), 200, String("5")),
            (String("/report"), 200, String("6")),
            (String("/signed/x"), 400, String("11")),
            (String("/form"), 405, String("18")),
        ]
        for c in h1_cases:
            var resp = client.head(base + c[0])
            print(
                "observed HTTP/1.1 HEAD",
                c[0],
                resp.status,
                repr(resp.headers.get("content-length")),
            )
            assert_equal(resp.status, c[1], c[0])
            assert_equal(resp.headers.get("content-length"), c[2], c[0])
            var local = app.handle(Request("HEAD", c[0]))
            _same_allow(resp.headers.get_all("allow"), local, c[0])
        # The raw bytes of `HEAD /form` over HTTP/1.1: 405, `Allow`, the
        # length, and nothing after the header block.
        var raw_head = h1_raw(child.port, "HEAD", "/form")
        print("observed HTTP/1.1 HEAD /form:", repr(raw_head))
        assert_true(raw_head.startswith("HTTP/1.1 405 Method Not Allowed\r\n"))
        assert_true("\r\nAllow: POST\r\n" in raw_head)
        assert_true("\r\nContent-Length: 18\r\n" in raw_head)
        assert_true(raw_head.endswith("\r\n\r\n"))
        assert_equal(raw_head.count("\r\n\r\n"), 1)
        # Only the exact token maps: Flare answers `head` and `Head` 400
        # before `App.handle`, which would answer them 405.
        for method in ["head", "Head"]:
            var other = client.send(
                FlareRequest(method, base + "/hello", List[UInt8]())
            )
            print("observed:", method, "/hello", other.status)
            assert_equal(other.status, 400, method)
            assert_equal(app.handle(Request(method, "/hello")).status, 405)
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


def greet_created(var body: Json[Greeting]) -> Json[Greeting]:
    return Json(body^.take(), status=201)


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
    app.post["/greet-created"](greet_created)
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
        # (path suffix, body, request Content-Type, status, whether the
        # answer is a converted `Json` with `Content-Type: application/json`,
        # whatever its status).
        var cases = [
            (
                String(""),
                good,
                String("application/json; charset=utf-8"),
                200,
                True,
            ),
            (String(""), good, String(""), 415, False),
            (String(""), good, String("text/plain"), 415, False),
            (String(""), big, String("application/json"), 413, False),
            (
                String(""),
                String('{"name":'),
                String("application/json"),
                400,
                False,
            ),
            (String("/7"), good, String("application/json"), 200, True),
            (String("/7"), good, String(""), 415, False),
            (String("/7"), big, String("application/json"), 413, False),
            (String("/x"), big, String("text/plain"), 400, False),
            (String("-created"), good, String("application/json"), 201, True),
            (String("-created"), good, String(""), 415, False),
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
            assert_equal(resp.text(), local.text(), label)
            if c[4]:
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
            assert_equal(resp.text(), local.text(), label)
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
            assert_equal(resp.text(), local.text(), label)
            if c[2] == 200:
                # The fields in order, with their casing, over the wire.
                assert_equal(resp.text(), "note 7 X-A=1 x-a=2")
    finally:
        _ = kill(child.pid, SIGKILL)
        waitpid(child.pid)


# ── M3-038: request body bytes ─────────────────────────────────────────────


def _hex(bytes: Span[UInt8, _]) -> String:
    var digits = "0123456789abcdef"
    var out = String()
    for i in range(len(bytes)):
        var b = Int(bytes[i])
        out += String(digits[byte=b // 16]) + String(digits[byte=b % 16])
    return out^


def _octets(values: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for v in values:
        out.append(UInt8(v))
    return out^


def body_bytes(req: Request) raises -> Response:
    """Answers with the hex of the body bytes it received, which the wire
    cannot alter, and their count in a field."""
    var r = Response.text(_hex(Span(req.body)))
    r.headers.add("X-Body-Length", String(len(req.body)))
    return r^


def body_echo(req: Request) -> Response:
    """Answers with the body bytes it received, unchanged and unread: the
    raw byte echo (M3-040)."""
    return Response(200, req.body.copy())


def marked(var request: Request, var next: Next) raises -> Response:
    """Adds `X-Seen: 1` to every answer `App.handle` gives."""
    var response = next^.run(request^)
    response.headers.add("X-Seen", "1")
    return response^


def bodies_app() -> App:
    var app = App()
    app.use(marked)
    app.get["/hello"](hello)
    app.post["/bytes"](body_bytes)
    app.post["/echo-raw"](body_echo)
    app.post["/echo"](echo)
    app.post["/greet"](greet)
    return app^


def h1_exchange(
    port: Int,
    method: String,
    path: String,
    fields: List[Tuple[String, String]],
    body: List[UInt8],
    chunked: Bool = False,
) raises -> Tuple[String, String, List[UInt8]]:
    """One HTTP/1.1 request with `Content-Length`, `Connection: close`,
    `fields` and `body`: the response's status line, its header lines
    (`\\r\\n`-separated, `Date` removed) and every byte after the blank
    line. With `chunked`, the body goes out with `Transfer-Encoding:
    chunked` instead, in two chunks (the first half, then the rest; one
    chunk for a single byte, none when empty)."""
    var head = String(method, " ", path, " HTTP/1.1\r\nHost: localhost\r\n")
    for f in fields:
        head += f[0] + ": " + f[1] + "\r\n"
    var wire: List[UInt8]
    if chunked:
        head += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        wire = List(head.as_bytes())
        for piece in _halves(body):
            wire.extend(
                Span(String(hex(len(piece))[byte=2:], "\r\n").as_bytes())
            )
            wire.extend(Span(piece))
            wire.extend(Span("\r\n".as_bytes()))
        wire.extend(Span("0\r\n\r\n".as_bytes()))
    else:
        head += String(
            "Content-Length: ", len(body), "\r\nConnection: close\r\n\r\n"
        )
        wire = List(head.as_bytes())
        wire.extend(Span(body))
    var stream = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    stream.set_recv_timeout(TIMEOUT_MS)
    stream.write_all(Span[UInt8, _](wire))
    var acc = List[UInt8]()
    var buf = List[UInt8]()
    buf.resize(4096, 0)
    while True:
        var n = stream.read(buf.unsafe_ptr(), len(buf))
        if n == 0:
            break
        for k in range(n):
            acc.append(buf[k])
    var split = -1
    for i in range(len(acc) - 3):
        if (
            acc[i] == 13
            and acc[i + 1] == 10
            and acc[i + 2] == 13
            and acc[i + 3] == 10
        ):
            split = i
            break
    if split < 0:
        raise Error("no HTTP/1.1 response head")
    var text = String(from_utf8=Span(acc)[:split])
    var lines = text.split("\r\n")
    var kept = String()
    for i in range(1, len(lines)):
        if not lines[i].startswith("Date: "):
            kept += String(lines[i]) + ";"
    var rest = List[UInt8]()
    for i in range(split + 4, len(acc)):
        rest.append(acc[i])
    return (String(lines[0]), kept^, rest^)


def _h2_field(fields: List[HpackHeader], name: String) -> String:
    for f in fields:
        if f.name == name:
            return f.value
    return "<none>"


def _same_bytes(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _every_byte() -> List[UInt8]:
    """An arbitrary binary payload: every byte value, 0x00 to 0xFF, twice,
    the second time in reverse."""
    var out = List[UInt8]()
    for i in range(256):
        out.append(UInt8(i))
    for i in range(256):
        out.append(UInt8(255 - i))
    return out^


def _bracketed(body: List[UInt8]) -> List[UInt8]:
    var out = List("[".as_bytes())
    out.extend(Span(body))
    out.append(UInt8(ord("]")))
    return out^


def test_request_and_response_body_bytes_over_http1_and_h2c() raises:
    """Every request body reaches `App.handle` byte for byte and a raw
    handler sends any bytes back unchanged, over HTTP/1.1 (`Content-Length`
    and chunked) and h2c (one DATA frame and two); a typed text body that is
    not UTF-8 is `App.handle`'s 400 (M3-040). Every comparison is by length
    and byte by byte."""
    # Well-formed UTF-8: a U+FFFD the client sent and NUL included.
    var text: List[Tuple[String, List[UInt8]]] = [
        (String("ascii"), List("hello".as_bytes())),
        (String("japanese"), List("こんにちは、世界".as_bytes())),
        (String("fffd"), _octets([0x61, 0xEF, 0xBF, 0xBD, 0x62])),
        (String("nul"), _octets([0x61, 0x00, 0x62, 0x00])),
        (String("x00"), _octets([0x00])),
        (String("empty"), List[UInt8]()),
        (String("octets_utf8"), _octets([0x00, 0x01, 0x7F, 0x0A])),
    ]
    # Not UTF-8: each one changed by a lossy conversion, and since M3-040
    # carried exactly to a raw handler.
    var binary: List[Tuple[String, List[UInt8]]] = [
        (String("x80"), _octets([0x80])),
        (String("xff"), _octets([0xFF])),
        (String("truncated"), _octets([0xE3, 0x81])),
        (String("overlong"), _octets([0xC0, 0xAF])),
        (String("surrogate"), _octets([0xED, 0xA0, 0x80])),
        (String("fffd_ff"), _octets([0xEF, 0xBF, 0xBD, 0xFF])),
        (
            String("png"),
            _octets([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        ),
        (String("every_byte"), _every_byte()),
    ]
    var cases = List[Tuple[String, List[UInt8], Bool]]()
    for c in text:
        cases.append((c[0], c[1].copy(), True))
    for c in binary:
        cases.append((c[0], c[1].copy(), False))
    var octets: List[Tuple[String, String]] = [
        (String("content-type"), String("application/octet-stream"))
    ]
    var json: List[Tuple[String, String]] = [
        (String("content-type"), String("application/json"))
    ]
    var app = bodies_app()
    var client = TestClient(app)
    var child = _serve_in_child(bodies_app())
    try:
        for c in cases:
            ref body = c[1]
            var utf8 = c[2]
            # In memory: the raw echo through middleware and TestClient.
            var local = client.post("/echo-raw", body.copy())
            assert_equal(local.status, 200, c[0])
            assert_equal(len(local.body), len(body), c[0])
            assert_true(_same_bytes(Span(local.body), Span(body)), c[0])
            var seen = client.post("/bytes", body.copy())
            assert_equal(seen.text(), _hex(Span(body)), c[0])
            for transport in range(4):
                var name = String(c[0], " via ")
                var status: String
                var head: String
                var got: List[UInt8]
                var bytes_seen: String
                var typed_status: String
                var typed: List[UInt8]
                if transport < 2:
                    var chunked = transport == 1
                    name += "HTTP/1.1 chunked" if chunked else "HTTP/1.1"
                    var e = h1_exchange(
                        child.port, "POST", "/echo-raw", octets, body, chunked
                    )
                    status = e[0]
                    head = e[1]
                    got = e[2].copy()
                    var b = h1_exchange(
                        child.port, "POST", "/bytes", octets, body, chunked
                    )
                    bytes_seen = String(from_utf8=Span(b[2]))
                    var t = h1_exchange(
                        child.port, "POST", "/echo", octets, body, chunked
                    )
                    typed_status = t[0]
                    typed = t[2].copy()
                    assert_equal(status, "HTTP/1.1 200 OK", name)
                    # No `Content-Type`: the adapter adds none for bytes.
                    assert_equal(
                        head,
                        String(
                            "X-Seen: 1;Content-Length: ",
                            len(body),
                            ";Connection: close;",
                        ),
                        name,
                    )
                    if utf8:
                        assert_equal(typed_status, "HTTP/1.1 200 OK", name)
                    else:
                        assert_equal(
                            typed_status, "HTTP/1.1 400 Bad Request", name
                        )
                        assert_equal(
                            t[1],
                            "X-Seen: 1;Content-Length: 11;Connection: close;",
                            name,
                        )
                else:
                    var split = transport == 3
                    name += "h2c two DATA frames" if split else "h2c"
                    var e = h2_exchange(
                        child.port, "POST", "/echo-raw", octets, body, split
                    )
                    assert_equal(
                        _h2_fields(e[0]), ":status=200;x-seen=1;", name
                    )
                    got = e[1].copy()
                    var b = h2_exchange(
                        child.port, "POST", "/bytes", octets, body, split
                    )
                    bytes_seen = String(from_utf8=Span(b[1]))
                    var t = h2_exchange(
                        child.port, "POST", "/echo", octets, body, split
                    )
                    typed = t[1].copy()
                    if utf8:
                        assert_equal(t[0][0].value, "200", name)
                    else:
                        assert_equal(
                            _h2_fields(t[0]), ":status=400;x-seen=1;", name
                        )
                # The response body is the request body, byte for byte.
                assert_equal(len(got), len(body), name)
                assert_true(_same_bytes(Span(got), Span(body)), name)
                # The bytes App.handle received, as hex the wire cannot alter.
                assert_equal(bytes_seen, _hex(Span(body)), name)
                if utf8:
                    assert_true(
                        _same_bytes(Span(typed), Span(_bracketed(body))), name
                    )
                else:
                    assert_equal(
                        String(from_utf8=Span(typed)), "Bad Request", name
                    )
            print(
                "observed",
                c[0] + ":",
                len(body),
                (
                    "bytes echoed exactly over HTTP/1.1 (Content-Length,"
                    " chunked) and h2c (one and two DATA frames); typed text"
                ),
                "200" if utf8 else "400",
            )
            # App.handle's 405 and 404, through the middleware, whatever the
            # body; `HEAD` on a `GET` route under the HEAD rule.
            var h1 = h1_exchange(child.port, "POST", "/hello", octets, body)
            assert_equal(h1[0], "HTTP/1.1 405 Method Not Allowed", c[0])
            assert_equal(
                h1[1],
                (
                    "Allow: GET, HEAD;X-Seen: 1;Content-Length: 18;Connection:"
                    " close;"
                ),
                c[0],
            )
            var h2 = h2_exchange(child.port, "POST", "/missing", octets, body)
            assert_equal(_h2_fields(h2[0]), ":status=404;x-seen=1;", c[0])
            var hh = h2_exchange(child.port, "HEAD", "/hello", octets, body)
            assert_equal(
                _h2_fields(hh[0]),
                ":status=200;x-seen=1;content-length=5;",
                c[0],
            )
            assert_equal(len(hh[1]), 0, c[0])
        # JSON: a sent U+FFFD is a value; a byte that is not UTF-8 inside a
        # JSON string is App.handle's 400 before parsing (through the
        # middleware), never a U+FFFD.
        var sent_fffd = List('{"name":"'.as_bytes())
        sent_fffd.extend(Span(_octets([0xEF, 0xBF, 0xBD])))
        sent_fffd.extend(Span(List('"}'.as_bytes())))
        var bad_json = List('{"name":"'.as_bytes())
        bad_json.append(0xFF)
        bad_json.extend(Span(List('"}'.as_bytes())))
        var j1 = h1_exchange(child.port, "POST", "/greet", json, sent_fffd)
        assert_equal(j1[0], "HTTP/1.1 200 OK")
        assert_equal(String(from_utf8=Span(j1[2])), '{"hello":"�"}')
        var j2 = h2_exchange(child.port, "POST", "/greet", json, sent_fffd)
        assert_equal(String(from_utf8=Span(j2[1])), '{"hello":"�"}')
        var b1 = h1_exchange(child.port, "POST", "/greet", json, bad_json)
        print("observed HTTP/1.1 /greet 0xFF:", b1[0], b1[1])
        assert_equal(b1[0], "HTTP/1.1 400 Bad Request")
        assert_equal(b1[1], "X-Seen: 1;Content-Length: 11;Connection: close;")
        assert_equal(String(from_utf8=Span(b1[2])), "Bad Request")
        var b2 = h2_exchange(child.port, "POST", "/greet", json, bad_json, True)
        assert_equal(_h2_fields(b2[0]), ":status=400;x-seen=1;")
        # The same Server still answers after every exchange above.
        var after = h2_exchange(
            child.port,
            "GET",
            "/hello",
            List[Tuple[String, String]](),
            List[UInt8](),
        )
        assert_equal(after[0][0].value, "200")
        assert_equal(String(from_utf8=Span(after[1])), "hello")
    finally:
        _ = kill(child.pid, SIGKILL)
        waitpid(child.pid)


def targets_app() -> App:
    var app = App()
    app.use(marked)
    app.get["/hello"](hello)
    app.get["/names/{name}"](name_of)
    app.get["/items?{limit}"](list_items)
    return app^


def _unchecked(values: List[Int]) -> String:
    """`values` as a `String`'s bytes, unchecked, as Flare v0.12.0 builds a
    method or target over HTTP/2 from HPACK octets."""
    return String(unsafe_from_utf8=Span(_octets(values)))


def _running(pid: Int) -> Bool:
    """Whether the child `pid` has not exited (`waitpid` with `WNOHANG`)."""
    return Int(external_call["waitpid", c_int](c_int(pid), 0, c_int(1))) == 0


def _bad_then_hello(
    got: List[Tuple[List[HpackHeader], List[UInt8], Int]], at: String
) raises:
    """Stream 1 is the adapter's 400 and stream 3 the well-formed `GET
    /hello`'s answer, through the middleware."""
    assert_equal(_h2_field(got[0][0], ":status"), "400", at)
    assert_equal(String(from_utf8=Span(got[0][1])), "Bad Request", at)
    assert_equal(_h2_field(got[0][0], "x-seen"), "<none>", at)
    assert_equal(_h2_field(got[1][0], ":status"), "200", at)
    assert_equal(String(from_utf8=Span(got[1][1])), "hello", at)
    assert_equal(_h2_field(got[1][0], "x-seen"), "1", at)


def test_request_target_and_method_bytes_over_h2c_and_http1() raises:
    """A method or target that is not UTF-8 is the adapter's 400 before
    `App.handle`, and the `Server` keeps serving (M3-039)."""
    var app = targets_app()
    var child = _serve_in_child(targets_app())
    try:
        var get = String("GET")
        var hello_path = String("/hello")
        # Targets that are not UTF-8: in the path (a 404 path, a route's
        # capture), in the query, and a byte where a slice would start
        # inside a sequence (after `?`, after `=`, after `&`).
        var bad_targets: List[String] = [
            _unchecked([0x2F, 0xFF]),
            _unchecked([0x2F, 0x80]),
            _unchecked([0x2F, 0x6E, 0x61, 0x6D, 0x65, 0x73, 0x2F, 0xFF]),
            _unchecked([0x2F, 0xE3, 0x81]),  # truncated
            _unchecked([0x2F, 0xC0, 0xAF]),  # overlong
            _unchecked([0x2F, 0xED, 0xA0, 0x80]),  # a surrogate
            _unchecked([0x2F, 0xEF, 0xBF, 0xBD, 0xFF]),  # U+FFFD, then 0xFF
            _unchecked([0x2F, 0xC3, 0x3F, 0x61]),  # truncated before `?`
            hello_path + _unchecked([0x3F, 0xFF]),
            hello_path + _unchecked([0x3F, 0x80]),
            String("/items?limit=") + _unchecked([0x80]),
            String("/items?a=1&") + _unchecked([0xBF, 0x3D, 0x35]),
        ]
        var bad_methods: List[String] = [
            _unchecked([0xFF]),
            _unchecked([0x47, 0x45, 0x80]),
            _unchecked([0x47, 0xC3]),
            _unchecked([0xEF, 0xBF, 0xBD, 0xFF]),
        ]
        var bad = List[Tuple[String, String]]()
        for t in bad_targets:
            bad.append((get, t))
        for m in bad_methods:
            bad.append((m, hello_path))
            bad.append((m, String("/missing")))
        bad.append((bad_methods[0], bad_targets[0]))
        for b in bad:
            var at = String("method ", _hex(b[0].as_bytes()), " target ")
            at += _hex(b[1].as_bytes())
            # The request, then a well-formed one on the next stream of the
            # same connection: both sent at once, and the well-formed one
            # sent only after the 400 has been read.
            _bad_then_hello(h2_streams(child.port, [b, (get, hello_path)]), at)
            _bad_then_hello(h2_in_turn(child.port, [b, (get, hello_path)]), at)
            # A new connection to the same `Server`.
            var again = h2_request(
                child.port, get, hello_path, List[Tuple[String, String]]()
            )
            assert_equal(_h2_field(again[0], ":status"), "200", at)
            assert_equal(again[1], "hello", at)
            assert_true(_running(child.pid), at)
        # `HEAD`: the adapter's 400 under the `HEAD` rule (M3-027).
        var head = h2_streams(child.port, [(String("HEAD"), bad_targets[9])])
        assert_equal(_h2_field(head[0][0], ":status"), "400")
        assert_equal(_h2_field(head[0][0], "content-length"), "11")
        assert_equal(_h2_field(head[0][0], "x-seen"), "<none>")
        assert_equal(head[0][2], 0)

        # Well-formed methods and targets: `App.handle`'s answer, through
        # the middleware, as before.
        var fffd = _unchecked([0xEF, 0xBF, 0xBD])
        var good: List[Tuple[String, String]] = [
            (get, hello_path),
            (get, String("/names/é")),
            (get, String("/names/") + fffd),
            (get, String("/names/%C3%A9")),
            (get, String("/names/%FF")),  # `App.handle`'s 400 (M3-018)
            (get, String("/é")),
            (get, String("/items?limit=5")),
            (get, String("/items?limit=%35&q=é")),
            (get, String("/hello?é=") + fffd),
            (get, String("/missing")),
            (String("POST"), hello_path),
            (String("FOO"), hello_path),
            (String("get"), hello_path),
            (String(""), hello_path),
            (String("é"), hello_path),
            (fffd, hello_path),
        ]
        var answers = h2_streams(child.port, good)
        for i in range(len(good)):
            var at = String("method ", _hex(good[i][0].as_bytes()), " target ")
            at += _hex(good[i][1].as_bytes())
            var local = app.handle(Request(good[i][0], good[i][1]))
            assert_equal(
                _h2_field(answers[i][0], ":status"), String(local.status), at
            )
            assert_true(_same_bytes(Span(answers[i][1]), Span(local.body)), at)
            assert_equal(_h2_field(answers[i][0], "x-seen"), "1", at)
            var allow = local.headers.get("allow")
            var want = allow.value() if allow else String("<none>")
            assert_equal(_h2_field(answers[i][0], "allow"), want, at)
        var head_ok = h2_streams(child.port, [(String("HEAD"), hello_path)])
        assert_equal(_h2_field(head_ok[0][0], ":status"), "200")
        assert_equal(_h2_field(head_ok[0][0], "content-length"), "5")
        assert_equal(_h2_field(head_ok[0][0], "x-seen"), "1")
        assert_equal(head_ok[0][2], 0)

        # HTTP/1.1: Flare refuses every byte outside `!`..`~` in a method or
        # target itself, well-formed UTF-8 included, with its own body
        # (`400 Bad Request`, not the adapter's `Bad Request`).
        var h1_refused: List[Tuple[String, String]] = [
            (get, bad_targets[0]),
            (get, bad_targets[9]),
            (get, String("/names/é")),
            (bad_methods[0], hello_path),
            (String("é"), hello_path),
        ]
        var none = List[Tuple[String, String]]()
        for r in h1_refused:
            var at = String("method ", _hex(r[0].as_bytes()), " target ")
            at += _hex(r[1].as_bytes())
            var h1 = h1_exchange(child.port, r[0], r[1], none, List[UInt8]())
            assert_equal(h1[0], "HTTP/1.1 400 Bad Request", at)
            assert_equal(String(from_utf8=Span(h1[2])), "400 Bad Request", at)
            assert_true(_running(child.pid), at)
        var h1_ok = h1_exchange(
            child.port, get, String("/names/%C3%A9"), none, List[UInt8]()
        )
        assert_equal(h1_ok[0], "HTTP/1.1 200 OK")
        assert_equal(String(from_utf8=Span(h1_ok[2])), "name é")
        assert_true(_running(child.pid))
    finally:
        _ = kill(child.pid, SIGKILL)
        waitpid(child.pid)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
