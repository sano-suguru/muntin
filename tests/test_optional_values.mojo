# Optional query values (M3-025): an `Optional[Int]` or `Optional[String]`
# parameter is a route value that binds a query placeholder only; it is
# `None` when the key is absent, has an empty value or has no `=`, and a
# present value keeps every rule of a required one. Through `App.handle` and
# `TestClient`: absent, empty and present values, escapes and `+`, each 400
# of a present value (bad escape, not UTF-8, not an `Int`, a repeated key)
# without calling the handler or `from_body`, an optional value beside a
# required one in both query orders and after a path value, `Headers` after
# it on `get` and `delete`, a body after it on `post`, `put` and `patch`
# (`Json[T]` and `WithHeaders[B]` included), the stateful forms, a defaulted
# `Int` parameter that stays required, first registration wins, a typed
# function value and generic forwarding, and docs/DX.md's example as
# written. Decision: docs/history/architecture-decisions.md, "Optional query
# values decision (M3-024)". Must-not-compile counterparts:
# tests/optional_values_api_fail.

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, TestSuite

from muntin import (
    App,
    FromBody,
    FromJson,
    Headers,
    Json,
    JsonValue,
    Request,
    Response,
    State,
    WithHeaders,
)
from muntin.testing import TestClient

# Handlers are thin functions and cannot capture state, so calls are counted
# in environment variables.
comptime FROM_BODY_CALLS = "MUNTIN_TEST_OPTIONAL_VALUES_FROM_BODY_CALLS"
comptime HANDLER_CALLS = "MUNTIN_TEST_OPTIONAL_VALUES_HANDLER_CALLS"


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


def _show(v: Optional[Int]) -> String:
    return String(v.value()) if v else "None"


def _show(v: Optional[String]) -> String:
    return "[" + v.value() + "]" if v else "None"


# docs/DX.md, "Optional query values", as written there.


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("expected name=<text>")
        return Self(String(body[byte=5:]))


def list_items(limit: Optional[Int]) -> String:
    return "items " + String(limit.or_else(20))


def search(q: String, sort: Optional[String]) -> String:
    return "results for " + q + " by " + sort.or_else("relevance")


def posts(uid: Int, limit: Optional[Int], headers: Headers) -> String:
    return String("user ", uid, ": ", limit.or_else(20), " posts")


def tag_user(tag: Optional[String], body: CreateUser) -> String:
    return "created " + body.name + " tagged " + tag.or_else("none")


def _dx_app() -> App:
    """docs/DX.md's registrations, as written there, on its own `App`."""
    var app = App()
    app.get["/items?{limit}"](list_items)
    app.get["/search?{q}&{sort}"](search)
    app.get["/users/{uid}/posts?{limit}"](posts)
    app.post["/users?{tag}"](tag_user)
    return app^


# Handlers.


def opt_int(a: Optional[Int]) -> String:
    return "int " + _show(a)


def opt_str(a: Optional[String]) -> String:
    return "str " + _show(a)


def owned(var a: Optional[Int]) -> String:
    if a:
        a = a.value() + 1  # the handler's own value
    return "owned " + _show(a)


def counted(a: Optional[Int]) -> String:
    _bump(HANDLER_CALLS)
    return "counted " + _show(a)


def counted_body(a: Optional[String], body: Note) -> String:
    _bump(HANDLER_CALLS)
    return "counted " + _show(a) + "=" + body.text


def req_opt(q: String, sort: Optional[String]) -> String:
    return "q " + q + " sort " + _show(sort)


def opt_req(limit: Optional[Int], q: String) -> String:
    return "limit " + _show(limit) + " q " + q


def path_opt(uid: Int, limit: Optional[Int]) -> String:
    return String("uid ", uid, " limit ", _show(limit))


def two_opt(a: Optional[Int], b: Optional[String]) -> String:
    return "a " + _show(a) + " b " + _show(b)


def with_headers(a: Optional[Int], headers: Headers) -> String:
    return String(_show(a), " ", len(headers))


def two_with_headers(a: Int, b: Optional[String], headers: Headers) -> String:
    return String(a, ",", _show(b), " ", len(headers))


def with_body(a: Optional[String], body: Note) -> String:
    return _show(a) + "=" + body.text


