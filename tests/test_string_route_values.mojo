# Route-value decoding and `String` route values (M3-019): a route value is
# percent-decoded once at capture, then converted; `String` is a route-value
# kind beside `Int`. Through `App.handle` and `TestClient`: path and query
# decoding, the closed invalid set (400), the `Int` decoding the M2 reopen
# adds, one decoding and not two, raw handlers undecoded, and a `String` value
# composed with `Headers`, `State`, a body, `Json[T]`, `WithHeaders[B]`, both
# result policies and generic forwarding; and docs/DX.md's `String` route
# value examples, as written. Decision: docs/history/architecture-decisions.md,
# "Route-value decoding and String route values decision (M3-018)".
# Must-not-compile counterparts: tests/string_route_api_fail.

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
    ToErrorResponse,
    ToResponse,
    WithHeaders,
)
from muntin.testing import TestClient


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
        if body == "bad":
            raise Error("bad body")
        return Self(body)


@fieldwise_init
struct Name(FromJson):
    var name: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string())


@fieldwise_init
struct Card(ToResponse):
    var name: String

    def to_response(deinit self) -> Response:
        return Response.text("card " + self.name, status=201)


@fieldwise_init
struct Missing(ToErrorResponse):
    var name: String

    def to_error_response(deinit self) -> Response:
        return Response.text("no " + self.name, status=404)


def _codes(text: String) -> String:
    """The bytes of `text` as decimal numbers, so a test sees exactly what
    the handler received, control characters included."""
    var out = String()
    for b in text.as_bytes():
        if out.byte_length() > 0:
            out += ","
        out += String(Int(b))
    return out


def _h(*pairs: String) raises -> Headers:
    var h = Headers()
    var i = 0
    while i + 1 < len(pairs):
        h.add(pairs[i], pairs[i + 1])
        i += 2
    return h^


def _json() raises -> Headers:
    return _h("Content-Type", "application/json")


# docs/DX.md, `String` route values, as written there.


def profile(name: String) -> String:
    return "profile " + name


def search(q: String) -> String:
    return "results for " + q


def list_items(limit: Int) -> String:
    return "items " + String(limit)


# Handlers.


def get_user(id: Int) -> String:
    return String(id)


def codes(value: String) -> String:
    return _codes(value)


def me() -> String:
    return "me"


def owned(var name: String) -> String:
    name += "!"  # the handler's own value
    return name^


def with_headers(name: String, headers: Headers) -> String:
    return String(name, " ", len(headers))


def stateful(p: State[Prefix], name: String) -> String:
    return p[].text + name


def stateful_headers(
    p: State[Prefix], name: String, headers: Headers
) -> String:
    return String(p[].text, name, " ", len(headers))


def rename(name: String, body: Note) -> String:
    return name + "=" + body.text


def stateful_rename(p: State[Prefix], name: String, var body: Note) -> String:
    return p[].text + name + "=" + body.text


def json_rename(name: String, body: Json[Name]) -> String:
    return name + "=" + body.value.name


def carried(name: String, input: WithHeaders[Note]) -> String:
    return String(name, "=", input.body.text, " ", len(input.headers))


def carried_json(name: String, input: WithHeaders[Json[Name]]) -> String:
    return String(name, "=", input.body.value.name, " ", len(input.headers))


def card(name: String) -> Card:
    return Card(name)


def find(name: String) raises Missing -> String:
    if name == "ghost":
        raise Missing(name)
    return "found " + name


def raw(req: Request) -> Response:
    return Response.text(req.path + "|" + req.query)


def typed_value(var name: String) -> String:
    return "typed " + name


# Generic forwarding (M3-015 edge 4) reaching the `String` kind.


def fwd_one[
    A: Movable & Deinitable
](mut app: App, h: def(var A) thin raises Never -> String):
    app.get["/fwd/{name}"](h)


def fwd_two[
    A: Movable & Deinitable, B: Movable & Deinitable
](mut app: App, h: def(var A, var B) thin raises Never -> String):
    app.post["/fwd?{name}"](h)


def _app() -> App:
    var app = App()
    app.get["/users/me"](me)  # registered first: wins over the value route
    app.get["/users/{id}"](get_user)
    app.get["/users/{name}"](profile)  # never reached: the Int route answers
    app.get["/profiles/{name}"](profile)
    app.get["/search?{q}"](search)
    app.get["/items?{limit}"](list_items)
    app.get["/codes/{value}"](codes)
    app.get["/codes?{value}"](codes)
    app.get["/owned/{name}"](owned)
    app.get["/h/{name}"](with_headers)
    app.get["/h?{name}"](with_headers)
    var prefix = State(Prefix("p:"))
    app.get["/st/{name}"](stateful, prefix)
    app.get["/sth/{name}"](stateful_headers, prefix)
    app.post["/notes/{name}"](rename)
    app.post["/notes?{name}"](rename)
    app.post["/st/{name}"](stateful_rename, prefix)
    app.post["/json/{name}"](json_rename)
    app.post["/carried/{name}"](carried)
    app.post["/carried-json/{name}"](carried_json)
    app.get["/cards/{name}"](card)
    app.get["/find/{name}"](find)
    app.get["/raw/a%2Fb"](raw)
    var f: def(var String) thin raises Never -> String = typed_value
    app.get["/typed/{name}"](f)
    fwd_one(app, profile)
    fwd_two(app, rename)
    return app^


