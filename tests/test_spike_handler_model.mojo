# M0.5 handler-model feasibility spike. Not production code: it lives in tests/
# so CI keeps it compiling, and it is replaced by the real router in M2.
#
# Question: can one Muntin app store and dispatch handlers of different shapes,
#   def root() -> String
#   def get_user(id: Int) -> User
#   def raw(req: Request) -> Response
# on Mojo 1.1.0 without exposing the representation to application code?
#
# Two prototypes, both dispatching through `handle(Request) -> Response`:
#   RuntimeApp      app.get["/users/{id}"](get_user)   handler is a runtime value
#   CompileTimeApp  app.get["/users/{id}", get_user]()  handler is a parameter
# Findings and the trade-off are recorded in docs/DX.md ("Handler model").

from std.sys.info import size_of
from std.testing import assert_equal, TestSuite

from muntin import Request, Response


# ---------------------------------------------------------------------------
# Shared pieces: route-literal analysis, matching, result conversion.


def _count_params(path: StaticString) -> Int:
    var n = 0
    for b in path.as_bytes():
        if Int(b) == ord("{"):
            n += 1
    return n


def _match(pattern: String, path: String, mut params: List[String]) -> Bool:
    """Segment match; `{name}` segments capture positionally into params."""
    var want = pattern.split("/")
    var got = path.split("/")
    if len(want) != len(got):
        return False
    params.clear()
    for i in range(len(want)):
        if want[i].startswith("{") and want[i].endswith("}"):
            params.append(String(got[i]))
        elif want[i] != got[i]:
            return False
    return True


def _to_response[R: Writable & Deinitable](value: R) -> Response:
    # Stand-in for M2 response conversion: any Writable becomes a text body.
    return Response.text(String(value))


comptime _Call = def(Request, List[String]) raises thin -> Response


@fieldwise_init
struct _Dispatch(Copyable, Movable):
    var method: String
    var pattern: String
    var call: _Call


def _dispatch(routes: List[_Dispatch], request: Request) -> Response:
    var params = List[String]()
    for route in routes:
        if route.method == request.method and _match(
            route.pattern, request.path, params
        ):
            try:
                return route.call(request, params)
            except:
                return Response.text("Bad Request", status=400)
    return Response.text("Not Found", status=404)


# ---------------------------------------------------------------------------
# Prototype A: handler passed as a runtime value (docs/DX.md syntax).
#
# A thin function value is erased to its address bits and restored by a
# trampoline instantiated for the same type F. Erase and restore are paired
# inside one generic function (`_register`), so the types cannot drift apart.


comptime _Erased = def(Int, Request, List[String]) raises thin -> Response


@fieldwise_init
struct _ErasedRoute(Copyable, Movable):
    var method: String
    var pattern: String
    var handler_bits: Int
    var invoke: _Erased


def _invoke[
    F: Copyable & Deinitable,
    //,
    call: def(F, Request, List[String]) raises thin -> Response,
](bits: Int, request: Request, params: List[String]) raises -> Response:
    var handler = Pointer(to=bits).unsafe_bitcast[F]()[].copy()
    return call(handler, request, params)


def _call_none[
    R: Writable & Deinitable
](
    h: def() thin -> R, request: Request, params: List[String]
) raises -> Response:
    return _to_response(h())


def _call_int[
    R: Writable & Deinitable
](
    h: def(Int) thin -> R, request: Request, params: List[String]
) raises -> Response:
    return _to_response(h(Int(params[0])))


def _call_raw(
    h: def(Request) thin -> Response, request: Request, params: List[String]
) raises -> Response:
    return h(request)


struct RuntimeApp(Movable):
    var _routes: List[_ErasedRoute]

    def __init__(out self):
        self._routes = List[_ErasedRoute]()

    def _register[
        F: Copyable & Deinitable,
        //,
        call: def(F, Request, List[String]) raises thin -> Response,
    ](mut self, method: String, path: String, handler: F):
        comptime assert (
            size_of[F]() == size_of[Int]()
        ), "handler must be a thin function"
        var bits = Pointer(to=handler).unsafe_bitcast[Int]()[]
        self._routes.append(_ErasedRoute(method, path, bits, _invoke[call]))

    def get[
        path: StaticString, R: Writable & Deinitable
    ](mut self, handler: def() thin -> R):
        comptime assert (
            _count_params(path) == 0
        ), "route declares path parameters but the handler takes none"
        self._register[_call_none[R]]("GET", String(path), handler)

    def get[
        path: StaticString, R: Writable & Deinitable
    ](mut self, handler: def(Int) thin -> R):
        comptime assert (
            _count_params(path) == 1
        ), "handler takes one path parameter; route must declare exactly one"
        self._register[_call_int[R]]("GET", String(path), handler)

    def post[
        path: StaticString
    ](mut self, handler: def(Request) thin -> Response):
        self._register[_call_raw]("POST", String(path), handler)

    def handle(self, request: Request) -> Response:
        var params = List[String]()
        for route in self._routes:
            if route.method == request.method and _match(
                route.pattern, request.path, params
            ):
                try:
                    return route.invoke(route.handler_bits, request, params)
                except:
                    return Response.text("Bad Request", status=400)
        return Response.text("Not Found", status=404)


