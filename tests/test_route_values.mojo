# Two route values (M3-023): a typed handler takes at most two route values,
# bound by position in the literal's order (path placeholders left to right,
# then query placeholders left to right), on every registration method.
# Through `App.handle` and `TestClient`: two path values, a path and a query
# value, two query values in either request order, every `Int`/`String` mix,
# duplicate path names, each value a `Param` named after its placeholder (M3-050), one
# decoding per value and each value's own 400 before the handler and the body,
# `Headers` after two values on `get` and `delete`, a body after two values on
# `post`, `put` and `patch` (`Json[T]` and `WithHeaders[B]` included), the
# stateful forms, raw handlers, first registration wins, a typed function
# value and generic forwarding to the slot-arity-3 overloads, and docs/DX.md's
# example as written. Decision: docs/history/architecture-decisions.md,
# "Several route values decision (M3-022)". Must-not-compile counterparts:
# tests/route_values_api_fail.

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, TestSuite

from muntin import (
    App,
    FromBody,
    FromJson,
    Headers,
    Json,
    JsonValue,
    JsonWriter,
    Param,
    Request,
    Response,
    State,
    ToErrorResponse,
    ToJson,
    WithHeaders,
)
from muntin.testing import TestClient

# Handlers are thin functions and cannot capture state, so calls are counted
# in environment variables.
comptime FROM_BODY_CALLS = "MUNTIN_TEST_ROUTE_VALUES_FROM_BODY_CALLS"
comptime HANDLER_CALLS = "MUNTIN_TEST_ROUTE_VALUES_HANDLER_CALLS"


def _reset():
    _ = unsetenv(FROM_BODY_CALLS)
    _ = unsetenv(HANDLER_CALLS)


def _count(name: StaticString) -> Int:
    var n = getenv(name)
    try:
        return Int(n) if n else 0
    except:
        return -1


def _bump(name: StaticString):
    _ = setenv(name, String(_count(name) + 1))


struct Prefix(Movable):
    var text: String

    def __init__(out self, text: String):
        self.text = text


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(FROM_BODY_CALLS)
        if body == "bad":
            raise Error("bad body")
        return Self(body)


@fieldwise_init
struct Name(FromJson):
    var name: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string())


def _h(*pairs: String) raises -> Headers:
    var h = Headers()
    var i = 0
    while i + 1 < len(pairs):
        h.add(pairs[i], pairs[i + 1])
        i += 2
    return h^


def _json() raises -> Headers:
    return _h("Content-Type", "application/json")


# docs/DX.md, "Two route values", as written there.


@fieldwise_init
struct Edit(FromJson):
    var title: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["title"].string())


@fieldwise_init
struct Post(ToJson):
    var uid: Int
    var pid: Int
    var title: String

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("uid")
        out.int(self.uid)
        out.name("pid")
        out.int(self.pid)
        out.name("title")
        out.string(self.title)
        out.end_object()


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(deinit self) -> Response:
        return Response.text("Unauthorized", status=401)


def post_of(uid: Param["uid", Int], pid: Param["pid", Int]) -> String:
    return String("post ", pid.value, " of user ", uid.value)


def misled(pid: Param["uid", Int], uid: Param["pid", Int]) -> String:
    # Each variable is named after the other placeholder; only the `Param`
    # names are compared, so this registers on /users/{uid}/posts/{pid}.
    return String("post ", pid.value, " of user ", uid.value)


def user_fields(
    id: Param["id", Int], fields: Param["fields", String]
) -> String:
    return String("user ", id.value, ": ", fields.value)


def search(q: Param["q", String], limit: Param["limit", Int]) -> String:
    return String(limit.value, " results for ", q.value)


def edit_post(
    uid: Param["uid", Int], pid: Param["pid", Int], body: Json[Edit]
) -> Json[Post]:
    return Json(Post(uid.value, pid.value, body.value.title))


def remove_post(
    uid: Param["uid", Int],
    pid: Param["pid", Int],
    headers: Headers,
) raises Unauthorized -> String:
    if not headers.get("authorization"):
        raise Unauthorized()
    return String("removed post ", pid.value, " of user ", uid.value)


