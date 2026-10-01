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


def list_items(limit: Int) -> String:
    return "items " + String(limit)


def users_app() -> App:
    var app = App()
    app.get["/hello"](hello)
    app.get["/users/{id}"](get_user)
    app.get["/users/{id}/posts"](user_posts)
    app.get["/items?{limit}"](list_items)
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


def test_request_splits_target_at_first_question_mark() raises:
    var plain = Request("GET", "/users/42")
    assert_equal(plain.path, "/users/42")
    assert_equal(plain.query, "")

    var with_query = Request("GET", "/users/42?x=1&y=2")
    assert_equal(with_query.path, "/users/42")
    assert_equal(with_query.query, "x=1&y=2")

    var empty_query = Request("GET", "/a?")
    assert_equal(empty_query.path, "/a")
    assert_equal(empty_query.query, "")

    var second_mark = Request("GET", "/a?b=1?c=2")
    assert_equal(second_mark.path, "/a")
    assert_equal(second_mark.query, "b=1?c=2")


def test_route_matching_ignores_the_query() raises:
    var app = users_app()
    var client = TestClient(app)

    assert_equal(client.get("/hello?x=1").status, 200)
    assert_equal(client.get("/hello?x=1").text(), "hello")
    # The path Int comes from "42", not from "42?x=1".
    assert_equal(client.get("/users/42?x=1").text(), "42")
    assert_equal(client.get("/users/042?id=7").text(), "42")
    assert_equal(client.get("/users/42/posts?x").text(), "posts of 42")
    assert_equal(client.get("/users/abc?x=1").status, 400)
    assert_equal(client.get("/missing?x=1").status, 404)
    assert_equal(client.get("/users?id=42").status, 404)


def test_query_parameter_reaches_handler_as_int() raises:
    var app = users_app()
    var client = TestClient(app)

    var response = client.get("/items?limit=10")
    assert_equal(response.status, 200)
    assert_equal(response.text(), "items 10")
    # The handler's output differs from the raw value, so it saw an Int.
    assert_equal(client.get("/items?limit=010").text(), "items 10")
    assert_equal(client.get("/items?limit=-3").text(), "items -3")
    assert_equal(
        client.get("/items?limit=9223372036854775807").text(),
        "items 9223372036854775807",
    )


def test_unrelated_query_keys_are_ignored() raises:
    var app = users_app()
    var client = TestClient(app)

    for target in [
        "/items?other=z&limit=10",
        "/items?limit=10&other",
        "/items?&&limit=10&",
        "/items?limits=1&limit=10&Limit=2&=3",
        "/items?limit=10&x=a=b",
    ]:
        assert_equal(client.get(target).text(), "items 10", target)


def test_missing_query_parameter_is_bad_request() raises:
    var app = users_app()
    var client = TestClient(app)

    for target in [
        "/items",
        "/items?",
        "/items?other=10",
        "/items?Limit=10",
        "/items?limits=10",
        "/items?lim%69t=10",
    ]:
        var response = client.get(target)
        assert_equal(response.status, 400, target)
        assert_equal(response.text(), "Bad Request", target)


def test_invalid_query_value_is_bad_request() raises:
    var app = users_app()
    var client = TestClient(app)

    for target in [
        "/items?limit=",
        "/items?limit",
        "/items?limit=abc",
        "/items?limit=+10",
        "/items?limit= 10",
        "/items?limit=%2010",
        "/items?limit=1_0",
        "/items?limit=%31%30",
        "/items?limit=10#x",
        "/items?limit=9223372036854775808",
    ]:
        var response = client.get(target)
        assert_equal(response.status, 400, target)
        assert_equal(response.text(), "Bad Request", target)


def test_duplicate_query_key_is_bad_request() raises:
    var app = users_app()
    var client = TestClient(app)

    for target in [
        "/items?limit=1&limit=2",
        "/items?limit=1&limit=1",
        "/items?limit=1&limit",
    ]:
        var response = client.get(target)
        assert_equal(response.status, 400, target)
        assert_equal(response.text(), "Bad Request", target)


def test_query_route_does_not_match_other_paths_or_methods() raises:
    var app = users_app()
    var client = TestClient(app)

    for target in ["/items/?limit=1", "/item?limit=1", "/items/1?limit=1"]:
        assert_equal(client.get(target).status, 404, target)
    assert_equal(app.handle(Request("POST", "/items?limit=1")).status, 404)


def test_query_does_not_take_part_in_route_selection() raises:
    var app = App()
    app.get["/items?{limit}"](list_items)
    app.get["/items"](hello)
    var client = TestClient(app)

    # The first route matches on path alone; a missing key is 400 there,
    # not a fall-through to the later route.
    assert_equal(client.get("/items?limit=5").text(), "items 5")
    assert_equal(client.get("/items").status, 400)


def test_query_binding_is_positional() raises:
    var app = App()
    # The key need not match the handler's parameter name (`limit`).
    app.get["/items?{count}"](list_items)
    var client = TestClient(app)

    assert_equal(client.get("/items?count=3").text(), "items 3")
    assert_equal(client.get("/items?limit=3").status, 400)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
