# `put`, `patch` and `delete` in production (M3-021): `put` and `patch` take
# exactly `post`'s shapes and `delete` exactly `get`'s, with the same rules,
# results and errors; method matching stays byte for byte, a method with no
# route on a matching path is 404, and `TestClient.put`, `.patch` and
# `.delete` equal `App.handle` for the same request. Decision:
# docs/history/architecture-decisions.md, "HTTP methods decision (M3-020)".
# DX's example runs as written in `test_dx_example`. Must-not-compile cases:
# tests/methods_api_fail.

from std.testing import assert_equal, TestSuite

from muntin import (
    App,
    FromBody,
    FromJson,
    Headers,
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


# Application types.


struct Note(FromBody):
    """Any body but `bad`, unchanged, the empty body included."""

    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        if body == "bad":
            raise Error("bad body")
        return Self(body)


@fieldwise_init
struct Greeting(FromJson):
    var name: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string())


@fieldwise_init
struct Db(Movable):
    var name: String


@fieldwise_init
struct Created(ToResponse):
    var text: String

    def to_response(deinit self) -> Response:
        return Response.text("created " + self.text, status=201)


@fieldwise_init
struct Conflict(ToErrorResponse):
    var id: Int

    def to_error_response(deinit self) -> Response:
        return Response.text(String("conflict ", self.id), status=409)


# `put` and `patch` handlers: `post`'s shapes.


def body_only(body: Note) -> String:
    return "b " + body.text


def value_body(id: Int, body: Note) -> String:
    return String("i ", id, " ", body.text)


def text_body(name: String, body: Note) -> String:
    return "s " + name + " " + body.text


def json_body(body: Json[Greeting]) -> String:
    return "hi " + body.value.name


def carrier(input: WithHeaders[Note]) -> String:
    return String("w ", input.body.text, " ", len(input.headers.get_all("x-a")))


def raw(req: Request) -> Response:
    return Response.text(
        req.method + "|" + req.path + "|" + req.query + "|" + req.body,
        status=202,
    )


def state_body(db: State[Db], body: Note) -> String:
    return db[].name + " " + body.text


def state_value_body(db: State[Db], id: Int, body: Note) -> String:
    return String(db[].name, " ", id, " ", body.text)


def state_raw(db: State[Db], req: Request) -> Response:
    return Response.text(db[].name + " " + req.method + "|" + req.body)


def converted(body: Note) -> Created:
    return Created(body.text)


def failing(body: Note) raises -> String:
    raise Error("secret " + body.text)


def conflicting(id: Int, body: Note) raises Conflict -> String:
    if id == 0:
        raise Conflict(id)
    return String("ok ", id, " ", body.text)


def owned_value_body(var id: Int, var body: Note) -> String:
    return String("typed ", id, " ", body.text)


def forward_put[
    A: Movable & Deinitable, B: Movable & Deinitable
](mut app: App, h: def(var A, var B) thin raises Never -> String):
    """A generic helper forwarding two slots to `put`."""
    app.put["/fwd/{id}"](h)


def forward_patch[
    A: Movable & Deinitable, B: Movable & Deinitable
](mut app: App, h: def(var A, var B) thin raises Never -> String):
    """A generic helper forwarding two slots to `patch`."""
    app.patch["/fwd/{id}"](h)


def put_app() -> App:
    var app = App()
    var db = State(Db("db"))
    app.put["/b"](body_only)
    app.put["/i/{id}"](value_body)
    app.put["/q?{id}"](value_body)
    app.put["/s/{name}"](text_body)
    app.put["/j"](json_body)
    app.put["/w"](carrier)
    app.put["/raw"](raw)
    app.put["/st"](state_body, db)
    app.put["/st/{id}"](state_value_body, db)
    app.put["/st-raw"](state_raw, db)
    app.put["/resp"](converted)
    app.put["/raise"](failing)
    app.put["/err/{id}"](conflicting)
    var typed: def(
        var Int, var Note
    ) thin raises Never -> String = owned_value_body
    app.put["/typed/{id}"](typed)
    forward_put(app, value_body)
    return app^


