# 405 with `Allow` (M3-031): when no route matches a request's method and
# path but some route's path matches it (`_match`, nothing decoded), the
# answer is 405 `Method Not Allowed` with one `Allow` field listing those
# routes' methods once, in first-registration order, `HEAD` right after
# `GET`; otherwise 404 as before. Every method is answered alike. The `App`
# and the requests are the measured premise's, as written. Decision:
# docs/history/architecture-decisions.md, "Method not allowed decision
# (M3-030)".

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import App, FromBody, Request, Response, State
from muntin.testing import TestClient

# Handlers are thin functions and cannot capture state, so handler calls,
# body conversions and the method a raw handler receives are recorded in
# environment variables.
comptime HANDLER_CALLS = "MUNTIN_TEST_405_HANDLER_CALLS"
comptime CONVERSIONS = "MUNTIN_TEST_405_CONVERSIONS"
comptime RAW_METHOD = "MUNTIN_TEST_405_RAW_METHOD"


def _reset():
    _ = unsetenv(HANDLER_CALLS)
    _ = unsetenv(CONVERSIONS)
    _ = unsetenv(RAW_METHOD)


def _count(name: StaticString) -> Int:
    var n = getenv(name)
    try:
        return Int(n) if n else 0
    except:
        return -1


def _bump(name: StaticString):
    _ = setenv(name, String(_count(name) + 1))


struct Note(FromBody):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(CONVERSIONS)
        return Self(body)


@fieldwise_init
struct Db(Movable):
    var name: String


def me() -> String:
    _bump(HANDLER_CALLS)
    return "me"


def delete_user(id: Int) -> String:
    _bump(HANDLER_CALLS)
    return String("deleted ", id)


def get_user(id: Int) -> String:
    _bump(HANDLER_CALLS)
    return String("user ", id)


def update_user(id: Int, body: Note) -> String:
    _bump(HANDLER_CALLS)
    return String("updated ", id, " ", body.text)


def create_user(body: Note) -> String:
    _bump(HANDLER_CALLS)
    return "created " + body.text


def search(q: String) -> String:
    _bump(HANDLER_CALLS)
    return "search " + q


def report(req: Request) -> Response:
    """Raw: the same body for `GET` and `HEAD` (DX), the method recorded."""
    _bump(HANDLER_CALLS)
    _ = setenv(RAW_METHOD, req.method)
    return Response.text("report")


def hook(req: Request) -> Response:
    _bump(HANDLER_CALLS)
    return Response.text("hook")


def put_item(name: String, body: Note) -> String:
    _bump(HANDLER_CALLS)
    return "put " + name


def show_item(name: String) -> String:
    _bump(HANDLER_CALLS)
    return "item " + name


def premise_app() -> App:
    """The measured premise's `App`, registered in its order."""
    var app = App()
    app.get["/users/me"](me)
    app.delete["/users/{id}"](delete_user)
    app.get["/users/{id}"](get_user)
    app.put["/users/{id}"](update_user)
    app.post["/users"](create_user)
    app.get["/search?{q}"](search)
    app.get["/report"](report)
    app.post["/hooks"](hook)
    app.put["/items/{name}"](put_item)
    app.get["/items/{name}"](show_item)
    app.get["/items/{name}"](show_item)
    return app^


def raw_post(req: Request) -> Response:
    return Response.text("post")


def raw_get(req: Request) -> Response:
    return Response.text("get")


def two_route_app() -> App:
    """Raw `post` registered before raw `get` on one path."""
    var app = App()
    app.post["/a"](raw_post)
    app.get["/a"](raw_get)
    return app^


def save_note(db: State[Db], id: Int, body: Note) -> String:
    _bump(HANDLER_CALLS)
    return String("saved ", id)


def read_note(db: State[Db], id: Int) -> String:
    _bump(HANDLER_CALLS)
    return String("note ", id)


def list_notes(db: State[Db], req: Request) -> Response:
    _bump(HANDLER_CALLS)
    return Response.text("notes")


