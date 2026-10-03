# Stateful POST handlers in production (M3-006): the four `App.post`
# overloads taking `(handler, state)`, `def(State[S], B)` and
# `def(State[S], Int, B)`, each returning `String` or `R: ToResponse`,
# driven through `TestClient`. Decision: docs/ARCHITECTURE.md, "Application
# state decision (M3-001)". Must-not-compile counterparts:
# tests/state_post_fail and tests/compile_fail/state_post_*.

from std.memory import ArcPointer
from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, TestSuite

from muntin import (
    App,
    FromBody,
    Headers,
    Request,
    Response,
    State,
    ToErrorResponse,
    ToResponse,
)
from muntin.testing import TestClient

# `from_body` is static and cannot see the state, so its calls are counted
# in an environment variable; handler calls are counted in the state.
comptime FROM_BODY_CALLS = "MUNTIN_TEST_STATE_POST_FROM_BODY_CALLS"


def _reset():
    _ = unsetenv(FROM_BODY_CALLS)


def _from_body_calls() -> Int:
    var n = getenv(FROM_BODY_CALLS)
    try:
        return Int(n) if n else 0
    except:
        return -1


def _bump_from_body():
    _ = setenv(FROM_BODY_CALLS, String(_from_body_calls() + 1))


# Application types.


struct Users(Movable):
    """A move-only in-memory repository. Every handler call is counted in
    `calls`, which the application keeps mutable on purpose (its own
    `ArcPointer[Int]` field, not Muntin's): the counter is the oracle for
    "handler not called"."""

    var names: List[String]
    var calls: ArcPointer[Int]

    def __init__(out self, var names: List[String]):
        self.names = names^
        self.calls = ArcPointer(0)

    def count(self):
        self.calls[] += 1

    def get(self, id: Int) raises NotFound -> String:
        if id < 0 or id >= len(self.names):
            raise NotFound(id)
        return self.names[id]


struct CreateUser(FromBody):
    """A move-only request body (not `Copyable`) in `name=<text>` format."""

    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump_from_body()
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("expected name=<text>")
        return Self(String(body[byte=5:]))


struct Note(FromBody):
    """Accepts any body unchanged, so a body that is itself an integer
    shows which source fills which parameter."""

    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump_from_body()
        return Self(body)


struct Tracked(Movable):
    """Records its own destruction in a shared counter held by the test."""

    var drops: ArcPointer[Int]

    def __init__(out self, drops: ArcPointer[Int]):
        self.drops = drops.copy()

    def __deinit__(deinit self):
        self.drops[] += 1


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):
    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("no user " + String(self.id), status=404)


@fieldwise_init
struct Rejected(Movable):
    """An application error type without `ToErrorResponse`: fixed 500."""

    var reason: String


@fieldwise_init
struct User(Movable, ToResponse):
    var id: Int
    var name: String

    def to_response(var self) -> Response:
        return Response.text(String(self.id) + ":" + self.name, status=201)


# Stateful POST handlers: `State[S]` first, then `def(B)` or `def(Int, B)`.


def add_user(users: State[Users], body: CreateUser) -> String:
    users[].count()
    return users[].names[0] + " adds " + body.name


def create_user(users: State[Users], var body: CreateUser) -> User:
    users[].count()
    return User(len(users[].names), body.name)


def rename(
    users: State[Users], id: Int, body: CreateUser
) raises NotFound -> String:
    users[].count()
    return users[].get(id) + " -> " + body.name


def replace_user(
    users: State[Users], id: Int, var body: CreateUser
) raises NotFound -> User:
    users[].count()
    return User(id, users[].get(id) + "/" + body.name)


def annotate(users: State[Users], id: Int, note: Note) -> String:
    # "users 2 id 5 note 7" only if the state, the route value and the
    # body each reached their own parameter.
    users[].count()
    return (
        "users "
        + String(len(users[].names))
        + " id "
        + String(id)
        + " note "
        + note.text
    )