def patch_app() -> App:
    var app = App()
    var db = State(Db("db"))
    app.patch["/b"](body_only)
    app.patch["/i/{id}"](value_body)
    app.patch["/q?{id}"](value_body)
    app.patch["/s/{name}"](text_body)
    app.patch["/j"](json_body)
    app.patch["/w"](carrier)
    app.patch["/raw"](raw)
    app.patch["/st"](state_body, db)
    app.patch["/st/{id}"](state_value_body, db)
    app.patch["/st-raw"](state_raw, db)
    app.patch["/resp"](converted)
    app.patch["/raise"](failing)
    app.patch["/err/{id}"](conflicting)
    var typed: def(
        var Int, var Note
    ) thin raises Never -> String = owned_value_body
    app.patch["/typed/{id}"](typed)
    forward_patch(app, value_body)
    return app^


comptime JSON = "json"
"""A case's fields: `Content-Type: application/json`."""
comptime XA = "xa"
"""A case's fields: `X-A: 1` and `x-a: 2`."""


@fieldwise_init
struct Case(Copyable):
    var target: String
    var body: String
    var fields: String
    var status: Int
    var text: String


def _fields(kind: String) raises -> Headers:
    var headers = Headers()
    if kind == JSON:
        headers.add("Content-Type", "application/json")
    elif kind == XA:
        headers.add("X-A", "1")
        headers.add("x-a", "2")
    return headers^


def _send(app: App, method: String, c: Case) raises -> Response:
    return app.handle(Request(method, c.target, c.body, _fields(c.fields)))


def _body_cases(method: String) -> List[Case]:
    """One table for `put` and `patch`: each of `post`'s shapes and its
    400, 413, 415 and 500 answers, before or after the handler."""
    var over = String('{"name":"Ada"}') + String(" ") * 1_048_577
    return [
        Case("/b", "hi", "", 200, "b hi"),
        Case("/b", "bad", "", 400, "Bad Request"),
        # An empty body is a body: it follows the body rules.
        Case("/b", "", "", 200, "b "),
        Case("/b?x=1", "hi", "", 200, "b hi"),
        Case("/i/042", "hi", "", 200, "i 42 hi"),
        Case("/i/%34%32", "hi", "", 200, "i 42 hi"),
        Case("/i/abc", "hi", "", 400, "Bad Request"),
        Case("/i/1", "bad", "", 400, "Bad Request"),
        Case("/i", "hi", "", 404, "Not Found"),
        Case("/q?id=7", "hi", "", 200, "i 7 hi"),
        Case("/q", "hi", "", 400, "Bad Request"),
        Case("/q?id=1&id=2", "hi", "", 400, "Bad Request"),
        Case("/s/J%C3%B6rg", "hi", "", 200, "s Jörg hi"),
        Case("/s/a+b", "hi", "", 200, "s a+b hi"),
        Case("/s/%zz", "hi", "", 400, "Bad Request"),
        Case("/s/%FF", "hi", "", 400, "Bad Request"),
        Case("/j", '{"name":"Ada"}', JSON, 200, "hi Ada"),
        Case("/j", '{"name":"Ada"}', "", 415, "Unsupported Media Type"),
        Case("/j", over, JSON, 413, "Content Too Large"),
        Case("/j", '{"name":', JSON, 400, "Bad Request"),
        Case("/j", '{"other":1}', JSON, 400, "Bad Request"),
        Case("/w", "hi", XA, 200, "w hi 2"),
        Case("/w", "hi", "", 200, "w hi 0"),
        Case("/w", "bad", XA, 400, "Bad Request"),
        Case("/raw?id=abc&id=2", "x", "", 202, method + "|/raw|id=abc&id=2|x"),
        Case("/raw", "", "", 202, method + "|/raw||"),
        Case("/st", "hi", "", 200, "db hi"),
        Case("/st", "bad", "", 400, "Bad Request"),
        Case("/st/3", "hi", "", 200, "db 3 hi"),
        Case("/st/x", "hi", "", 400, "Bad Request"),
        Case("/st-raw?k", "b", "", 200, "db " + method + "|b"),
        Case("/resp", "hi", "", 201, "created hi"),
        Case("/raise", "hi", "", 500, "Internal Server Error"),
        Case("/raise", "bad", "", 400, "Bad Request"),
        Case("/err/0", "hi", "", 409, "conflict 0"),
        Case("/err/1", "hi", "", 200, "ok 1 hi"),
        Case("/err/x", "hi", "", 400, "Bad Request"),
        Case("/typed/5", "hi", "", 200, "typed 5 hi"),
        Case("/typed/x", "hi", "", 400, "Bad Request"),
        Case("/fwd/2", "hi", "", 200, "i 2 hi"),
        Case("/fwd/x", "hi", "", 400, "Bad Request"),
    ]


