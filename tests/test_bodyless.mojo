# Bodyless typed `post`, `put` and `patch` handlers (M3-048): a handler whose
# slots are only route values and at most one `Headers` last, stateless or
# stateful, takes `get`'s rules on the body family and answers exactly as the
# same handler on `get` answers the same target; the request's body is not
# read. Body shapes keep `post`'s rules (every other test). Decision:
# docs/history/architecture-decisions.md, "Bodyless typed post, put and patch
# handlers decision (M3-048)". DX's example runs as written in
# `test_dx_example`. Must-not-compile cases: tests/bodyless_api_fail.

from std.testing import assert_equal, assert_true, TestSuite

from muntin import (
    App,
    Headers,
    Request,
    Response,
    State,
    ToErrorResponse,
    ToResponse,
)
from muntin.testing import TestClient


@fieldwise_init
struct Db(Movable):
    var name: String


@fieldwise_init
struct Created(ToResponse):
    var text: String

    def to_response(deinit self) -> Response:
        var response = Response.text("created " + self.text, status=201)
        try:
            response.headers.add("X-Made", self.text)
        except:
            pass
        return response^


@fieldwise_init
struct Conflict(ToErrorResponse):
    var id: Int

    def to_error_response(deinit self) -> Response:
        return Response.text(String("conflict ", self.id), status=409)


def _fields(headers: Headers) -> String:
    """Every `x-a` field's value, in order, joined with `,`."""
    var out = String()
    var values = headers.get_all("x-a")
    for i in range(len(values)):
        if i > 0:
            out += ","
        out += values[i]
    return out


def none() -> String:
    return "none"


def one_int(id: Int) -> String:
    return String("i ", id)


def one_text(var q: String) -> String:
    return "s " + q


def optional_int(n: Optional[Int]) -> String:
    return String("o ", n.value()) if n else "o none"


def int_text(a: Int, b: String) -> String:
    return String("it ", a, " ", b)


def headers_only(headers: Headers) -> String:
    return "h " + _fields(headers)


def int_headers(id: Int, headers: Headers) -> String:
    return String("ih ", id, " ", _fields(headers))


def two_ints_headers(a: Int, b: Int, var headers: Headers) -> String:
    return String("iih ", a, " ", b, " ", _fields(headers))


def created() -> Created:
    return Created("x")


def conflict(id: Int) raises Conflict -> String:
    if id == 9:
        raise Conflict(id)
    return String("ok ", id)


def raising(id: Int) raises -> String:
    if id == 9:
        raise Error("nine")
    return String("ok ", id)


def state_only(db: State[Db]) -> String:
    return "st " + db[].name


def state_int_headers(db: State[Db], id: Int, headers: Headers) -> String:
    return String("sih ", db[].name, " ", id, " ", _fields(headers))


def state_int(db: State[Db], id: Int) -> String:
    return String("si ", db[].name, " ", id)


def state_headers(db: State[Db], headers: Headers) -> String:
    return "sh " + db[].name + " " + _fields(headers)


def state_int_text(db: State[Db], a: Int, b: String) -> String:
    return String("sit ", db[].name, " ", a, " ", b)


def state_two_headers(
    db: State[Db], a: Int, b: Optional[Int], headers: Headers
) -> String:
    return String(
        "sooh ", db[].name, " ", a, " ", b.or_else(-1), " ", _fields(headers)
    )