def _dx_app() -> App:
    """docs/DX.md's registrations, as written there, on its own `App`."""
    var app = App()
    app.get["/users/{uid}/posts/{pid}"](post_of)
    app.get["/users/{id}?{fields}"](user_fields)
    app.get["/search?{q}&{limit}"](search)
    app.patch["/users/{uid}/posts/{pid}"](edit_post)
    app.delete["/users/{uid}/posts/{pid}"](remove_post)
    return app^


# Handlers.


def named_one(id: Param["id", Int]) -> String:
    return String("named ", id.value)


def named_optional(limit: Param["limit", Optional[Int]]) -> String:
    return String("limit ", limit.value.or_else(20))


def two_ints(a: Param["a", Int], b: Param["b", Int]) -> String:
    return String("ints ", a.value, ",", b.value)


def int_str(a: Param["a", Int], b: Param["b", String]) -> String:
    return String("int-str ", a.value, ",", b.value)


def str_int(a: Param["a", String], b: Param["b", Int]) -> String:
    return String("str-int ", a.value, ",", b.value)


def two_strs(a: Param["a", String], b: Param["b", String]) -> String:
    return String("strs ", a.value, ",", b.value)


def id_fields(a: Param["id", Int], b: Param["fields", String]) -> String:
    return String("int-str ", a.value, ",", b.value)


def q_limit(a: Param["q", String], b: Param["limit", Int]) -> String:
    return String("str-int ", a.value, ",", b.value)


def dup_strs(a: Param["a", String], b: Param["a", String]) -> String:
    return String("strs ", a.value, ",", b.value)


def owned(var a: Param["a", String], var b: Param["b", Int]) -> String:
    a.value += "!"  # the handler's own values
    b.value += 1
    return String(a.value, b.value)


def one_value(pid: Int) -> String:
    return String("me, post ", pid)


def counted(a: Param["a", Int], b: Param["b", Int]) -> String:
    _bump(HANDLER_CALLS)
    return String(a.value + b.value)


def counted_body(
    a: Param["a", Int], b: Param["b", String], body: Note
) -> String:
    _bump(HANDLER_CALLS)
    return String(a.value, b.value, body.text)


def with_headers(
    a: Param["a", Int], b: Param["b", String], headers: Headers
) -> String:
    return String(a.value, ",", b.value, " ", len(headers))


def with_body(a: Param["a", Int], b: Param["b", String], body: Note) -> String:
    return String(a.value, ",", b.value, "=", body.text)


def with_json(
    a: Param["a", Int], b: Param["b", Int], body: Json[Name]
) -> String:
    return String(a.value, ",", b.value, "=", body.value.name)


def carried(
    a: Param["a", String], b: Param["b", Int], input: WithHeaders[Note]
) -> String:
    return String(
        a.value, ",", b.value, "=", input.body.text, " ", len(input.headers)
    )


def carried_json(
    a: Param["a", Int], b: Param["b", String], input: WithHeaders[Json[Name]]
) -> String:
    return String(
        a.value,
        ",",
        b.value,
        "=",
        input.body.value.name,
        " ",
        len(input.headers),
    )


def stateful(
    p: State[Prefix], a: Param["a", Int], b: Param["b", String]
) -> String:
    return String(p[].text, a.value, ",", b.value)


def stateful_headers(
    p: State[Prefix],
    a: Param["a", String],
    b: Param["b", Int],
    headers: Headers,
) -> String:
    return String(p[].text, a.value, ",", b.value, " ", len(headers))


def stateful_body(
    p: State[Prefix], a: Param["a", Int], b: Param["b", Int], var body: Note
) -> String:
    return String(p[].text, a.value, ",", b.value, "=", body.text)


def raw(req: Request) -> Response:
    return Response.text("raw " + req.path + "|" + req.query)


def typed_headers(
    var a: Param["a", Int], var b: Param["b", String], var headers: Headers
) -> String:
    return String("typed ", a.value, ",", b.value, " ", len(headers))


def typed_body(
    var a: Param["a", String], var b: Param["b", String], var body: Note
) -> String:
    return String("typed ", a.value, ",", b.value, "=", body.text)


# Generic forwarding (M3-015 edge 4) reaching the slot-arity-3 overloads.


def fwd_three[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    C: Movable & Deinitable,
](mut app: App, h: def(var A, var B, var C) thin raises Never -> String):
    app.put["/fwd/{a}/{b}"](h)


