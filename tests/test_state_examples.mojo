# docs/reference/state.md's three examples, each on its own `App`, with the
# answers their comments state. The text between `# example: <id>` and
# `# example: end` is what the page shows (scripts/check_doc_examples.py
# compares them), each `main` renamed; `# fmt: off` keeps its layout. Each
# example's `main` runs as written; the tests register its routes again to
# send requests. The types the page takes from other pages come first.

from std.testing import assert_equal, TestSuite

from muntin import App, FromBody, Headers, Request, Response, State
from muntin import ToErrorResponse, ToResponse
from muntin.testing import TestClient


# errors.md's `ToErrorResponse` type.


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):
    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("no user " + String(self.id), status=404)


# responses.md's `UserText`, with `:` for its space.


@fieldwise_init
struct User(ToResponse):
    var id: Int
    var name: String

    def to_response(deinit self) -> Response:
        var name = self.name^
        return Response.text(String(self.id) + ":" + name)


# bodies.md's `name=` text body.


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("expected name=<text>")
        return Self(String(body[byte=5:]))


# fmt: off
# example: state
from muntin import App, State


struct Users(Movable):
    var names: List[String]

    def __init__(out self, var names: List[String]):
        self.names = names^

    def get(self, id: Int) raises NotFound -> String:
        if id < 0 or id >= len(self.names):
            raise NotFound(id)
        return self.names[id]


def load_names() -> List[String]:
    var names = List[String]()
    names.append("ada")
    return names^


def hello() -> String:
    return "hello"


def get_user(users: State[Users], id: Int) raises NotFound -> User:
    return User(id, users[].get(id))       # read-only access to the shared value


def state_example():
    var users = State(Users(load_names()))   # the application builds the value once
    var app = App()                          # App stays non-generic
    app.get["/hello"](hello)                 # stateless handlers: unchanged
    app.get["/users/{id}"](get_user, users)  # the state is the registration's second argument
# GET /hello    -> 200 "hello"
# GET /users/0  -> get_user(users, 0) -> User(0, "ada").to_response() -> 200 "0:ada"
# GET /users/1  -> NotFound(1).to_error_response() -> 404 "no user 1"
# GET /users/x  -> 400 "Bad Request"   (get_user not called)
# example: end


# example: state-post
def update_user(users: State[Users], id: Int, body: CreateUser) raises NotFound -> User:
    return User(id, users[].get(id) + " as " + body.name)


def post_example():
    var names = List[String]()
    names.append("ada")
    names.append("bob")
    var users = State(Users(names^))
    var app = App()
    app.post["/users/{id}"](update_user, users)  # state, route value, body
# POST /users/1 "name=bo" -> update_user(users, 1, CreateUser("bo")) -> User(1, "bob as bo")
# POST /users/9 "name=bo" -> NotFound(9).to_error_response() -> 404 "no user 9"
# POST /users/x "name=bo" -> 400 "Bad Request"   (from_body and update_user not called)
# example: end


# example: state-raw
from muntin import App, Request, Response, State


@fieldwise_init
struct WebhookKeys(Movable):
    var secret: String


def webhook(keys: State[WebhookKeys], req: Request) raises -> Response:
    var signature = req.headers.get("x-signature")
    if not signature or signature.value() != keys[].secret:
        return Response.text("unsigned", status=401)
    var resp = Response.text("ok")
    resp.headers.add("X-Request-Id", "42")
    return resp^


def raw_example():
    var keys = State(WebhookKeys("sha256=valid"))
    var app = App()
    app.post["/webhook"](webhook, keys)          # app.get too
# POST /webhook  X-Signature: sha256=valid  -> 200 "ok", X-Request-Id: 42
# POST /webhook  (no X-Signature)           -> 401 "unsigned"
# GET /webhook                              -> 405 "Method Not Allowed", Allow: POST  (webhook not called)
# example: end
# fmt: on


def test_state() raises:
    state_example()
    var users = State(Users(load_names()))
    var app = App()
    app.get["/hello"](hello)
    app.get["/users/{id}"](get_user, users)
    var client = TestClient(app)
    var r = client.get("/hello")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "hello")
    r = client.get("/users/0")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "0:ada")
    r = client.get("/users/1")
    assert_equal(r.status, 404)
    assert_equal(r.text(), "no user 1")
    r = client.get("/users/x")
    assert_equal(r.status, 400)
    assert_equal(r.text(), "Bad Request")


def test_state_post() raises:
    post_example()
    var names: List[String] = ["ada", "bob"]
    var users = State(Users(names^))
    var app = App()
    app.post["/users/{id}"](update_user, users)
    var client = TestClient(app)
    var r = client.post("/users/1", "name=bo")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "1:bob as bo")
    r = client.post("/users/9", "name=bo")
    assert_equal(r.status, 404)
    assert_equal(r.text(), "no user 9")
    r = client.post("/users/x", "name=bo")
    assert_equal(r.status, 400)
    assert_equal(r.text(), "Bad Request")


def test_state_raw() raises:
    raw_example()
    var keys = State(WebhookKeys("sha256=valid"))
    var app = App()
    app.post["/webhook"](webhook, keys)
    var client = TestClient(app)
    var signed = Headers()
    signed.add("X-Signature", "sha256=valid")
    var r = client.post("/webhook", "", headers=signed^)
    assert_equal(r.status, 200)
    assert_equal(r.text(), "ok")
    assert_equal(len(r.headers), 1)
    assert_equal(r.headers.name(0), "X-Request-Id")
    assert_equal(r.headers.value(0), "42")
    r = app.handle(Request("POST", "/webhook"))
    assert_equal(r.status, 401)
    assert_equal(r.text(), "unsigned")
    r = client.get("/webhook")
    assert_equal(r.status, 405)
    assert_equal(r.text(), "Method Not Allowed")
    assert_equal(len(r.headers), 1)
    assert_equal(r.headers.name(0), "Allow")
    assert_equal(r.headers.value(0), "POST")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