def two_with_body(a: Int, b: Optional[Int], body: Note) -> String:
    return String(a, ",", _show(b), "=", body.text)


def with_json(a: Optional[Int], body: Json[Name]) -> String:
    return _show(a) + "=" + body.value.name


def carried(a: Optional[String], input: WithHeaders[Note]) -> String:
    return String(_show(a), "=", input.body.text, " ", len(input.headers))


def carried_json(
    a: Optional[Int], b: Optional[String], input: WithHeaders[Json[Name]]
) -> String:
    return String(
        _show(a),
        ",",
        _show(b),
        "=",
        input.body.value.name,
        " ",
        len(input.headers),
    )


def stateful(p: State[Prefix], a: Optional[Int]) -> String:
    return p[].text + _show(a)


def stateful_headers(
    p: State[Prefix], a: Optional[String], b: Int, headers: Headers
) -> String:
    return String(p[].text, _show(a), ",", b, " ", len(headers))


def stateful_body(
    p: State[Prefix], a: Optional[String], var body: Note
) -> String:
    return p[].text + _show(a) + "=" + body.text


def stateful_two_body(
    p: State[Prefix], a: Int, b: Optional[Int], var body: Note
) -> String:
    return String(p[].text, a, ",", _show(b), "=", body.text)


def defaulted(limit: Int = 20) -> String:
    return String("defaulted ", limit)


def search_defaulted(query: String, limit: Int = 20) -> String:
    return String(limit, " results for ", query)


def required(limit: Int) -> String:
    return String("required ", limit)


def raw(req: Request) -> Response:
    return Response.text("raw " + req.path + "|" + req.query)


def typed_one(var a: Optional[Int]) -> String:
    return "typed " + _show(a)


def typed_body(var b: Int, var a: Optional[String], var body: Note) -> String:
    return String("typed ", _show(a), ",", b, "=", body.text)


# Generic forwarding (M3-015) reaching an optional slot.


def fwd_one[
    A: Movable & Deinitable
](mut app: App, h: def(var A) thin raises Never -> String):
    app.get["/fwd?{a}"](h)


def fwd_state_two[
    S: Movable & Deinitable,
    A: Movable & Deinitable,
    B: Movable & Deinitable,
](
    mut app: App,
    h: def(State[S], var A, var B) thin raises Never -> String,
    state: State[S],
):
    app.patch["/fwd?{a}"](h, state)