def _check_body_cases(app: App, method: String) raises:
    for c in _body_cases(method):
        var r = _send(app, method, c)
        var at = String(method, " ", c.target, " ", c.body.byte_length())
        assert_equal(r.status, c.status, at)
        assert_equal(r.text(), c.text, at)


def test_put_takes_posts_shapes() raises:
    _check_body_cases(put_app(), "PUT")


def test_patch_takes_posts_shapes() raises:
    _check_body_cases(patch_app(), "PATCH")


def test_body_routes_answer_their_own_method_only() raises:
    var put = put_app()
    var patch = patch_app()
    for method in ["GET", "POST", "PATCH", "DELETE", "HEAD", "put"]:
        for target in ["/b", "/i/1", "/raw", "/st"]:
            var r = put.handle(Request(method, target, "hi"))
            assert_equal(r.status, 404, String(method, " ", target))
            assert_equal(r.text(), "Not Found")
    for method in ["GET", "POST", "PUT", "DELETE", "patch"]:
        assert_equal(patch.handle(Request(method, "/b", "hi")).status, 404)


# `delete` handlers: `get`'s shapes.


def removed() -> String:
    return "removed"


def removed_id(id: Int) -> String:
    return String("removed ", id)


def removed_name(name: String) -> String:
    return "removed " + name


def removed_with(headers: Headers) -> String:
    return String("traces=", len(headers.get_all("x-a")))


def removed_id_with(id: Int, headers: Headers) -> String:
    return String(id, " traces=", len(headers.get_all("x-a")))


def state_removed(db: State[Db]) -> String:
    return db[].name + " removed"


def state_removed_id(db: State[Db], id: Int) -> String:
    return String(db[].name, " removed ", id)


def state_removed_id_with(db: State[Db], id: Int, headers: Headers) -> String:
    return String(db[].name, " ", id, " traces=", len(headers.get_all("x-a")))


def removed_resource() -> Created:
    return Created("gone")


def removing_fails() raises -> String:
    raise Error("secret")


def removing_conflicts(id: Int) raises Conflict -> String:
    if id == 0:
        raise Conflict(id)
    return String("removed ", id)


def owned_removed_id(var id: Int) -> String:
    id += 1
    return String("typed ", id)


def forward_delete[
    A: Movable & Deinitable
](mut app: App, h: def(var A) thin raises Never -> String):
    """A generic helper forwarding one slot to `delete`."""
    app.delete["/dfwd/{id}"](h)


def delete_app() -> App:
    var app = App()
    var db = State(Db("db"))
    app.delete["/d"](removed)
    app.delete["/d/{id}"](removed_id)
    app.delete["/dq?{id}"](removed_id)
    app.delete["/ds/{name}"](removed_name)
    app.delete["/dh"](removed_with)
    app.delete["/dh/{id}"](removed_id_with)
    app.delete["/draw"](raw)
    app.delete["/dst"](state_removed, db)
    app.delete["/dst/{id}"](state_removed_id, db)
    app.delete["/dst-h/{id}"](state_removed_id_with, db)
    app.delete["/dst-raw"](state_raw, db)
    app.delete["/dresp"](removed_resource)
    app.delete["/draise"](removing_fails)
    app.delete["/derr/{id}"](removing_conflicts)
    var typed: def(var Int) thin raises Never -> String = owned_removed_id
    app.delete["/dtyped/{id}"](typed)
    forward_delete(app, removed_id)
    return app^


