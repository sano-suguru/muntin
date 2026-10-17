# Application route-value types (M3-055): a type conforming to
# `FromRouteValue` is a route value wherever a `String` is, converted from
# the decoded, non-empty text before the handler, a raise being 400.
# Through `App.handle` and `TestClient`: the reference's example as written,
# decoding, the empty value, conversion before the body, a move-only and an
# owned value, a `Param`, two values with a `String`, an `Int` or each
# other, `Headers`, `State`, and every method, bodyless included. The types
# and handlers are in tests/app_route_value_handlers.mojo. Decision:
# docs/history/architecture-decisions.md, "Application route-value types
# decision (M3-054)". Must-not-compile counterparts:
# tests/app_values_api_fail.

from std.testing import assert_equal, TestSuite

from muntin import App, Headers, State
from muntin.testing import TestClient
from app_route_value_handlers import (
    Prefix,
    make_app,
    name_then_user,
    named_pair,
    named_user,
    owned_user,
    stateful_user,
    text_value,
    touch,
    two_values_and_body,
    unreached_value,
    user_and_body,
    user_then_unreached,
    user_headers,
    user_then_int,
)


def _expect(app: App, target: String, status: Int, body: String) raises:
    var r = TestClient(app).get(target)
    assert_equal(r.status, status, target)
    assert_equal(r.text(), body, target)


def test_dx_example() raises:
    var app = make_app()
    _expect(app, "/users/u42", 200, "user 42")
    _expect(app, "/users/42", 400, "Bad Request")
    _expect(
        app, "/users/u42/posts?order=new", 200, "posts of user 42, newest first"
    )
    _expect(app, "/users/u42/posts?order=top", 400, "Bad Request")
    _expect(app, "/users/u42/posts", 400, "Bad Request")


def test_value_is_decoded_once_and_never_empty() raises:
    var app = App()
    app.get["/t/{v}"](text_value)
    app.get["/q?{v}"](text_value)
    _expect(app, "/t/a%20b", 200, "[a b]")
    _expect(app, "/t/a+b", 200, "[a+b]")
    _expect(app, "/t/%2541", 200, "[%41]")
    _expect(app, "/q?v=a+b", 200, "[a b]")
    # `Text` accepts the empty text, so these 400s come before it is called.
    _expect(app, "/q?v=", 400, "Bad Request")
    _expect(app, "/q", 400, "Bad Request")
    _expect(app, "/t/%zz", 400, "Bad Request")
    _expect(app, "/t/%FF", 400, "Bad Request")
    var app2 = make_app()
    _expect(app2, "/users/%7542", 200, "user 42")


def test_empty_or_missing_value_is_not_converted() raises:
    # `Unreached` ends the process if its conversion runs, so surviving these
    # requests shows the 400 came before it.
    var app = App()
    app.get["/q?{v}"](unreached_value)
    _expect(app, "/q?v=", 400, "Bad Request")
    _expect(app, "/q", 400, "Bad Request")
    _expect(app, "/q?v=1&v=2", 400, "Bad Request")


def test_a_raise_stops_the_later_conversions() raises:
    # The first value raises: neither the second value's conversion nor the
    # body's (both end the process if called) nor the handler runs.
    var app = App()
    app.post["/u/{id}/{x}"](user_then_unreached)
    var r = TestClient(app).post("/u/x1/anything", "body")
    assert_equal(r.status, 400)
    assert_equal(r.text(), "Bad Request")


def test_two_values_before_a_body() raises:
    var app = App()
    app.patch["/u/{id}?{order}"](two_values_and_body)
    var client = TestClient(app)
    assert_equal(client.patch("/u/u1?order=new", "z").text(), "1 new z")
    assert_equal(client.patch("/u/u1?order=top", "z").status, 400)


def test_value_converts_before_the_body() raises:
    # `NoBytes` takes at most 0 bytes: reaching it with one byte is 413, so a
    # 400 shows the value's raise came first and the body was not converted.
    var app = App()
    app.post["/u/{id}"](user_and_body)
    var client = TestClient(app)
    assert_equal(client.post("/u/x1", "z").status, 400)
    assert_equal(client.post("/u/u1", "z").status, 413)
    assert_equal(client.post("/u/u1", "").text(), "body for 1")


def test_named_and_owned_values() raises:
    var app = App()
    app.get["/n/{id}"](named_user)
    app.get["/p/{id}?{order}"](named_pair)
    app.get["/o/{id}"](owned_user)
    _expect(app, "/n/u7", 200, "named 7")
    _expect(app, "/n/7", 400, "Bad Request")
    _expect(app, "/p/u7?order=old", 200, "7 old")
    _expect(app, "/o/u8", 200, "owned 8")


def test_beside_other_slots() raises:
    var app = App()
    app.get["/s/{name}/{id}"](name_then_user)
    app.delete["/i/{id}/{n}"](user_then_int)
    app.get["/h/{id}"](user_headers)
    app.get["/st/{id}"](stateful_user, State(Prefix("p:")))
    var client = TestClient(app)
    _expect(app, "/s/a%20b/u5", 200, "a b/5")
    _expect(app, "/s/a/5", 400, "Bad Request")
    assert_equal(client.delete("/i/u1/2").text(), "1+2")
    assert_equal(client.delete("/i/u1/x").status, 400)
    var h = Headers()
    h.add("X-A", "1")
    assert_equal(client.get("/h/u3", headers=h^).text(), "3 1")
    _expect(app, "/st/u9", 200, "p:9")


def test_bodyless_on_post_put_and_patch() raises:
    var app = App()
    app.post["/a/{id}"](touch)
    app.put["/b/{id}"](touch)
    app.patch["/c/{id}"](touch)
    var client = TestClient(app)
    assert_equal(client.post("/a/u1", "ignored").text(), "touched 1")
    assert_equal(client.put("/b/u2", "").text(), "touched 2")
    assert_equal(client.patch("/c/u3", "").text(), "touched 3")
    assert_equal(client.put("/b/2", "").status, 400)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
