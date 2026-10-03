# M3-001 scoped-registrar spike (candidate A2), application side. State
# types and handlers live here; the library side
# (tests/scoped_state_spike.mojo) never names them. Handlers are written
# exactly as for candidate A1: `State[S]` first, then one M2 shape. Only the
# registration differs. Decision and evidence: docs/ARCHITECTURE.md,
# "Application state decision (M3-001)".

from std.memory import ArcPointer
from std.testing import assert_equal, TestSuite

from muntin import FromBody, Request, Response, ToErrorResponse, ToResponse
from scoped_state_spike import ScopedApp
from state_spike import State


struct Users(Movable):
    """In-memory repository; `calls` counts handler calls (the
    application's own mutable field, the "handler not called" oracle)."""

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
    var text: String

    def __init__(out self, text: String):
        self.text = text


struct Tracked(Movable):
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
    var name: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("bad body")
        return Self(String(body[byte=5:]))


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


def greet(greeting: State[Greeting], id: Int) -> String:
    return greeting[].text + " " + String(id)


def handles(users: State[Users]) -> String:
    # Spike-only: the handle's reference count from inside a request.
    return String(users._shared.count())


def track(tracked: State[Tracked]) -> String:
    return String(tracked[].drops[])


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


def _get(app: ScopedApp, target: String) -> Response:
    return app.handle(Request("GET", target))


def _post(app: ScopedApp, target: String, body: String) -> Response:
    return app.handle(Request("POST", target, body))


def test_every_shape_through_one_registrar() raises:
    var users = _users()
    var app = ScopedApp()
    var api = app.with_state(users)
    api.get["/count"](count_users)
    api.get["/first"](first_user)
    api.get["/users/{id}"](get_user)
    api.get["/typed?{id}"](get_user_typed)
    api.post["/users"](create_user)
    api.post["/created"](create_user_typed)
    api.post["/users/{id}"](rename_user)
    api.post["/renamed?{id}"](rename_user_typed)
    api.get["/audit"](audit)
    api.post["/audit"](audit)
    assert_equal(_get(app, "/count").body, "2")
    assert_equal(_get(app, "/first").body, "0:ada")
    assert_equal(_get(app, "/users/1").body, "bob")
    assert_equal(_get(app, "/typed?id=1").body, "1:bob")
    assert_equal(_post(app, "/users", "name=cy").body, "created cy after 2")
    assert_equal(_post(app, "/created", "name=cy").body, "2:cy")
    assert_equal(_post(app, "/users/0", "name=cy").body, "ada -> cy")
    assert_equal(_post(app, "/renamed?id=7", "name=cy").body, "7:cy")
    assert_equal(_get(app, "/audit?x=1").body, "GET /audit?x=1 ")
    assert_equal(_post(app, "/audit", "b").status, 202)
    assert_equal(_calls(users), 10)


def test_request_failures_and_errors_use_the_m2_model() raises:
    var users = _users()
    var app = ScopedApp()
    var api = app.with_state(users)
    api.get["/users/{id}"](get_user)
    api.get["/check/{id}"](check_user)
    api.post["/users/{id}"](rename_user)
    assert_equal(_get(app, "/users/x").status, 400)
    assert_equal(_post(app, "/users/x", "name=cy").status, 400)
    assert_equal(_post(app, "/users/1", "nope").status, 400)
    assert_equal(_get(app, "/missing").status, 404)
    assert_equal(_calls(users), 0)
    assert_equal(_get(app, "/users/9").body, "no user 9")
    var failed = _get(app, "/check/1")
    assert_equal(failed.status, 500)
    assert_equal(failed.body, "Internal Server Error")
    assert_equal(_calls(users), 2)


def test_chained_temporary_and_interleaved_stateless_routes() raises:
    # A one-off registration chains on a temporary registrar; stateless
    # routes register on the app itself, before, between and after.
    var users = _users()
    var app = ScopedApp()
    app.get["/hello"](hello)
    app.with_state(users).get["/users/{id}"](get_user)
    app.get["/plain/{id}"](plain_user)
    app.post["/plain"](plain_create)
    app.post["/raw"](plain_raw)
    assert_equal(_get(app, "/hello").body, "hello")
    assert_equal(_get(app, "/users/0").body, "ada")
    assert_equal(_get(app, "/plain/3").body, "plain 3")
    assert_equal(_post(app, "/plain", "name=cy").body, "0:cy")
    assert_equal(_post(app, "/raw", "x").body, "raw x")


def test_several_state_types_and_one_shared_value() raises:
    var users = _users()
    var app = ScopedApp()
    app.with_state(State(Greeting("hi"))).get["/greet/{id}"](greet)
    var api = app.with_state(users)
    api.get["/users/{id}"](get_user)
    api.get["/count"](count_users)
    assert_equal(_get(app, "/greet/5").body, "hi 5")
    _ = _get(app, "/users/0")
    _ = _get(app, "/count")
    assert_equal(_calls(users), 2)


def test_handles_registrar_copy_is_released_and_requests_borrow() raises:
    var users = _users()
    var app = ScopedApp()
    var api = app.with_state(users)
    assert_equal(
        users._shared.count(), 2
    )  # the application's + the registrar's
    api.get["/users/{id}"](get_user)
    api.get["/handles"](handles)
    _ = api^  # the registrar's copy goes with it
    assert_equal(users._shared.count(), 3)  # the application's + two routes
    assert_equal(_get(app, "/handles").body, "3")
    for _ in range(5):
        _ = _get(app, "/users/0")
        assert_equal(users._shared.count(), 3)
    _ = app^
    assert_equal(users._shared.count(), 1)


def test_state_survives_app_moves_and_is_dropped_once() raises:
    var drops = ArcPointer(0)
    var app = ScopedApp()
    app.with_state(State(Tracked(drops))).get["/track"](track)
    assert_equal(drops[], 0)
    var moved = app^  # the registrar is gone, so the app may move
    assert_equal(_get(moved, "/track").body, "0")
    var again = moved^
    assert_equal(_get(again, "/track").body, "0")
    _ = again^
    assert_equal(drops[], 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