def test_delete_takes_gets_shapes() raises:
    var app = delete_app()
    var cases: List[Case] = [
        Case("/d", "", "", 200, "removed"),
        Case("/d?x=1", "", "", 200, "removed"),
        # A typed `delete` handler takes no body: one sent is not read.
        Case("/d", "ignored", "", 200, "removed"),
        Case("/d/042", "", "", 200, "removed 42"),
        Case("/d/%34%32", "", "", 200, "removed 42"),
        Case("/d/abc", "", "", 400, "Bad Request"),
        Case("/dq?id=7", "", "", 200, "removed 7"),
        Case("/dq", "", "", 400, "Bad Request"),
        Case("/dq?id=", "", "", 400, "Bad Request"),
        Case("/ds/J%C3%B6rg", "", "", 200, "removed Jörg"),
        Case("/ds/%zz", "", "", 400, "Bad Request"),
        Case("/dh", "", XA, 200, "traces=2"),
        Case("/dh", "", "", 200, "traces=0"),
        Case("/dh/3", "", XA, 200, "3 traces=2"),
        Case("/dh/x", "", XA, 400, "Bad Request"),
        # The raw handler receives the whole request, its body included.
        Case("/draw?id=abc", "a body", "", 202, "DELETE|/draw|id=abc|a body"),
        Case("/draw", "", "", 202, "DELETE|/draw||"),
        Case("/dst", "", "", 200, "db removed"),
        Case("/dst/3", "", "", 200, "db removed 3"),
        Case("/dst/x", "", "", 400, "Bad Request"),
        Case("/dst-h/3", "", XA, 200, "db 3 traces=2"),
        Case("/dst-h/x", "", XA, 400, "Bad Request"),
        Case("/dst-raw", "kept", "", 200, "db DELETE|kept"),
        Case("/dresp", "", "", 201, "created gone"),
        Case("/draise", "", "", 500, "Internal Server Error"),
        Case("/derr/0", "", "", 409, "conflict 0"),
        Case("/derr/1", "", "", 200, "removed 1"),
        Case("/derr/x", "", "", 400, "Bad Request"),
        Case("/dtyped/5", "", "", 200, "typed 6"),
        Case("/dtyped/x", "", "", 400, "Bad Request"),
        Case("/dfwd/2", "", "", 200, "removed 2"),
        Case("/dfwd/x", "", "", 400, "Bad Request"),
        Case("/d/1/x", "", "", 404, "Not Found"),
    ]
    for c in cases:
        var r = _send(app, "DELETE", c)
        assert_equal(r.status, c.status, c.target)
        assert_equal(r.text(), c.text, c.target)
    for method in ["GET", "POST", "PUT", "PATCH", "delete", "Delete"]:
        for target in ["/d", "/d/1", "/draw", "/dst"]:
            var r = app.handle(Request(method, target))
            assert_equal(r.status, 404, String(method, " ", target))
            assert_equal(r.text(), "Not Found")


# Matching across methods.


def got(id: Int) -> String:
    return String("GET ", id)


def posted(id: Int, body: Note) -> String:
    return String("POST ", id, " ", body.text)


def put_one(id: Int, body: Note) -> String:
    return String("PUT ", id, " ", body.text)


def patched(id: Int, body: Note) -> String:
    return String("PATCH ", id, " ", body.text)


def deleted(id: Int) -> String:
    return String("DELETE ", id)


def first(body: Note) -> String:
    return "first " + body.text


def second(body: Note) -> String:
    return "second " + body.text


def by_name(name: String) -> String:
    return "by name " + name


