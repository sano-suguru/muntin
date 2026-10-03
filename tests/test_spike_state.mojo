# M3-001 application-state decision spike, application side. State types,
# body types, error types and handlers live here; the library side
# (tests/state_spike.mojo) never names them. Decision and evidence:
# docs/ARCHITECTURE.md, "Application state decision (M3-001)".

from std.memory import ArcPointer
from std.reflection import reflect
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import FromBody, Request, Response, ToErrorResponse, ToResponse
from state_spike import State, StateApp


# Application types.


struct Users(Movable):
    """A move-only in-memory repository: the `users.get(id)` of DX
    sections 2 and 8. Every call to a handler is counted in `calls`, which
    the application keeps mutable on purpose (its own `ArcPointer[Int]`
    field, not Muntin's): the counter is the oracle for "handler not
    called", and shows where mutability lives when a value must change."""

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


struct Greeting(Movable):
    """A second, unrelated state type for other routes of the same app."""

    var text: String

    def __init__(out self, text: String):
        self.text = text


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
struct User(Movable, ToResponse):
    var id: Int
    var name: String

    def to_response(var self) -> Response:
        return Response.text(String(self.id) + ":" + self.name)


@fieldwise_init
struct NewUser(FromBody, Movable):
    """Move-only body: `name=<text>`."""

    var name: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("bad body")
        return Self(String(body[byte=5:]))


# Stateful handlers: `State[S]` first, then one M2 shape.


def count_users(users: State[Users]) -> String:
    users[].count()
    return String(len(users[].names))


def first_user(users: State[Users]) -> User:
    users[].count()
    return User(0, users[].names[0])


def get_user(users: State[Users], id: Int) raises NotFound -> String:
    users[].count()
    return users[].get(id)


def get_user_typed(users: State[Users], id: Int) raises NotFound -> User:
    users[].count()
    return User(id, users[].get(id))


def check_user(users: State[Users], id: Int) raises -> String:
    users[].count()
    raise Error("secret detail " + String(id))


def create_user(users: State[Users], var body: NewUser) -> String:
    users[].count()
    return "created " + body.name + " after " + String(len(users[].names))


def create_user_typed(users: State[Users], body: NewUser) -> User:
    users[].count()
    return User(len(users[].names), body.name)


def rename_user(
    users: State[Users], id: Int, var body: NewUser
) raises NotFound -> String:
    users[].count()
    return users[].get(id) + " -> " + body.name


def rename_user_typed(users: State[Users], id: Int, body: NewUser) -> User:
    users[].count()
    return User(id, body.name)


def audit(users: State[Users], req: Request) -> Response:
    users[].count()
    return Response.text(
        req.method + " " + req.path + "?" + req.query + " " + req.body,
        status=202,
    )


def audit_owned(users: State[Users], var req: Request) -> Response:
    users[].count()
    return Response.text(req.body^, status=201)


def handles(users: State[Users]) -> String:
    # Spike-only: reads the handle's reference count from inside a request.
    return String(users._shared.count())


def greet(greeting: State[Greeting], id: Int) -> String:
    return greeting[].text + " " + String(id)


def track(tracked: State[Tracked]) -> String:
    return String(tracked[].drops[])


# Stateless M2 handlers, registered on the same app.


def hello() -> String:
    return "hello"


def plain_user(id: Int) -> String:
    return "plain " + String(id)


def plain_create(body: NewUser) -> User:
    return User(0, body.name)


def plain_raw(req: Request) -> Response:
    return Response.text("raw " + req.body)


def _users() -> State[Users]:
    var names = List[String]()
    names.append("ada")
    names.append("bob")
    return State(Users(names^))


def _calls(users: State[Users]) -> Int:
    return users[].calls[]


def _get(app: StateApp, target: String) -> Response:
    return app.handle(Request("GET", target))


def _post(app: StateApp, target: String, body: String) -> Response:
    return app.handle(Request("POST", target, body))