def _app() raises -> App:
    """Every bodyless shape on one path each, registered on `get`, `post`,
    `put` and `patch` with the same handler."""
    var app = App()
    app.get["/none"](none)
    app.post["/none"](none)
    app.put["/none"](none)
    app.patch["/none"](none)
    app.get["/int/{id}"](one_int)
    app.post["/int/{id}"](one_int)
    app.put["/int/{id}"](one_int)
    app.patch["/int/{id}"](one_int)
    app.get["/text?{q}"](one_text)
    app.post["/text?{q}"](one_text)
    app.put["/text?{q}"](one_text)
    app.patch["/text?{q}"](one_text)
    app.get["/textp/{q}"](one_text)
    app.post["/textp/{q}"](one_text)
    app.put["/textp/{q}"](one_text)
    app.patch["/textp/{q}"](one_text)
    app.get["/opt?{n}"](optional_int)
    app.post["/opt?{n}"](optional_int)
    app.put["/opt?{n}"](optional_int)
    app.patch["/opt?{n}"](optional_int)
    app.get["/it/{a}?{b}"](int_text)
    app.post["/it/{a}?{b}"](int_text)
    app.put["/it/{a}?{b}"](int_text)
    app.patch["/it/{a}?{b}"](int_text)
    app.get["/h"](headers_only)
    app.post["/h"](headers_only)
    app.put["/h"](headers_only)
    app.patch["/h"](headers_only)
    app.get["/ih/{id}"](int_headers)
    app.post["/ih/{id}"](int_headers)
    app.put["/ih/{id}"](int_headers)
    app.patch["/ih/{id}"](int_headers)
    app.get["/iih/{a}/{b}"](two_ints_headers)
    app.post["/iih/{a}/{b}"](two_ints_headers)
    app.put["/iih/{a}/{b}"](two_ints_headers)
    app.patch["/iih/{a}/{b}"](two_ints_headers)
    app.get["/created"](created)
    app.post["/created"](created)
    app.put["/created"](created)
    app.patch["/created"](created)
    app.get["/conflict/{id}"](conflict)
    app.post["/conflict/{id}"](conflict)
    app.put["/conflict/{id}"](conflict)
    app.patch["/conflict/{id}"](conflict)
    app.get["/raising/{id}"](raising)
    app.post["/raising/{id}"](raising)
    app.put["/raising/{id}"](raising)
    app.patch["/raising/{id}"](raising)
    app.get["/st"](state_only, State(Db("g")))
    app.post["/st"](state_only, State(Db("g")))
    app.put["/st"](state_only, State(Db("g")))
    app.patch["/st"](state_only, State(Db("g")))
    app.get["/sih/{id}"](state_int_headers, State(Db("g")))
    app.post["/sih/{id}"](state_int_headers, State(Db("g")))
    app.put["/sih/{id}"](state_int_headers, State(Db("g")))
    app.patch["/sih/{id}"](state_int_headers, State(Db("g")))
    app.get["/si/{id}"](state_int, State(Db("g")))
    app.post["/si/{id}"](state_int, State(Db("g")))
    app.put["/si/{id}"](state_int, State(Db("g")))
    app.patch["/si/{id}"](state_int, State(Db("g")))
    app.get["/sh"](state_headers, State(Db("g")))
    app.post["/sh"](state_headers, State(Db("g")))
    app.put["/sh"](state_headers, State(Db("g")))
    app.patch["/sh"](state_headers, State(Db("g")))
    app.get["/sit/{a}?{b}"](state_int_text, State(Db("g")))
    app.post["/sit/{a}?{b}"](state_int_text, State(Db("g")))
    app.put["/sit/{a}?{b}"](state_int_text, State(Db("g")))
    app.patch["/sit/{a}?{b}"](state_int_text, State(Db("g")))
    app.get["/sooh/{a}?{b}"](state_two_headers, State(Db("g")))
    app.post["/sooh/{a}?{b}"](state_two_headers, State(Db("g")))
    app.put["/sooh/{a}?{b}"](state_two_headers, State(Db("g")))
    app.patch["/sooh/{a}?{b}"](state_two_headers, State(Db("g")))
    return app^


def _targets() -> List[String]:
    """Accepted targets and targets answered 400 before the handler."""
    return [
        "/none",
        "/none?x=1",
        "/int/042",
        "/int/abc",
        "/int/%34%32",
        "/int/%ZZ",
        "/text?q=a%20b",
        "/text?q=",
        "/text",
        "/text?q=1&q=2",
        "/textp/J%C3%B6rg",
        "/textp/%FF",
        "/opt?n=5",
        "/opt",
        "/opt?n=",
        "/opt?n=x",
        "/it/1?b=two",
        "/it/x?b=two",
        "/it/1",
        "/h",
        "/ih/7",
        "/ih/x",
        "/iih/1/2",
        "/iih/1/x",
        "/created",
        "/conflict/1",
        "/conflict/9",
        "/raising/1",
        "/raising/9",
        "/st",
        "/sih/3",
        "/sih/x",
        "/si/5",
        "/si/x",
        "/sh",
        "/sit/1?b=z",
        "/sit/x?b=z",
        "/sooh/2?b=3",
        "/sooh/2",
        "/sooh/2?b=x",
    ]