def _app() -> App:
    var app = App()
    # One optional value of each kind.
    app.get["/i?{a}"](opt_int)
    app.get["/s?{a}"](opt_str)
    app.delete["/i?{a}"](opt_int)
    app.get["/owned?{a}"](owned)
    # Counted: a 400 calls neither `from_body` nor the handler.
    app.get["/count?{a}"](counted)
    app.post["/count?{a}"](counted_body)
    # An optional value beside a required one, in both query orders and
    # after a path value; two optional values.
    app.get["/rq?{q}&{sort}"](req_opt)
    app.get["/qr?{limit}&{q}"](opt_req)
    app.get["/p/{uid}?{limit}"](path_opt)
    app.get["/oo?{a}&{b}"](two_opt)
    # `Headers` after it on `get` and `delete`.
    app.get["/h?{a}"](with_headers)
    app.delete["/h/{a}?{b}"](two_with_headers)
    # A body after it on `post`, `put` and `patch`.
    app.post["/b?{a}"](with_body)
    app.put["/b/{a}?{b}"](two_with_body)
    app.patch["/b?{a}"](with_body)
    app.post["/j?{a}"](with_json)
    app.put["/c?{a}"](carried)
    app.patch["/cj?{a}&{b}"](carried_json)
    # Stateful forms.
    var prefix = State(Prefix("p:"))
    app.get["/st?{a}"](stateful, prefix)
    app.delete["/st?{a}&{b}"](stateful_headers, prefix)
    app.post["/st?{a}"](stateful_body, prefix)
    app.put["/st/{a}?{b}"](stateful_two_body, prefix)
    # A defaulted parameter registers as a required value.
    app.get["/d?{limit}"](defaulted)
    app.get["/sd?{query}&{limit}"](search_defaulted)
    # First registration wins, either way round; a 400 never falls through.
    app.get["/first?{limit}"](opt_int)
    app.get["/first?{limit}"](required)  # never reached
    app.get["/req?{limit}"](required)
    app.get["/req?{limit}"](opt_int)  # never reached
    # A raw handler is never decoded and never gets `None`.
    app.get["/raw"](raw)
    # A typed function value and generic forwarding.
    var f: def(var Optional[Int]) thin raises Never -> String = typed_one
    app.get["/typed?{a}"](f)
    var g: def(
        var Int, var Optional[String], var Note
    ) thin raises Never -> String = typed_body
    app.post["/typed/{b}?{a}"](g)
    fwd_one(app, opt_str)
    fwd_state_two(app, stateful_body, prefix)
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
    for target in ["/items", "/items?limit=", "/items?limit"]:
        _expect(app, target, 200, "items 20")
    _expect(app, "/items?limit=5", 200, "items 5")
    _expect(app, "/items?limit=%35", 200, "items 5")
    _expect(app, "/items?%6Cimit=5", 200, "items 20")  # keys are undecoded
    _bad(app, "/items?limit=x")
    _bad(app, "/items?limit=1&limit=2")
    _expect(app, "/search?q=mojo", 200, "results for mojo by relevance")
    _expect(app, "/search?sort=date&q=mojo", 200, "results for mojo by date")
    _bad(app, "/search?sort=date")
    _expect(app, "/users/1/posts", 200, "user 1: 20 posts")
    _expect(app, "/users/1/posts?limit=5", 200, "user 1: 5 posts")
    var r = client.post("/users", "name=Ada")
    assert_equal(r.text(), "created Ada tagged none")
    r = client.post("/users?tag=a+b", "name=Ada")
    assert_equal(r.text(), "created Ada tagged a b")


def test_absent_and_empty_are_none() raises:
    var app = _app()
    for path in ["/i", "/s"]:
        var kind = "int " if path == "/i" else "str "
        for query in ["", "?", "?a=", "?a", "?x=1", "?a=&x=1", "?x&a&y"]:
            _expect(app, path + query, 200, kind + "None")
    # Keys are matched undecoded: `%61` is not `a`, so `a` is absent.
    _expect(app, "/i?%61=5", 200, "int None")
    _expect(app, "/s?A=x", 200, "str None")
    var r = TestClient(app).delete("/i?a=")
    assert_equal(r.text(), "int None")


def test_present_values_are_decoded_once() raises:
    var app = _app()
    _expect(app, "/i?a=5", 200, "int 5")
    _expect(app, "/i?a=-07", 200, "int -7")
    _expect(app, "/i?x=1&a=%34%32", 200, "int 42")
    _expect(app, "/s?a=mojo", 200, "str [mojo]")
    _expect(app, "/s?a=a+b%2B", 200, "str [a b+]")
    _expect(app, "/s?a=J%C3%B6rg", 200, "str [Jörg]")
    _expect(app, "/s?a=%2541", 200, "str [%41]")
    # A value that decodes to a space is present, not empty.
    _expect(app, "/s?a=+", 200, "str [ ]")
    _expect(app, "/s?a=%20", 200, "str [ ]")
    _expect(app, "/owned?a=1", 200, "owned 2")
    _expect(app, "/owned", 200, "owned None")
    var r = TestClient(app).delete("/i?a=3")
    assert_equal(r.text(), "int 3")


def test_present_values_keep_every_bad_request() raises:
    var app = _app()
    for target in [
        "/i?a=x",  # not an `Int`
        "/i?a=%2B1",
        "/i?a=+",  # a space is not an `Int`
        "/i?a=%2534",  # `%34` after one decoding
        "/i?a=%zz",  # a bad escape
        "/i?a=%4",
        "/s?a=%zz",
        "/s?a=%",
        "/s?a=%FF",  # not UTF-8
        "/s?a=%C3",
        "/i?a=1&a=2",  # repeated, with equal or empty values too
        "/i?a=1&a=1",
        "/s?a=&a=",
        "/s?a&a",
        "/s?a=x&a",
    ]:
        _bad(app, target)


