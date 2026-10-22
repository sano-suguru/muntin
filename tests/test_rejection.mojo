# Request rejection reports (M3-085): every 400 `src/muntin` makes before a
# handler carries a `Rejection` that `Response.rejection()` returns, naming
# the step, the route value and Muntin's fixed message or the conversion's
# own, while the client's status, body and fields stay what they were.
# Through `App.handle` and `TestClient`: every step and fixed message, a
# repeated query key as the one pass finds it, each source of a name (path,
# query, `RouteValues` fields, `FromRouteValue`, `Param`), guarded routes
# with and without a context slot, carriers, `None` elsewhere, `HEAD` and
# copies, a middleware reading it, and `Response`'s size. Contract:
# docs/history/architecture-decisions.md, "Request rejection report decision
# (M3-084)", "Next production slice"; semantics: docs/reference/errors.md.
# The `Param` handlers are in tests/named_value_handlers.mojo, so this
# module can discover its tests. Over loopback:
# adapters/flare/test_localhost_roundtrip.mojo.

from std.sys import stderr
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
from named_value_handlers import checked_post_of, named_optional, query_pair


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


# docs/reference/errors.md, "Reports of rejected requests": the text
# between the `# example:` lines is what the page shows
# (scripts/check_doc_examples.py).


# example: errors-rejection
from muntin import App, FromJson, Json, JsonValue, Rejection


@fieldwise_init
struct Note(FromJson, Movable):
    var text: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["txet"].string())  # misspelled: every body is 400


def add_note(body: Json[Note]) -> String:
    return body.value.text


def show_user(id: Int) -> String:
    return "user " + String(id)


# example: end


@fieldwise_init
struct Count(FromJson, Movable):
    var n: Int

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["n"].int())


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


@fieldwise_init
struct Pair(RouteValues):
    """Two query keys: compared one by one, not looked up in the index."""

    var a: Int
    var b: Int


@fieldwise_init
struct Nine(RouteValues):
    """More query keys than `_LINEAR_QUERY_KEYS`: looked up in the index."""

    var a: Int
    var b: Int
    var c: Int
    var d: Int
    var e: Int
    var f: Int
    var g: Int
    var h: Int
    var i: Int


def by_id(id: Int) -> String:
    return "id " + String(id)


def by_name(name: String) -> String:
    return "name " + name


def by_page(id: Int, page: Int) -> String:
    return String(id, " ", page)


def by_q(q: String) -> String:
    return q


def by_limit(limit: Optional[Int]) -> String:
    return String(limit.or_else(20))


def by_sku(sku: Sku) -> String:
    return sku.code


def by_record(at: At) -> String:
    return String(at.id, " ", at.page)


def by_pair(p: Pair) -> String:
    return String(p.a, " ", p.b)


def by_nine(n: Nine) -> String:
    return String(n.i)


def by_id_with_headers(id: Int, headers: Headers) -> String:
    return String(id, " ", len(headers))


def post_text(body: Text) -> String:
    return body.text


def post_blob(body: Blob) -> String:
    return String(body.size)


def post_count(body: Json[Count]) -> String:
    return String(body.value.n)


def post_carried(body: WithHeaders[Json[Note]]) -> String:
    return "carried"


def post_carried_text(body: WithHeaders[Text]) -> String:
    return "carried"


def post_carried_blob(body: WithHeaders[Blob]) -> String:
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
    """The guard's value: the group's context type."""

    var name: String


def check_key(keys: State[Keys], headers: Headers) raises Denied -> Who:
    if headers.get("x-key").or_else("") != keys[].key:
        raise Denied()
    return Who("ada")


def exact_fields(keys: State[Keys], headers: Headers) raises Denied -> Who:
    """Admits only a request whose fields it receives are exactly `X-Key: k`
    then `X-B: 2`: a deferred 400's `Rejection` is not among them."""
    var seen = String()
    for i in range(len(headers)):
        seen += headers.name(i) + "=" + headers.value(i) + ";"
    if seen != "X-Key=k;X-B=2;":
        raise Denied()
    return Who(seen)


def seen_by_the_guard(who: Who, id: Int) -> String:
    return who.name


def guarded_value(id: Int) -> String:
    return String(id)


def guarded_with_context(who: Who, id: Int) -> String:
    return who.name + " " + String(id)


def guarded_without_context(id: Int, page: Int) -> String:
    return String(id, " ", page)