def _headers() raises -> Headers:
    var h = Headers()
    h.add("X-A", "1")
    h.add("Content-Type", "application/json")
    h.add("x-a", "")
    h.add("X-A", "three")
    return h^


def _same(got: Response, want: Response, what: String) raises:
    """The same status, the same body bytes, and the same header fields
    (names and values, in order)."""
    assert_equal(got.status, want.status, what)
    assert_true(got.body == want.body, what)
    assert_equal(len(got.headers), len(want.headers), what)
    for i in range(len(want.headers)):
        assert_equal(got.headers.name(i), want.headers.name(i), what)
        assert_equal(got.headers.value(i), want.headers.value(i), what)


def test_every_bodyless_shape_answers_as_on_get() raises:
    """Each shape, on `post`, `put` and `patch`, answers every target as the
    same handler on `get`, with header fields and with none, whatever body
    is sent: none, text, a JSON document under a JSON `Content-Type`, and
    bytes that are not UTF-8."""
    var app = _app()
    var bodies = List[List[UInt8]]()
    bodies.append(List[UInt8]())
    bodies.append(List("name=Ada".as_bytes()))
    bodies.append(List('{"name":'.as_bytes()))
    bodies.append([UInt8(0xFF), UInt8(0x80), UInt8(0)])
    var checked = 0
    for target in _targets():
        for with_fields in [False, True]:
            var want = app.handle(
                Request(
                    "GET",
                    target,
                    List[UInt8](),
                    _headers() if with_fields else Headers(),
                )
            )
            for method in ["POST", "PUT", "PATCH"]:
                for body in bodies:
                    var got = app.handle(
                        Request(
                            method,
                            target,
                            body.copy(),
                            _headers() if with_fields else Headers(),
                        )
                    )
                    _same(
                        got,
                        want,
                        String(method, " ", target, " ", len(body)),
                    )
                    checked += 1
    assert_equal(checked, len(_targets()) * 2 * 3 * 4)


def test_answers_are_the_handlers() raises:
    """Spot checks that the comparison above compares real answers: the
    handler ran with its converted values, the 400s are before it, and
    the header fields arrived in order with their values."""
    var app = _app()
    var client = TestClient(app)
    assert_equal(client.post("/none", "ignored").text(), "none")
    assert_equal(client.put("/int/042", "").text(), "i 42")
    assert_equal(client.patch("/text?q=a%20b", "x").text(), "s a b")
    assert_equal(client.post("/opt", "x").text(), "o none")
    assert_equal(client.post("/opt?n=5", "x").text(), "o 5")
    assert_equal(client.put("/it/1?b=two", "x").text(), "it 1 two")
    var bad = client.post("/int/abc", "x")
    assert_equal(bad.status, 400)
    assert_equal(bad.text(), "Bad Request")
    assert_equal(
        client.patch("/ih/7", "x", headers=_headers()).text(), "ih 7 1,,three"
    )
    assert_equal(
        client.post("/iih/1/2", "x", headers=_headers()).text(),
        "iih 1 2 1,,three",
    )
    assert_equal(client.put("/h", "x").text(), "h ")
    var made = client.post("/created", "x")
    assert_equal(made.status, 201)
    assert_equal(made.text(), "created x")
    assert_equal(made.headers.get("x-made").or_else(""), "x")
    var refused = client.put("/conflict/9", "x")
    assert_equal(refused.status, 409)
    assert_equal(refused.text(), "conflict 9")
    var failed = client.patch("/raising/9", "x")
    assert_equal(failed.status, 500)
    assert_equal(client.post("/st", "x").text(), "st g")
    assert_equal(
        client.put("/sih/3", "x", headers=_headers()).text(),
        "sih g 3 1,,three",
    )
    assert_equal(client.patch("/si/5", "x").text(), "si g 5")
    assert_equal(
        client.put("/sh", "x", headers=_headers()).text(), "sh g 1,,three"
    )
    assert_equal(client.patch("/sit/1?b=z", "x").text(), "sit g 1 z")
    assert_equal(
        client.post("/sooh/2", "x", headers=_headers()).text(),
        "sooh g 2 -1 1,,three",
    )
    var bytes = client.post("/none", [UInt8(0xFF)])
    assert_equal(bytes.status, 200)
    assert_equal(bytes.text(), "none")


