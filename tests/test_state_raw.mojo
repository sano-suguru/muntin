# Stateful raw handlers in production (M3-007): the `App.get` and `App.post`
# overloads taking `(handler, state)` for `def(State[S], var Request) ->
# Response`, driven through `App.handle` and `TestClient`. Decision:
# docs/ARCHITECTURE.md, "Application state decision (M3-001)"; raw request
# semantics: "Raw Request handlers in production (M2-015)" and "Headers in
# production (M3-005)". Must-not-compile counterparts: tests/state_raw_fail
# and tests/compile_fail/state_raw_*.

from std.memory import ArcPointer
from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import (
    App,
    FromBody,
    Headers,
    Request,
    Response,
    State,
    ToErrorResponse,
    ToResponse,
)
from muntin.testing import TestClient

# `from_body` is static and cannot see the state, so its calls are counted
# in an environment variable; handler calls are counted in the state.
comptime FROM_BODY_CALLS = "MUNTIN_TEST_STATE_RAW_FROM_BODY_CALLS"


def _reset():
    _ = unsetenv(FROM_BODY_CALLS)


def _from_body_calls() -> Int:
    var n = getenv(FROM_BODY_CALLS)
    try:
        return Int(n) if n else 0
    except:
        return -1


# Application types.


struct Keys(Movable):
    """A move-only application value: the webhook secret. Every handler call
    is counted in `calls`, which the application keeps mutable on purpose
    (its own `ArcPointer[Int]` field, not Muntin's)."""

    var secret: String
    var calls: ArcPointer[Int]

    def __init__(out self, secret: String):
        self.secret = secret
        self.calls = ArcPointer(0)

    def count(self):
        self.calls[] += 1


struct Note(FromBody):
    """A typed body, for the typed routes registered beside raw ones."""

    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        _ = setenv(FROM_BODY_CALLS, String(_from_body_calls() + 1))
        if body.byte_length() == 0:
            raise Error("empty note")
        return Self(body)


struct Tracked(Movable):
    """Records its own destruction in a shared counter held by the test."""

    var drops: ArcPointer[Int]

    def __init__(out self, drops: ArcPointer[Int]):
        self.drops = drops.copy()

    def __deinit__(deinit self):
        self.drops[] += 1


@fieldwise_init
struct BadSignature(Movable, ToErrorResponse):
    """Opts into its own response: 401."""

    var reason: String

    def to_error_response(var self) -> Response:
        return Response.text("bad signature: " + self.reason, status=401)


@fieldwise_init
struct Unmapped(Movable):
    """An application error type without `ToErrorResponse`: fixed 500."""

    var reason: String


@fieldwise_init
struct Echoed(Movable, ToResponse):
    var text: String

    def to_response(var self) -> Response:
        return Response.text("typed " + self.text, status=201)


def _fields(req: Request) -> String:
    """The request as the handler received it: method, path, query, body,
    then each header field in order."""
    var out = req.method + "|" + req.path + "|" + req.query + "|" + req.body
    for i in range(len(req.headers)):
        out += "|" + req.headers.name(i) + "=" + req.headers.value(i)
    return out^


def _header_list(h: Headers) -> String:
    var out = String()
    for i in range(len(h)):
        out += h.name(i) + "=" + h.value(i) + ";"
    return out^


# Stateful raw handlers: `State[S]` first, then the whole `Request`.


def echo(keys: State[Keys], req: Request) -> Response:
    # The state and the request in the same call: "<secret>|<fields>".
    keys[].count()
    return Response.text(keys[].secret + "|" + _fields(req), status=202)


def take_body(keys: State[Keys], var req: Request) -> Response:
    """Owns the request and moves its body into the response."""
    keys[].count()
    var body = req.body^
    req.body = "taken"
    return Response.text(keys[].secret + " " + body^, status=201)


def signed(keys: State[Keys], req: Request) raises BadSignature -> Response:
    """Checks `X-Signature` against the state's secret; answers with
    response fields of its own."""
    keys[].count()
    var sig = req.headers.get("x-signature")
    if not sig:
        raise BadSignature("missing")
    if sig.value() != keys[].secret:
        raise BadSignature(sig.value())
    var resp = Response.text("ok " + req.body, status=200)
    try:
        resp.headers.add("X-Request-Id", "42")
        resp.headers.add("Set-Cookie", "a=1")
        resp.headers.add("Set-Cookie", "b=2")
        resp.headers.add("X-Empty", "")
    except:
        pass
    return resp^


