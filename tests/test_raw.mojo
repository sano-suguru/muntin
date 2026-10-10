# Raw `Request -> Response` handlers in production (M2-015): the M2-014 decision
# (docs/history/architecture-decisions.md, "Raw Request decision (M2-014)") on
# the production `App` and `TestClient`. Handlers and their error types live
# here, in the application module.

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import App, FromBody, Request, Response, ToErrorResponse, ToResponse
from muntin.testing import TestClient

# Handlers are thin functions and cannot capture state, so calls are
# counted in environment variables.
comptime FROM_BODY = "MUNTIN_TEST_RAW_FROM_BODY"
comptime HANDLER = "MUNTIN_TEST_RAW_HANDLER"
comptime TYPED = "MUNTIN_TEST_RAW_TYPED"


def _reset():
    for name in [FROM_BODY, HANDLER, TYPED]:
        _ = unsetenv(name)


def _count(name: StaticString) raises -> Int:
    var n = getenv(name)
    return Int(n) if n else 0


def _bump(name: StaticString):
    var n = 0
    try:
        n = _count(name)
    except:
        pass
    _ = setenv(name, String(n + 1))


# Application types.


@fieldwise_init
struct User(Movable, ToResponse):
    var id: Int

    def to_response(var self) -> Response:
        return Response.text("User(" + String(self.id) + ")")


struct Name(FromBody):
    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(FROM_BODY)
        if body.byte_length() == 0:
            raise Error("empty name")
        return Self(body)


@fieldwise_init
struct BadSignature(Movable, ToErrorResponse):
    """Opts into its own response: 401."""

    var reason: String

    def to_error_response(var self) -> Response:
        return Response.text("bad signature: " + self.reason, status=401)


@fieldwise_init
struct Malformed(Movable, ToErrorResponse):
    """Opts into a 400: the application, not Muntin, chooses it."""

    def to_error_response(var self) -> Response:
        return Response.text("malformed payload", status=400)


@fieldwise_init
struct Unmapped(Movable):
    """Declares no error-response conformance: a raise is the fixed 500."""

    var reason: String


# Raw handlers.


def _fields(req: Request) -> List[UInt8]:
    """The request's parts, then its body bytes, unread."""
    var out = List(
        String(req.method + "|" + req.path + "|" + req.query + "|").as_bytes()
    )
    out.extend(Span(req.body))
    return out^


def echo(req: Request) -> Response:
    _bump(HANDLER)
    return Response(202, _fields(req))


def take_body(var req: Request) -> Response:
    """Owns the request and moves its body into the response."""
    _bump(HANDLER)
    var body = req.body^
    req.body = List[UInt8]()
    return Response(201, body^)


def reject(req: Request) -> Response:
    """Answers 400 itself: a raw handler may use any status."""
    _bump(HANDLER)
    return Response.text("rejected " + req.query, status=400)


def verify(req: Request) raises -> Response:
    _bump(HANDLER)
    if req.text() != "signed":
        raise Error("secret key mismatch")
    return Response.text("verified")


def verify_typed(req: Request) raises BadSignature -> Response:
    _bump(HANDLER)
    if Span(req.body) != "signed".as_bytes():
        raise BadSignature("unsigned")
    return Response.text("verified")


def parse(req: Request) raises Malformed -> Response:
    _bump(HANDLER)
    if Span(req.body) != "ok".as_bytes():
        raise Malformed()
    return Response.text("parsed")


def verify_unmapped(req: Request) raises Unmapped -> Response:
    _bump(HANDLER)
    raise Unmapped("secret")


def webhook(req: Request) -> Response:
    """The docs/DX.md section 9 example, verbatim."""
    if Span(req.body) != "signed".as_bytes():  # the body's bytes
        return Response.text("unsigned", status=401)
    return Response.text("ok")


def raw_first(req: Request) -> Response:
    return Response.text("raw")


# Typed handlers, one per production shape and result policy.


def hello() -> String:
    _bump(TYPED)
    return "hello"


def hello_static() -> StaticString:
    _bump(TYPED)
    return "static"


def teapot() -> Response:
    _bump(TYPED)
    return Response.text("teapot", status=418)


def get_text(id: Int) -> String:
    _bump(TYPED)
    return "id " + String(id)


def get_user(id: Int) -> User:
    _bump(TYPED)
    return User(id)