def test_bodyless_route_is_selected_by_method_and_path() raises:
    """A bodyless `post` route is one route of method `POST`: another
    method on its path is 405 with its `Allow`; a second `post` route on
    the same path is a route conflict (M3-052)."""
    var app = App()
    app.post["/x/{id}"](one_int)
    var client = TestClient(app)
    assert_equal(client.post("/x/9", "").text(), "i 9")
    var other = client.get("/x/9")
    assert_equal(other.status, 405)
    assert_true(other.headers.get("allow"))
    assert_equal(other.headers.get("allow").value(), "POST")


def test_typed_value_and_generic_forwarding() raises:
    """An explicitly typed function value (`var` slots) and a generic
    helper forward a bodyless handler to `post`, `put` and `patch`."""
    var app = App()
    var f: def(var Int, var Headers) thin raises Never -> String = int_headers
    app.post["/f/{id}"](f)
    _forward_put(app, int_headers)
    _forward_patch(app, one_int)
    var client = TestClient(app)
    assert_equal(
        client.post("/f/1", "", headers=_headers()).text(), "ih 1 1,,three"
    )
    assert_equal(
        client.put("/g/2", "", headers=_headers()).text(), "ih 2 1,,three"
    )
    assert_equal(client.patch("/p/3", "").text(), "i 3")


def _forward_put[
    A: Movable & Deinitable, B: Movable & Deinitable
](mut app: App, h: def(var A, var B) thin raises Never -> String):
    app.put["/g/{id}"](h)


def _forward_patch[
    A: Movable & Deinitable
](mut app: App, h: def(var A) thin raises Never -> String):
    app.patch["/p/{id}"](h)


# DX section 3's example, as written.


struct Unauthorized(ToErrorResponse):
    def __init__(out self):
        pass

    def to_error_response(deinit self) -> Response:
        return Response.text("Unauthorized", status=401)


def activate(id: Int) -> String:  # no body: the request's is not read
    return String("activated ", id)


def logout(headers: Headers) raises Unauthorized -> String:
    if not headers.get("authorization"):
        raise Unauthorized()
    return "bye"


def follow(db: State[Db], id: Int) -> String:
    return String(db[].name, " follows ", id)


def test_dx_example() raises:
    var app = App()
    app.post["/users/{id}/activate"](activate)
    app.post["/logout"](logout)
    app.put["/users/{id}/follow"](follow, State(Db("ada")))
    # POST /users/7/activate  (no body, or any body App.handle receives) -> 200 "activated 7"
    # POST /users/abc/activate                     -> 400 "Bad Request"
    # POST /logout  Authorization: t1              -> 200 "bye"
    # POST /logout  (no Authorization)             -> 401 "Unauthorized"
    # PUT /users/7/follow                          -> 200 "ada follows 7"
    # GET /users/7/activate                        -> 405, Allow: POST

    var client = TestClient(app)
    var a = client.post("/users/7/activate", "")
    assert_equal(a.status, 200)
    assert_equal(a.text(), "activated 7")
    assert_equal(
        client.post("/users/7/activate", "anything").text(), "activated 7"
    )
    var bad = client.post("/users/abc/activate", "")
    assert_equal(bad.status, 400)
    assert_equal(bad.text(), "Bad Request")
    var auth = Headers()
    auth.add("Authorization", "t1")
    var bye = client.post("/logout", "", headers=auth^)
    assert_equal(bye.status, 200)
    assert_equal(bye.text(), "bye")
    var denied = client.post("/logout", "")
    assert_equal(denied.status, 401)
    assert_equal(denied.text(), "Unauthorized")
    assert_equal(client.put("/users/7/follow", "").text(), "ada follows 7")
    var other = client.get("/users/7/activate")
    assert_equal(other.status, 405)
    assert_equal(other.headers.get("allow").value(), "POST")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
