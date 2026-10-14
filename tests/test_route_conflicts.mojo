# Route conflicts (M3-053, pull request #95): which registrations
# `_conflict` refuses, that `App`'s `_RouteIndex` answers as `_conflict`
# does, and that the orders it accepts dispatch every request to the most
# specific matching route. The abort itself is checked by
# tests/route_conflict_abort.
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import App, Request, Response
from muntin.app import _RouteIndex, _conflict, _covers, _match, _overlaps
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


def _refusal(app: App, method: String, path: String) raises -> String:
    """The registration's answer, checked against `_conflict`."""
    ref index = app._route_index
    var answer = index.refusal(method, path)
    assert_equal(answer, _conflict(index.methods, index.paths, method, path))
    return answer


def test_refused_registrations() raises:
    var app = _accepted()
    assert_equal(
        _refusal(app, "GET", "/users/{name}"),
        (
            "route conflict: GET /users/{name} matches the same requests as GET"
            " /users/{id}, registered earlier (the query takes no part in"
            " selection)"
        ),
    )
    assert_equal(
        _refusal(app, "GET", "/users/you"),
        (
            "route conflict: GET /users/you is registered after GET"
            " /users/{id}, which matches every request it matches; register GET"
            " /users/you first"
        ),
    )
    assert_equal(
        _refusal(app, "GET", "/users/me"),
        (
            "route conflict: GET /users/me matches the same requests as GET"
            " /users/me, registered earlier (the query takes no part in"
            " selection)"
        ),
    )
    assert_equal(
        _refusal(app, "GET", "/{y}/b"),
        (
            "route conflict: GET /{y}/b and GET /users/{id}, registered"
            " earlier, both match some requests and neither is more specific"
        ),
    )
    # The first earlier route that conflicts is the one named.
    assert_equal(
        _refusal(app, "GET", "/raw/all"),
        (
            "route conflict: GET /raw/all is registered after GET /raw/{name},"
            " which matches every request it matches; register GET /raw/all"
            " first"
        ),
    )


def test_accepted_registrations() raises:
    var app = _accepted()
    # A more general route after more specific ones.
    assert_equal(_refusal(app, "GET", "/{p}/{q}/{r}"), "")
    # The same path for another method.
    assert_equal(_refusal(app, "PUT", "/users/{id}"), "")
    assert_equal(
        _refusal(app, "POST", "/users/me"),
        (
            "route conflict: POST /users/me is registered after POST"
            " /users/{id}, which matches every request it matches; register"
            " POST /users/me first"
        ),
    )
    # No overlap: a different static segment or segment count, or an empty
    # segment where the earlier route has a placeholder.
    assert_equal(_refusal(app, "GET", "/users/{a}/comments/{b}"), "")
    assert_equal(_refusal(app, "GET", "/users/"), "")


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


def test_index_names_the_first_conflicting_route() raises:
    # Routes of another method or segment count between the conflicting
    # one and the new route are passed over, and of two conflicting
    # earlier routes, the one without a placeholder found through `shapes`
    # and a later one with a placeholder, the earlier is named.
    var app = App()
    app.get["/a/{x}"](name_of)
    app.post["/a/{x}"](name_of)
    app.get["/a/b/c"](me)
    assert_equal(
        _refusal(app, "GET", "/a/b"),
        (
            "route conflict: GET /a/b is registered after GET /a/{x}, which"
            " matches every request it matches; register GET /a/b first"
        ),
    )
    var both = App()
    both.get["/a/b"](me)
    both.post["/c/{x}"](name_of)
    both.get["/{p}/{q}"](pair)
    assert_equal(
        _refusal(both, "GET", "/a/b"),
        (
            "route conflict: GET /a/b matches the same requests as GET /a/b,"
            " registered earlier (the query takes no part in selection)"
        ),
    )


def _alphabet() -> List[String]:
    """Every path of one to three segments from "", "a", "b" and "{x}"."""
    var parts = ["", "a", "b", "{x}"]
    var paths = List[String]()
    for n in range(1, 4):
        var count = 1
        for _ in range(n):
            count *= 4
        for k in range(count):
            var path = String()
            var rest = k
            for _ in range(n):
                path += "/" + parts[rest % 4]
                rest //= 4
            paths.append(path)
    return paths^


def test_index_answers_as_the_reference_scan() raises:
    # Pseudo-random registration sequences over `_alphabet()` and two
    # methods: before each registration the index and `_conflict` give the
    # same answer, and an accepted route is recorded in both.
    var paths = _alphabet()
    var methods = ["GET", "POST"]
    var seed = 12345
    var refused = 0
    for _ in range(3000):
        var index = _RouteIndex()
        var done_methods = List[String]()
        var done_paths = List[String]()
        for _ in range(12):
            seed = (seed * 1103515245 + 12345) % 2147483648
            var path = paths[(seed // 8) % len(paths)]
            var method = methods[(seed // 2) % 2]
            var answer = index.refusal(method, path)
            assert_equal(
                answer, _conflict(done_methods, done_paths, method, path)
            )
            if answer.byte_length() > 0:
                refused += 1
                continue
            index.add(method, path)
            done_methods.append(method)
            done_paths.append(path)
    # The sequences exercise refusals too, not only acceptances.
    assert_true(refused > 1000)


def test_accepted_routes_match_most_specific_first() raises:
    # Over the same sequences: for every request path, the first accepted
    # route that matches it is covered by every later one that does.
    var paths = _alphabet()
    var seed = 777
    var args = List[String]()
    for _ in range(300):
        var index = _RouteIndex()
        for _ in range(12):
            seed = (seed * 1103515245 + 12345) % 2147483648
            var path = paths[(seed // 8) % len(paths)]
            if index.refusal("GET", path).byte_length() == 0:
                index.add("GET", path)
        # Requests: the alphabet with "c" for each placeholder, so a
        # placeholder's own text never decides a match.
        for request in paths:
            var target = request.replace("{x}", "c")
            var first = -1
            for i in range(len(index.paths)):
                if not _match(index.paths[i], target, args):
                    continue
                if first < 0:
                    first = i
                else:
                    assert_true(_covers(index.paths[i], index.paths[first]))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