def fwd_state_three[
    S: Movable & Deinitable,
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    C: Movable & Deinitable,
](
    mut app: App,
    h: def(State[S], var A, var B, var C) thin raises Never -> String,
    state: State[S],
):
    app.delete["/fwd/{a}?{b}"](h, state)


def fwd_two[
    A: Movable & Deinitable, B: Movable & Deinitable
](mut app: App, h: def(var A, var B) thin raises Never -> String):
    app.get["/fwd?{a}&{b}"](h)


def _app() -> App:
    var app = App()
    # Two path values in every `Int`/`String` mix; the shapes that the
    # retired one-value fixtures rejected register.
    app.get["/add/{a}/{b}"](two_ints)
    app.delete["/x/{a}/{b}"](two_ints)
    app.get["/x/{a}/{b}"](int_str)
    app.get["/is/{a}/{b}"](int_str)
    app.get["/si/{a}/{b}"](str_int)
    app.get["/ss/{a}/{b}"](two_strs)
    # A path and a query value; two query values.
    app.get["/pq/{id}?{fields}"](id_fields)
    app.get["/q?{q}&{limit}"](q_limit)
    # Duplicate path names register and bind by position.
    app.get["/dup/{a}/{a}"](dup_strs)
    app.get["/dupq/{a}?{a}"](dup_strs)
    app.get["/owned/{a}?{b}"](owned)
    # First registration wins; a 400 never falls through.
    app.get["/users/me/posts/{pid}"](one_value)
    app.get["/users/{uid}/posts/{pid}"](post_of)
    app.get["/fw/{a}/{b}"](two_ints)
    app.get["/fw/{a}/{b}"](two_strs)  # never reached
    # A raw handler on a two-segment static path, before a typed route that
    # would match it.
    app.get["/raw/a%2Fb/c"](raw)
    app.get["/raw/{a}/{b}"](two_strs)
    # Counted: a 400 calls neither `from_body` nor the handler.
    app.get["/count/{a}/{b}"](counted)
    app.post["/count/{a}?{b}"](counted_body)
    # `Headers` after two values on `get` and `delete`.
    app.get["/h/{a}/{b}"](with_headers)
    app.delete["/h/{a}?{b}"](with_headers)
    # A body after two values on `post`, `put` and `patch`.
    app.post["/b/{a}/{b}"](with_body)
    app.put["/b/{a}?{b}"](with_body)
    app.patch["/b?{a}&{b}"](with_body)
    app.post["/j/{a}/{b}"](with_json)
    app.put["/c/{a}/{b}"](carried)
    app.patch["/cj/{a}?{b}"](carried_json)
    # Stateful forms.
    var prefix = State(Prefix("p:"))
    app.get["/st/{a}/{b}"](stateful, prefix)
    app.delete["/st/{a}?{b}"](stateful_headers, prefix)
    app.get["/sh/{a}?{b}"](stateful_headers, prefix)
    app.delete["/st2/{a}/{b}"](stateful, prefix)
    app.post["/st/{a}/{b}"](stateful_body, prefix)
    app.put["/st?{a}&{b}"](stateful_body, prefix)
    app.patch["/st/{a}?{b}"](stateful_body, prefix)
    # A typed function value and generic forwarding.
    var f: def(
        var Param["a", Int], var Param["b", String], var Headers
    ) thin raises Never -> String = typed_headers
    app.get["/typed/{a}/{b}"](f)
    var g: def(
        var Param["a", String], var Param["b", String], var Note
    ) thin raises Never -> String = typed_body
    app.post["/typed?{a}&{b}"](g)
    fwd_three(app, with_body)
    fwd_state_three(app, stateful_headers, prefix)
    fwd_two(app, str_int)
    return app^


def _expect(app: App, target: String, status: Int, body: String) raises:
    var r = TestClient(app).get(target)
    assert_equal(r.status, status, target)
    assert_equal(r.text(), body, target)


def _bad(app: App, target: String) raises:
    _expect(app, target, 400, "Bad Request")