def create(body: Name) -> String:
    _bump(TYPED)
    return "created " + body.text


def create_response(var body: Name) -> Response:
    _bump(TYPED)
    return Response.text("made " + body.text, status=201)


def update(id: Int, body: Name) -> String:
    _bump(TYPED)
    return String(id) + " " + body.text


def update_user(id: Int, var body: Name) -> User:
    _bump(TYPED)
    return User(id)


def find(id: Int) raises -> String:
    _bump(TYPED)
    if id == 0:
        raise Error("typed secret")
    return "found " + String(id)


def typed_first(body: Name) -> String:
    return "typed"


def typed_get_first() -> String:
    return "typed"


def _app() -> App:
    var app = App()
    app.get["/raw"](echo)
    app.post["/webhook"](echo)
    app.post["/take"](take_body)
    app.get["/reject"](reject)
    app.post["/verify"](verify)
    app.post["/verify_typed"](verify_typed)
    app.get["/parse"](parse)
    app.post["/verify_unmapped"](verify_unmapped)
    app.get["/hello"](hello)
    app.get["/static"](hello_static)
    app.get["/teapot"](teapot)
    app.get["/users/{id}"](get_user)
    app.get["/items?{id}"](get_text)
    app.get["/find/{id}"](find)
    app.post["/users"](create)
    app.post["/made"](create_response)
    app.post["/users/{id}"](update)
    app.post["/profiles?{id}"](update_user)
    return app^


# Query strings that a typed `?{id}` route answers 400 (missing, duplicated,
# empty or non-integer `id`) or that look like route syntax.
comptime ADVERSARIAL = [
    "",
    "?",
    "?id",
    "?id=",
    "?id=abc",
    "?id=1&id=2",
    "?id=4_2",
    "?{id}",
    "?a?b=c?",
    "?x=1&x",
    "?=&&=",
    "?%69d=%31 +1#frag",
]


def test_dx_section_9_example() raises:
    var app = App()
    app.post["/webhook"](webhook)
    var client = TestClient(app)
    var ok = client.post("/webhook", "signed")
    assert_equal(ok.status, 200)
    assert_equal(ok.text(), "ok")
    var unsigned = client.post("/webhook", "forged")
    assert_equal(unsigned.status, 401)
    assert_equal(unsigned.text(), "unsigned")
    var query = client.post("/webhook?id=abc", "forged")
    assert_equal(query.status, 401)
    assert_equal(query.text(), "unsigned")
    var get = client.get("/webhook")
    assert_equal(get.status, 405)
    assert_equal(get.text(), "Method Not Allowed")
    assert_equal(len(get.headers.get_all("Allow")), 1)
    assert_equal(get.headers.get_all("Allow")[0], "POST")
    assert_equal(client.post("/webhook/x", "signed").status, 404)


def test_raw_get_and_post_receive_the_whole_request() raises:
    _reset()
    var app = _app()
    var bodies = ["", " payload?\n", "a=b&c"]
    var n = 0
    for q in materialize[ADVERSARIAL]():
        for body in bodies:
            var sent = Request("POST", "/webhook" + q, body)
            var r = app.handle(sent)
            assert_equal(r.status, 202, q)
            assert_equal(r.body, _fields(sent), q)
            n += 1
        var g = Request("GET", "/raw" + q)
        var rg = app.handle(g)
        assert_equal(rg.status, 202, q)
        assert_equal(rg.body, _fields(g), q)
        n += 1
    # The field values themselves, not only their round trip.
    var exact = app.handle(Request("POST", "/webhook?id=1&id=2", ""))
    assert_equal(exact.text(), "POST|/webhook|id=1&id=2|")
    var get = app.handle(Request("GET", "/raw?a?b", "ignored?"))
    assert_equal(get.text(), "GET|/raw|a?b|ignored?")
    assert_equal(_count(HANDLER), n + 2)


def test_borrowed_and_owned_requests_register() raises:
    _reset()
    var app = _app()
    var sent = Request("POST", "/take?k=v", "moved")
    var r = app.handle(sent)
    assert_equal(r.status, 201)
    assert_equal(r.text(), "moved")
    # The handler owned a rebuilt request; the caller's is untouched.
    assert_equal(sent.text(), "moved")
    assert_equal(sent.query, "k=v")
    assert_equal(app.handle(Request("POST", "/webhook", "b")).status, 202)
    assert_equal(_count(HANDLER), 2)