def guarded_with_headers(id: Int, headers: Headers) -> String:
    return String(id, " ", len(headers))


def guarded_body(who: Who, id: Int, body: Json[Note]) -> String:
    return who.name


def make_app() -> App:
    var app = App()
    app.get["/users/{id}"](by_id)
    app.get["/names/{name}"](by_name)
    app.get["/pages/{id}?{page}"](by_page)
    app.get["/search?{q}"](by_q)
    app.get["/items?{limit}"](by_limit)
    app.get["/skus/{sku}"](by_sku)
    app.get["/records/{id}?{page}"](by_record)
    app.get["/pair?{a}&{b}"](by_pair)
    app.get["/nine?{a}&{b}&{c}&{d}&{e}&{f}&{g}&{h}&{i}"](by_nine)
    app.get["/fields/{id}"](by_id_with_headers)
    app.get["/checked/{uid}/posts/{pid}"](checked_post_of)
    app.put["/named?{q}&{limit}"](query_pair)
    app.get["/named-optional?{limit}"](named_optional)
    app.post["/text"](post_text)
    app.post["/blob"](post_blob)
    app.post["/notes"](add_note)
    app.post["/counts"](post_count)
    app.post["/carried"](post_carried)
    app.post["/carried-text"](post_carried_text)
    app.post["/carried-blob"](post_carried_blob)
    app.get["/own"](own_400)
    app.get["/boom/{id}"](raises_error)
    var g = Group(check_key, State(Keys("k")))
    g.get["/guarded/{id}"](guarded_with_context)
    g.get["/plain/{id}?{page}"](guarded_without_context)
    g.get["/held/{id}"](guarded_with_headers)
    g.post["/guarded-notes/{id}"](guarded_body)
    app.mount(g^)
    var exact = Group(exact_fields, State(Keys("k")))
    exact.get["/seen/{id}"](seen_by_the_guard)
    exact.get["/seen-plain/{id}"](guarded_value)
    app.mount(exact^)
    return app^


def json_headers() -> Headers:
    var h = Headers()
    try:
        h.add("Content-Type", "application/json")
    except:
        pass
    return h^


def key(json: Bool = False) -> Headers:
    var h = json_headers() if json else Headers()
    try:
        h.add("X-Key", "k")
    except:
        pass
    return h^


def expect(r: Response, step: String, name: String, message: String) raises:
    """Muntin's 400 as the client sees it, carrying this `Rejection`."""
    var at = String(step, " ", name, ": ", message)
    assert_equal(r.status, 400, at)
    assert_equal(r.text(), "Bad Request", at)
    assert_equal(len(r.headers), 0, at)
    assert_false(r.failure(), at)
    var rejection = r.rejection()
    assert_true(rejection, at)
    assert_equal(rejection.value().step, step, at)
    assert_equal(rejection.value().name, name, at)
    assert_equal(rejection.value().message, message, at)


def test_path_values() raises:
    var app = make_app()
    var c = TestClient(app)
    expect(c.get("/users/abc"), Rejection.PATH, "id", "not an integer")
    expect(c.get("/users/-"), Rejection.PATH, "id", "not an integer")
    expect(c.get("/users/%zz"), Rejection.PATH, "id", "bad percent escape")
    expect(c.get("/users/%ff"), Rejection.PATH, "id", "not UTF-8")
    expect(
        c.get("/names/%4"), Rejection.PATH, "name", "truncated percent escape"
    )
    # Muntin's own text never quotes what the client sent; `Int`'s would.
    expect(
        c.get("/users/99999999999999999999"),
        Rejection.PATH,
        "id",
        "out of Int range",
    )
    # A path capture is never empty, so `empty` is a query value's alone.
    assert_equal(c.get("/names/").status, 404)