def refuse(keys: State[Keys], req: Request) -> Response:
    """Answers 400 itself: a raw handler may use any status."""
    keys[].count()
    return Response.text("refused " + req.query, status=400)


def fail(keys: State[Keys], req: Request) raises -> Response:
    keys[].count()
    raise Error("secret detail " + keys[].secret)


def fail_unmapped(keys: State[Keys], req: Request) raises Unmapped -> Response:
    keys[].count()
    raise Unmapped(keys[].secret)


def handles(keys: State[Keys], req: Request) -> Response:
    # Reads the handle's reference count from inside a request.
    return Response.text(String(keys._shared.count()))


def handles_raising(keys: State[Keys], req: Request) raises -> Response:
    if req.body == "raise":
        raise Error("count " + String(keys._shared.count()))
    return Response.text(String(keys._shared.count()))


def track(tracked: State[Tracked], req: Request) -> Response:
    return Response.text(String(tracked[].drops[]) + " " + req.body)


def later(keys: State[Keys], req: Request) -> Response:
    return Response.text("stateful raw")


# Stateless and typed handlers registered on the same apps.


def plain_raw(req: Request) -> Response:
    return Response.text("plain raw " + req.body)


def typed_get() -> String:
    return "typed get"


def typed_post(body: Note) -> String:
    return "typed post " + body.text


def stateful_get(keys: State[Keys], id: Int) -> String:
    keys[].count()
    return keys[].secret + " " + String(id)


def stateful_post(keys: State[Keys], var body: Note) -> Echoed:
    keys[].count()
    return Echoed(body.text)


def _keys() -> State[Keys]:
    return State(Keys("sha256=k"))


def _calls(keys: State[Keys]) -> Int:
    return keys[].calls[]


def _handles(keys: State[Keys]) -> Int:
    return Int(keys._shared.count())


# Query strings that a typed `?{id}` route answers 400 (missing, duplicated,
# empty or non-integer `id`) or that look like route syntax.
comptime ADVERSARIAL = [
    "",
    "?",
    "?id",
    "?id=",
    "?id=abc",
    "?id=1&id=2",
    "?{id}",
    "?a?b=c?",
    "?=&&=",
    "?%69d=%31 +1#frag",
]


def _headers() raises -> Headers:
    var h = Headers()
    h.add("X-B", "2")
    h.add("Content-Type", "text/plain; charset=utf-8")
    h.add("x-b", "")
    h.add("X-Odd", "a:b\tc")
    return h^


# Tests.


def test_get_and_post_receive_the_whole_request_and_the_state() raises:
    # Method, path, query, body and every header field reach the handler
    # unchanged, beside the state, on both methods.
    var keys = _keys()
    var app = App()
    app.get["/hook"](echo, keys)
    app.post["/hook"](echo, keys)
    var bodies = ["", " payload?\n", "a=b&c"]
    var n = 0
    for q in materialize[ADVERSARIAL]():
        for body in bodies:
            var sent = Request("POST", "/hook" + q, body, _headers())
            var r = app.handle(sent)
            assert_equal(r.status, 202, q)
            assert_equal(r.body, "sha256=k|" + _fields(sent), q)
            n += 1
        var g = Request("GET", "/hook" + q, "", _headers())
        var rg = app.handle(g)
        assert_equal(rg.status, 202, q)
        assert_equal(rg.body, "sha256=k|" + _fields(g), q)
        n += 1
    # The field values themselves, not only their round trip.
    var exact = app.handle(Request("POST", "/hook?id=1&id=2", "b", _headers()))
    assert_equal(
        exact.body,
        (
            "sha256=k|POST|/hook|id=1&id=2|b|X-B=2|Content-Type=text/plain;"
            " charset=utf-8|x-b=|X-Odd=a:b\tc"
        ),
    )
    var get = app.handle(Request("GET", "/hook?a?b", "ignored?"))
    assert_equal(get.body, "sha256=k|GET|/hook|a?b|ignored?")
    assert_equal(_calls(keys), n + 2)


