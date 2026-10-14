# Route conflicts (M3-053, pull request #95): which registrations
# `_conflict` refuses, and that the orders it accepts dispatch every request
# to the most specific matching route. The abort itself is checked by
# tests/route_conflict_abort.
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import App, Request, Response
from muntin.app import _conflict, _covers, _overlaps
from muntin.testing import TestClient


def get_user(id: Int) -> String:
    return "user " + String(id)


def me() -> String:
    return "me"


def name_of(name: String) -> String:
    return "name " + name


def pair(a: String, b: String) -> String:
    return "pair " + a + "," + b


def post_of(a: String, b: Int) -> String:
    return "post " + a + "," + String(b)


def raw(req: Request) -> Response:
    return Response.text("raw " + req.path)


def test_covers_and_overlaps() raises:
    assert_true(_covers("/users/{id}", "/users/me"))
    assert_false(_covers("/users/me", "/users/{id}"))
    assert_true(_covers("/users/{id}", "/users/{name}"))
    assert_true(_covers("/{a}/{b}", "/a/{x}"))
    assert_false(_covers("/a/{x}", "/{y}/b"))
    assert_false(_covers("/users/{id}", "/users/{id}/posts"))
    assert_true(_overlaps("/a/{x}", "/{y}/b"))
    assert_true(_overlaps("/users/me", "/users/{id}"))
    assert_false(_overlaps("/users/me", "/users/you"))
    assert_false(_overlaps("/users/{id}", "/users/{id}/posts"))
    assert_false(_overlaps("/a/{x}", "/b/{x}"))
    # A placeholder matches no empty segment: `/` and `/{name}`, `/a/` and
    # `/a/{x}` share no request path.
    assert_false(_overlaps("/", "/{name}"))
    assert_false(_overlaps("/a/{x}", "/a/"))
    assert_false(_covers("/{name}", "/"))
    assert_false(_covers("/a/{x}", "/a/"))
    assert_true(_covers("/a/", "/a/"))


def _accepted() -> App:
    """Every pair of overlapping routes here is registered most specific
    first; none aborts."""
    var app = App()
    app.get["/users/me"](me)
    app.get["/users/{id}"](get_user)
    app.get["/a/b"](me)
    app.get["/a/{x}"](name_of)
    app.get["/raw/me"](raw)
    app.get["/raw/{name}"](name_of)
    app.get["/{x}/{y}"](pair)
    # Other methods and lengths never conflict.
    app.post["/users/{id}"](get_user)
    app.get["/users/{a}/posts/{b}"](post_of)
    return app^


def test_refused_registrations() raises:
    var app = _accepted()
    ref routes = app._routes
    assert_equal(
        _conflict(routes, "GET", "/users/{name}"),
        (
            "route conflict: GET /users/{name} matches the same requests as GET"
            " /users/{id}, registered earlier (the query takes no part in"
            " selection)"
        ),
    )
    assert_equal(
        _conflict(routes, "GET", "/users/you"),
        (
            "route conflict: GET /users/you is registered after GET"
            " /users/{id}, which matches every request it matches; register GET"
            " /users/you first"
        ),
    )
    assert_equal(
        _conflict(routes, "GET", "/users/me"),
        (
            "route conflict: GET /users/me matches the same requests as GET"
            " /users/me, registered earlier (the query takes no part in"
            " selection)"
        ),
    )
    assert_equal(
        _conflict(routes, "GET", "/{y}/b"),
        (
            "route conflict: GET /{y}/b and GET /users/{id}, registered"
            " earlier, both match some requests and neither is more specific"
        ),
    )
    # The first earlier route that conflicts is the one named.
    assert_equal(
        _conflict(routes, "GET", "/raw/all"),
        (
            "route conflict: GET /raw/all is registered after GET /raw/{name},"
            " which matches every request it matches; register GET /raw/all"
            " first"
        ),
    )


def test_accepted_registrations() raises:
    var app = _accepted()
    ref routes = app._routes
    # A more general route after more specific ones.
    assert_equal(_conflict(routes, "GET", "/{p}/{q}/{r}"), "")
    # The same path for another method.
    assert_equal(_conflict(routes, "PUT", "/users/{id}"), "")
    assert_equal(
        _conflict(routes, "POST", "/users/me"),
        (
            "route conflict: POST /users/me is registered after POST"
            " /users/{id}, which matches every request it matches; register"
            " POST /users/me first"
        ),
    )
    # No overlap: a different static segment or segment count, or an empty
    # segment where the earlier route has a placeholder.
    assert_equal(_conflict(routes, "GET", "/users/{a}/comments/{b}"), "")
    assert_equal(_conflict(routes, "GET", "/users/"), "")


def test_first_match_is_the_most_specific() raises:
    var app = _accepted()
    var client = TestClient(app)
    assert_equal(client.get("/users/me").text(), "me")
    assert_equal(client.get("/users/7").text(), "user 7")
    assert_equal(client.get("/users/x").status, 400)
    assert_equal(client.get("/a/b").text(), "me")
    assert_equal(client.get("/a/c").text(), "name c")
    assert_equal(client.get("/b/c").text(), "pair b,c")
    assert_equal(client.get("/raw/me").text(), "raw /raw/me")
    assert_equal(client.get("/raw/you").text(), "name you")
    assert_equal(client.post("/users/me", "").status, 400)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
