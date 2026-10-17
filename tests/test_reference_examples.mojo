# The docs/reference/ examples no other test runs as written: each as the
# page writes it, on its own `App`, with the answers its comments state.
# Where two pages define the same name, the second is renamed here, as the
# line after its example says.

from std.testing import assert_equal, TestSuite

from muntin import App, FromBody, Headers, Request, Response
from muntin import ToErrorResponse, ToResponse
from muntin.testing import TestClient


# responses.md, `ToResponse`.


@fieldwise_init
struct UserText(ToResponse):
    var id: Int
    var name: String

    def to_response(deinit self) -> Response:
        var name = self.name^
        return Response.text(String(self.id) + " " + name)


def get_user(id: Int) -> UserText:
    return UserText(id, "Ada")


def health() -> Response:
    return Response.text("ok")


# errors.md, the first example (`get_user` there).


def get_user_or_500(id: Int) raises -> UserText:
    if id == 0:
        raise Error("no such user")
    return UserText(id, "Ada")


# errors.md, `ToErrorResponse` (`get_user` there).


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):
    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("no user " + String(self.id), status=404)


def get_user_or_404(id: Int) raises NotFound -> UserText:
    if id == 0:
        raise NotFound(id)
    return UserText(id, "Ada")


# bodies.md, text bodies.


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("expected name=<text>")
        return Self(String(body[byte=5:]))


def create_user(body: CreateUser) -> String:
    return "created " + body.name


# testing.md, request header fields.


def echo(req: Request) -> Response:
    var out = req.method + " " + req.path
    for i in range(len(req.headers)):
        out += " " + req.headers.name(i) + "=" + req.headers.value(i)
    return Response.text(out)


def test_responses_to_response() raises:
    var app = App()
    app.get["/users/{id}"](get_user)
    app.get["/health"](health)
    var client = TestClient(app)
    var r = client.get("/users/7")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "7 Ada")
    assert_equal(len(r.headers), 0)
    r = client.get("/health")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "ok")
    assert_equal(len(r.headers), 0)


def test_errors_fixed_500() raises:
    var app = App()
    app.get["/users/{id}"](get_user_or_500)
    var client = TestClient(app)
    var r = client.get("/users/1")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "1 Ada")
    r = client.get("/users/0")
    assert_equal(r.status, 500)
    assert_equal(r.text(), "Internal Server Error")
    r = client.get("/users/abc")
    assert_equal(r.status, 400)
    assert_equal(r.text(), "Bad Request")


def test_errors_to_error_response() raises:
    var app = App()
    app.get["/users/{id}"](get_user_or_404)
    var client = TestClient(app)
    var r = client.get("/users/1")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "1 Ada")
    r = client.get("/users/0")
    assert_equal(r.status, 404)
    assert_equal(r.text(), "no user 0")
    r = client.get("/users/abc")
    assert_equal(r.status, 400)
    assert_equal(r.text(), "Bad Request")


def test_bodies_text_body() raises:
    var app = App()
    app.post["/users"](create_user)
    var client = TestClient(app)
    var r = client.post("/users", "name=Ada")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "created Ada")
    r = client.post("/users", "Ada")
    assert_equal(r.status, 400)
    assert_equal(r.text(), "Bad Request")
    r = client.post("/users", "")
    assert_equal(r.status, 400)
    assert_equal(r.text(), "Bad Request")
    r = client.get("/users")
    assert_equal(r.status, 405)
    assert_equal(r.text(), "Method Not Allowed")
    assert_equal(r.headers.get("allow").value(), "POST")
    r = client.put("/users", "name=Ada")
    assert_equal(r.status, 405)
    assert_equal(r.headers.get("allow").value(), "POST")
    r = client.post("/missing", "name=Ada")
    assert_equal(r.status, 404)
    assert_equal(r.text(), "Not Found")


def test_testing_header_fields() raises:
    var app = App()
    app.get["/echo"](echo)
    app.post["/echo"](echo)
    var client = TestClient(app)
    var headers = Headers()
    headers.add("X-Request-Id", "42")
    var r = client.get("/echo", headers=headers.copy())
    assert_equal(r.text(), "GET /echo X-Request-Id=42")
    assert_equal(len(headers), 1)
    r = client.post("/echo", "body", headers=headers^)
    assert_equal(r.text(), "POST /echo X-Request-Id=42")
    assert_equal(client.get("/echo").text(), "GET /echo")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