def drop_note(id: Int) -> String:
    _bump(HANDLER_CALLS)
    return String("dropped ", id)


def stateful_app() -> App:
    """A stateful `post`, a stateful `get` and a stateless `delete` on one
    path, and a stateful raw `get` on another."""
    var db = State(Db("notes"))
    var app = App()
    app.post["/notes/{id}"](save_note, db)
    app.get["/notes/{id}"](read_note, db)
    app.delete["/notes/{id}"](drop_note)
    app.get["/notes"](list_notes, db)
    return app^


def _send(app: App, method: String, target: String) -> Response:
    return app.handle(Request(method, target, "x"))


def _expect(
    app: App, method: String, target: String, status: Int, body: String
) raises:
    var response = _send(app, method, target)
    assert_equal(response.status, status, method + " " + target)
    assert_equal(response.body, body, method + " " + target)
    assert_equal(len(response.headers.get_all("Allow")), 0)


def _expect_404(app: App, method: String, target: String) raises:
    var response = _send(app, method, target)
    assert_equal(response.status, 404, method + " " + target)
    assert_equal(response.body, "Not Found")
    assert_equal(len(response.headers), 0)


# Each method sent to a 405 row's target: a method in `Allow` selects a
# route, any other is 405 with the same `Allow`.
def _probes() -> List[String]:
    return [
        "GET",
        "HEAD",
        "POST",
        "PUT",
        "PATCH",
        "DELETE",
        "OPTIONS",
        "FOO",
        "get",
        "head",
    ]


def _expect_405(app: App, method: String, target: String, allow: String) raises:
    """405, the fixed body and exactly one field, `Allow: allow`, whose
    tokens do not repeat; each probe method in it selects a route on
    `target` and each probe method not in it is 405 with the same `Allow`.
    """
    var response = _send(app, method, target)
    var request = method + " " + target
    assert_equal(response.status, 405, request)
    assert_equal(response.body, "Method Not Allowed", request)
    assert_equal(len(response.headers), 1, request)
    var allows = response.headers.get_all("Allow")
    assert_equal(len(allows), 1, request)
    assert_equal(allows[0], allow, request)
    var listed = List[String]()
    for token in allow.split(", "):
        assert_false(String(token) in listed, request + ": " + allow)
        listed.append(String(token))
    for probe in _probes():
        var answer = _send(app, probe, target)
        if probe in listed:
            assert_true(
                answer.status != 404 and answer.status != 405,
                probe + " " + target,
            )
        else:
            assert_equal(answer.status, 405, probe + " " + target)
            assert_equal(answer.headers.get_all("Allow")[0], allow)


def test_premise_table_matched_requests_are_unchanged() raises:
    var app = premise_app()
    _expect(app, "POST", "/users", 200, "created x")
    _expect(app, "GET", "/users/me", 200, "me")
    _expect(app, "HEAD", "/users/me", 200, "me")
    _expect(app, "PUT", "/users/me", 400, "Bad Request")
    _expect(app, "DELETE", "/users/me", 400, "Bad Request")
    _expect(app, "GET", "/users/7", 200, "user 7")
    _expect(app, "HEAD", "/users/7", 200, "user 7")
    _expect(app, "GET", "/users/abc", 400, "Bad Request")
    _expect(app, "GET", "/search?q=a", 200, "search a")
    _expect(app, "GET", "/search", 400, "Bad Request")
    _reset()
    _expect(app, "GET", "/report", 200, "report")
    assert_equal(getenv(RAW_METHOD), "GET")
    _expect(app, "HEAD", "/report", 200, "report")
    assert_equal(getenv(RAW_METHOD), "HEAD")