def test_bad_request_calls_neither_handler_nor_from_body() raises:
    var app = _app()
    var client = TestClient(app)
    _reset()
    for target in ["/count?a=x", "/count?a=%zz", "/count?a=1&a"]:
        _bad(app, target)
    for target in ["/count?a=%FF", "/count?a=x&a=y"]:
        var r = client.post(target, "hi")
        assert_equal(r.status, 400, target)
    assert_equal(_count(HANDLER_CALLS), 0)
    assert_equal(_count(FROM_BODY_CALLS), 0)
    _expect(app, "/count", 200, "counted None")
    var r = client.post("/count?a=", "hi")
    assert_equal(r.text(), "counted None=hi")
    assert_equal(_count(HANDLER_CALLS), 2)
    assert_equal(_count(FROM_BODY_CALLS), 1)
    _reset()


def test_optional_beside_required_value() raises:
    var app = _app()
    # The optional value second, then first in the literal.
    _expect(app, "/rq?q=a", 200, "q a sort None")
    _expect(app, "/rq?sort=&q=a", 200, "q a sort None")
    _expect(app, "/rq?sort=n+m&q=a", 200, "q a sort [n m]")
    _expect(app, "/qr?q=a", 200, "limit None q a")
    _expect(app, "/qr?q=a&limit", 200, "limit None q a")
    _expect(app, "/qr?q=a&limit=5", 200, "limit 5 q a")
    # After a path value.
    _expect(app, "/p/1", 200, "uid 1 limit None")
    _expect(app, "/p/1?limit=", 200, "uid 1 limit None")
    _expect(app, "/p/1?limit=5", 200, "uid 1 limit 5")
    # Two optional values.
    _expect(app, "/oo", 200, "a None b None")
    _expect(app, "/oo?b=x&a=1", 200, "a 1 b [x]")
    _expect(app, "/oo?b=x", 200, "a None b [x]")
    # The required value is still 400 when absent or empty, and the
    # optional one keeps its 400s.
    for target in [
        "/rq",
        "/rq?sort=n",
        "/rq?q=&sort=n",
        "/rq?q",
        "/qr?limit=5",
        "/qr?limit=5&q=",
        "/rq?q=a&sort=%FF",
        "/rq?q=a&sort=1&sort=2",
        "/qr?q=a&limit=x",
        "/p/x",
        "/p/1?limit=x",
        "/oo?a=x&b=y",
        "/oo?a=1&b=%zz",
    ]:
        _bad(app, target)
    _expect(app, "/p", 404, "Not Found")


def test_headers_after_an_optional_value() raises:
    var app = _app()
    var client = TestClient(app)
    var r = client.get("/h", headers=_h("X-A", "1", "X-B", "2"))
    assert_equal(r.text(), "None 2")
    r = client.get("/h?a=4", headers=_h("X-A", "1"))
    assert_equal(r.text(), "4 1")
    r = client.delete("/h/1", headers=_h("X-A", "1"))
    assert_equal(r.text(), "1,None 1")
    r = client.delete("/h/1?b=a+b")
    assert_equal(r.text(), "1,[a b] 0")
    r = client.get("/h?a=x", headers=_h("X-A", "1"))
    assert_equal(r.status, 400)
    r = client.delete("/h/1?b=%FF", headers=_h("X-A", "1"))
    assert_equal(r.status, 400)


def test_body_after_an_optional_value() raises:
    var app = _app()
    var client = TestClient(app)
    var r = client.post("/b", "hi")
    assert_equal(r.text(), "None=hi")
    r = client.post("/b?a=a%2Fb", "hi")
    assert_equal(r.text(), "[a/b]=hi")
    r = client.put("/b/1?b", "hi")
    assert_equal(r.text(), "1,None=hi")
    r = client.put("/b/1?b=2", "hi")
    assert_equal(r.text(), "1,2=hi")
    r = client.patch("/b?a=", "hi")
    assert_equal(r.text(), "None=hi")
    r = client.post("/b", "bad")  # the body's own 400
    assert_equal(r.status, 400)
    for c in [("/b?a=%zz", "POST"), ("/b/1?b=x", "PUT"), ("/b?a&a", "PATCH")]:
        var req = Request(c[1], c[0], "hi")
        assert_equal(app.handle(req).status, 400, c[0])