def test_dx_examples() raises:
    var app = _dx_app()
    var client = TestClient(app)
    _expect(app, "/users/1/posts/2", 200, "post 2 of user 1")
    _expect(app, "/users/1?fields=name+email", 200, "user 1: name email")
    _expect(app, "/search?limit=5&q=mojo", 200, "5 results for mojo")
    for target in [
        "/users/1/posts/x",
        "/search?q=mojo",
        "/search?q=a&q=b&limit=5",
    ]:
        _bad(app, target)
    var r = client.patch("/users/1/posts/2", '{"title":"Hi"}', headers=_json())
    assert_equal(r.status, 200)
    assert_equal(r.text(), '{"uid":1,"pid":2,"title":"Hi"}')
    r = client.patch("/users/1/posts/x", '{"title":"Hi"}')
    assert_equal(r.status, 400)  # the value before the body's 415
    r = client.patch("/users/1/posts/2", '{"title":"Hi"}')
    assert_equal(r.status, 415)
    r = client.delete("/users/1/posts/2", headers=_h("Authorization", "t1"))
    assert_equal(r.status, 200)
    assert_equal(r.text(), "removed post 2 of user 1")
    r = client.delete("/users/1/posts/2")
    assert_equal(r.status, 401)
    assert_equal(r.text(), "Unauthorized")


def test_two_path_values_in_every_mix() raises:
    var app = _app()
    _expect(app, "/add/1/2", 200, "ints 1,2")
    _expect(app, "/x/042/a", 200, "int-str 42,a")
    _expect(app, "/is/-7/J%C3%B6rg", 200, "int-str -7,Jörg")
    _expect(app, "/si/a+b/010", 200, "str-int a+b,10")
    _expect(app, "/ss/a%2Fb/c", 200, "strs a/b,c")
    var r = TestClient(app).delete("/x/3/4")
    assert_equal(r.text(), "ints 3,4")
    _expect(app, "/owned/a?b=1", 200, "a!2")


def test_path_then_query_value() raises:
    var app = _app()
    _expect(app, "/pq/1?fields=name+email", 200, "int-str 1,name email")
    _expect(app, "/pq/1?x=y&fields=a%26b", 200, "int-str 1,a&b")
    _bad(app, "/pq/1")
    _bad(app, "/pq/x?fields=a")


def test_two_query_values_bind_in_the_literals_order() raises:
    var app = _app()
    _expect(app, "/q?q=mojo&limit=5", 200, "str-int mojo,5")
    _expect(app, "/q?limit=5&q=mojo", 200, "str-int mojo,5")
    _expect(app, "/q?x=1&limit=%31&q=a+b", 200, "str-int a b,1")


def test_duplicate_path_names_bind_by_position() raises:
    var app = _app()
    _expect(app, "/dup/x/y", 200, "strs x,y")
    _expect(app, "/dupq/x?a=y", 200, "strs x,y")


def test_each_value_is_decoded_once() raises:
    var app = _app()
    _expect(app, "/ss/%2541/%2541", 200, "strs %41,%41")
    _expect(app, "/pq/1?fields=%2541", 200, "int-str 1,%41")
    _expect(app, "/q?q=%2541&limit=%34%32", 200, "str-int %41,42")
    _bad(app, "/add/1/%2534")  # `%34` after one decoding
    _bad(app, "/q?q=a&limit=%2534")


def test_each_value_has_its_own_bad_request() raises:
    var app = _app()
    for target in [
        "/add/x/1",  # the first value invalid
        "/add/1/x",  # the second value invalid
        "/si/a/%zz",  # a bad escape in the second value
        "/ss/a/%FF",  # not UTF-8
        "/pq/1?fields=",  # the query value empty
        "/pq/1?fields=a&fields=b",  # duplicated
        "/q?q=a",  # one key missing
        "/q?limit=1",
        "/q?q=&limit=1",  # one value empty
        "/q?q=a&limit=",
        "/q?q=a&q=a&limit=1",  # one key duplicated
        "/q?q=a&limit=1&limit=1",
        "/q?q=a&limit=x",
    ]:
        _bad(app, target)
    _expect(app, "/add/1/", 404, "Not Found")  # an empty segment does not match


def test_bad_request_calls_neither_handler_nor_from_body() raises:
    var app = _app()
    var client = TestClient(app)
    _reset()
    _bad(app, "/count/1/x")
    var r = client.post("/count/1?b=", "hi")
    assert_equal(r.status, 400)
    r = client.post("/count/x?b=y", "hi")
    assert_equal(r.status, 400)
    r = client.post("/count/1", "hi")  # the query value missing
    assert_equal(r.status, 400)
    assert_equal(_count(HANDLER_CALLS), 0)
    assert_equal(_count(FROM_BODY_CALLS), 0)
    _expect(app, "/count/1/2", 200, "3")
    r = client.post("/count/1?b=y", "hi")
    assert_equal(r.text(), "1yhi")
    assert_equal(_count(HANDLER_CALLS), 2)
    assert_equal(_count(FROM_BODY_CALLS), 1)
    _reset()