def test_each_method_reaches_its_own_route() raises:
    var app = App()
    app.get["/r/{id}"](got)
    app.post["/r/{id}"](posted)
    app.put["/r/{id}"](put_one)
    app.patch["/r/{id}"](patched)
    app.delete["/r/{id}"](deleted)
    var want = [
        ("GET", "GET 7"),
        ("POST", "POST 7 x"),
        ("PUT", "PUT 7 x"),
        ("PATCH", "PATCH 7 x"),
        ("DELETE", "DELETE 7"),
    ]
    for w in want:
        var r = app.handle(Request(w[0], "/r/7", "x"))
        assert_equal(r.status, 200, w[0])
        assert_equal(r.text(), w[1], w[0])
    # No route of that method, or a method that matches none byte for byte.
    for method in ["HEAD", "OPTIONS", "TRACE", "delete", "Put", "PATCH "]:
        var r = app.handle(Request(method, "/r/7", "x"))
        assert_equal(r.status, 404, method)
        assert_equal(r.text(), "Not Found", method)


def test_method_without_a_route_on_a_matching_path_is_404() raises:
    var app = App()
    app.put["/only"](body_only)
    for method in ["GET", "POST", "PATCH", "DELETE"]:
        assert_equal(app.handle(Request(method, "/only", "x")).status, 404)
    assert_equal(app.handle(Request("PUT", "/only", "x")).text(), "b x")
    var deletes = App()
    deletes.delete["/gone/{id}"](removed_id)
    for method in ["GET", "POST", "PUT", "PATCH"]:
        assert_equal(deletes.handle(Request(method, "/gone/1")).status, 404)
    assert_equal(deletes.handle(Request("delete", "/gone/1")).status, 404)
    assert_equal(deletes.handle(Request("DELETE", "/gone/1")).status, 200)


def test_first_registration_wins_and_never_falls_through() raises:
    var app = App()
    app.put["/f"](first)
    app.put["/f"](second)
    app.delete["/g/{name}"](by_name)
    app.patch["/g/{id}"](patched)
    app.patch["/g/{name}"](text_body)
    assert_equal(app.handle(Request("PUT", "/f", "x")).text(), "first x")
    # The `patch` route's 400 does not fall through to the later `patch`
    # route on the same path, nor to the `delete` route before it.
    var bad = app.handle(Request("PATCH", "/g/abc", "x"))
    assert_equal(bad.status, 400)
    assert_equal(bad.text(), "Bad Request")
    assert_equal(app.handle(Request("PATCH", "/g/7", "x")).text(), "PATCH 7 x")
    assert_equal(app.handle(Request("DELETE", "/g/abc")).text(), "by name abc")


# `TestClient` equals `App.handle` for the same request.


def _assert_same(got: Response, want: Response, at: String) raises:
    assert_equal(got.status, want.status, at)
    assert_equal(got.text(), want.text(), at)
    assert_equal(len(got.headers), len(want.headers), at)
    for i in range(len(want.headers)):
        assert_equal(got.headers.name(i), want.headers.name(i), at)
        assert_equal(got.headers.value(i), want.headers.value(i), at)


def test_test_client_methods_equal_app_handle() raises:
    var put = put_app()
    var patch = patch_app()
    var deletes = delete_app()
    var puts = TestClient(put)
    var patches = TestClient(patch)
    var dels = TestClient(deletes)
    for c in _body_cases("PUT"):
        _assert_same(
            puts.put(c.target, c.body, headers=_fields(c.fields)),
            _send(put, "PUT", c),
            "PUT " + c.target,
        )
    for c in _body_cases("PATCH"):
        _assert_same(
            patches.patch(c.target, c.body, headers=_fields(c.fields)),
            _send(patch, "PATCH", c),
            "PATCH " + c.target,
        )
    # Without `headers=`, no field is sent: the JSON route is 415.
    assert_equal(puts.put("/j", '{"name":"Ada"}').status, 415)
    assert_equal(patches.patch("/j", '{"name":"Ada"}').status, 415)
    for target in ["/d", "/d/7", "/d/x", "/dh", "/dh/3", "/draw?q", "/dst-raw"]:
        _assert_same(
            dels.delete(target, headers=_fields(XA)),
            deletes.handle(Request("DELETE", target, "", _fields(XA))),
            "DELETE " + target,
        )
        _assert_same(
            dels.delete(target),
            deletes.handle(Request("DELETE", target)),
            "DELETE " + target,
        )
    # `TestClient.delete` sends an empty body.
    assert_equal(dels.delete("/draw").text(), "DELETE|/draw||")