def test_query_values() raises:
    var app = make_app()
    var c = TestClient(app)
    expect(c.get("/search"), Rejection.QUERY, "q", "missing")
    expect(c.get("/search?q=a&q=b"), Rejection.QUERY, "q", "repeated")
    expect(c.get("/search?q="), Rejection.QUERY, "q", "empty")
    expect(c.get("/search?q=%zz"), Rejection.QUERY, "q", "bad percent escape")
    expect(c.get("/search?q=%FF"), Rejection.QUERY, "q", "not UTF-8")
    # An `Int` parse in the handler's slot names the query value too.
    expect(c.get("/pages/1?page=x"), Rejection.QUERY, "page", "not an integer")
    expect(c.get("/pages/1"), Rejection.QUERY, "page", "missing")
    expect(c.get("/pages/x?page=1"), Rejection.PATH, "id", "not an integer")
    # docs/reference/routing.md, "Order of checks": the path values are
    # decoded before the query keys are looked for, each query key is
    # missing or decoded in order, and a repeat is found before either.
    expect(c.get("/pages/%zz"), Rejection.PATH, "id", "bad percent escape")
    expect(c.get("/pair?a=%zz"), Rejection.QUERY, "a", "bad percent escape")
    expect(c.get("/pair?a=%zz&b=1&b=2"), Rejection.QUERY, "b", "repeated")
    expect(c.get("/items?limit=x"), Rejection.QUERY, "limit", "not an integer")
    assert_equal(c.get("/items?limit=").text(), "20")


def test_repeated_key_is_the_one_pass_finds() raises:
    """The repeated key is the first, in the query's order, whose second
    occurrence the one pass reaches: `c` below, though `a` is declared first
    and repeats too. A search key by key in declaration order would name
    `a`. Both ways of finding a key: compared one by one (two keys) and
    looked up in the index (nine)."""
    var app = make_app()
    var c = TestClient(app)
    expect(c.get("/pair?b=1&a=1&b=2&a=2"), Rejection.QUERY, "b", "repeated")
    expect(c.get("/nine?c=1&a=1&c=2&a=2"), Rejection.QUERY, "c", "repeated")
    # The last key, repeated behind unrelated pairs, is found in that pass.
    var nine = String("/nine?a=1&b=1&c=1&d=1&e=1&f=1&g=1&h=1&i=1")
    for _ in range(100):
        nine += "&x=1"
    expect(c.get(nine + "&i=2"), Rejection.QUERY, "i", "repeated")
    # A repeated key the route does not declare is not a rejection.
    assert_equal(c.get(nine + "&x=2").text(), "1")
    # A repeat is found before a missing key is.
    expect(c.get("/nine?a=1&a=2"), Rejection.QUERY, "a", "repeated")
    expect(c.get("/nine?a=1"), Rejection.QUERY, "b", "missing")


def test_names_of_application_route_values() raises:
    var app = make_app()
    var c = TestClient(app)
    expect(
        c.get("/skus/abc"),
        Rejection.FROM_ROUTE_VALUE,
        "sku",
        "a sku starts with sku-",
    )
    # A record's fields, on the path and in the query.
    expect(c.get("/records/x?page=1"), Rejection.PATH, "id", "not an integer")
    expect(
        c.get("/records/1?page=x"), Rejection.QUERY, "page", "not an integer"
    )
    expect(c.get("/records/1"), Rejection.QUERY, "page", "missing")
    expect(c.get("/pair?a=1&b=x"), Rejection.QUERY, "b", "not an integer")
    # A `Headers` slot after the value does not change its name.
    expect(c.get("/fields/x"), Rejection.PATH, "id", "not an integer")
    # `Param`s: a name the registration checked is the placeholder's.
    expect(c.get("/checked/1/posts/x"), Rejection.PATH, "pid", "not an integer")
    expect(
        c.put("/named?q=a&limit=x", ""),
        Rejection.QUERY,
        "limit",
        "not an integer",
    )
    expect(c.put("/named?limit=1", ""), Rejection.QUERY, "q", "missing")
    expect(
        c.get("/named-optional?limit=x"),
        Rejection.QUERY,
        "limit",
        "not an integer",
    )


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
    # Not one JSON value: the parser's message, apart from `from_json`.
    expect(
        c.post("/notes", "{", headers=json_headers()),
        Rejection.JSON,
        "",
        "invalid JSON: expected member name",
    )
    expect(
        c.post("/notes", not_utf8.copy(), headers=json_headers()),
        Rejection.UTF8,
        "",
        "not UTF-8",
    )
    # #167: the decoder's misspelling, named by `JsonValue[name]`.
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


def test_carriers_report_their_body_step() raises:
    var app = make_app()
    var c = TestClient(app)
    var not_utf8: List[UInt8] = [0xFF, 0xFE]
    expect(
        c.post("/carried", '{"text": "hi"}', headers=json_headers()),
        Rejection.FROM_JSON,
        "",
        'JSON member "txet" is missing',
    )
    expect(
        c.post("/carried", "nope", headers=json_headers()),
        Rejection.JSON,
        "",
        "invalid JSON: bad literal",
    )
    expect(
        c.post("/carried-text", not_utf8.copy()),
        Rejection.UTF8,
        "",
        "not UTF-8",
    )
    expect(
        c.post("/carried-text", "bad"),
        Rejection.FROM_BODY,
        "",
        "text must not be 'bad'",
    )
    expect(c.post("/carried-blob", ""), Rejection.FROM_BYTES, "", "empty blob")