def _dx_app() -> App:
    """docs/DX.md's registrations, as written there, on its own `App`."""
    var app = App()
    app.get["/users/{name}"](profile)
    app.get["/search?{q}"](search)
    app.get["/items?{limit}"](list_items)
    return app^


def _expect(app: App, target: String, status: Int, body: String) raises:
    var r = TestClient(app).get(target)
    assert_equal(r.status, status, target)
    assert_equal(r.text(), body, target)


def _bad(app: App, target: String) raises:
    _expect(app, target, 400, "Bad Request")


def test_dx_examples() raises:
    var app = _dx_app()
    _expect(app, "/users/alice", 200, "profile alice")
    _expect(app, "/users/J%C3%B6rg", 200, "profile Jörg")
    _expect(app, "/users/a+b", 200, "profile a+b")
    _bad(app, "/users/%zz")
    _bad(app, "/users/%FF")
    _expect(app, "/search?q=mojo+lang", 200, "results for mojo lang")
    _expect(app, "/search?q=a%2Bb", 200, "results for a+b")
    for target in ["/search", "/search?q=", "/search?q=1&q=2"]:
        _bad(app, target)
    _expect(app, "/items?limit=%31%30", 200, "items 10")


def test_path_value_is_decoded_once_after_matching() raises:
    var app = _app()
    for c in [
        ("/profiles/a%20b", "profile a b"),
        ("/profiles/a%2Fb", "profile a/b"),  # one value, not two segments
        ("/profiles/a%2fb", "profile a/b"),  # hex digits in either c
        ("/profiles/a+b", "profile a+b"),  # `+` is literal in a path
        ("/profiles/..", "profile .."),  # nothing is normalized
        ("/profiles/%2E%2E", "profile .."),
        ("/profiles/%2541", "profile %41"),  # decoded once, not twice
        ("/profiles/%E2%9C%93", "profile ✓"),
    ]:
        _expect(app, c[0], 200, c[1])
    # Matching ran on the raw path: the decoded `/` adds no segment.
    _expect(app, "/profiles/a/b", 404, "Not Found")
    # Control characters are values once they decode to valid UTF-8.
    _expect(app, "/codes/%00", 200, "0")
    _expect(app, "/codes/a%0A%09b", 200, "97,10,9,98")


def test_query_value_is_decoded_once_after_gathering() raises:
    var app = _app()
    for c in [
        ("/search?q=a+b%2B", "results for a b+"),  # `+` first, then escapes
        ("/search?q=a%26b", "results for a&b"),  # `&` inside one value
        ("/search?q=a%3Db", "results for a=b"),
        ("/search?q=%2541", "results for %41"),  # decoded once, not twice
        ("/search?q=J%c3%b6rg", "results for Jörg"),
        ("/search?x=%zz&q=ok", "results for ok"),  # other pairs untouched
    ]:
        _expect(app, c[0], 200, c[1])
    _expect(app, "/codes?value=%00", 200, "0")
    _expect(app, "/codes?value=+", 200, "32")


def test_query_keys_stay_raw() raises:
    var app = _app()
    # `%71` is `q` decoded, but keys are compared undecoded: no `q` here.
    _bad(app, "/search?%71=x")
    _bad(app, "/items?lim%69t=10")


def test_invalid_values_are_bad_request() raises:
    var app = _app()
    for target in [
        "/profiles/%zz",  # not hex
        "/profiles/%4",  # truncated escape
        "/profiles/%",
        "/profiles/a%2",
        "/profiles/%FF",  # not UTF-8
        "/profiles/%C3",  # truncated UTF-8 sequence
        "/profiles/%C3%28",
        "/search?q=",  # empty
        "/search?q",
        "/search?q=%zz",
        "/search?q=%4",
        "/search?q=%",
        "/search?q=%FF",
        "/search?q=%C3",
        "/search",  # missing
        "/search?q=a&q=a",  # duplicated
    ]:
        _bad(app, target)


def test_empty_path_segment_does_not_match() raises:
    var app = _app()
    _expect(app, "/profiles/", 404, "Not Found")
    _expect(app, "/profiles", 404, "Not Found")


