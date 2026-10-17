# Stateful GET handlers in production (M3-003): `muntin.State[S]` and the
# `App.get` registrations taking `(handler, state)`, driven through
# `TestClient`. Decision: docs/history/architecture-decisions.md, "Application
# state decision (M3-001)". Must-not-compile counterparts: tests/state_get_fail
# and tests/compile_fail/state_*.

from std.memory import ArcPointer, OwnedPointer
from std.utils import Variant
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import App, Response, State, ToErrorResponse, ToResponse
from muntin.testing import TestClient


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


# Stateful handlers: `State[S]` first, then `def()` or `def(Int)`.


def count_users(users: State[Users]) -> String:
    users[].count()
    return String(len(users[].names))


def first_user(users: State[Users]) -> User:
    users[].count()
    return User(0, users[].names[0])


def name_of(users: State[Users], id: Int) raises NotFound -> String:
    users[].count()
    return users[].get(id)


def get_user(users: State[Users], id: Int) raises NotFound -> User:
    users[].count()
    return User(id, users[].get(id))


def echo_id(users: State[Users], id: Int) -> String:
    users[].count()
    return "id " + String(id)


def check_user(users: State[Users], id: Int) raises -> String:
    users[].count()
    raise Error("secret detail " + String(id))


def check_all(users: State[Users]) raises -> User:
    users[].count()
    raise Error("secret detail")


def missing_first(users: State[Users]) raises NotFound -> String:
    users[].count()
    raise NotFound(0)


def handles(users: State[Users]) -> String:
    # Reads the handle's reference count from inside a request.
    return String(users._shared.count())


def handles_at(users: State[Users], id: Int) -> String:
    # The same, from the `def(State[S], Int)` shape.
    return String(users._shared.count())


def greet(greeting: State[Greeting], id: Int) -> String:
    return greeting[].text + " " + String(id)


def track(tracked: State[Tracked]) -> String:
    return String(tracked[].drops[])


def track_or_fail(tracked: State[Tracked], id: Int) raises NotFound -> String:
    if id != 0:
        raise NotFound(id)
    return String(tracked[].drops[])


def track_and_raise(tracked: State[Tracked]) raises -> String:
    raise Error("secret detail")


def later(users: State[Users]) -> String:
    return "later"


# Stateless M2 handlers, registered on the same app.


def hello() -> String:
    return "hello"


def plain_user(id: Int) -> String:
    return "plain " + String(id)


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


def test_get_shapes_and_results() raises:
    var users = _users()
    var app = App()
    app.get["/count"](count_users, users)
    app.get["/first"](first_user, users)
    app.get["/names/{id}"](name_of, users)
    app.get["/users/{id}"](get_user, users)
    app.get["/typed?{id}"](get_user, users)
    var client = TestClient(app)
    var count = client.get("/count")
    assert_equal(count.status, 200)
    assert_equal(count.text(), "2")
    assert_equal(client.get("/first").text(), "0:ada")
    assert_equal(client.get("/names/1").text(), "bob")
    assert_equal(client.get("/users/1").text(), "1:bob")
    assert_equal(client.get("/typed?id=1").text(), "1:bob")
    assert_equal(_calls(users), 5)


def test_int_is_converted_from_path_and_query() raises:
    # "id 42" for "042" and "id -7" only if the handler received the
    # converted Int after the state, from the path or from the query.
    var users = _users()
    var app = App()
    app.get["/ids/{id}"](echo_id, users)
    app.get["/ids?{id}"](echo_id, users)
    var client = TestClient(app)
    assert_equal(client.get("/ids/042").text(), "id 42")
    assert_equal(client.get("/ids/-7").text(), "id -7")
    assert_equal(client.get("/ids?id=042").text(), "id 42")
    assert_equal(client.get("/ids?x=1&id=9").text(), "id 9")
    assert_equal(_calls(users), 4)