def test_premise_table_method_mismatch_is_405_with_allow() raises:
    var app = premise_app()
    for method in ["GET", "HEAD", "OPTIONS"]:
        _expect_405(app, method, "/users", "POST")
    # Static and parameterized routes both match.
    _expect_405(app, "POST", "/users/me", "GET, HEAD, DELETE, PUT")
    for method in ["POST", "PATCH", "OPTIONS", "FOO", "get", "head"]:
        _expect_405(app, method, "/users/7", "DELETE, GET, HEAD, PUT")
    # An invalid `Int` and a bad escape: nothing is decoded or converted.
    _expect_405(app, "POST", "/users/abc", "DELETE, GET, HEAD, PUT")
    _expect_405(app, "POST", "/users/%zz", "DELETE, GET, HEAD, PUT")
    # The query takes no part; a required value need not be present.
    _expect_405(app, "POST", "/search?q=a", "GET, HEAD")
    _expect_405(app, "POST", "/search", "GET, HEAD")
    _expect_405(app, "POST", "/report", "GET, HEAD")
    _expect_405(app, "GET", "/hooks", "POST")
    _expect_405(app, "HEAD", "/hooks", "POST")
    # One method on two routes is listed once.
    _expect_405(app, "PATCH", "/items/a", "PUT, GET, HEAD")


def test_premise_table_no_path_match_is_404() raises:
    var app = premise_app()
    _expect_404(app, "POST", "/users/")
    _expect_404(app, "POST", "/users/7/x")
    _expect_404(app, "POST", "/missing")
    _expect_404(app, "OPTIONS", "/missing")
    _expect_404(app, "GET", "http://h/users")


def test_allow_follows_registration_order() raises:
    var app = two_route_app()
    _expect_405(app, "PUT", "/a", "POST, GET, HEAD")
    _expect_405(app, "OPTIONS", "/a", "POST, GET, HEAD")


def test_stateful_routes_count_like_stateless_ones() raises:
    var app = stateful_app()
    _expect_405(app, "PATCH", "/notes/1", "POST, GET, HEAD, DELETE")
    _expect_405(app, "PUT", "/notes/x", "POST, GET, HEAD, DELETE")
    _expect_405(app, "PATCH", "/notes", "GET, HEAD")
    _expect_404(app, "PATCH", "/notes/1/x")


def test_405_runs_no_handler_and_no_body_conversion() raises:
    var app = premise_app()
    var notes = stateful_app()
    _reset()
    _ = _send(app, "POST", "/users/7")
    _ = _send(app, "PATCH", "/items/a")
    _ = _send(app, "POST", "/users/%zz")
    _ = _send(app, "GET", "/users")
    _ = _send(app, "POST", "/report")
    _ = _send(app, "GET", "/hooks")
    _ = _send(notes, "PATCH", "/notes/1")
    _ = _send(notes, "POST", "/notes")
    _ = _send(app, "POST", "/missing")
    assert_equal(_count(HANDLER_CALLS), 0)
    assert_equal(_count(CONVERSIONS), 0)
    assert_equal(getenv(RAW_METHOD), "")


def _same(a: Response, b: Response, allow: String) raises:
    assert_equal(a.status, 405)
    assert_equal(b.status, 405)
    assert_equal(a.body, b.body)
    assert_equal(len(a.headers), 1)
    assert_equal(len(b.headers), 1)
    assert_equal(a.headers.get_all("Allow")[0], allow)
    assert_equal(b.headers.get_all("Allow")[0], allow)


def test_test_client_equals_app_handle() raises:
    var app = premise_app()
    var client = TestClient(app)
    _same(
        client.post("/users/me", "x"),
        app.handle(Request("POST", "/users/me", "x")),
        "GET, HEAD, DELETE, PUT",
    )
    _same(client.get("/users"), app.handle(Request("GET", "/users")), "POST")
    _same(
        client.put("/search", "x"),
        app.handle(Request("PUT", "/search", "x")),
        "GET, HEAD",
    )
    _same(
        client.patch("/items/a", "x"),
        app.handle(Request("PATCH", "/items/a", "x")),
        "PUT, GET, HEAD",
    )
    _same(
        client.delete("/report"),
        app.handle(Request("DELETE", "/report")),
        "GET, HEAD",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