def test_int_parses_the_decoded_text() raises:
    var app = _app()
    for c in [
        ("/users/%34%32", "42"),
        ("/users/%2D7", "-7"),
        ("/users/-%37", "-7"),
        ("/users/0%34%32", "42"),
    ]:
        _expect(app, c[0], 200, c[1])
    _expect(app, "/items?limit=%31%30", 200, "items 10")
    _expect(app, "/items?limit=-%31", 200, "items -1")
    # Decoded text outside M2's `Int` rule stays 400, as does a bad capture.
    for target in [
        "/users/+1",
        "/users/%2B1",
        "/users/%20",
        "/users/%2042",
        "/users/%zz",
        "/users/%2D%2D7",
        "/users/%39223372036854775808",
        "/users/%2534",  # `%34` after one decoding: one decoding, not two
        "/items?limit=+1",  # a space after decoding
        "/items?limit=%2B1",
        "/items?limit=%zz",
        "/items?limit=%2534",
    ]:
        _bad(app, target)


def test_first_registration_wins() raises:
    var app = _app()
    _expect(app, "/users/me", 200, "me")
    _expect(app, "/users/42", 200, "42")
    # The Int route answers; a 400 never falls through to the String route.
    _bad(app, "/users/alice")
    _bad(app, "/users/%zz")


def test_owned_typed_and_forwarded_values() raises:
    var app = _app()
    _expect(app, "/owned/a%20b", 200, "a b!")
    _expect(app, "/typed/J%C3%B6rg", 200, "typed Jörg")
    _expect(app, "/fwd/a+b", 200, "profile a+b")
    var r = TestClient(app).post("/fwd?name=a+b", "x")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "a b=x")
    _bad(app, "/fwd/%zz")


def test_raw_handler_and_request_stay_undecoded() raises:
    var app = _app()
    _expect(app, "/raw/a%2Fb?q=a+b%2B", 200, "/raw/a%2Fb|q=a+b%2B")
    _expect(app, "/raw/a/b", 404, "Not Found")  # raw matching, not decoded


def test_headers_and_state_after_a_string() raises:
    var app = _app()
    var client = TestClient(app)
    var r = client.get("/h/a%20b", headers=_h("X-A", "1", "X-B", "2"))
    assert_equal(r.text(), "a b 2")
    r = client.get("/h?name=a+b", headers=_h("X-A", "1"))
    assert_equal(r.text(), "a b 1")
    _expect(app, "/st/J%C3%B6rg", 200, "p:Jörg")
    r = client.get("/sth/a%2Fb", headers=_h("X-A", "1"))
    assert_equal(r.text(), "p:a/b 1")
    for target in ["/h/%zz", "/h?name=", "/st/%FF", "/sth/%4"]:
        r = client.get(target, headers=_h("X-A", "1"))
        assert_equal(r.status, 400, target)


def test_post_body_after_a_string() raises:
    var app = _app()
    var client = TestClient(app)
    var cases = [
        ("/notes/a%2Fb", "hi", 200, "a/b=hi"),
        ("/notes?name=a+b%2B", "hi", 200, "a b+=hi"),
        ("/st/a%20b", "hi", 200, "p:a b=hi"),
        ("/notes/a", "bad", 400, "Bad Request"),  # the body's own 400
        ("/notes/%zz", "hi", 400, "Bad Request"),
        ("/notes?name=", "hi", 400, "Bad Request"),
        ("/st/%FF", "hi", 400, "Bad Request"),
        ("/notes", "hi", 400, "Bad Request"),  # the query route's missing value
    ]
    for c in cases:
        var r = client.post(c[0], c[1])
        assert_equal(r.status, c[2], c[0])
        assert_equal(r.text(), c[3], c[0])


def test_json_and_carrier_after_a_string_reject_the_value_first() raises:
    var app = _app()
    var client = TestClient(app)
    var ok = String('{"name":"Ada"}')
    var r = client.post("/json/a%20b", ok, headers=_json())
    assert_equal(r.text(), "a b=Ada")
    r = client.post("/carried/a%2Fb", "hi", headers=_h("X-A", "1"))
    assert_equal(r.text(), "a/b=hi 1")
    r = client.post("/carried-json/J%C3%B6rg", ok, headers=_json())
    assert_equal(r.text(), "Jörg=Ada 1")
    # Without a JSON `Content-Type` the body step would answer 415; the bad
    # route value answers 400 before it.
    for target in ["/json/%zz", "/carried-json/%FF"]:
        r = client.post(target, ok)
        assert_equal(r.status, 400, target)
    r = client.post("/json/ok", ok)
    assert_equal(r.status, 415)
    r = client.post("/carried/%4", "bad", headers=_h("X-A", "1"))
    assert_equal(r.status, 400)


def test_result_policies_after_a_string() raises:
    var app = _app()
    _expect(app, "/cards/a%20b", 201, "card a b")
    _expect(app, "/find/ann", 200, "found ann")
    _expect(app, "/find/gh%6Fst", 404, "no ghost")  # the decoded value raised
    _bad(app, "/cards/%zz")
    _bad(app, "/find/%zz")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