def test_borrowed_and_owned_requests_register() raises:
    var keys = _keys()
    var app = App()
    app.post["/take"](take_body, keys)
    app.get["/take"](take_body, keys)
    var sent = Request("POST", "/take?k=v", "moved", _headers())
    var r = app.handle(sent)
    assert_equal(r.status, 201)
    assert_equal(r.body, "sha256=k moved")
    # The handler owned a rebuilt request; the caller's is untouched.
    assert_equal(sent.body, "moved")
    assert_equal(sent.query, "k=v")
    assert_equal(len(sent.headers), 4)
    assert_equal(app.handle(Request("GET", "/take", "g")).body, "sha256=k g")
    assert_equal(_calls(keys), 2)


def test_explicit_function_value_registers() raises:
    var f: def(State[Keys], var Request) thin raises Never -> Response = echo
    var keys = _keys()
    var app = App()
    app.post["/value"](f, keys)
    app.get["/value"](f, keys)
    var r = app.handle(Request("POST", "/value?q", "v"))
    assert_equal(r.status, 202)
    assert_equal(r.body, "sha256=k|POST|/value|q|v")
    assert_equal(app.handle(Request("GET", "/value")).status, 202)


def test_no_typed_extraction_runs_after_the_match() raises:
    # Every adversarial query and an empty body: a typed route would answer
    # 400 from query gathering, `_parse_int` or `from_body`.
    _reset()
    var keys = _keys()
    var app = App()
    app.get["/hook"](echo, keys)
    app.post["/hook"](echo, keys)
    app.get["/typed?{id}"](stateful_get, keys)
    app.post["/typed"](stateful_post, keys)
    for q in materialize[ADVERSARIAL]():
        assert_equal(app.handle(Request("POST", "/hook" + q, "")).status, 202)
        assert_equal(app.handle(Request("GET", "/hook" + q)).status, 202)
    assert_equal(_from_body_calls(), 0)
    assert_equal(_calls(keys), 2 * len(materialize[ADVERSARIAL]()))
    # Control: the same query and body on stateful typed routes do run
    # extraction, and answer 400 without calling their handlers.
    assert_equal(app.handle(Request("GET", "/typed?id=abc")).status, 400)
    assert_equal(app.handle(Request("POST", "/typed", "")).status, 400)
    assert_equal(_from_body_calls(), 1)
    assert_equal(_calls(keys), 2 * len(materialize[ADVERSARIAL]()))


def test_response_status_body_and_headers_survive() raises:
    var keys = _keys()
    var app = App()
    app.post["/signed"](signed, keys)
    app.get["/refuse"](refuse, keys)
    var h = Headers()
    h.add("X-Signature", "sha256=k")
    var ok = app.handle(Request("POST", "/signed", "data", h^))
    assert_equal(ok.status, 200)
    assert_equal(ok.body, "ok data")
    assert_equal(
        _header_list(ok.headers),
        "X-Request-Id=42;Set-Cookie=a=1;Set-Cookie=b=2;X-Empty=;",
    )
    # A returned 400 is the handler's own response, not a Muntin 400.
    var refused = app.handle(Request("GET", "/refuse?why"))
    assert_equal(refused.status, 400)
    assert_equal(refused.body, "refused why")
    assert_equal(len(refused.headers), 0)
    assert_equal(_calls(keys), 2)


def test_errors_use_the_m2_model() raises:
    var keys = _keys()
    var app = App()
    app.post["/signed"](signed, keys)
    app.get["/signed"](signed, keys)
    app.post["/fail"](fail, keys)
    app.get["/unmapped"](fail_unmapped, keys)
    # `raises BadSignature`: its own response, decided from the state.
    var missing = app.handle(Request("POST", "/signed", "data"))
    assert_equal(missing.status, 401)
    assert_equal(missing.body, "bad signature: missing")
    var h = Headers()
    h.add("x-signature", "sha256=forged")
    var forged = app.handle(Request("GET", "/signed", "", h^))
    assert_equal(forged.status, 401)
    assert_equal(forged.body, "bad signature: sha256=forged")
    assert_equal(len(forged.headers), 0)
    # Bare `raises` and an application type without `ToErrorResponse`: the
    # fixed 500, without the error's text.
    for req in [Request("POST", "/fail"), Request("GET", "/unmapped")]:
        var r = app.handle(req)
        assert_equal(r.status, 500, req.path)
        assert_equal(r.body, "Internal Server Error", req.path)
        assert_false("secret" in r.body)
        assert_equal(len(r.headers), 0)
    assert_equal(_calls(keys), 4)


