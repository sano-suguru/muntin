from std.testing import assert_equal, TestSuite

from muntin import App, Request, Response
from muntin.testing import TestClient


def hello() -> String:
    return "hello"


def goodbye() -> String:
    return "goodbye"


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
