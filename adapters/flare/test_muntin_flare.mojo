"""Socket-free contract tests for the Flare adapter (M1-002).

Runs only in the `flare` pixi environment (see scripts/check_flare.sh). Every
dispatch goes through `MuntinHandler.serve`, the entry point Flare's server
calls, and from there through the real `App.handle`.
"""

from std.testing import assert_equal, TestSuite

from flare.http import Request as FlareRequest, Response as FlareResponse
from muntin import App, Response
from muntin.testing import TestClient
from muntin_flare import MuntinHandler, to_flare_response, to_muntin_request


def hello() -> String:
    return "hello"


def goodbye() -> String:
    return "goodbye"


def list_items(limit: Int) -> String:
    return "items " + String(limit)


def app_with_routes() -> App:
    var app = App()
    app.get["/hello"](hello)
    app.get["/goodbye"](goodbye)
    app.get["/items?{limit}"](list_items)
    return app^


def test_request_conversion_keeps_method_target_and_body() raises:
    var request = to_muntin_request(
        FlareRequest("POST", "/items?page=1&x", body=List("ping".as_bytes()))
    )

    assert_equal(request.method, "POST")
    # The adapter passes the target verbatim; Muntin's Request splits it.
    assert_equal(request.path, "/items")
    assert_equal(request.query, "page=1&x")
    assert_equal(request.body, "ping")


def test_request_body_is_decoded_as_lossy_utf8() raises:
    var bytes = List("hé".as_bytes())
    bytes.append(0xFF)

    var request = to_muntin_request(FlareRequest("POST", "/", body=bytes^))

    assert_equal(request.body, "hé�")


def test_response_conversion_keeps_status_and_body() raises:
    var response = to_flare_response(Response.text("created", status=201))

    assert_equal(response.status, 201)
    assert_equal(response.text(), "created")


def test_registered_routes_dispatch_through_app_handle() raises:
    var handler = MuntinHandler(app_with_routes())

    var hello_response = handler.serve(FlareRequest("GET", "/hello"))
    var goodbye_response = handler.serve(FlareRequest("GET", "/goodbye"))

    assert_equal(hello_response.status, 200)
    assert_equal(hello_response.text(), "hello")
    assert_equal(goodbye_response.status, 200)
    assert_equal(goodbye_response.text(), "goodbye")


def test_unmatched_path_is_not_found() raises:
    var handler = MuntinHandler(app_with_routes())

    var response = handler.serve(FlareRequest("GET", "/missing"))

    assert_equal(response.status, 404)
    assert_equal(response.text(), "Not Found")


def test_unmatched_method_is_not_found() raises:
    var handler = MuntinHandler(app_with_routes())

    var response = handler.serve(FlareRequest("POST", "/hello"))

    assert_equal(response.status, 404)
    assert_equal(response.text(), "Not Found")


def test_adapter_matches_in_memory_backend() raises:
    var handler = MuntinHandler(app_with_routes())
    var client = TestClient(handler.app)

    for path in [
        "/hello",
        "/goodbye",
        "/missing",
        "/hello?x=1",
        "/items?limit=010",
        "/items?limit=abc",
        "/items?limit=1&limit=2",
        "/items",
    ]:
        var expected = client.get(path)
        var actual = handler.serve(FlareRequest("GET", path))
        assert_equal(actual.status, expected.status, path)
        assert_equal(actual.text(), expected.text(), path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