# ---------------------------------------------------------------------------
# Prototype B: handler passed as a compile-time parameter. No unsafe code: each
# registration instantiates a trampoline with the handler baked in, so every
# stored entry already has the uniform type _Call.


def _bake_none[
    R: Writable & Deinitable, //, h: def() thin -> R
](request: Request, params: List[String]) raises -> Response:
    return _to_response(h())


def _bake_int[
    R: Writable & Deinitable, //, h: def(Int) thin -> R
](request: Request, params: List[String]) raises -> Response:
    return _to_response(h(Int(params[0])))


def _bake_raw[
    h: def(Request) thin -> Response
](request: Request, params: List[String]) raises -> Response:
    return h(request)


struct CompileTimeApp(Movable):
    var _routes: List[_Dispatch]

    def __init__(out self):
        self._routes = List[_Dispatch]()

    def get[
        R: Writable & Deinitable, //, path: StaticString, h: def() thin -> R
    ](mut self):
        comptime assert (
            _count_params(path) == 0
        ), "route declares path parameters but the handler takes none"
        self._routes.append(_Dispatch("GET", String(path), _bake_none[h]))

    def get[
        R: Writable & Deinitable, //, path: StaticString, h: def(Int) thin -> R
    ](mut self):
        comptime assert (
            _count_params(path) == 1
        ), "handler takes one path parameter; route must declare exactly one"
        self._routes.append(_Dispatch("GET", String(path), _bake_int[h]))

    def post[path: StaticString, h: def(Request) thin -> Response](mut self):
        self._routes.append(_Dispatch("POST", String(path), _bake_raw[h]))

    def handle(self, request: Request) -> Response:
        return _dispatch(self._routes, request)


# ---------------------------------------------------------------------------
# Application code: the three handler shapes from the feedback.


@fieldwise_init
struct User(Copyable, Movable, Writable):
    var id: Int
    var name: String

    def write_to(self, mut writer: Some[Writer]):
        writer.write("User(", self.id, ", ", self.name, ")")


def root() -> String:
    return "hello"


def get_user(id: Int) -> User:
    return User(id, "Alice")


def raw(req: Request) -> Response:
    return Response.text("raw:" + req.body, status=201)


def test_runtime_value_app_dispatches_three_shapes() raises:
    var app = RuntimeApp()
    app.get["/"](root)
    app.get["/users/{id}"](get_user)
    app.post["/raw"](raw)

    assert_equal(app.handle(Request("GET", "/")).text(), "hello")
    assert_equal(
        app.handle(Request("GET", "/users/42")).text(), "User(42, Alice)"
    )
    var r = app.handle(Request("POST", "/raw", "ping"))
    assert_equal(r.status, 201)
    assert_equal(r.text(), "raw:ping")
    assert_equal(app.handle(Request("GET", "/users/abc")).status, 400)
    assert_equal(app.handle(Request("GET", "/raw")).status, 404)
    assert_equal(app.handle(Request("GET", "/users")).status, 404)


def test_compile_time_app_dispatches_three_shapes() raises:
    var app = CompileTimeApp()
    app.get["/", root]()
    app.get["/users/{id}", get_user]()
    app.post["/raw", raw]()

    assert_equal(app.handle(Request("GET", "/")).text(), "hello")
    assert_equal(
        app.handle(Request("GET", "/users/42")).text(), "User(42, Alice)"
    )
    var r = app.handle(Request("POST", "/raw", "ping"))
    assert_equal(r.status, 201)
    assert_equal(r.text(), "raw:ping")
    assert_equal(app.handle(Request("GET", "/users/abc")).status, 400)
    assert_equal(app.handle(Request("GET", "/raw")).status, 404)
    assert_equal(app.handle(Request("GET", "/users")).status, 404)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
