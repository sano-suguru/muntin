# The docs/reference/ examples no feature test runs: each on its own `App`,
# with the answers its comments state. The text between `# example: <id>`
# and `# example: end` is what the page shows (scripts/check_doc_examples.py
# compares them, with the names the page's marker line maps); `# fmt: off`
# keeps its layout. Where two pages define the same name, the second is
# renamed here.

from std.testing import assert_equal, TestSuite

from muntin import App, FromBody, Headers, Request, Response
from muntin import ToErrorResponse, ToResponse
from muntin.testing import TestClient


# responses.md, `ToResponse`.


# fmt: off
# example: responses-to-response
from muntin import App, Response, ToResponse


@fieldwise_init
struct UserText(ToResponse):              # defined by the application; may be move-only
    var id: Int
    var name: String

    def to_response(deinit self) -> Response:   # the application chooses status and body
        var name = self.name^                    # moved, not copied
        return Response.text(String(self.id) + " " + name)


def get_user(id: Int) -> UserText:
    return UserText(id, "Ada")


def health() -> Response:                 # Response conforms itself
    return Response.text("ok")
# example: end
# fmt: on


# errors.md, the first example (`get_user` there).


# fmt: off
# example: errors-fixed-500
def get_user_or_500(id: Int) raises -> UserText:    # or raises T, an application error type that does not opt in
    if id == 0:
        raise Error("no such user")
    return UserText(id, "Ada")
# example: end
# fmt: on


# errors.md, `ToErrorResponse` (`get_user` there).


# fmt: off
# example: errors-to-error-response
from muntin import App, Response, ToErrorResponse


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):     # the opt-in, in the type's own declaration
    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("no user " + String(self.id), status=404)


def get_user_or_404(id: Int) raises NotFound -> UserText:
    if id == 0:
        raise NotFound(id)
    return UserText(id, "Ada")
# example: end
# fmt: on


# bodies.md, text bodies.


# fmt: off
# example: bodies-text-body
from muntin import App, FromBody


struct CreateUser(FromBody):              # defined by the application; may be move-only
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:   # the application owns the body format
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("expected name=<text>")
        return Self(String(body[byte=5:]))


def create_user(body: CreateUser) -> String:      # `var body: CreateUser` also works
    return "created " + body.name
# example: end
# fmt: on


# bodies.md, a route value then a body.


# fmt: off
# example: bodies-route-value-then-body
from muntin import App, FromBody


struct UpdateUser(FromBody):              # the name=<text> format of CreateUser above; may be move-only
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("expected name=<text>")
        return Self(String(body[byte=5:]))


def update_user(id: Int, body: UpdateUser) -> String:   # `var body: UpdateUser` also works
    return "user " + String(id) + " " + body.name
# example: end
# fmt: on


# testing.md, `TestClient` (`main` there).


# fmt: off
# example: testing-client
from muntin import App, Request, Response
from muntin.testing import TestClient


def hello() -> String:
    return "hello"


def client_example() raises:
    var app = App()
    app.get["/hello"](hello)          # compile-time route literal, runtime handler value

    var client = TestClient(app)      # borrows the app; no socket
    var response = client.get("/hello")
    print(response.status, response.text())            # 200 hello

    var direct = app.handle(Request("GET", "/hello"))  # backend seam
    print(direct.status, direct.text())                # 200 hello
    var custom = Response.text("ok", status=201)
    print(custom.status, custom.text())                # 201 ok
# example: end
# fmt: on


# testing.md, request header fields (`main` there).


# fmt: off
# example: testing-header-fields
from muntin import App, Headers, Request, Response
from muntin.testing import TestClient


def echo(req: Request) -> Response:                 # answers with every field it received
    var out = req.method + " " + req.path
    for i in range(len(req.headers)):
        out += " " + req.headers.name(i) + "=" + req.headers.value(i)
    return Response.text(out)


def header_fields_example() raises:                                   # building Headers raises
    var app = App()
    app.get["/echo"](echo)
    app.post["/echo"](echo)
    var client = TestClient(app)
    var headers = Headers()
    headers.add("X-Request-Id", "42")
    _ = client.get("/echo", headers=headers.copy())    # headers stays usable: "GET /echo X-Request-Id=42"
    _ = client.post("/echo", "body", headers=headers^)  # moved: "POST /echo X-Request-Id=42"
    _ = client.get("/echo")                             # no fields: "GET /echo"