def test_routes_run_only_after_route_selection() raises:
    var keys = _keys()
    var app = App()
    app.post["/hook"](echo, keys)
    app.get["/view"](echo, keys)
    for req in [
        Request("GET", "/hook"),
        Request("PUT", "/hook", "x"),
        Request("post", "/hook", "x"),
        Request("POST", "/view"),
        Request("POST", "/hook/x"),
        Request("POST", "/hook/"),
        Request("POST", "/Hook"),
        Request("GET", "/view/x"),
        Request("POST", "/missing?/hook"),
    ]:
        var r = app.handle(req)
        assert_equal(r.status, 404, req.method + " " + req.path)
        assert_equal(r.body, "Not Found")
    assert_equal(_calls(keys), 0)


def test_first_registration_wins() raises:
    # Across stateless raw, stateful raw and typed routes, both orders.
    var keys = _keys()
    var post = App()
    post.post["/a"](plain_raw)
    post.post["/a"](later, keys)
    post.post["/b"](later, keys)
    post.post["/b"](plain_raw)
    post.post["/c"](later, keys)
    post.post["/c"](typed_post)
    post.post["/c"](stateful_post, keys)
    post.post["/d"](typed_post)
    post.post["/d"](later, keys)
    post.post["/e"](stateful_post, keys)
    post.post["/e"](later, keys)
    assert_equal(post.handle(Request("POST", "/a", "x")).body, "plain raw x")
    assert_equal(post.handle(Request("POST", "/b", "x")).body, "stateful raw")
    assert_equal(post.handle(Request("POST", "/c", "")).body, "stateful raw")
    assert_equal(post.handle(Request("POST", "/d", "x")).body, "typed post x")
    assert_equal(post.handle(Request("POST", "/e", "x")).body, "typed x")
    # A typed route's 400 does not fall through to a later raw route.
    assert_equal(post.handle(Request("POST", "/d", "")).status, 400)
    assert_equal(post.handle(Request("POST", "/e", "")).status, 400)

    var get = App()
    get.get["/a"](plain_raw)
    get.get["/a"](later, keys)
    get.get["/b"](later, keys)
    get.get["/b"](plain_raw)
    get.get["/c"](later, keys)
    get.get["/c"](typed_get)
    get.get["/d"](typed_get)
    get.get["/d"](later, keys)
    get.get["/e?{id}"](stateful_get, keys)
    get.get["/e"](later, keys)
    assert_equal(get.handle(Request("GET", "/a")).body, "plain raw ")
    assert_equal(get.handle(Request("GET", "/b")).body, "stateful raw")
    assert_equal(get.handle(Request("GET", "/c")).body, "stateful raw")
    assert_equal(get.handle(Request("GET", "/d")).body, "typed get")
    assert_equal(get.handle(Request("GET", "/e")).status, 400)
    assert_equal(get.handle(Request("GET", "/e?id=3")).body, "sha256=k 3")


def test_handles_change_at_registration_and_drop_only() raises:
    # One handle per route plus the application's: each registration copies
    # the handle once, and requests only borrow it, so the reference count
    # is the same inside a handler, across successful and failing requests,
    # and after them.
    var keys = _keys()
    var app = App()
    app.get["/hook"](echo, keys)
    assert_equal(_handles(keys), 2)
    app.post["/hook"](echo, keys)
    assert_equal(_handles(keys), 3)
    app.get["/handles"](handles, keys)
    app.post["/handles"](handles_raising, keys)
    app.post["/signed"](signed, keys)
    app.get["/fail"](fail, keys)
    assert_equal(_handles(keys), 7)  # one per registration, both methods
    var client = TestClient(app)
    assert_equal(client.get("/handles").body, "7")
    assert_equal(client.post("/handles", "").body, "7")
    for _ in range(5):
        _ = client.get("/hook?x")
        _ = client.post("/hook", "b")
        _ = client.post("/signed", "unsigned")  # 401
        _ = client.get("/fail")  # 500
        _ = client.post("/handles", "raise")  # 500
        _ = client.get("/missing")  # 404
        assert_equal(_handles(keys), 7)
    assert_equal(_calls(keys), 20)
    _ = app^  # the routes' handles go with the app
    assert_equal(_handles(keys), 1)


def test_state_survives_app_moves_and_is_dropped_once() raises:
    var drops = ArcPointer(0)
    var tracked = State(Tracked(drops))
    var app = App()
    app.post["/track"](track, tracked)
    app.get["/track"](track, tracked)
    _ = tracked^  # the app now holds the only handles
    assert_equal(drops[], 0)
    var moved = app^
    assert_equal(TestClient(moved).post("/track", "a").body, "0 a")
    var again = moved^
    assert_equal(TestClient(again).post("/track", "b").body, "0 b")
    assert_equal(TestClient(again).get("/track").body, "0 ")
    assert_equal(drops[], 0)
    _ = again^
    assert_equal(drops[], 1)