def test_headers_after_two_values() raises:
    var app = _app()
    var client = TestClient(app)
    var r = client.get("/h/1/a%20b", headers=_h("X-A", "1", "X-B", "2"))
    assert_equal(r.text(), "1,a b 2")
    r = client.delete("/h/1?b=a+b", headers=_h("X-A", "1"))
    assert_equal(r.text(), "1,a b 1")
    for target in ["/h/1/%zz", "/h/x/a"]:
        r = client.get(target, headers=_h("X-A", "1"))
        assert_equal(r.status, 400, target)
    r = client.delete("/h/1?b=", headers=_h("X-A", "1"))
    assert_equal(r.status, 400)


def test_body_after_two_values() raises:
    var app = _app()
    var client = TestClient(app)
    var r = client.post("/b/1/a%2Fb", "hi")
    assert_equal(r.text(), "1,a/b=hi")
    r = client.put("/b/1?b=a+b", "hi")
    assert_equal(r.text(), "1,a b=hi")
    r = client.patch("/b?b=y&a=2", "hi")
    assert_equal(r.text(), "2,y=hi")
    r = client.post("/b/1/a", "bad")  # the body's own 400
    assert_equal(r.status, 400)
    for c in [("/b/1/%zz", "POST"), ("/b/x?b=y", "PUT"), ("/b?a=1", "PATCH")]:
        var req = Request(c[1], c[0], "hi")
        assert_equal(app.handle(req).status, 400, c[0])


def test_json_and_carrier_after_two_values_reject_the_values_first() raises:
    var app = _app()
    var client = TestClient(app)
    var ok = String('{"name":"Ada"}')
    var r = client.post("/j/1/2", ok, headers=_json())
    assert_equal(r.text(), "1,2=Ada")
    r = client.put("/c/a%20b/3", "hi", headers=_h("X-A", "1"))
    assert_equal(r.text(), "a b,3=hi 1")
    var h = _json()
    h.add("X-A", "1")
    r = client.patch("/cj/1?b=J%C3%B6rg", ok, headers=h^)
    assert_equal(r.text(), "1,Jörg=Ada 2")
    # Without a JSON `Content-Type` the body step would answer 415; an
    # invalid second value answers 400 before it.
    r = client.post("/j/1/x", ok)
    assert_equal(r.status, 400)
    r = client.patch("/cj/1?b=", ok)
    assert_equal(r.status, 400)
    r = client.post("/j/1/2", ok)
    assert_equal(r.status, 415)
    r = client.put("/c/a/%4", "bad", headers=_h("X-A", "1"))
    assert_equal(r.status, 400)


def test_stateful_forms() raises:
    var app = _app()
    var client = TestClient(app)
    _expect(app, "/st/1/a%20b", 200, "p:1,a b")
    var r = client.delete("/st/a?b=2", headers=_h("X-A", "1"))
    assert_equal(r.text(), "p:a,2 1")
    r = client.post("/st/1/2", "hi")
    assert_equal(r.text(), "p:1,2=hi")
    r = client.put("/st?b=2&a=1", "hi")
    assert_equal(r.text(), "p:1,2=hi")
    r = client.patch("/st/1?b=2", "hi")
    assert_equal(r.text(), "p:1,2=hi")
    r = client.get("/sh/a%20b?b=2", headers=_h("X-A", "1", "X-B", "2"))
    assert_equal(r.text(), "p:a b,2 2")
    r = client.delete("/st2/3/a+b")
    assert_equal(r.text(), "p:3,a+b")
    r = client.get("/sh/a?b=x", headers=_h("X-A", "1"))
    assert_equal(r.status, 400)
    _bad(app, "/st/x/a")
    r = client.post("/st/1/x", "hi")
    assert_equal(r.status, 400)


