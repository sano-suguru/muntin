# Prototype M3-096 spike: bare JSON bodies and results.
# Build flags (scripts/build_one.sh): -D MUNTIN_OPENAPI
from std.testing import assert_equal, assert_true, TestSuite

from muntin import App, Headers, Json, JsonFields, Request, Response, State
from muntin.testing import TestClient


@fieldwise_init
struct CreateUser(JsonFields):
    var name: String
    var age: Int


@fieldwise_init
struct User(JsonFields):
    var id: Int
    var name: String
    var tags: List[String]


def create_user(body: CreateUser) -> User:
    return User(7, body.name, ["a"])


def create_many(body: List[CreateUser]) -> List[User]:
    var out = List[User]()
    for i in range(len(body)):
        out.append(User(i, body[i].name, []))
    return out^


def list_users() -> List[User]:
    return [User(1, "ann", []), User(2, "bo", ["x", "y"])]


def get_user(id: Int) -> User:
    return User(id, "u", [])


def update(id: Int, body: CreateUser) -> User:
    return User(id, body.name, [])


def raising(body: CreateUser) raises -> User:
    if body.age < 0:
        raise Error("negative")
    return User(0, body.name, [])


def stateful(s: State[Int], body: CreateUser) -> User:
    return User(s[], body.name, [])


def wrapped(body: Json[CreateUser]) -> Json[User]:
    return Json(User(1, body.value.name, []), status=201)


def json_post(app: App, target: String, body: String) raises -> Response:
    var h = Headers()
    h.add("Content-Type", "application/json")
    return app.handle(Request("POST", target, body, h^))


def make_app() -> App:
    var app = App()
    app.post["/users"](create_user)
    app.post["/many-users"](create_many)
    app.get["/users"](list_users)
    app.get["/users/{id}"](get_user)
    app.put["/users/{id}"](update)
    app.post["/raise"](raising)
    app.post["/state"](stateful, State(42))
    app.post["/wrapped"](wrapped)
    return app^


def test_bare_body_and_result() raises:
    var app = make_app()
    var r = json_post(app, "/users", '{"name":"ann","age":3}')
    assert_equal(r.status, 200)
    assert_equal(r.text(), '{"id":7,"name":"ann","tags":["a"]}')
    assert_equal(r.headers.get("content-type").value(), "application/json")


def test_bare_list_body_and_result() raises:
    var app = make_app()
    var r = json_post(
        app, "/many-users", '[{"name":"a","age":1},{"name":"b","age":2}]'
    )
    assert_equal(r.status, 200)
    assert_equal(
        r.text(),
        '[{"id":0,"name":"a","tags":[]},{"id":1,"name":"b","tags":[]}]',
    )
    var c = TestClient(app)
    var g = c.get("/users")
    assert_equal(g.status, 200)
    assert_equal(
        g.text(),
        '[{"id":1,"name":"ann","tags":[]},{"id":2,"name":"bo","tags":["x","y"]}]',
    )
    var one = c.get("/users/5")
    assert_equal(one.text(), '{"id":5,"name":"u","tags":[]}')
    var head = c.head("/users/5")
    assert_equal(head.status, 200)


def test_json_rules_apply() raises:
    var app = make_app()
    var c = TestClient(app)
    assert_equal(c.post("/users", '{"name":"a","age":1}').status, 415)
    var big = String('{"name":"') + String("x") * (1 << 20) + '","age":1}'
    assert_equal(json_post(app, "/users", big).status, 413)
    assert_equal(json_post(app, "/users", "{").status, 400)
    var r = json_post(app, "/users", '{"name":"a"}')
    assert_equal(r.status, 400)
    assert_equal(json_post(app, "/many-users", "{}").status, 400)
    # A failure past the first element: the built ones are destroyed once.
    var partial = json_post(
        app, "/many-users", '[{"name":"a","age":1},{"name":"b"}]'
    )
    assert_equal(partial.status, 400)


def test_openapi_describes_bare_json_as_json() raises:
    var app = make_app()
    var doc = app.openapi(title="t", version="1")
    var bare_post = doc.find('"/users":{"post":')
    assert_true(bare_post >= 0)
    var post_part = String(doc[byte = bare_post : bare_post + 700])
    assert_true(
        post_part.find(
            '"requestBody":{"required":true,"content":{"application/json"'
        )
        >= 0,
        post_part,
    )
    assert_true(
        post_part.find(
            '"200":{"description":"The handler\'s JSON'
            ' value","content":{"application/json"'
        )
        >= 0,
        post_part,
    )
    assert_true(doc.find('"type":"array","items":{"type":"object"') >= 0, doc)


def test_shapes() raises:
    var app = make_app()
    var r = json_post(app, "/raise", '{"name":"a","age":-1}')
    assert_equal(r.status, 500)
    var s = json_post(app, "/state", '{"name":"a","age":1}')
    assert_equal(s.text(), '{"id":42,"name":"a","tags":[]}')
    var h = Headers()
    h.add("Content-Type", "application/json")
    var u = app.handle(Request("PUT", "/users/9", '{"name":"z","age":1}', h^))
    assert_equal(u.text(), '{"id":9,"name":"z","tags":[]}')
    var w = json_post(app, "/wrapped", '{"name":"a","age":1}')
    assert_equal(w.status, 201)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