def test_explicit_function_value_registers() raises:
    var f: def(var Request) thin raises Never -> Response = echo
    var app = App()
    app.post["/value"](f)
    var r = app.handle(Request("POST", "/value?q", "v"))
    assert_equal(r.status, 202)
    assert_equal(r.text(), "POST|/value|q|v")


def test_raw_routes_run_no_typed_extraction() raises:
    _reset()
    var app = _app()
    # Every adversarial query and an empty body: a typed route would answer
    # 400 from query gathering, `_parse_int` or `from_body`.
    for q in materialize[ADVERSARIAL]():
        assert_equal(
            app.handle(Request("POST", "/webhook" + q, "")).status, 202
        )
        assert_equal(app.handle(Request("GET", "/raw" + q)).status, 202)
    assert_equal(_count(FROM_BODY), 0)
    assert_equal(_count(TYPED), 0)
    # Control: the same queries and body on typed routes do run extraction.
    assert_equal(app.handle(Request("GET", "/items?id=abc")).status, 400)
    assert_equal(app.handle(Request("POST", "/users", "")).status, 400)
    assert_equal(_count(FROM_BODY), 1)
    assert_equal(_count(TYPED), 0)


def test_raw_handler_chooses_any_status() raises:
    _reset()
    var app = _app()
    var r = app.handle(Request("GET", "/reject?why"))
    assert_equal(r.status, 400)
    assert_equal(r.text(), "rejected why")
    var p = app.handle(Request("GET", "/parse", "nope"))
    assert_equal(p.status, 400)
    assert_equal(p.text(), "malformed payload")
    var ok = app.handle(Request("GET", "/parse", "ok"))
    assert_equal(ok.status, 200)
    assert_equal(ok.text(), "parsed")
    assert_equal(_count(HANDLER), 3)


def test_raw_routes_run_only_after_route_selection() raises:
    _reset()
    var app = _app()
    # Another method on a raw route's path: 405 with that path's `Allow`.
    for row in [
        (Request("GET", "/webhook"), "POST"),
        (Request("PUT", "/webhook", "x"), "POST"),
        (Request("post", "/webhook", "x"), "POST"),
        (Request("POST", "/raw"), "GET, HEAD"),
    ]:
        var r = app.handle(row[0])
        var label = row[0].method + " " + row[0].path
        assert_equal(r.status, 405, label)
        assert_equal(r.text(), "Method Not Allowed", label)
        assert_equal(len(r.headers.get_all("Allow")), 1, label)
        assert_equal(r.headers.get_all("Allow")[0], row[1], label)
    for req in [
        Request("POST", "/webhook/x"),
        Request("POST", "/webhook/"),
        Request("POST", "/Webhook"),
        Request("POST", "/missing?/webhook"),
    ]:
        var r = app.handle(req)
        assert_equal(r.status, 404, req.method + " " + req.path)
        assert_equal(r.text(), "Not Found")
    assert_equal(_count(HANDLER), 0)


def test_raw_raise_is_the_fixed_500() raises:
    _reset()
    var app = _app()
    var r = app.handle(Request("POST", "/verify", "forged"))
    assert_equal(r.status, 500)
    assert_equal(r.text(), "Internal Server Error")
    assert_false("secret" in r.text())
    assert_equal(app.handle(Request("POST", "/verify", "signed")).status, 200)
    var u = app.handle(Request("POST", "/verify_unmapped"))
    assert_equal(u.status, 500)
    assert_equal(u.text(), "Internal Server Error")
    assert_equal(_count(HANDLER), 3)


def test_raw_raise_uses_to_error_response() raises:
    var app = _app()
    var r = app.handle(Request("POST", "/verify_typed", "forged"))
    assert_equal(r.status, 401)
    assert_equal(r.text(), "bad signature: unsigned")
    var ok = app.handle(Request("POST", "/verify_typed", "signed"))
    assert_equal(ok.status, 200)
    assert_equal(ok.text(), "verified")


