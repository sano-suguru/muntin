# Spike for the request rejection report decision (M3-084; evidence for its
# pull request, not a production test): every 400 `src/muntin` makes before a
# handler carries a `Rejection` that `Response.rejection()` returns, naming
# the step, the route value and the cause, while the client's status, body
# and fields stay what they were. The decision record names what the
# production slice adds. A `Param` handler is left out: one in a module that
# discovers its tests crashes Mojo 1.1.0 (tests/test_named_values.mojo).

from std.sys.info import size_of
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import (
    App,
    FromBody,
    FromBytes,
    FromJson,
    FromRouteValue,
    Group,
    Headers,
    Json,
    JsonValue,
    Next,
    Rejection,
    Request,
    Response,
    RouteValues,
    State,
    ToErrorResponse,
    WithHeaders,
)
from muntin.testing import TestClient


@fieldwise_init
struct Text(FromBody, Movable):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        if body == "bad":
            raise Error("text must not be 'bad'")
        return Self(body)


@fieldwise_init
struct Blob(FromBytes, Movable):
    comptime max_bytes = 16
    var size: Int

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        if len(body) == 0:
            raise Error("empty blob")
        return Self(len(body))


@fieldwise_init
struct Note(FromJson, Movable):
    var text: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["txet"].string())  # #167's misspelling


@fieldwise_init
struct Sku(FromRouteValue, Movable):
    var code: String

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        if not value.startswith("sku-"):
            raise Error("a sku starts with sku-")
        return Self(value)


@fieldwise_init
struct At(RouteValues):
    var id: Int
    var page: Int


def by_id(id: Int) -> String:
    return "id " + String(id)


def by_name(name: String) -> String:
    return "name " + name


def by_page(id: Int, page: Int) -> String:
    return String(id, " ", page)


def by_q(q: String) -> String:
    return q


def by_sku(sku: Sku) -> String:
    return sku.code


def by_record(at: At) -> String:
    return String(at.id, " ", at.page)


def post_text(body: Text) -> String:
    return body.text


def post_blob(body: Blob) -> String:
    return String(body.size)


@fieldwise_init
struct Count(FromJson, Movable):
    var n: Int

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["n"].int())


def post_count(body: Json[Count]) -> String:
    return String(body.value.n)


def post_note(body: Json[Note]) -> String:
    return body.value.text


def post_carried(body: WithHeaders[Json[Note]]) -> String:
    return "carried"


def post_carried_text(body: WithHeaders[Text]) -> String:
    return "carried"


def own_400() -> Response:
    return Response.text("Bad Request", status=400)


def raises_error(id: Int) raises -> String:
    raise Error("boom")


@fieldwise_init
struct Denied(Movable, ToErrorResponse):
    def to_error_response(var self) -> Response:
        return Response.text("Unauthorized", status=401)


@fieldwise_init
struct Keys(Copyable, Movable):
    var key: String


@fieldwise_init
struct Who(Movable):
    var name: String


def check_key(keys: State[Keys], headers: Headers) raises Denied -> Who:
    if headers.get("x-key").or_else("") != keys[].key:
        raise Denied()
    return Who("ada")


def guarded_by_id(who: Who, id: Int) -> String:
    return who.name + " " + String(id)


def make_app() -> App:
    var app = App()
    app.get["/users/{id}"](by_id)
    app.get["/names/{name}"](by_name)
    app.get["/pages/{id}?{page}"](by_page)
    app.get["/search?{q}"](by_q)
    app.get["/skus/{sku}"](by_sku)
    app.get["/records/{id}?{page}"](by_record)
    app.post["/text"](post_text)
    app.post["/blob"](post_blob)
    app.post["/notes"](post_note)
    app.post["/counts"](post_count)
    app.post["/carried"](post_carried)
    app.post["/carried-text"](post_carried_text)
    app.get["/own"](own_400)
    app.get["/boom/{id}"](raises_error)
    var keys = State(Keys("k"))
    var g = Group(check_key, keys)
    g.get["/guarded/{id}"](guarded_by_id)
    app.mount(g^)
    return app^


def json_headers() -> Headers:
    var h = Headers()
    try:
        h.add("Content-Type", "application/json")
    except:
        pass
    return h^


def expect(r: Response, step: String, name: String, message: String) raises:
    assert_equal(r.status, 400)
    assert_equal(r.text(), "Bad Request")
    assert_equal(len(r.headers), 0)
    assert_false(r.failure())
    var rejection = r.rejection()
    assert_true(rejection)
    assert_equal(rejection.value().step, step)
    assert_equal(rejection.value().name, name)
    assert_equal(rejection.value().message, message)


def test_path_values() raises:
    var app = make_app()
    var c = TestClient(app)
    expect(c.get("/users/abc"), Rejection.PATH, "id", "not an integer")
    expect(c.get("/users/%zz"), Rejection.PATH, "id", "bad percent escape")
    expect(c.get("/users/%ff"), Rejection.PATH, "id", "not UTF-8")
    expect(
        c.get("/names/%4"), Rejection.PATH, "name", "truncated percent escape"
    )
    # Muntin's own text never quotes what the client sent.
    expect(
        c.get("/users/99999999999999999999"),
        Rejection.PATH,
        "id",
        "out of Int range",
    )