def test_test_client_equals_handle_before_and_after_a_move() raises:
    var keys = _keys()
    var app = App()
    app.get["/hook"](echo, keys)
    app.post["/hook"](echo, keys)
    app.post["/signed"](signed, keys)
    app.post["/fail"](fail, keys)
    var before = TestClient(app)
    assert_equal(
        before.get("/hook?id=x").body,
        app.handle(Request("GET", "/hook?id=x")).body,
    )
    var moved = app^
    var after = TestClient(moved)
    var gets = ["/hook?id=abc", "/hook", "/hook?", "/missing"]
    for t in gets:
        var direct = moved.handle(Request("GET", t))
        var local = after.get(t)
        assert_equal(local.status, direct.status, t)
        assert_equal(local.body, direct.body, t)
    var posts = [
        ("/hook?id=1&id=2", ""),
        ("/hook", " x \n"),
        ("/signed", "data"),
        ("/fail", ""),
        ("/hook/x", "x"),
    ]
    for p in posts:
        var direct = moved.handle(Request("POST", p[0], p[1]))
        var local = after.post(p[0], p[1])
        assert_equal(local.status, direct.status, p[0])
        assert_equal(local.body, direct.body, p[0])
    assert_equal(_handles(keys), 5)
    _ = moved^
    assert_equal(_handles(keys), 1)


def test_existing_routes_are_unchanged_beside_stateful_raw() raises:
    _reset()
    var keys = _keys()
    var app = App()
    app.get["/hook"](echo, keys)
    app.post["/hook"](echo, keys)
    app.get["/plain"](typed_get)
    app.post["/plain"](typed_post)
    app.post["/raw"](plain_raw)
    app.get["/raw"](plain_raw)
    app.get["/keys/{id}"](stateful_get, keys)
    app.post["/keys"](stateful_post, keys)
    assert_equal(app.handle(Request("GET", "/plain")).body, "typed get")
    assert_equal(
        app.handle(Request("POST", "/plain", "n")).body, "typed post n"
    )
    assert_equal(app.handle(Request("POST", "/plain", "")).status, 400)
    assert_equal(app.handle(Request("POST", "/raw", "r")).body, "plain raw r")
    assert_equal(app.handle(Request("GET", "/raw")).body, "plain raw ")
    assert_equal(app.handle(Request("GET", "/keys/4")).body, "sha256=k 4")
    assert_equal(app.handle(Request("GET", "/keys/x")).status, 400)
    var typed = app.handle(Request("POST", "/keys", "n"))
    assert_equal(typed.status, 201)
    assert_equal(typed.body, "typed n")
    # Typed routes without a carrier still receive no header strings (M3-005).
    var with_fields = app.handle(Request("GET", "/keys/4", "", _headers()))
    assert_equal(with_fields.body, "sha256=k 4")
    assert_equal(_from_body_calls(), 3)
    assert_equal(_calls(keys), 3)


# The docs/DX.md section 8 stateful raw webhook, verbatim but for the
# handler's name.


@fieldwise_init
struct WebhookKeys(Movable):
    var secret: String


def dx_webhook(keys: State[WebhookKeys], req: Request) raises -> Response:
    var signature = req.headers.get("x-signature")
    if not signature or signature.value() != keys[].secret:
        return Response.text("unsigned", status=401)
    var resp = Response.text("ok")
    resp.headers.add("X-Request-Id", "42")
    return resp^


def test_dx_section_8_stateful_raw_example() raises:
    var keys = State(WebhookKeys("sha256=valid"))
    var app = App()
    app.post["/webhook"](dx_webhook, keys)
    var h = Headers()
    h.add("X-Signature", "sha256=valid")
    var ok = app.handle(Request("POST", "/webhook", "", h^))
    assert_equal(ok.status, 200)
    assert_equal(ok.body, "ok")
    assert_equal(_header_list(ok.headers), "X-Request-Id=42;")
    var unsigned = TestClient(app).post("/webhook", "")
    assert_equal(unsigned.status, 401)
    assert_equal(unsigned.body, "unsigned")
    assert_equal(TestClient(app).get("/webhook").status, 404)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
