# Production handler storage (M2-004): ownership and move evidence for the
# private `_Erased` box in src/muntin/_handler_storage.mojo, and for `App`
# routes stored in it. Compile-time negatives: tests/storage_fail.

from std.memory import ArcPointer
from std.testing import assert_equal, TestSuite

from muntin import App, Request, Response
from muntin._handler_storage import _Erased


@fieldwise_init
struct _Counted(Movable):
    """A boxed value whose live instances are counted by an `ArcPointer`."""

    var live: ArcPointer[Int]


def _call_counted(
    c: _Counted, args: List[String], bytes: List[UInt8]
) raises -> Response:
    return Response.text(String(c.live.count()))


def test_erased_owns_exactly_one_value() raises:
    # Oracle: `live.count()` is 1 + the number of live `_Counted` values.
    # A missing or wrong-type drop (leak) changes one of these numbers; a
    # second drop, or a move that frees its source, crashes.
    var live = ArcPointer(0)
    var a = _Erased.__init__[call=_call_counted](_Counted(live))
    assert_equal(live.count(), 2)
    assert_equal(a.invoke([], List[UInt8]()).text(), "2")
    var b = a^
    assert_equal(live.count(), 2)
    assert_equal(b.invoke([], List[UInt8]()).text(), "2")
    _ = b^
    assert_equal(live.count(), 1)


def test_erased_survives_list_growth_and_list_move() raises:
    # Appending past the capacity moves every element to a new buffer; each
    # box must move with its owner and still be freed exactly once.
    var live = ArcPointer(0)
    var boxes = List[_Erased]()
    for _ in range(100):
        boxes.append(_Erased.__init__[call=_call_counted](_Counted(live)))
    assert_equal(live.count(), 101)
    var moved = boxes^
    assert_equal(live.count(), 101)
    for i in range(len(moved)):
        assert_equal(moved[i].invoke([], List[UInt8]()).text(), "101")
    _ = moved.pop()
    assert_equal(live.count(), 100)
    _ = moved^
    assert_equal(live.count(), 1)


def _echo(
    c: _Counted, args: List[String], bytes: List[UInt8]
) raises -> Response:
    if len(args) != 1:
        raise Error("expected one argument")
    return Response.text(args[0])


def test_erased_passes_args_and_propagates_raises() raises:
    var live = ArcPointer(0)
    var e = _Erased.__init__[call=_echo](_Counted(live))
    assert_equal(e.invoke(["x"], List[UInt8]()).text(), "x")
    var raised = False
    try:
        _ = e.invoke([], List[UInt8]())
    except:
        raised = True
    assert_equal(raised, True)
    _ = e^
    assert_equal(live.count(), 1)


# App with both production shapes, moved as production code moves it.


def hello() -> String:
    return "hello"


def get_user(id: Int) -> String:
    return String(id)


def list_items(limit: Int) -> String:
    return "items " + String(limit)


def other() -> String:
    return "other"


def _app() -> App:
    var app = App()
    app.get["/hello"](hello)
    app.get["/users/{id}"](get_user)
    app.get["/items?{limit}"](list_items)
    # Later registrations grow the route list, moving the first three
    # routes (and their boxes) to new buffers.
    comptime for _ in range(20):
        app.get["/other"](other)
    return app^


def _check(app: App) raises:
    assert_equal(app.handle(Request("GET", "/hello")).text(), "hello")
    assert_equal(app.handle(Request("GET", "/users/042")).text(), "42")
    assert_equal(
        app.handle(Request("GET", "/items?limit=010")).text(), "items 10"
    )
    assert_equal(app.handle(Request("GET", "/other")).text(), "other")
    assert_equal(app.handle(Request("GET", "/users/abc")).status, 400)
    assert_equal(app.handle(Request("GET", "/items")).status, 400)
    assert_equal(app.handle(Request("GET", "/missing")).status, 404)


struct _Holder(Movable):
    """Owns an `App` by value, as a backend adapter does."""

    var app: App

    def __init__(out self, var app: App):
        self.app = app^

    def take(deinit self) -> App:
        return self.app^


def test_app_routes_dispatch_after_moves() raises:
    var app = _app()  # moved out of `_app`
    _check(app)
    var moved = app^
    _check(moved)
    var holder = _Holder(moved^)
    _check(holder.app)
    var apps = List[App]()
    apps.append(holder^.take())
    for _ in range(8):
        apps.append(App())  # grows the list, moving the first App
    _check(apps[0])
    var last = apps.pop(0)
    _check(last)


def test_app_routes_hold_erased_handlers() raises:
    # Production routes store `_Erased` boxes (this does not build against a
    # Variant), and each box carries the adapter for its own shape.
    var app = _app()
    assert_equal(
        app._routes[0].handler.invoke([], List[UInt8]()).text(), "hello"
    )
    assert_equal(
        app._routes[1].handler.invoke(["042"], List[UInt8]()).text(), "42"
    )
    assert_equal(
        app._routes[2].handler.invoke(["-3"], List[UInt8]()).text(), "items -3"
    )
    # A bad value is answered 400 by the adapter itself (M2-011): no
    # adapter raises out of `invoke`.
    var bad = app._routes[1].handler.invoke(["4_2"], List[UInt8]())
    assert_equal(bad.status, 400)
    assert_equal(bad.text(), "Bad Request")


def test_partly_matched_route_leaves_no_argument_behind() raises:
    # `/{a}/b` captures "q" from `/q/c` before failing on its static segment;
    # the next route must start from no arguments, so its handler gets the
    # query value, not "q".
    var app = App()
    app.get["/{a}/b"](get_user)
    app.get["/q/c?{limit}"](list_items)
    assert_equal(app.handle(Request("GET", "/q/c?limit=5")).text(), "items 5")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