def test_first_registration_wins() raises:
    var app = _app()
    _expect(app, "/users/me/posts/2", 200, "me, post 2")
    _expect(app, "/users/1/posts/2", 200, "post 2 of user 1")
    _expect(app, "/fw/1/2", 200, "ints 1,2")
    _bad(app, "/fw/x/2")  # the `Int` route answers; no fall-through


def test_raw_handler_is_unaffected() raises:
    var app = _app()
    _expect(app, "/raw/a%2Fb/c?q=a+b", 200, "raw /raw/a%2Fb/c|q=a+b")
    _expect(app, "/raw/x/y", 200, "strs x,y")


def test_typed_values_and_forwarding() raises:
    var app = _app()
    var client = TestClient(app)
    var r = client.get("/typed/1/a+b", headers=_h("X-A", "1"))
    assert_equal(r.text(), "typed 1,a+b 1")
    r = client.post("/typed?b=y&a=x", "hi")
    assert_equal(r.text(), "typed x,y=hi")
    r = client.put("/fwd/1/a", "hi")
    assert_equal(r.text(), "1,a=hi")
    r = client.delete("/fwd/a?b=2")
    assert_equal(r.text(), "p:a,2 0")
    _expect(app, "/fwd?b=3&a=x", 200, "str-int x,3")
    r = client.put("/fwd/x/a", "hi")
    assert_equal(r.status, 400)


def test_one_value_may_be_named() raises:
    # One value binds the only placeholder whatever its name, so it may be
    # plain; a `Param` converts as its bare type would (M3-050).
    var app = App()
    app.get["/n/{id}"](named_one)
    app.get["/o?{limit}"](named_optional)
    app.get["/p/{pid}"](one_value)
    _expect(app, "/n/042", 200, "named 42")
    _bad(app, "/n/x")
    _expect(app, "/o", 200, "limit 20")
    _expect(app, "/o?limit=5", 200, "limit 5")
    _bad(app, "/o?limit=x")
    _expect(app, "/p/3", 200, "me, post 3")


def test_param_holds_and_copies_its_value() raises:
    var id = Param["id", Int](7)
    var copy = id.copy()
    copy.value += 1
    assert_equal(id.value, 7)
    assert_equal(copy.value, 8)
    var text = Param["q", String]("mojo")
    assert_equal(text.value, "mojo")


def test_variable_names_are_not_compared() raises:
    # Known constraint (M3-050): Mojo 1.1.0 cannot reflect a parameter's name,
    # so a variable named after another placeholder registers and receives the
    # value its `Param` name binds, and a lone bare value binds the only
    # placeholder whatever both are called. If either stops registering or
    # binding this way, the record's "Revisit when" has fired.
    var app = App()
    app.get["/users/{uid}/posts/{pid}"](misled)
    app.get["/p/{uid}"](one_value)
    _expect(app, "/users/1/posts/2", 200, "post 1 of user 2")
    _expect(app, "/p/3", 200, "me, post 3")


def _tests() -> TestSuite:
    """This module's tests, registered by hand: discovering them
    (`TestSuite.discover_tests[__functions_in_module()]`) crashes Mojo 1.1.0
    because a handler here declares a `Param` (M3-050;
    tests/named_values_api_fail/discover_tests_crash.mojo).
    `scripts/check.sh` checks that every `test_` function is listed."""
    var suite = TestSuite()
    suite.test[test_dx_examples]()
    suite.test[test_two_path_values_in_every_mix]()
    suite.test[test_path_then_query_value]()
    suite.test[test_two_query_values_bind_in_the_literals_order]()
    suite.test[test_duplicate_path_names_bind_by_position]()
    suite.test[test_each_value_is_decoded_once]()
    suite.test[test_each_value_has_its_own_bad_request]()
    suite.test[test_bad_request_calls_neither_handler_nor_from_body]()
    suite.test[test_headers_after_two_values]()
    suite.test[test_body_after_two_values]()
    suite.test[test_json_and_carrier_after_two_values_reject_the_values_first]()
    suite.test[test_stateful_forms]()
    suite.test[test_first_registration_wins]()
    suite.test[test_raw_handler_is_unaffected]()
    suite.test[test_typed_values_and_forwarding]()
    suite.test[test_one_value_may_be_named]()
    suite.test[test_param_holds_and_copies_its_value]()
    suite.test[test_variable_names_are_not_compared]()
    return suite^


def main() raises:
    _tests().run()
