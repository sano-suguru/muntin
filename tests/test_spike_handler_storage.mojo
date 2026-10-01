# M2 handler-storage decision spike, application side. Not production code.
#
# Question: which representation should production App use to store handlers
# of different shapes once SPEC M2 adds request bodies and typed returns?
# Each candidate below stores all six fixture shapes in ONE route list and
# dispatches them through ONE `handle(Request) -> Response`:
#
#   () -> String          (Int) -> String          (String) -> String
#   (Int, Int) -> String  (Int, String) -> String  (Int) -> User
#
# `User` is defined in this module, as an application type would be; the
# boxed candidate's library code lives in tests/handler_storage_spike.mojo.
# The shapes are investigation fixtures, not supported Muntin APIs.
# Decision and the evidence for every rejected candidate: docs/ARCHITECTURE.md,
# "Handler storage decision (M2)". Compile-time negatives: tests/spike_fail.

from std.memory import ArcPointer
from std.testing import assert_equal, TestSuite
from std.utils import Variant

from handler_storage_spike import (
    BoxApp,
    FromArg,
    Reply,
    _Erased,
    _count_params,
    _int,
    _match,
)
from muntin import Request, Response


# ---------------------------------------------------------------------------
# Application code.


@fieldwise_init
struct User(Copyable, Reply):
    var id: Int
    var name: String

    def reply(self) -> Response:
        return Response.text("User(" + String(self.id) + ", " + self.name + ")")


def hello() -> String:
    return "hello"


def get_id(id: Int) -> String:
    return "id " + String(id)


def greet(name: String) -> String:
    return "hi " + name


def add(a: Int, b: Int) -> String:
    return String(a + b)


def tag(id: Int, name: String) -> String:
    return String(id) + ":" + name


def risky(id: Int) raises -> String:
    if id < 0:
        raise Error("negative")
    return String(id)


def get_user(id: Int) -> User:
    return User(id, "Alice")


@fieldwise_init
struct CreateUser(FromArg):
    """Stands in for an application-defined request body."""

    var name: String

    @staticmethod
    def from_arg(s: String) raises -> Self:
        return Self("body:" + s)


def create_user(body: CreateUser) -> String:
    return body.name


def update_user(id: Int, body: CreateUser) -> User:
    return User(id, body.name)


# ---------------------------------------------------------------------------
# Candidate 1: closed Variant (production design since M2-001), extended to the
# six fixture shapes. Each shape costs one `comptime` alias, one Variant arm,
# one `get` overload and one dispatch branch. This model has to live in the
# application module because its arm set names `User`; a library-side arm set
# cannot (tests/spike_fail/variant_app_return_type.mojo).

comptime _V0 = def() thin -> String
comptime _V1 = def(Int) thin -> String
comptime _V2 = def(String) thin -> String
comptime _V3 = def(Int, Int) thin -> String
comptime _V4 = def(Int, String) thin -> String
comptime _V5 = def(Int) thin -> User
comptime _VHandler = Variant[_V0, _V1, _V2, _V3, _V4, _V5]


def _variant_call(h: _VHandler, args: List[String]) raises -> Response:
    # One branch per arm. The loop visits every arm type, and an arm without
    # a branch reaches the `comptime assert`, so a missing branch is a compile
    # error (tests/spike_fail/variant_arm_without_branch.mojo) rather than
    # the run-time `abort` that production App.handle's `isa` chain ends in.
    comptime for i in range(_VHandler.Ts.length):
        comptime T = _VHandler.Ts[i]
        if h.isa[T]():
            comptime if T == _V0:
                return Response.text(h[_V0]())
            elif T == _V1:
                return Response.text(h[_V1](_int(args[0])))
            elif T == _V2:
                return Response.text(h[_V2](args[0]))
            elif T == _V3:
                return Response.text(h[_V3](_int(args[0]), _int(args[1])))
            elif T == _V4:
                return Response.text(h[_V4](_int(args[0]), args[1]))
            elif T == _V5:
                return h[_V5](_int(args[0])).reply()
            else:
                comptime assert False, "Variant arm without a dispatch branch"
    return Response.text("unreachable", status=500)


@fieldwise_init
struct _VRoute(Copyable, Movable):
    var pattern: String
    var handler: _VHandler


struct VariantApp(Movable):
    var _routes: List[_VRoute]

    def __init__(out self):
        self._routes = List[_VRoute]()

    def get[path: StaticString](mut self, handler: _V0):
        comptime assert _count_params(path) == 0, "arity"
        self._routes.append(_VRoute(String(path), handler))

    def get[path: StaticString](mut self, handler: _V1):
        comptime assert _count_params(path) == 1, "arity"
        self._routes.append(_VRoute(String(path), handler))

    def get[path: StaticString](mut self, handler: _V2):
        comptime assert _count_params(path) == 1, "arity"
        self._routes.append(_VRoute(String(path), handler))

    def get[path: StaticString](mut self, handler: _V3):
        comptime assert _count_params(path) == 2, "arity"
        self._routes.append(_VRoute(String(path), handler))

    def get[path: StaticString](mut self, handler: _V4):
        comptime assert _count_params(path) == 2, "arity"
        self._routes.append(_VRoute(String(path), handler))

    def get[path: StaticString](mut self, handler: _V5):
        comptime assert _count_params(path) == 1, "arity"
        self._routes.append(_VRoute(String(path), handler))

    def handle(self, request: Request) -> Response:
        var args = List[String]()
        for route in self._routes:
            if request.method != "GET" or not _match(
                route.pattern, request.path, args
            ):
                continue
            try:
                return _variant_call(route.handler, args)
            except:
                return Response.text("Bad Request", status=400)
        return Response.text("Not Found", status=404)