def test_request_failures_do_not_call_the_handler() raises:
    var users = _users()
    var app = App()
    app.get["/users/{id}"](get_user, users)
    app.get["/names?{id}"](name_of, users)
    app.get["/count"](count_users, users)
    var client = TestClient(app)
    for target in [
        "/users/x",
        "/users/+1",
        "/users/1_0",
        "/names",
        "/names?id=",
        "/names?id=x",
        "/names?id=1&id=2",
        "/names?other=1",
    ]:
        var got = client.get(target)
        assert_equal(got.status, 400, target)
        assert_equal(got.text(), "Bad Request", target)
    for target in ["/missing", "/users", "/users/1/x", "/count/1"]:
        var got = client.get(target)
        assert_equal(got.status, 404, target)
        assert_equal(got.text(), "Not Found", target)
    var post = client.post("/count", "")
    assert_equal(post.status, 405)
    assert_equal(post.text(), "Method Not Allowed")
    assert_equal(len(post.headers.get_all("Allow")), 1)
    assert_equal(post.headers.get_all("Allow")[0], "GET, HEAD")
    assert_equal(_calls(users), 0)


def test_errors_use_the_m2_model() raises:
    var users = _users()
    var app = App()
    app.get["/names/{id}"](name_of, users)
    app.get["/users/{id}"](get_user, users)
    app.get["/check/{id}"](check_user, users)
    app.get["/check"](check_all, users)
    app.get["/first"](missing_first, users)
    var client = TestClient(app)
    var missing = client.get("/names/9")
    assert_equal(missing.status, 404)
    assert_equal(missing.text(), "no user 9")
    var typed = client.get("/users/9")
    assert_equal(typed.status, 404)
    assert_equal(typed.text(), "no user 9")
    assert_equal(client.get("/first").text(), "no user 0")
    for target in ["/check/1", "/check"]:
        var failed = client.get(target)
        assert_equal(failed.status, 500, target)
        assert_equal(failed.text(), "Internal Server Error", target)
    assert_equal(_calls(users), 5)


def test_route_kinds_share_one_app() raises:
    # Each kind on a path of its own: a second route on one path is a route
    # conflict whatever the kinds (M3-053, tests/route_conflict_abort).
    var users = _users()
    var app = App()
    app.get["/count"](count_users, users)
    app.get["/later"](later, users)
    var client = TestClient(app)
    assert_equal(client.get("/count").text(), "2")
    assert_equal(client.get("/later").text(), "later")


def test_stateless_m2_shapes_resolve_as_before() raises:
    # One-argument calls never meet the stateful overloads.
    var users = _users()
    var app = App()
    app.get["/hello"](hello)
    app.get["/plain/{id}"](plain_user)
    app.get["/users/{id}"](get_user, users)
    var client = TestClient(app)
    assert_equal(client.get("/hello").text(), "hello")
    assert_equal(client.get("/plain/3").text(), "plain 3")
    assert_equal(client.get("/users/0").text(), "0:ada")
    assert_equal(_calls(users), 1)


def test_several_state_types_and_one_shared_value() raises:
    # Different routes bind different state types in one App, and several
    # routes share one value: both routes count into the application's own
    # handle.
    var users = _users()
    var greeting = State(Greeting("hi"))
    var app = App()
    app.get["/users/{id}"](get_user, users)
    app.get["/count"](count_users, users)
    app.get["/greet/{id}"](greet, greeting)
    var client = TestClient(app)
    assert_equal(client.get("/greet/5").text(), "hi 5")
    _ = client.get("/users/0")
    _ = client.get("/count")
    assert_equal(_calls(users), 2)


def test_handles_change_at_registration_and_drop_only() raises:
    # One handle per route plus the application's: each registration copies
    # the handle once, and requests only borrow it, so the reference count
    # is the same inside a handler, across requests of every shape and
    # outcome, and after them.
    var users = _users()
    assert_equal(_handles(users), 1)
    var app = App()
    app.get["/users/{id}"](get_user, users)
    assert_equal(_handles(users), 2)
    app.get["/count"](count_users, users)
    app.get["/handles"](handles, users)
    app.get["/handles/{id}"](handles_at, users)
    assert_equal(_handles(users), 5)
    var client = TestClient(app)
    assert_equal(client.get("/handles").text(), "5")
    assert_equal(client.get("/handles/1").text(), "5")
    for _ in range(5):
        _ = client.get("/users/0")
        _ = client.get("/users/9")
        _ = client.get("/users/x")
        _ = client.get("/count")
        assert_equal(_handles(users), 5)
    assert_equal(_calls(users), 15)
    _ = app^  # the routes' handles go with the app
    assert_equal(_handles(users), 1)