# Tests.


def test_get_shapes_and_results() raises:
    var users = _users()
    var app = StateApp()
    app.get["/count"](count_users, users)
    app.get["/first"](first_user, users)
    app.get["/users/{id}"](get_user, users)
    app.get["/typed?{id}"](get_user_typed, users)
    assert_equal(_get(app, "/count").body, "2")
    assert_equal(_get(app, "/first").body, "0:ada")
    assert_equal(_get(app, "/users/1").body, "bob")
    assert_equal(_get(app, "/typed?id=1").body, "1:bob")
    assert_equal(_calls(users), 4)


def test_request_failures_do_not_call_the_handler() raises:
    var users = _users()
    var app = StateApp()
    app.get["/users/{id}"](get_user, users)
    app.get["/typed?{id}"](get_user_typed, users)
    app.post["/users"](create_user, users)
    app.post["/users/{id}"](rename_user, users)
    assert_equal(_get(app, "/users/x").status, 400)
    assert_equal(_get(app, "/typed").status, 400)
    assert_equal(_get(app, "/typed?id=1&id=2").status, 400)
    assert_equal(_post(app, "/users", "nope").status, 400)
    assert_equal(_post(app, "/users/x", "name=cy").status, 400)
    assert_equal(_post(app, "/users/1", "nope").status, 400)
    assert_equal(_get(app, "/missing").status, 404)
    assert_equal(_post(app, "/users/1/x", "name=cy").status, 404)
    assert_equal(_calls(users), 0)


def test_post_shapes_bind_state_route_value_body_in_order() raises:
    var users = _users()
    var app = StateApp()
    app.post["/users"](create_user, users)
    app.post["/typed"](create_user_typed, users)
    app.post["/users/{id}"](rename_user, users)
    app.post["/renamed?{id}"](rename_user_typed, users)
    assert_equal(_post(app, "/users", "name=cy").body, "created cy after 2")
    assert_equal(_post(app, "/typed", "name=cy").body, "2:cy")
    assert_equal(_post(app, "/users/0", "name=cy").body, "ada -> cy")
    assert_equal(_post(app, "/renamed?id=7", "name=cy").body, "7:cy")
    assert_equal(_calls(users), 4)


def test_errors_use_the_m2_model() raises:
    var users = _users()
    var app = StateApp()
    app.get["/users/{id}"](get_user, users)
    app.get["/typed/{id}"](get_user_typed, users)
    app.get["/check/{id}"](check_user, users)
    app.post["/users/{id}"](rename_user, users)
    var missing = _get(app, "/users/9")
    assert_equal(missing.status, 404)
    assert_equal(missing.body, "no user 9")
    assert_equal(_get(app, "/typed/9").body, "no user 9")
    var failed = _get(app, "/check/1")
    assert_equal(failed.status, 500)
    assert_equal(failed.body, "Internal Server Error")
    assert_equal(_post(app, "/users/9", "name=cy").status, 404)
    assert_equal(_calls(users), 4)


def test_raw_handlers_take_state_then_the_request() raises:
    var users = _users()
    var app = StateApp()
    app.get["/audit"](audit, users)
    app.post["/audit"](audit, users)
    app.post["/owned"](audit_owned, users)
    var got = _get(app, "/audit?x=1")
    assert_equal(got.status, 202)
    assert_equal(got.body, "GET /audit?x=1 ")
    assert_equal(_post(app, "/audit", "b").body, "POST /audit? b")
    var owned = _post(app, "/owned?id=abc", "raw body")
    assert_equal(owned.status, 201)
    assert_equal(owned.body, "raw body")
    assert_equal(_calls(users), 3)