def reject(users: State[Users], body: CreateUser) raises Rejected -> String:
    users[].count()
    raise Rejected("secret " + body.name)


def fail_at(users: State[Users], id: Int, body: Note) raises -> User:
    users[].count()
    raise Error("secret detail " + String(id))


def missing_body(users: State[Users], body: CreateUser) raises NotFound -> User:
    users[].count()
    raise NotFound(9)


def handles(users: State[Users], body: Note) -> String:
    # Reads the handle's reference count from inside a request.
    return String(users._shared.count())


def handles_at(users: State[Users], id: Int, body: Note) -> String:
    # The same, from the `def(State[S], Int, B)` shape.
    return String(users._shared.count())


def handles_typed(users: State[Users], body: Note) -> User:
    # The same, from the `def(State[S], B) -> R: ToResponse` shape.
    return User(Int(users._shared.count()), body.text)


def handles_typed_at(users: State[Users], id: Int, body: Note) -> User:
    # The same, from the `def(State[S], Int, B) -> R: ToResponse` shape.
    return User(Int(users._shared.count()), body.text)


def track(tracked: State[Tracked], body: Note) -> String:
    return String(tracked[].drops[]) + " " + body.text


def later(users: State[Users], body: Note) -> String:
    return "later"


# Stateless M2 POST handlers, registered on the same app.


def plain_create(body: CreateUser) -> String:
    return "plain " + body.name


def plain_update(id: Int, body: CreateUser) -> String:
    return "plain " + String(id) + " " + body.name


def _users() -> State[Users]:
    var names = List[String]()
    names.append("ada")
    names.append("bob")
    return State(Users(names^))


def _calls(users: State[Users]) -> Int:
    return users[].calls[]


def _handles(users: State[Users]) -> Int:
    return Int(users._shared.count())


# Tests.


def test_post_shapes_and_results() raises:
    _reset()
    var users = _users()
    var app = App()
    app.post["/add"](add_user, users)
    app.post["/users"](create_user, users)
    app.post["/rename/{id}"](rename, users)
    app.post["/rename?{id}"](rename, users)
    app.post["/users/{id}"](replace_user, users)
    var client = TestClient(app)
    var added = client.post("/add", "name=cy")
    assert_equal(added.status, 200)
    assert_equal(added.body, "ada adds cy")
    var created = client.post("/users", "name=cy")
    assert_equal(created.status, 201)
    assert_equal(created.body, "2:cy")
    assert_equal(client.post("/rename/1", "name=cy").body, "bob -> cy")
    assert_equal(client.post("/rename?id=01", "name=cy").body, "bob -> cy")
    var replaced = client.post("/users/0", "name=cy")
    assert_equal(replaced.status, 201)
    assert_equal(replaced.body, "0:ada/cy")
    assert_equal(_calls(users), 5)
    assert_equal(_from_body_calls(), 5)


def test_state_route_value_and_body_reach_their_parameters() raises:
    _reset()
    var users = _users()
    var app = App()
    app.post["/notes/{id}"](annotate, users)
    app.post["/notes?{id}"](annotate, users)
    var client = TestClient(app)
    assert_equal(client.post("/notes/5", "7").body, "users 2 id 5 note 7")
    assert_equal(client.post("/notes/-05", "").body, "users 2 id -5 note ")
    assert_equal(
        client.post("/notes?id=3", "x=1").body, "users 2 id 3 note x=1"
    )
    assert_equal(_calls(users), 3)


def test_bad_body_is_400_before_the_handler() raises:
    _reset()
    var users = _users()
    var app = App()
    app.post["/add"](add_user, users)
    app.post["/users"](create_user, users)
    app.post["/rename/{id}"](rename, users)
    app.post["/users/{id}"](replace_user, users)
    var client = TestClient(app)
    for target in ["/add", "/users", "/rename/1", "/users/1"]:
        for body in ["", "name=", "ada"]:
            var got = client.post(target, body)
            assert_equal(got.status, 400, target)
            assert_equal(got.body, "Bad Request", target)
    assert_equal(_calls(users), 0)
    assert_equal(_from_body_calls(), 12)


