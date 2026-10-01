from std.testing import assert_equal, TestSuite

from muntin import App, Request, Response
from muntin.testing import TestClient


def hello() -> String:
    return "hello"


def goodbye() -> String:
    return "goodbye"


def get_user(id: Int) -> String:
    return String(id)


def user_posts(id: Int) -> String:
    return "posts of " + String(id)


def me() -> String:
    return "me"


def users_app() -> App:
    var app = App()
    app.get["/hello"](hello)
    app.get["/users/{id}"](get_user)
    app.get["/users/{id}/posts"](user_posts)
    return app^


def test_get_hello_through_test_client() raises:
    var app = App()
    app.get["/hello"](hello)

    var client = TestClient(app)
    var response = client.get("/hello")

    assert_equal(response.status, 200)
    assert_equal(response.text(), "hello")


def test_get_hello_through_backend_seam() raises:
    var app = App()
    app.get["/hello"](hello)

    var response = app.handle(Request("GET", "/hello"))

    assert_equal(response.status, 200)
    assert_equal(response.text(), "hello")


def test_router_selects_matching_route() raises:
    var app = App()
    app.get["/hello"](hello)
    app.get["/goodbye"](goodbye)

    var client = TestClient(app)

    assert_equal(client.get("/goodbye").text(), "goodbye")
    assert_equal(client.get("/hello").text(), "hello")


def test_unregistered_path_is_not_found() raises:
    var app = App()
    app.get["/hello"](hello)

    var response = TestClient(app).get("/missing")

    assert_equal(response.status, 404)


def test_method_mismatch_is_not_found() raises:
    var app = App()
    app.get["/hello"](hello)

    var response = app.handle(Request("POST", "/hello"))

    assert_equal(response.status, 404)


def test_response_text_constructor() raises:
    var response = Response.text("ok", status=201)

    assert_equal(response.status, 201)
    assert_equal(response.text(), "ok")


def test_path_parameter_reaches_handler_as_int() raises:
    var app = users_app()
    var client = TestClient(app)

    var response = client.get("/users/42")
    assert_equal(response.status, 200)
    assert_equal(response.text(), "42")
    # The handler's output differs from the raw segment, so it saw an Int.
    assert_equal(client.get("/users/042").text(), "42")
    assert_equal(client.get("/users/-7").text(), "-7")
    assert_equal(client.get("/users/7").text(), "7")


def test_path_parameter_before_static_segment() raises:
    var app = users_app()
    var client = TestClient(app)

    var response = client.get("/users/42/posts")
    assert_equal(response.status, 200)
    assert_equal(response.text(), "posts of 42")
    assert_equal(client.get("/users/42/likes").status, 404)


def test_invalid_int_is_bad_request() raises:
    var app = users_app()
    var client = TestClient(app)

    # Forms Mojo's Int(String) would accept are rejected too.
    for segment in ["abc", "+42", "%2042", "4_2", "-", "1e3", "0x2a"]:
        var response = client.get("/users/" + segment)
        assert_equal(response.status, 400, segment)
        assert_equal(response.text(), "Bad Request", segment)
    assert_equal(client.get("/users/ 42").status, 400)
    assert_equal(client.get("/users/9223372036854775808").status, 400)
    assert_equal(client.get("/users/abc/posts").status, 400)


def test_int_range_limits() raises:
    var app = users_app()
    var client = TestClient(app)

    assert_equal(
        client.get("/users/9223372036854775807").text(), "9223372036854775807"
    )
    assert_equal(
        client.get("/users/-9223372036854775808").text(),
        "-9223372036854775808",
    )


def test_typed_route_does_not_match_other_paths() raises:
    var app = users_app()
    var client = TestClient(app)

    for path in ["/users", "/users/", "/users/42/", "/user/42", "/users/1/2"]:
        assert_equal(client.get(path).status, 404, path)
    assert_equal(app.handle(Request("POST", "/users/42")).status, 404)


def test_exact_and_typed_routes_share_one_app() raises:
    var app = users_app()
    var client = TestClient(app)

    assert_equal(client.get("/hello").text(), "hello")
    assert_equal(client.get("/users/5").text(), "5")
    assert_equal(client.get("/hello/5").status, 404)


def test_first_registered_matching_route_wins() raises:
    var app = App()
    app.get["/users/me"](me)
    app.get["/users/{id}"](get_user)
    app.get["/users/{id}/posts"](user_posts)
    app.get["/users/7"](me)
    var client = TestClient(app)

    assert_equal(client.get("/users/me").text(), "me")
    assert_equal(client.get("/users/7").text(), "7")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