def test_stateless_m2_shapes_resolve_as_before() raises:
    # One-argument calls never meet the stateful family: every M2 shape,
    # including the raw one on `post` (shorter-list rule), resolves to its
    # production overload in an app that also has stateful routes.
    var users = _users()
    var app = StateApp()
    app.get["/hello"](hello)
    app.get["/plain/{id}"](plain_user)
    app.post["/plain"](plain_create)
    app.post["/raw"](plain_raw)
    app.get["/users/{id}"](get_user, users)
    assert_equal(_get(app, "/hello").body, "hello")
    assert_equal(_get(app, "/plain/3").body, "plain 3")
    assert_equal(_post(app, "/plain", "name=cy").body, "0:cy")
    assert_equal(_post(app, "/raw", "x").body, "raw x")
    assert_equal(_get(app, "/users/0").body, "ada")
    assert_equal(_calls(users), 1)


def test_several_state_types_and_one_shared_value() raises:
    # Several values: one state type per registration, inferred from the
    # arguments; different routes may bind different types, and several
    # routes may share one value. Several values in one handler are the
    # fields of one state type.
    var users = _users()
    var greeting = State(Greeting("hi"))
    var app = StateApp()
    app.get["/users/{id}"](get_user, users)
    app.get["/count"](count_users, users)
    app.get["/greet/{id}"](greet, greeting)
    assert_equal(_get(app, "/greet/5").body, "hi 5")
    _ = _get(app, "/users/0")
    _ = _get(app, "/count")
    # Both routes counted into the application's own handle: one value.
    assert_equal(_calls(users), 2)


def test_handles_are_copied_at_registration_only() raises:
    # One handle per route plus the application's: registration copies the
    # handle, requests only borrow it (the reference count is unchanged by
    # any number of requests).
    var users = _users()
    var app = StateApp()
    assert_equal(users._shared.count(), 1)
    app.get["/users/{id}"](get_user, users)
    app.post["/users"](create_user, users)
    app.get["/handles"](handles, users)
    assert_equal(users._shared.count(), 4)
    # Inside a request the count is the same: the handler borrows the
    # route's handle.
    assert_equal(_get(app, "/handles").body, "4")
    for _ in range(5):
        _ = _get(app, "/users/0")
        _ = _post(app, "/users", "name=cy")
        assert_equal(users._shared.count(), 4)
    assert_equal(_calls(users), 10)
    _ = app^  # the routes' handles go with the app
    assert_equal(users._shared.count(), 1)


def test_state_survives_app_moves_and_is_dropped_once() raises:
    var drops = ArcPointer(0)
    var tracked = State(Tracked(drops))
    var app = StateApp()
    app.get["/track"](track, tracked)
    _ = tracked^  # the app now holds the only handle
    assert_equal(drops[], 0)
    var moved = app^
    assert_equal(_get(moved, "/track").body, "0")
    var again = moved^
    assert_equal(_get(again, "/track").body, "0")
    assert_equal(drops[], 0)
    _ = again^
    assert_equal(drops[], 1)


def test_application_handle_reads_after_requests() raises:
    # The application keeps its handle while the app serves; both see the
    # same value. Muntin's handle is read-only (`state[]` is immutable,
    # tests/state_fail/mutate_through_state.mojo), so the only change is the
    # one the application built into `Users.calls`.
    var users = _users()
    var app = StateApp()
    app.get["/count"](count_users, users)
    _ = _get(app, "/count")
    assert_equal(len(users[].names), 2)
    assert_equal(_calls(users), 1)
    assert_true(users[].names[0] == "ada")
    assert_false(users[].names[0] == "bob")


def test_runtime_type_identity_is_only_a_name_string() raises:
    # Candidate B2 (a non-generic App storing one erased state value,
    # handlers asking for `State[S]`) must check at dispatch that the stored
    # value is an `S`. Mojo 1.1.0's only runtime type identity is the
    # module-qualified name `reflect[T].name()` returns, a `String`: the
    # check would be a string key and the recovery an unsafe cast.
    assert_equal(reflect[Users].name(), "test_spike_state.Users")
    assert_true(
        reflect[State[Users]].name().endswith("State[test_spike_state.Users]")
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