def test_bad_route_value_is_400_before_the_body() raises:
    # `from_body` is never called: the route value fails first.
    _reset()
    var users = _users()
    var app = App()
    app.post["/rename/{id}"](rename, users)
    app.post["/rename?{id}"](rename, users)
    app.post["/users/{id}"](replace_user, users)
    var client = TestClient(app)
    for target in [
        "/rename/x",
        "/rename/+1",
        "/users/1_0",
        "/rename",
        "/rename?id=",
        "/rename?id=x",
        "/rename?id=1&id=2",
        "/rename?other=1",
    ]:
        var got = client.post(target, "name=cy")
        assert_equal(got.status, 400, target)
        assert_equal(got.body, "Bad Request", target)
    for target in ["/missing", "/users", "/users/1/x", "/rename/1/x"]:
        var got = client.post(target, "name=cy")
        assert_equal(got.status, 404, target)
        assert_equal(got.body, "Not Found", target)
    assert_equal(client.get("/users/1").status, 404)
    assert_equal(_calls(users), 0)
    assert_equal(_from_body_calls(), 0)


def test_errors_use_the_m2_model() raises:
    _reset()
    var users = _users()
    var app = App()
    app.post["/rename/{id}"](rename, users)
    app.post["/users/{id}"](replace_user, users)
    app.post["/reject"](reject, users)
    app.post["/fail/{id}"](fail_at, users)
    app.post["/missing"](missing_body, users)
    var client = TestClient(app)
    var missing = client.post("/rename/9", "name=cy")
    assert_equal(missing.status, 404)
    assert_equal(missing.body, "no user 9")
    var typed = client.post("/users/9", "name=cy")
    assert_equal(typed.status, 404)
    assert_equal(typed.body, "no user 9")
    assert_equal(client.post("/missing", "name=cy").body, "no user 9")
    for target in ["/reject", "/fail/1"]:
        var failed = client.post(target, "name=cy")
        assert_equal(failed.status, 500, target)
        assert_equal(failed.body, "Internal Server Error", target)
    assert_equal(_calls(users), 5)


def test_first_registration_wins() raises:
    _reset()
    var users = _users()
    var app = App()
    app.post["/add"](add_user, users)
    app.post["/add"](later, users)
    app.post["/later"](later, users)
    app.post["/later"](add_user, users)
    app.post["/plain"](plain_create)
    app.post["/plain"](later, users)
    var client = TestClient(app)
    assert_equal(client.post("/add", "name=cy").body, "ada adds cy")
    assert_equal(client.post("/later", "name=cy").body, "later")
    assert_equal(client.post("/plain", "name=cy").body, "plain cy")


def test_stateless_post_shapes_resolve_as_before() raises:
    # One-argument calls never meet the stateful overloads.
    _reset()
    var users = _users()
    var app = App()
    app.post["/plain"](plain_create)
    app.post["/plain/{id}"](plain_update)
    app.post["/users/{id}"](replace_user, users)
    var client = TestClient(app)
    assert_equal(client.post("/plain", "name=cy").body, "plain cy")
    assert_equal(client.post("/plain/3", "name=cy").body, "plain 3 cy")
    assert_equal(client.post("/plain", "cy").status, 400)
    assert_equal(client.post("/plain/x", "name=cy").status, 400)
    assert_equal(client.post("/users/0", "name=cy").body, "0:ada/cy")
    assert_equal(_calls(users), 1)


