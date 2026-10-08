# DX section 4 and 5's JSON examples (M3-009; section 5's `status=`, M3-029), compiled and run as written
# there against production `muntin`. The successful JSON bodies go through
# `TestClient.post(target, body, headers=headers^)` with the `Content-Type`
# set, as DX section 4 shows (M3-011), one of them also compared with
# `App.handle(Request(...))`; `TestClient.post` without the field is 415. The
# rejected bodies go through `App.handle(Request(..., headers^))`. The
# result-only route goes through `TestClient`.

from std.collections import Optional
from std.testing import assert_equal, TestSuite

from muntin import (
    App,
    FromJson,
    Headers,
    Json,
    JsonValue,
    JsonWriter,
    Request,
    Response,
    ToJson,
)
from muntin.testing import TestClient


@fieldwise_init
struct CreateUser(FromJson):
    var name: String
    var age: Int
    var nickname: Optional[String]

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        var nick = Optional[String]()
        var n = value.get("nickname")
        if n and not n.value().is_null():
            nick = n.value().string()
        return Self(value["name"].string(), value["age"].int(), nick^)


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


def create_user(body: Json[CreateUser]) -> Json[User]:
    return Json(User(1, body.value.name))


def replace_user(id: Int, var body: Json[CreateUser]) -> Json[User]:
    var c = body^.take()
    return Json(User(id, c.name))


def register(var body: Json[CreateUser]) -> Json[User]:
    var c = body^.take()
    return Json(User(2, c.name), status=201)


def create() raises -> Response:
    var r = Json(User(7, "Ada"), status=201).to_response()
    r.headers.set("Content-Type", "application/problem+json")
    return r^


def _post(
    app: App, target: String, body: String, *types: String
) raises -> Response:
    var headers = Headers()
    for t in types:
        headers.add("Content-Type", t)
    return app.handle(Request("POST", target, body, headers^))


def _content_type(t: String) raises -> Headers:
    var headers = Headers()
    headers.add("Content-Type", t)
    return headers^


def test_dx_json_examples() raises:
    var app = App()
    app.post["/users"](create_user)
    app.post["/users/{id}"](replace_user)
    app.get["/create"](create)
    app.post["/accounts"](register)
    var client = TestClient(app)
    var headers = Headers()
    headers.add("Content-Type", "application/json")
    var r = client.post("/users", '{"name":"Ada","age":36}', headers=headers^)
    assert_equal(r.status, 200)
    assert_equal(r.body, '{"id":1,"name":"Ada"}')
    assert_equal(len(r.headers), 1)
    assert_equal(r.headers.get("content-type").value(), "application/json")
    var direct = app.handle(
        Request(
            "POST",
            "/users",
            '{"name":"Ada","age":36}',
            _content_type("application/json"),
        )
    )
    assert_equal(r.status, direct.status)
    assert_equal(r.body, direct.body)
    assert_equal(len(r.headers), len(direct.headers))
    assert_equal(r.headers.name(0), direct.headers.name(0))
    assert_equal(r.headers.value(0), direct.headers.value(0))
    assert_equal(
        client.post(
            "/users/4",
            '{"name":"Bo","age":1,"nickname":null}',
            headers=_content_type("application/json"),
        ).body,
        '{"id":4,"name":"Bo"}',
    )
    assert_equal(
        client.post(
            "/users",
            '{"name":"Ada","age":36}',
            headers=_content_type("application/json; charset=utf-8"),
        ).status,
        200,
    )
    # Content-Type missing, text/plain, two fields, application/problem+json.
    var ok = '{"name":"Ada","age":36}'
    for r415 in [
        _post(app, "/users", ok),
        _post(app, "/users", ok, "text/plain"),
        _post(app, "/users", ok, "application/json", "application/json"),
        _post(app, "/users", ok, "application/problem+json"),
        TestClient(app).post("/users", ok),
    ]:
        assert_equal(r415.status, 415)
        assert_equal(r415.body, "Unsupported Media Type")
    # A body over 1 MiB.
    var big = ok + String(" ") * (1_048_576 - ok.byte_length() + 1)
    var r413 = _post(app, "/users", big, "application/json")
    assert_equal(r413.status, 413)
    assert_equal(r413.body, "Content Too Large")
    # Malformed JSON, a missing member, a wrong kind.
    for bad in ['{"name":', '{"name":"Ada"}', '{"name":"Ada","age":"36"}']:
        var r400 = _post(app, "/users", bad, "application/json")
        assert_equal(r400.status, 400)
        assert_equal(r400.body, "Bad Request")
    var c = TestClient(app).get("/create")
    assert_equal(c.status, 201)
    assert_equal(c.body, '{"id":7,"name":"Ada"}')
    assert_equal(
        c.headers.get("content-type").value(), "application/problem+json"
    )
    var a = TestClient(app).post(
        "/accounts",
        '{"name":"Bo","age":1}',
        headers=_content_type("application/json"),
    )
    assert_equal(a.status, 201)
    assert_equal(a.body, '{"id":2,"name":"Bo"}')
    assert_equal(len(a.headers), 1)
    assert_equal(a.headers.get("content-type").value(), "application/json")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