def test_state_survives_app_moves_and_is_dropped_once() raises:
    var drops = ArcPointer(0)
    var tracked = State(Tracked(drops))
    var app = App()
    app.get["/track"](track, tracked)
    _ = tracked^  # the app now holds the only handle
    assert_equal(drops[], 0)
    var moved = app^
    assert_equal(TestClient(moved).get("/track").text(), "0")
    var again = moved^
    assert_equal(TestClient(again).get("/track").text(), "0")
    assert_equal(drops[], 0)
    _ = again^
    assert_equal(drops[], 1)


def test_state_is_dropped_once_after_failed_requests() raises:
    # Error paths release what they took: requests that end in a converted
    # error, a 500 or a 400 leave the routes' handles, and the value is
    # dropped once, with the app. Under `SANITIZE=address`, a leaked or
    # doubly freed box, header or value also fails this test.
    var drops = ArcPointer(0)
    var tracked = State(Tracked(drops))
    var app = App()
    app.get["/track/{id}"](track_or_fail, tracked)
    app.get["/raise"](track_and_raise, tracked)
    _ = tracked^  # the routes now hold the only handles
    var client = TestClient(app)
    for _ in range(3):
        assert_equal(client.get("/track/0").text(), "0")
        assert_equal(client.get("/track/7").status, 404)
        assert_equal(client.get("/track/x").status, 400)
        assert_equal(client.get("/raise").status, 500)
    assert_equal(drops[], 0)
    _ = app^
    assert_equal(drops[], 1)


def test_test_client_before_and_after_an_app_move() raises:
    # TestClient borrows the App: repeated requests before a move, then a
    # new client on the moved App, with the application still reading its
    # own handle.
    var users = _users()
    var app = App()
    app.get["/users/{id}"](get_user, users)
    var before = TestClient(app)
    assert_equal(before.get("/users/0").text(), "0:ada")
    assert_equal(before.get("/users/1").text(), "1:bob")
    var moved = app^
    var after = TestClient(moved)
    assert_equal(after.get("/users/0").text(), "0:ada")
    assert_equal(after.get("/users/9").status, 404)
    assert_equal(_handles(users), 2)  # the moved App still holds its copy
    assert_equal(after.get("/users/x").status, 400)
    _ = moved^
    assert_equal(_handles(users), 1)
    assert_equal(_calls(users), 4)
    assert_equal(len(users[].names), 2)
    assert_true(users[].names[0] == "ada")
    assert_false(users[].names[0] == "bob")


# A state's type may not borrow (M3-074): the rule refuses an origin (`{}`) in
# the type's name, so these types, whose parameters are owned types or values
# (an `Int`, a struct value, a function value) and whose static text sits in a
# field, still register and answer. The refused
# side is tests/state_fail/state_origin_*.mojo.


struct Label(Movable):
    var text: StaticString

    def __init__(out self, text: StaticString):
        self.text = text


struct Sized[n: Int](Movable):
    def __init__(out self):
        pass


@fieldwise_init
struct Mode(Equatable, ImplicitlyCopyable, Movable):
    """A struct value as a parameter prints with braces (`{0 : ...}`) but no
    `{}`, so it is not taken for an origin."""

    var level: Int
    comptime FAST = Mode(2)


struct Tuned[mode: Mode](Movable):
    def __init__(out self):
        pass


def five() -> Int:
    return 5


struct Computed[f: def() thin -> Int](Movable):
    """A function-valued parameter prints as `<unprintable>` and no `{}`."""

    def __init__(out self):
        pass