def test_guarded_routes() raises:
    """A decoding failure is deferred until the guard admits the request
    (M3-080), then answered with its report; a slot's own 400 comes after
    the guard. With and without a context slot, and with a `Headers` slot,
    whose fields the deferred 400 keeps out of the report."""
    var app = make_app()
    var c = TestClient(app)
    # Deferred.
    expect(
        c.get("/guarded/%zz", headers=key()),
        Rejection.PATH,
        "id",
        "bad percent escape",
    )
    expect(c.get("/plain/1", headers=key()), Rejection.QUERY, "page", "missing")
    expect(
        c.get("/held/%zz", headers=key()),
        Rejection.PATH,
        "id",
        "bad percent escape",
    )
    # In the slot.
    expect(
        c.get("/guarded/x", headers=key()),
        Rejection.PATH,
        "id",
        "not an integer",
    )
    expect(
        c.get("/plain/1?page=x", headers=key()),
        Rejection.QUERY,
        "page",
        "not an integer",
    )
    expect(
        c.get("/held/x", headers=key()), Rejection.PATH, "id", "not an integer"
    )
    expect(
        c.post("/guarded-notes/1", '{"text": "hi"}', headers=key(True)),
        Rejection.FROM_JSON,
        "",
        'JSON member "txet" is missing',
    )
    # The guard answers first: its response, no rejection.
    for target in ["/guarded/%zz", "/guarded/x", "/plain/1", "/held/%zz"]:
        var refused = c.get(target)
        assert_equal(refused.status, 401, target)
        assert_false(refused.rejection(), target)
    assert_equal(c.get("/guarded/7", headers=key()).text(), "ada 7")
    assert_equal(c.get("/plain/7?page=2", headers=key()).text(), "7 2")
    assert_equal(c.get("/held/7", headers=key()).text(), "7 1")


def test_the_guard_sees_only_the_fields_on_a_deferred_400() raises:
    """With and without a context slot."""
    var app = make_app()
    var c = TestClient(app)
    var h = key()
    h.add("X-B", "2")
    for target in ["/seen/%zz", "/seen-plain/%zz"]:
        expect(
            c.get(target, headers=h.copy()),
            Rejection.PATH,
            "id",
            "bad percent escape",
        )
    assert_equal(c.get("/seen/7", headers=h.copy()).text(), "X-Key=k;X-B=2;")
    assert_equal(c.get("/seen-plain/7", headers=h.copy()).text(), "7")
    assert_equal(c.get("/seen/%zz").status, 401)


def test_none_elsewhere() raises:
    var app = make_app()
    var c = TestClient(app)
    assert_false(c.get("/users/1").rejection())
    assert_false(c.get("/nowhere").rejection())  # 404
    assert_false(c.post("/users/1", "").rejection())  # 405
    assert_false(c.post("/notes", "{}").rejection())  # 415
    var big = List[UInt8](length=17, fill=1)
    assert_false(c.post("/blob", big^).rejection())  # 413
    var own = c.get("/own")  # the application's own 400
    assert_equal(own.status, 400)
    assert_false(own.rejection())
    var boom = c.get("/boom/1")
    assert_equal(boom.status, 500)
    assert_false(boom.rejection())
    assert_true(boom.failure())
    assert_false(Response.text("Bad Request", status=400).rejection())


def test_head_copies_and_edits_keep_it() raises:
    var app = make_app()
    var c = TestClient(app)
    expect(c.head("/users/abc"), Rejection.PATH, "id", "not an integer")
    var head = c.head("/users/abc")
    var copied = head.copy()
    copied.status = 422
    copied.body = List[UInt8]()
    assert_equal(copied.rejection().value().step, Rejection.PATH)
    assert_equal(copied.rejection().value().message, "not an integer")
    # A copy of the report is independent of the response's.
    var taken = copied.rejection().value().copy()
    taken.message = "changed"
    assert_equal(copied.rejection().value().message, "not an integer")


