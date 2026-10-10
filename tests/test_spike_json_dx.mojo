# DX section 4 and 5's JSON examples (M3-008 decision), compiled and run as
# written there, against the spike's `Json`/`FromJson`/`ToJson`
# (tests/json_spike.mojo) instead of `muntin` until the M3-009 slice.
# The request Content-Type step is not in production, so the 415 lines of the
# example are measured on the spike's adapter mirror in
# tests/test_spike_json.mojo.

from std.collections import Optional
from std.testing import assert_equal, TestSuite

from muntin import App, Response
from muntin.testing import TestClient
from json_spike import FromJson, Json, JsonValue, JsonWriter, ToJson


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


def create() raises -> Response:
    var r = Json(User(7, "Ada")).to_response()
    r.status = 201
    r.headers.set("Content-Type", "application/problem+json")
    return r^


def test_dx_json_examples() raises:
    var app = App()
    app.post["/users"](create_user)
    app.post["/users/{id}"](replace_user)
    app.get["/create"](create)
    var client = TestClient(app)
    var r = client.post("/users", '{"name":"Ada","age":36}')
    assert_equal(r.status, 200)
    assert_equal(r.text(), '{"id":1,"name":"Ada"}')
    assert_equal(r.headers.get("content-type").value(), "application/json")
    assert_equal(
        client.post("/users/4", '{"name":"Bo","age":1,"nickname":null}').text(),
        '{"id":4,"name":"Bo"}',
    )
    assert_equal(client.post("/users", '{"name":"Ada"}').status, 400)
    var c = client.get("/create")
    assert_equal(c.status, 201)
    assert_equal(
        c.headers.get("content-type").value(), "application/problem+json"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