def test_query_values() raises:
    var app = make_app()
    var c = TestClient(app)
    expect(c.get("/search"), Rejection.QUERY, "q", "missing")
    expect(c.get("/search?q=a&q=b"), Rejection.QUERY, "q", "repeated")
    expect(c.get("/search?q="), Rejection.QUERY, "q", "empty")
    expect(c.get("/pages/1?page=x"), Rejection.QUERY, "page", "not an integer")
    expect(c.get("/pages/x?page=1"), Rejection.PATH, "id", "not an integer")


def test_application_route_values() raises:
    var app = make_app()
    var c = TestClient(app)
    expect(
        c.get("/skus/abc"),
        Rejection.FROM_ROUTE_VALUE,
        "sku",
        "a sku starts with sku-",
    )
    expect(
        c.get("/records/1?page=x"), Rejection.QUERY, "page", "not an integer"
    )
    expect(c.get("/records/x?page=1"), Rejection.PATH, "id", "not an integer")


def test_bodies() raises:
    var app = make_app()
    var c = TestClient(app)
    var not_utf8: List[UInt8] = [0xFF, 0xFE]
    expect(c.post("/text", not_utf8.copy()), Rejection.UTF8, "", "not UTF-8")
    expect(
        c.post("/text", "bad"),
        Rejection.FROM_BODY,
        "",
        "text must not be 'bad'",
    )
    expect(c.post("/blob", ""), Rejection.FROM_BYTES, "", "empty blob")
    expect(
        c.post("/notes", "{", headers=json_headers()),
        Rejection.JSON,
        "",
        "invalid JSON: expected member name",
    )
    expect(
        c.post("/notes", '{"text": "hi"}', headers=json_headers()),
        Rejection.FROM_JSON,
        "",
        'JSON member "txet" is missing',
    )
    # Muntin's `JsonValue.int()` does not quote the client's literal.
    expect(
        c.post(
            "/counts", '{"n": 99999999999999999999}', headers=json_headers()
        ),
        Rejection.FROM_JSON,
        "",
        "JSON number is out of Int range",
    )
    # A carrier converts its body as a bare body of its type is.
    expect(
        c.post("/carried", '{"text": "hi"}', headers=json_headers()),
        Rejection.FROM_JSON,
        "",
        'JSON member "txet" is missing',
    )
    expect(
        c.post("/carried-text", not_utf8.copy()),
        Rejection.UTF8,
        "",
        "not UTF-8",
    )


def test_guarded_route() raises:
    var app = make_app()
    var c = TestClient(app)
    var key = Headers()
    key.add("X-Key", "k")
    # Decoding fails before the guard: the guard admits the request, then
    # the deferred 400 is answered with its report.
    expect(
        c.get("/guarded/%zz", headers=key.copy()),
        Rejection.PATH,
        "id",
        "bad percent escape",
    )
    # The slot's own 400, after the guard.
    expect(
        c.get("/guarded/x", headers=key.copy()),
        Rejection.PATH,
        "id",
        "not an integer",
    )
    # The guard answers first: its response, no rejection.
    for target in ["/guarded/%zz", "/guarded/x"]:
        var refused = c.get(target)
        assert_equal(refused.status, 401)
        assert_false(refused.rejection())
    var ok = c.get("/guarded/7", headers=key.copy())
    assert_equal(ok.text(), "ada 7")


def test_none_elsewhere() raises:
    var app = make_app()
    var c = TestClient(app)
    assert_false(c.get("/users/1").rejection())
    assert_false(c.get("/nowhere").rejection())  # 404
    assert_false(c.post("/users/1", "").rejection())  # 405
    assert_false(c.post("/notes", "{}").rejection())  # 415
    var big = List[UInt8](length=17, fill=1)
    assert_false(c.post("/blob", big^).rejection())  # 413
    assert_false(c.get("/own").rejection())  # the application's own 400
    var boom = c.get("/boom/1")
    assert_equal(boom.status, 500)
    assert_false(boom.rejection())
    assert_true(boom.failure())
    assert_false(Response.text("Bad Request", status=400).rejection())


def test_head_copies_and_edits_keep_it() raises:
    var app = make_app()
    var c = TestClient(app)
    var head = c.head("/users/abc")
    expect(head, Rejection.PATH, "id", "not an integer")
    var copied = head.copy()
    copied.status = 422
    assert_equal(copied.rejection().value().name, "id")
    assert_equal(String(copied.rejection().value()), "path id: not an integer")


def outer(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    var rejection = response.rejection()
    if rejection:
        response.headers.add("X-Log", String(rejection.value()))
    return response^


def test_middleware_reads_it() raises:
    var app = make_app()
    app.use(outer)
    var c = TestClient(app)
    var r = c.post("/notes", '{"text": "hi"}', headers=json_headers())
    assert_equal(
        r.headers.get("X-Log").value(),
        'from_json: JSON member "txet" is missing',
    )
    assert_equal(r.text(), "Bad Request")


def test_response_keeps_its_size() raises:
    assert_equal(size_of[Response](), 80)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