def test_typed_shapes_are_unchanged_beside_raw() raises:
    _reset()
    var app = _app()
    assert_equal(app.handle(Request("GET", "/hello")).text(), "hello")
    assert_equal(app.handle(Request("GET", "/static")).text(), "static")
    assert_equal(app.handle(Request("GET", "/teapot")).status, 418)
    assert_equal(app.handle(Request("GET", "/users/7")).text(), "User(7)")
    assert_equal(app.handle(Request("GET", "/users/x")).status, 400)
    assert_equal(app.handle(Request("GET", "/items?id=3")).text(), "id 3")
    assert_equal(app.handle(Request("GET", "/items?id=1&id=2")).status, 400)
    assert_equal(app.handle(Request("GET", "/find/4")).text(), "found 4")
    var err = app.handle(Request("GET", "/find/0"))
    assert_equal(err.status, 500)
    assert_equal(err.text(), "Internal Server Error")
    assert_equal(
        app.handle(Request("POST", "/users", "ann")).text(), "created ann"
    )
    assert_equal(app.handle(Request("POST", "/users", "")).status, 400)
    # A typed body handler returning `Response` still reaches the generic
    # body overload: `Name` is not `Request`, so no raw overload is viable.
    var made = app.handle(Request("POST", "/made", "bob"))
    assert_equal(made.status, 201)
    assert_equal(made.text(), "made bob")
    assert_equal(app.handle(Request("POST", "/users/4", "cy")).text(), "4 cy")
    assert_equal(app.handle(Request("POST", "/users/x", "cy")).status, 400)
    var p = app.handle(Request("POST", "/profiles?id=9", "dee"))
    assert_equal(p.text(), "User(9)")
    # `/users/x` answers 400 before `from_body`.
    assert_equal(_count(FROM_BODY), 5)
    assert_equal(_count(TYPED), 11)
    assert_equal(_count(HANDLER), 0)


def test_first_registered_route_wins_across_kinds() raises:
    var raw_post = App()
    raw_post.post["/same"](raw_first)
    raw_post.post["/same"](typed_first)
    assert_equal(raw_post.handle(Request("POST", "/same", "x")).text(), "raw")
    assert_equal(raw_post.handle(Request("POST", "/same", "")).text(), "raw")
    var typed_post = App()
    typed_post.post["/same"](typed_first)
    typed_post.post["/same"](raw_first)
    assert_equal(
        typed_post.handle(Request("POST", "/same", "x")).text(), "typed"
    )
    # The typed route answers its own 400; a matched route never falls
    # through to a later one.
    var bad = typed_post.handle(Request("POST", "/same", ""))
    assert_equal(bad.status, 400)
    assert_equal(bad.text(), "Bad Request")

    var raw_get = App()
    raw_get.get["/same"](raw_first)
    raw_get.get["/same"](typed_get_first)
    assert_equal(raw_get.handle(Request("GET", "/same")).text(), "raw")
    var typed_get = App()
    typed_get.get["/same"](typed_get_first)
    typed_get.get["/same"](raw_first)
    assert_equal(typed_get.handle(Request("GET", "/same")).text(), "typed")

    # A typed query route registered first keeps its 400 on the raw path.
    var query_first = App()
    query_first.get["/same?{id}"](get_text)
    query_first.get["/same"](raw_first)
    assert_equal(query_first.handle(Request("GET", "/same")).status, 400)
    assert_equal(
        query_first.handle(Request("GET", "/same?id=2")).text(), "id 2"
    )


def test_test_client_equals_handle() raises:
    var app = _app()
    var client = TestClient(app)
    var gets = ["/raw?id=abc", "/raw", "/reject?q", "/parse", "/webhook"]
    for t in gets:
        var direct = app.handle(Request("GET", t))
        var local = client.get(t)
        assert_equal(local.status, direct.status, t)
        assert_equal(local.body, direct.body, t)
    var posts = [
        ("/webhook?id=1&id=2", ""),
        ("/webhook", " x \n"),
        ("/take", "moved"),
        ("/verify", "forged"),
        ("/verify_typed", "forged"),
        ("/verify_unmapped", ""),
        ("/raw", "x"),
    ]
    for p in posts:
        var direct = app.handle(Request("POST", p[0], p[1]))
        var local = client.post(p[0], p[1])
        assert_equal(local.status, direct.status, p[0])
        assert_equal(local.body, direct.body, p[0])
    assert_equal(client.post("/webhook?a", "b").text(), "POST|/webhook|a|b")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