# example: end
# fmt: on


def test_responses_to_response() raises:
    # fmt: off
    # example: responses-to-response
    var app = App()
    app.get["/users/{id}"](get_user)          # unchanged registration syntax
    app.get["/health"](health)
    # GET /users/7  -> 200 "7 Ada", no fields
    # GET /health   -> 200 "ok", no fields
    # example: end
    # fmt: on
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
    # fmt: off
    # example: errors-fixed-500
    var app = App()
    app.get["/users/{id}"](get_user_or_500)              # unchanged registration
    # GET /users/1   -> 200 "1 Ada", converted by `to_response`
    # GET /users/0   -> 500 "Internal Server Error"   (the error text is not sent)
    # GET /users/abc -> 400 "Bad Request"             (get_user_or_500 not called)
    # example: end
    # fmt: on
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
    # fmt: off
    # example: errors-to-error-response
    var app = App()
    app.get["/users/{id}"](get_user_or_404)
    # GET /users/1   -> 200 "1 Ada"              (UserText.to_response)
    # GET /users/0   -> 404 "no user 0"          (NotFound.to_error_response; nothing returned to convert)
    # GET /users/abc -> 400 "Bad Request"        (get_user_or_404 not called)
    # example: end
    # fmt: on
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
    # fmt: off
    # example: bodies-text-body
    var app = App()
    app.post["/users"](create_user)
    # POST /users  "name=Ada"       -> 200 "created Ada"   (create_user received the converted value)
    # POST /users  "Ada" or ""      -> 400 "Bad Request"   (from_body raised; create_user not called)
    # GET /users, PUT /users      -> 405 "Method Not Allowed", Allow: POST (from_body not called)
    # POST /missing                -> 404 "Not Found" (from_body not called)
    # example: end
    # fmt: on
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


def test_bodies_route_value_then_body() raises:
    var app = App()
    # fmt: off
    # example: bodies-route-value-then-body
    app.post["/users/{id}"](update_user)      # route value from a path segment
    app.post["/users?{id}"](update_user)      # or from a query item
    # POST /users/042     "name=Ada"  -> 200 "user 42 Ada"
    # POST /users?id=042  "name=Ada"  -> 200 "user 42 Ada"
    # POST /users/abc, /users?id=1&id=2, /users  (any body) -> 400 "Bad Request"  (from_body and update_user not called;
    #                                    /users matches the query route's path, so its missing id is 400)
    # POST /users/1       "Ada"       -> 400 "Bad Request"  (from_body raised; update_user not called)
    # PUT /users/1                    -> 405 "Method Not Allowed", Allow: POST  (nothing converted)
    # POST /users/1/x                 -> 404 "Not Found"    (nothing converted)
    # example: end
    # fmt: on
    var client = TestClient(app)
    for target in ["/users/042", "/users?id=042"]:
        var r = client.post(target, "name=Ada")
        assert_equal(r.status, 200)
        assert_equal(r.text(), "user 42 Ada")
    for target in ["/users/abc", "/users?id=1&id=2", "/users"]:
        for body in ["name=Ada", "Ada", ""]:
            var r = client.post(target, body)
            assert_equal(r.status, 400)
            assert_equal(r.text(), "Bad Request")
    var r = client.post("/users/1", "Ada")
    assert_equal(r.status, 400)
    assert_equal(r.text(), "Bad Request")
    r = client.put("/users/1", "name=Ada")
    assert_equal(r.status, 405)
    assert_equal(r.text(), "Method Not Allowed")
    assert_equal(r.headers.get("allow").value(), "POST")
    r = client.post("/users/1/x", "name=Ada")
    assert_equal(r.status, 404)
    assert_equal(r.text(), "Not Found")


def test_testing_client() raises:
    # The example runs as written; the asserts send its requests again.
    client_example()
    var app = App()
    app.get["/hello"](hello)
    var r = TestClient(app).get("/hello")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "hello")
    var direct = app.handle(Request("GET", "/hello"))
    assert_equal(direct.status, 200)
    assert_equal(direct.text(), "hello")
    var custom = Response.text("ok", status=201)
    assert_equal(custom.status, 201)
    assert_equal(custom.text(), "ok")


def test_testing_header_fields() raises:
    # The example runs as written; the asserts send its requests again.
    header_fields_example()
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