# Candidate 1, safe escape: name the application's type in the arm set by
# making App generic over it. It compiles, but `App()` becomes `App[User]()`
# and every application-defined return or body type joins App's parameters.


struct ParamApp[R: Reply & Copyable](Movable):
    var _routes: List[Variant[_V0, def(Int) thin -> Self.R]]

    def __init__(out self):
        self._routes = List[Variant[_V0, def(Int) thin -> Self.R]]()

    def get(mut self, handler: def(Int) thin -> Self.R):
        self._routes.append(Variant[_V0, def(Int) thin -> Self.R](handler))


def test_variant_names_app_types_only_through_app_parameters() raises:
    var app = ParamApp[User]()
    app.get(get_user)
    var h = app._routes[0].copy()
    assert_equal(h[def(Int) thin -> User](3).reply().text(), "User(3, Alice)")


# ---------------------------------------------------------------------------
# Both candidates, same registrations, same oracle.


def _variant_app() -> VariantApp:
    var app = VariantApp()
    app.get["/hello"](hello)
    app.get["/ids/{id}"](get_id)
    app.get["/greet/{name}"](greet)
    app.get["/add/{a}/{b}"](add)
    app.get["/tag/{id}/{name}"](tag)
    app.get["/users/{id}"](get_user)
    return app^


def _box_app() -> BoxApp:
    var app = BoxApp()
    app.get["/hello"](hello)
    app.get["/ids/{id}"](get_id)
    app.get["/greet/{name}"](greet)
    app.get["/add/{a}/{b}"](add)
    app.get["/tag/{id}/{name}"](tag)
    app.get["/users/{id}"](get_user)
    return app^


def _check_variant(app: VariantApp) raises:
    var r = List[Response]()
    for target in _targets():
        r.append(app.handle(Request("GET", target)))
    _check_six_shapes(r)


def _check_box(app: BoxApp) raises:
    var r = List[Response]()
    for target in _targets():
        r.append(app.handle(Request("GET", target)))
    _check_six_shapes(r)


def _targets() -> List[String]:
    return [
        "/hello",
        "/ids/42",
        "/greet/bob",
        "/add/2/40",
        "/tag/7/x",
        "/users/7",
        "/ids/abc",
        "/add/1/x",
        "/missing",
    ]


def _check_six_shapes(r: List[Response]) raises:
    assert_equal(r[0].text(), "hello")
    assert_equal(r[1].text(), "id 42")
    assert_equal(r[2].text(), "hi bob")
    assert_equal(r[3].text(), "42")
    assert_equal(r[4].text(), "7:x")
    assert_equal(r[5].text(), "User(7, Alice)")
    assert_equal(r[6].status, 400)
    assert_equal(r[7].status, 400)
    assert_equal(r[8].status, 404)


def test_variant_stores_six_shapes_in_one_list() raises:
    var app = _variant_app()
    _check_variant(app)
    var moved = app^
    _check_variant(moved)


def test_box_stores_six_shapes_in_one_list() raises:
    var app = _box_app()
    _check_box(app)
    var moved = app^
    _check_box(moved)


def test_box_takes_app_defined_parameter_types() raises:
    # The body half of the deciding fact: a library-side Variant could not
    # name `CreateUser` either.
    var app = _box_app()
    app.get["/create/{body}"](create_user)
    app.get["/update/{id}/{body}"](update_user)
    assert_equal(app.handle(Request("GET", "/create/bob")).text(), "body:bob")
    assert_equal(
        app.handle(Request("GET", "/update/3/z")).text(), "User(3, body:z)"
    )
    _check_box(app)


def test_box_raising_handler() raises:
    var app = _box_app()
    app.get["/risky/{id}"](risky)
    assert_equal(app.handle(Request("GET", "/risky/5")).text(), "5")
    assert_equal(app.handle(Request("GET", "/risky/-5")).status, 400)


def test_box_handlers_survive_copy_and_move_of_their_owner() raises:
    var app = _box_app()
    var copies = app.route_handlers()
    var moved = app^
    _check_box(moved)
    assert_equal(len(copies), 6)
    assert_equal(copies[5].invoke(["9"]).text(), "User(9, Alice)")
    _ = copies^
    _check_box(moved)


@fieldwise_init
struct _Counted(Copyable):
    """A boxed value whose live copies are counted by an `ArcPointer`."""

    var live: ArcPointer[Int]


def _call_counted(c: _Counted, args: List[String]) raises -> Response:
    return Response.text(String(c.live.count()))


def test_box_owns_exactly_one_value_per_erased_handler() raises:
    # Ownership oracle: `live.count()` is 1 + the number of live _Counted
    # values. A shared box on copy (double free), a missing deinit (leak) or
    # an extra copy on move each change one of these numbers.
    var live = ArcPointer(0)
    var a = _Erased.__init__[call=_call_counted](_Counted(live))
    assert_equal(live.count(), 2)
    var b = a.copy()
    assert_equal(live.count(), 3)
    var c = a^
    assert_equal(live.count(), 3)
    assert_equal(c.invoke([]).text(), "3")
    _ = b^
    assert_equal(live.count(), 2)
    var handlers = List[_Erased]()
    handlers.append(c^)
    var copied = handlers.copy()
    assert_equal(live.count(), 3)
    var moved = handlers^
    assert_equal(live.count(), 3)
    _ = copied^
    _ = moved^
    assert_equal(live.count(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