def test_json_and_carrier_after_an_optional_value() raises:
    var app = _app()
    var client = TestClient(app)
    var ok = String('{"name":"Ada"}')
    var r = client.post("/j", ok, headers=_json())
    assert_equal(r.text(), "None=Ada")
    r = client.post("/j?a=3", ok, headers=_json())
    assert_equal(r.text(), "3=Ada")
    r = client.put("/c", "hi", headers=_h("X-A", "1"))
    assert_equal(r.text(), "None=hi 1")
    r = client.put("/c?a=x+y", "hi", headers=_h("X-A", "1"))
    assert_equal(r.text(), "[x y]=hi 1")
    var h = _json()
    h.add("X-A", "1")
    r = client.patch("/cj?b=J%C3%B6rg", ok, headers=h^)
    assert_equal(r.text(), "None,[Jörg]=Ada 2")
    # Without a JSON `Content-Type` the body step would answer 415; an
    # invalid present value answers 400 before it, an absent one does not.
    r = client.post("/j?a=x", ok)
    assert_equal(r.status, 400)
    r = client.patch("/cj?a=1&b=%FF", ok)
    assert_equal(r.status, 400)
    r = client.post("/j", ok)
    assert_equal(r.status, 415)
    r = client.patch("/cj?a=", ok)
    assert_equal(r.status, 415)
    r = client.put("/c?a=%4", "bad", headers=_h("X-A", "1"))
    assert_equal(r.status, 400)


def test_stateful_forms() raises:
    var app = _app()
    var client = TestClient(app)
    _expect(app, "/st", 200, "p:None")
    _expect(app, "/st?a=7", 200, "p:7")
    var r = client.delete("/st?b=2", headers=_h("X-A", "1"))
    assert_equal(r.text(), "p:None,2 1")
    r = client.delete("/st?a=x&b=2")
    assert_equal(r.text(), "p:[x],2 0")
    r = client.post("/st?a", "hi")
    assert_equal(r.text(), "p:None=hi")
    r = client.put("/st/1", "hi")
    assert_equal(r.text(), "p:1,None=hi")
    r = client.put("/st/1?b=5", "hi")
    assert_equal(r.text(), "p:1,5=hi")
    _bad(app, "/st?a=x")
    r = client.delete("/st?a=x")  # the required `b` is missing
    assert_equal(r.status, 400)
    r = client.put("/st/1?b=x", "hi")
    assert_equal(r.status, 400)


def test_defaulted_int_parameter_stays_required() raises:
    var app = _app()
    _expect(app, "/d?limit=5", 200, "defaulted 5")
    _bad(app, "/d")
    _bad(app, "/d?limit=")
    _expect(app, "/sd?query=a&limit=5", 200, "5 results for a")
    _bad(app, "/sd?query=a")


def test_first_registration_wins() raises:
    var app = _app()
    _expect(app, "/first", 200, "int None")
    _expect(app, "/first?limit=3", 200, "int 3")
    _bad(app, "/first?limit=x")  # no fall-through to the required route
    _bad(app, "/req")  # the required route answers first
    _bad(app, "/req?limit=")
    _expect(app, "/req?limit=3", 200, "required 3")


def test_raw_handler_is_unaffected() raises:
    var app = _app()
    _expect(app, "/raw?a=&b", 200, "raw /raw|a=&b")


def test_typed_values_and_forwarding() raises:
    var app = _app()
    var client = TestClient(app)
    _expect(app, "/typed", 200, "typed None")
    _expect(app, "/typed?a=2", 200, "typed 2")
    var r = client.post("/typed/3", "hi")
    assert_equal(r.text(), "typed None,3=hi")
    r = client.post("/typed/3?a=x", "hi")
    assert_equal(r.text(), "typed [x],3=hi")
    _expect(app, "/fwd", 200, "str None")
    _expect(app, "/fwd?a=y", 200, "str [y]")
    r = client.patch("/fwd?a=", "hi")
    assert_equal(r.text(), "p:None=hi")
    r = client.patch("/fwd?a=z", "hi")
    assert_equal(r.text(), "p:[z]=hi")
    _bad(app, "/typed?a=x")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