def test_handles_change_at_registration_and_drop_only() raises:
    # One handle per route plus the application's: each registration copies
    # the handle once, and requests only borrow it, so the reference count
    # is the same inside a handler, across requests of every shape and
    # outcome, and after them.
    _reset()
    var users = _users()
    var app = App()
    app.post["/users/{id}"](replace_user, users)
    assert_equal(_handles(users), 2)
    app.post["/add"](add_user, users)
    app.post["/handles"](handles, users)
    app.post["/handles/{id}"](handles_at, users)
    app.post["/reject"](reject, users)
    app.post["/users"](create_user, users)
    app.post["/typed"](handles_typed, users)
    app.post["/typed/{id}"](handles_typed_at, users)
    assert_equal(_handles(users), 9)  # one per registration, every overload
    var client = TestClient(app)
    assert_equal(client.post("/handles", "").body, "9")
    assert_equal(client.post("/handles/1", "").body, "9")
    assert_equal(client.post("/typed", "t").body, "9:t")
    assert_equal(client.post("/typed/1", "t").body, "9:t")
    for _ in range(5):
        _ = client.post("/users/0", "name=cy")
        _ = client.post("/users/9", "name=cy")
        _ = client.post("/users/x", "name=cy")
        _ = client.post("/users/0", "cy")
        _ = client.post("/add", "name=cy")
        _ = client.post("/reject", "name=cy")
        _ = client.post("/users", "name=cy")
        _ = client.post("/users", "")
        assert_equal(_handles(users), 9)
    assert_equal(_calls(users), 25)
    _ = app^  # the routes' handles go with the app
    assert_equal(_handles(users), 1)


def test_state_survives_app_moves_and_is_dropped_once() raises:
    _reset()
    var drops = ArcPointer(0)
    var tracked = State(Tracked(drops))
    var app = App()
    app.post["/track"](track, tracked)
    _ = tracked^  # the app now holds the only handle
    assert_equal(drops[], 0)
    var moved = app^
    assert_equal(TestClient(moved).post("/track", "a").body, "0 a")
    var again = moved^
    assert_equal(TestClient(again).post("/track", "b").body, "0 b")
    assert_equal(drops[], 0)
    _ = again^
    assert_equal(drops[], 1)


def test_test_client_before_and_after_an_app_move() raises:
    _reset()
    var users = _users()
    var app = App()
    app.post["/users/{id}"](replace_user, users)
    var before = TestClient(app)
    assert_equal(before.post("/users/0", "name=cy").body, "0:ada/cy")
    var moved = app^
    var after = TestClient(moved)
    assert_equal(after.post("/users/1", "name=cy").body, "1:bob/cy")
    assert_equal(after.post("/users/9", "name=cy").status, 404)
    assert_equal(after.post("/users/x", "name=cy").status, 400)
    assert_equal(after.post("/users/1", "cy").status, 400)
    assert_equal(_handles(users), 2)  # the moved App still holds its copy
    _ = moved^
    assert_equal(_handles(users), 1)
    assert_equal(_calls(users), 3)


def test_request_headers_take_no_part() raises:
    # Typed routes receive no header strings (M3-005): a stateful POST
    # answers the same through App.handle with or without fields.
    _reset()
    var users = _users()
    var app = App()
    app.post["/users/{id}"](replace_user, users)
    var fields = Headers()
    fields.add("Content-Type", "text/plain")
    fields.add("X-Id", "9")
    var with_fields = app.handle(
        Request("POST", "/users/1", "name=cy", fields^)
    )
    var without = app.handle(Request("POST", "/users/1", "name=cy"))
    assert_equal(with_fields.status, 201)
    assert_equal(with_fields.body, "1:bob/cy")
    assert_equal(with_fields.body, without.body)
    assert_equal(len(with_fields.headers), 0)
    assert_equal(_calls(users), 2)


# DX section 8's `post` rule, `def(State[Users], Int, CreateUser)`: state,
# route value, body.


def update_user(
    users: State[Users], id: Int, body: CreateUser
) raises NotFound -> User:
    return User(id, users[].get(id) + " as " + body.name)


def test_dx_section_8_post_example() raises:
    _reset()
    var users = _users()
    var app = App()
    app.post["/users/{id}"](update_user, users)
    var client = TestClient(app)
    assert_equal(client.post("/users/1", "name=bo").body, "1:bob as bo")
    assert_equal(client.post("/users/9", "name=bo").body, "no user 9")
    assert_equal(client.post("/users/x", "name=bo").status, 400)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