# DX "Proven vs. target status", "PUT, PATCH and DELETE", as written there.


struct UserForm(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("expected name=<text>")
        return Self(String(body[byte=5:]))


@fieldwise_init
struct User(ToJson):
    var id: Int
    var name: String

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("id")
        out.int(self.id)
        out.name("name")
        out.string(self.name)
        out.end_object()


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(deinit self) -> Response:
        return Response.text("Unauthorized", status=401)


@fieldwise_init
struct Rename(FromJson):
    var name: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string())


@fieldwise_init
struct Directory(Movable):
    var domain: String


def replace_user(id: Int, body: UserForm) -> String:  # `post`'s shapes
    return String("replaced ", id, " ", body.name)


def rename_user(
    users: State[Directory], id: Int, body: Json[Rename]
) -> Json[User]:
    return Json(User(id, body.value.name + "@" + users[].domain))


def remove_user(id: Int, headers: Headers) raises Unauthorized -> String:
    if not headers.get("authorization"):  # `get`'s shapes
        raise Unauthorized()
    return String("removed ", id)


def purge(req: Request) -> Response:  # raw: reads a DELETE body
    return Response.text("purged " + req.path + " [" + req.body + "]")


def test_dx_example() raises:
    var app = App()
    app.put["/users/{id}"](replace_user)
    app.patch["/users/{id}"](rename_user, State(Directory("example.com")))
    app.delete["/users/{id}"](remove_user)
    app.delete["/cache"](purge)

    var client = TestClient(app)
    var r = client.put("/users/7", "name=Ada")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "replaced 7 Ada")
    for body in ["Ada", ""]:
        var bad = client.put("/users/7", body)
        assert_equal(bad.status, 400)
        assert_equal(bad.text(), "Bad Request")

    var h = Headers()
    h.add("Content-Type", "application/json")
    var renamed = client.patch("/users/7", '{"name":"bo"}', headers=h^)
    assert_equal(renamed.status, 200)
    assert_equal(renamed.text(), '{"id":7,"name":"bo@example.com"}')
    assert_equal(
        renamed.headers.get("content-type").value(), "application/json"
    )
    var untyped = client.patch("/users/7", '{"name":"bo"}')
    assert_equal(untyped.status, 415)
    assert_equal(untyped.text(), "Unsupported Media Type")

    var auth = Headers()
    auth.add("Authorization", "t1")
    var gone = client.delete("/users/7", headers=auth^)
    assert_equal(gone.status, 200)
    assert_equal(gone.text(), "removed 7")
    var denied = client.delete("/users/7")
    assert_equal(denied.status, 401)
    assert_equal(denied.text(), "Unauthorized")
    var invalid = client.delete("/users/abc")
    assert_equal(invalid.status, 400)
    assert_equal(invalid.text(), "Bad Request")
    var purged = app.handle(Request("DELETE", "/cache", "all"))
    assert_equal(purged.status, 200)
    assert_equal(purged.text(), "purged /cache [all]")

    for method in ["POST", "HEAD", "OPTIONS"]:
        var r404 = app.handle(Request(method, "/users/7", "name=Ada"))
        assert_equal(r404.status, 404, method)
        assert_equal(r404.text(), "Not Found", method)
    assert_equal(client.get("/cache").status, 404)
    assert_equal(app.handle(Request("delete", "/users/7")).status, 404)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