def test_written_form() raises:
    var app = make_app()
    var c = TestClient(app)
    assert_equal(
        String(c.get("/users/abc").rejection().value()),
        "path id: not an integer",
    )
    assert_equal(
        String(c.post("/blob", "").rejection().value()),
        "from_bytes: empty blob",
    )


def outer(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    var rejection = response.rejection()
    if rejection:
        response.headers.add("X-Log", String(rejection.value()))
    return response^


def replacing(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    if response.status == 400:
        return Response.text("Bad Request", status=400)
    return response^


def quoted(text: String) -> String:
    """The `quoted` of docs/reference/middleware.md, as
    tests/test_failure.mojo has it."""
    var out = String('"')
    for b in text.as_bytes():
        var c = Int(b)
        if c < 0x20 or c > 0x7E or c == 0x22 or c == 0x5C:
            out += "\\x"
            for d in [c >> 4, c & 15]:
                out += chr(d + 48 if d < 10 else d + 87)
        else:
            out += chr(c)
    return out + '"'


# example: middleware-rejections
def log_rejections(var request: Request, var next: Next) raises -> Response:
    var path = request.path  # kept: `next` takes the request
    var response = next^.run(request^)
    var rejection = response.rejection()
    if rejection:
        print(quoted(path), quoted(String(rejection.value())), file=stderr)
    return response^


# example: end


def test_middleware_rejections_example() raises:
    # example: middleware-rejections
    var app = App()
    app.use(log_rejections)
    app.post["/notes"](add_note)  # add_note from errors.md
    # POST /notes '{"text": "hi"}', application/json -> 400 "Bad Request"; standard error:
    #   "/notes" "from_json: JSON member \x22txet\x22 is missing"
    # example: end
    var r = TestClient(app).post(
        "/notes", '{"text": "hi"}', headers=json_headers()
    )
    expect(r, Rejection.FROM_JSON, "", 'JSON member "txet" is missing')
    assert_equal(
        quoted(String(r.rejection().value())),
        '"from_json: JSON member \\x22txet\\x22 is missing"',
    )


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
    assert_false(c.get("/users/1").headers.get("X-Log"))


def test_a_new_response_drops_it() raises:
    var app = make_app()
    app.use(outer)
    app.use(replacing)
    var r = TestClient(app).get("/users/abc")
    assert_equal(r.status, 400)
    assert_false(r.rejection())
    assert_false(r.headers.get("X-Log"))


def test_errors_rejection_example() raises:
    # example: errors-rejection
    var app = App()
    app.get["/users/{id}"](show_user)
    app.post["/notes"](add_note)
    # GET /users/abc -> 400 "Bad Request", no fields; on that response
    # (as App.handle returns it, or a middleware outside the route receives it):
    #   response.rejection().value().step    == Rejection.PATH  ("path")
    #   response.rejection().value().name    == "id"
    #   response.rejection().value().message == "not an integer"
    #   String(response.rejection().value()) == "path id: not an integer"
    # POST /notes '{"text": "hi"}', application/json -> 400 "Bad Request";
    #   String(response.rejection().value()) == 'from_json: JSON member "txet" is missing'
    # POST /notes '{', application/json -> 400 "Bad Request";
    #   String(response.rejection().value()) == "json: invalid JSON: expected member name"
    # GET /users/1 -> 200 "user 1"; response.rejection() is None
    # example: end
    var client = TestClient(app)
    for r in [
        client.get("/users/abc"),
        app.handle(Request("GET", "/users/abc")),
    ]:
        expect(r, Rejection.PATH, "id", "not an integer")
        assert_equal(Rejection.PATH, "path")
        assert_equal(String(r.rejection().value()), "path id: not an integer")
    var misspelled = client.post(
        "/notes", '{"text": "hi"}', headers=json_headers()
    )
    expect(misspelled, Rejection.FROM_JSON, "", 'JSON member "txet" is missing')
    assert_equal(
        String(misspelled.rejection().value()),
        'from_json: JSON member "txet" is missing',
    )
    var broken = client.post("/notes", "{", headers=json_headers())
    assert_equal(
        String(broken.rejection().value()),
        "json: invalid JSON: expected member name",
    )
    var ok = client.get("/users/1")
    assert_equal(ok.status, 200)
    assert_equal(ok.text(), "user 1")
    assert_false(ok.rejection())


def test_response_keeps_its_size() raises:
    assert_equal(size_of[Response](), 80)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