struct Pair(Movable):
    """The migration for an owned `Tuple` state, which the rule refuses as the
    whole state (tests/state_fail/state_pack_tuple.mojo): a field of the
    application's own struct."""

    var value: Tuple[Int, String]

    def __init__(out self, var value: Tuple[Int, String]):
        self.value = value^


struct Choice(Movable):
    """The same migration for an owned `Variant`."""

    var value: Variant[Int, String]

    def __init__(out self, var value: Variant[Int, String]):
        self.value = value^


def peek[o: Origin[mut=False]]() -> Int:
    return 7


def label_text(label: State[Label]) -> String:
    return String(label[].text)


def list_len(names: State[List[String]]) -> String:
    return String(len(names[]))


def dict_value(scores: State[Dict[String, Int]]) -> String:
    try:
        return String(scores[]["ada"])
    except:
        return "missing"


def shared_name(users: State[ArcPointer[Users]]) -> String:
    return users[][].names[0]


def sized_n(sized: State[Sized[3]]) -> String:
    return String(sized[].n)


def tuned_level(tuned: State[Tuned[Mode.FAST]]) -> String:
    return String(tuned[].mode.level)


def computed(value: State[Computed[five]]) -> String:
    return String(value[].f())


def pair_text(pair: State[Pair]) -> String:
    return String(pair[].value[0]) + pair[].value[1]


def choice_text(choice: State[Choice]) -> String:
    return choice[].value[String]


def register_hidden_origin(mut app: App):
    """A function-valued parameter can bind a local's origin, which its name
    (`<unprintable>`) hides, but a function value is a compile-time value and
    carries no address: a closure over the local cannot be a parameter
    (tests/state_fail/state_function_parameter_captures_*.mojo), and the
    pointer it would read sits in a field whose type prints
    (state_origin_in_function_parameter_type.mojo). The local is gone before
    the request; under `SANITIZE=address` nothing reads it."""
    var token = OwnedPointer(42)
    comptime f = peek[origin_of(token)]
    app.get["/hidden"](computed_peek[f], State(Computed[f]()))


def computed_peek[f: def() thin -> Int](value: State[Computed[f]]) -> String:
    return String(value[].f())


def test_owned_values_in_a_wrapper_register() raises:
    var app = App()
    app.get["/pair"](pair_text, State(Pair(Tuple(1, String("a")))))
    app.get["/choice"](
        choice_text, State(Choice(Variant[Int, String](String("b"))))
    )
    var client = TestClient(app)
    assert_equal(client.get("/pair").text(), "1a")
    assert_equal(client.get("/choice").text(), "b")


def test_function_parameter_hides_no_address() raises:
    var app = App()
    register_hidden_origin(app)
    var client = TestClient(app)
    var response = client.get("/hidden")
    assert_equal(response.status, 200)
    assert_equal(response.text(), "7")


def test_owned_state_types_register() raises:
    var names = List[String]()
    names.append("ada")
    var scores = Dict[String, Int]()
    scores["ada"] = 7
    var users = List[String]()
    users.append("bob")
    var app = App()
    app.get["/label"](label_text, State(Label("static in a field")))
    app.get["/list"](list_len, State(names^))
    app.get["/dict"](dict_value, State(scores^))
    app.get["/arc"](shared_name, State(ArcPointer(Users(users^))))
    app.get["/sized"](sized_n, State(Sized[3]()))
    app.get["/tuned"](tuned_level, State(Tuned[Mode.FAST]()))
    app.get["/computed"](computed, State(Computed[five]()))
    var client = TestClient(app)
    var label = client.get("/label")
    assert_equal(label.status, 200)
    assert_equal(label.text(), "static in a field")
    assert_equal(client.get("/list").text(), "1")
    assert_equal(client.get("/dict").text(), "7")
    assert_equal(client.get("/arc").text(), "bob")
    assert_equal(client.get("/sized").text(), "3")
    assert_equal(client.get("/tuned").text(), "2")
    assert_equal(client.get("/computed").text(), "5")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
