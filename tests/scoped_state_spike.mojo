# M3-001 scoped-registrar spike (candidate A2), library side. Not
# production code. Candidate A1 (tests/state_spike.mojo) adds the stateful
# overloads to `App` itself, `app.get[route](handler, state)`; this models
# A2, `app.with_state(state).get[route](handler)`, where they live on a
# separate registrar type and `App` gains only `with_state`. It reuses A1's
# `State`, `_Bound`, stateful adapters and route type, imports production's
# adapters, route checks, matching and `_Erased` unchanged, and copies
# production's ten overloads (signatures and asserts; the four body
# overloads gain the `State` guard, worded for A2) so `App`'s overload set
# and diagnostics are measured as production would have them. The
# application side is tests/test_spike_scoped_state.mojo; the decision is
# docs/ARCHITECTURE.md, "Application state decision (M3-001)".
#
#   ScopedApp      production `App` plus `with_state(state)`, which returns
#                  a registrar borrowing the app mutably (a safe
#                  `Pointer[ScopedApp, origin]`, as `TestClient` borrows
#                  immutably) and holding a copy of the state handle.
#   StateRoutes    the registrar: `get`/`post` with the ten stateful shapes,
#                  one argument each, `S` fixed by the registrar. A route
#                  gets its own handle copy in `_Bound`, as in A1.

from muntin import Request, Response, ToResponse
from muntin.body import FromBody
from muntin._handler_storage import _Erased
from muntin.app import _bad_request, _converted, _handler_error, _text
from muntin.app import _call_body, _call_int, _call_int_body, _call_none
from muntin.app import _call_raw, _internal_error, _match, _parse_int
from muntin.app import _path_params, _query_params, _query_value
from state_spike import State, _Bound, _InjectedState, _StateRoute
from state_spike import _call_state_body, _call_state_int
from state_spike import _call_state_int_body, _call_state_none
from state_spike import _call_state_raw


struct StateRoutes[S: Movable & Deinitable, origin: Origin[mut=True]]:
    """Registers stateful handlers on one app with one state value.

    Holds a mutable borrow of the app for as long as it is used, and a copy
    of the state handle; each registration copies the handle once more into
    its route. Requests never see the registrar.
    """

    var _app: Pointer[ScopedApp, Self.origin]
    var _state: State[Self.S]

    def __init__(
        out self, ref[Self.origin] app: ScopedApp, state: State[Self.S]
    ):
        self._app = Pointer(to=app)
        self._state = state.copy()

    def get[
        E: Deinitable, //, path: StaticString
    ](self, handler: def(State[Self.S]) thin raises E -> String):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert (
            _path_params(path) == 0
        ), "route declares a path parameter but the handler takes none"
        comptime assert (
            _query_params(path) == 0
        ), "route declares a query parameter but the handler takes none"
        self._app[]._routes.append(
            _StateRoute(
                "GET",
                path,
                _Erased.__init__[
                    call=_call_state_none[Self.S, E, String, _text]
                ](_Bound(handler, self._state)),
            )
        )

    def get[
        E: Deinitable, R: ToResponse, //, path: StaticString
    ](self, handler: def(State[Self.S]) thin raises E -> R):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert (
            _path_params(path) == 0
        ), "route declares a path parameter but the handler takes none"
        comptime assert (
            _query_params(path) == 0
        ), "route declares a query parameter but the handler takes none"
        self._app[]._routes.append(
            _StateRoute(
                "GET",
                path,
                _Erased.__init__[
                    call=_call_state_none[Self.S, E, R, _converted[R]]
                ](_Bound(handler, self._state)),
            )
        )

    def get[
        E: Deinitable, //, path: StaticString
    ](self, handler: def(State[Self.S], Int) thin raises E -> String):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert _path_params(path) + _query_params(path) == 1, (
            "handler takes one Int parameter; route must declare exactly one"
            " path or query parameter"
        )
        self._app[]._routes.append(
            _StateRoute(
                "GET",
                path,
                _Erased.__init__[
                    call=_call_state_int[Self.S, E, String, _text]
                ](_Bound(handler, self._state)),
            )
        )

    def get[
        E: Deinitable, R: ToResponse, //, path: StaticString
    ](self, handler: def(State[Self.S], Int) thin raises E -> R):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert _path_params(path) + _query_params(path) == 1, (
            "handler takes one Int parameter; route must declare exactly one"
            " path or query parameter"
        )
        self._app[]._routes.append(
            _StateRoute(
                "GET",
                path,
                _Erased.__init__[
                    call=_call_state_int[Self.S, E, R, _converted[R]]
                ](_Bound(handler, self._state)),
            )
        )

    def get[
        E: Deinitable, //, path: StaticString
    ](self, handler: def(State[Self.S], var Request) thin raises E -> Response):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert (
            _path_params(path) == 0
        ), "route declares a path parameter but the handler takes none"
        comptime assert (
            _query_params(path) == 0
        ), "route declares a query parameter but the handler takes none"
        self._app[]._routes.append(
            _StateRoute(
                "GET",
                path,
                _Erased.__init__[call=_call_state_raw[Self.S, E]](
                    _Bound(handler, self._state)
                ),
                raw=True,
            )
        )

    def post[
        B: Movable & Deinitable, E: Deinitable, //, path: StaticString
    ](self, handler: def(State[Self.S], var B) thin raises E -> String):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert _path_params(path) + _query_params(path) == 0, (
            "handler takes only the request body; route must declare no path"
            " or query parameter"
        )
        comptime assert not B == Int, (
            "Int is a route-value type, never the request body; the body"
            " parameter's type must conform to FromBody"
        )
        comptime assert not B == Request, (
            "Request is the whole request, not a body; a raw handler takes"
            " only the Request and returns Response"
        )
        comptime assert not conforms_to(
            B, _InjectedState
        ), "a handler takes at most one State, as its first parameter"
        comptime assert conforms_to(B, FromBody), (
            "the handler's last parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._app[]._routes.append(
            _StateRoute(
                "POST",
                path,
                _Erased.__init__[
                    call=_call_state_body[Self.S, B, E, String, _text]
                ](_Bound(handler, self._state)),
                body=True,
            )
        )

    def post[
        B: Movable & Deinitable,
        E: Deinitable,
        R: ToResponse,
        //,
        path: StaticString,
    ](self, handler: def(State[Self.S], var B) thin raises E -> R):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert _path_params(path) + _query_params(path) == 0, (
            "handler takes only the request body; route must declare no path"
            " or query parameter"
        )
        comptime assert not B == Int, (
            "Int is a route-value type, never the request body; the body"
            " parameter's type must conform to FromBody"
        )
        comptime assert not B == Request, (
            "Request is the whole request, not a body; a raw handler takes"
            " only the Request and returns Response"
        )
        comptime assert not conforms_to(
            B, _InjectedState
        ), "a handler takes at most one State, as its first parameter"
        comptime assert conforms_to(B, FromBody), (
            "the handler's last parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._app[]._routes.append(
            _StateRoute(
                "POST",
                path,
                _Erased.__init__[
                    call=_call_state_body[Self.S, B, E, R, _converted[R]]
                ](_Bound(handler, self._state)),
                body=True,
            )
        )

    def post[
        B: Movable & Deinitable, E: Deinitable, //, path: StaticString
    ](self, handler: def(State[Self.S], Int, var B) thin raises E -> String):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert _path_params(path) + _query_params(path) == 1, (
            "handler takes one Int parameter and the request body; route must"
            " declare exactly one path or query parameter"
        )
        comptime assert not B == Int, (
            "Int is a route-value type, never the request body; the body"
            " parameter's type must conform to FromBody"
        )
        comptime assert not B == Request, (
            "Request is the whole request, not a body; a raw handler takes"
            " only the Request and returns Response"
        )
        comptime assert not conforms_to(
            B, _InjectedState
        ), "a handler takes at most one State, as its first parameter"
        comptime assert conforms_to(B, FromBody), (
            "the handler's last parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._app[]._routes.append(
            _StateRoute(
                "POST",
                path,
                _Erased.__init__[
                    call=_call_state_int_body[Self.S, B, E, String, _text]
                ](_Bound(handler, self._state)),
                body=True,
            )
        )

    def post[
        B: Movable & Deinitable,
        E: Deinitable,
        R: ToResponse,
        //,
        path: StaticString,
    ](self, handler: def(State[Self.S], Int, var B) thin raises E -> R):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert _path_params(path) + _query_params(path) == 1, (
            "handler takes one Int parameter and the request body; route must"
            " declare exactly one path or query parameter"
        )
        comptime assert not B == Int, (
            "Int is a route-value type, never the request body; the body"
            " parameter's type must conform to FromBody"
        )
        comptime assert not B == Request, (
            "Request is the whole request, not a body; a raw handler takes"
            " only the Request and returns Response"
        )
        comptime assert not conforms_to(
            B, _InjectedState
        ), "a handler takes at most one State, as its first parameter"
        comptime assert conforms_to(B, FromBody), (
            "the handler's last parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._app[]._routes.append(
            _StateRoute(
                "POST",
                path,
                _Erased.__init__[
                    call=_call_state_int_body[Self.S, B, E, R, _converted[R]]
                ](_Bound(handler, self._state)),
                body=True,
            )
        )

    def post[
        E: Deinitable, //, path: StaticString
    ](self, handler: def(State[Self.S], var Request) thin raises E -> Response):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert (
            _path_params(path) == 0
        ), "route declares a path parameter but the handler takes none"
        comptime assert (
            _query_params(path) == 0
        ), "route declares a query parameter but the handler takes none"
        self._app[]._routes.append(
            _StateRoute(
                "POST",
                path,
                _Erased.__init__[call=_call_state_raw[Self.S, E]](
                    _Bound(handler, self._state)
                ),
                raw=True,
            )
        )


struct ScopedApp(Movable):
    """Production `App` plus `with_state`."""

    var _routes: List[_StateRoute]

    def __init__(out self):
        self._routes = List[_StateRoute]()

    def with_state[
        S: Movable & Deinitable
    ](mut self, state: State[S]) -> StateRoutes[S, origin_of(self)]:
        """Returns a registrar whose `get`/`post` take handlers whose first
        parameter is `State[S]`."""
        return StateRoutes(self, state)

    # Production's ten overloads.

    def get[
        E: Deinitable, //, path: StaticString
    ](mut self, handler: def() thin raises E -> String):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert (
            _path_params(path) == 0
        ), "route declares a path parameter but the handler takes none"
        comptime assert (
            _query_params(path) == 0
        ), "route declares a query parameter but the handler takes none"
        self._routes.append(
            _StateRoute(
                "GET",
                path,
                _Erased.__init__[call=_call_none[E, String, _text]](handler),
            )
        )

    def get[
        E: Deinitable, R: ToResponse, //, path: StaticString
    ](mut self, handler: def() thin raises E -> R):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert (
            _path_params(path) == 0
        ), "route declares a path parameter but the handler takes none"
        comptime assert (
            _query_params(path) == 0
        ), "route declares a query parameter but the handler takes none"
        self._routes.append(
            _StateRoute(
                "GET",
                path,
                _Erased.__init__[call=_call_none[E, R, _converted[R]]](handler),
            )
        )

    def get[
        E: Deinitable, //, path: StaticString
    ](mut self, handler: def(Int) thin raises E -> String):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert _path_params(path) + _query_params(path) == 1, (
            "handler takes one Int parameter; route must declare exactly one"
            " path or query parameter"
        )
        self._routes.append(
            _StateRoute(
                "GET",
                path,
                _Erased.__init__[call=_call_int[E, String, _text]](handler),
            )
        )

    def get[
        E: Deinitable, R: ToResponse, //, path: StaticString
    ](mut self, handler: def(Int) thin raises E -> R):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert _path_params(path) + _query_params(path) == 1, (
            "handler takes one Int parameter; route must declare exactly one"
            " path or query parameter"
        )
        self._routes.append(
            _StateRoute(
                "GET",
                path,
                _Erased.__init__[call=_call_int[E, R, _converted[R]]](handler),
            )
        )

    def get[
        E: Deinitable, //, path: StaticString
    ](mut self, handler: def(var Request) thin raises E -> Response):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert (
            _path_params(path) == 0
        ), "route declares a path parameter but the handler takes none"
        comptime assert (
            _query_params(path) == 0
        ), "route declares a query parameter but the handler takes none"
        self._routes.append(
            _StateRoute(
                "GET",
                path,
                _Erased.__init__[call=_call_raw[E]](handler),
                raw=True,
            )
        )

    def post[
        B: Movable & Deinitable, E: Deinitable, //, path: StaticString
    ](mut self, handler: def(var B) thin raises E -> String):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert _path_params(path) + _query_params(path) == 0, (
            "handler takes only the request body; route must declare no path"
            " or query parameter"
        )
        comptime assert not B == Int, (
            "Int is a route-value type, never the request body; the body"
            " parameter's type must conform to FromBody"
        )
        comptime assert not B == Request, (
            "Request is the whole request, not a body; a raw handler takes"
            " only the Request and returns Response"
        )
        comptime assert not conforms_to(B, _InjectedState), (
            "State is injected application state, not the request body;"
            " register the handler through app.with_state(state)"
        )
        comptime assert conforms_to(B, FromBody), (
            "the handler's parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _StateRoute(
                "POST",
                path,
                _Erased.__init__[call=_call_body[B, E, String, _text]](handler),
                body=True,
            )
        )

    def post[
        B: Movable & Deinitable,
        E: Deinitable,
        R: ToResponse,
        //,
        path: StaticString,
    ](mut self, handler: def(var B) thin raises E -> R):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert _path_params(path) + _query_params(path) == 0, (
            "handler takes only the request body; route must declare no path"
            " or query parameter"
        )
        comptime assert not B == Int, (
            "Int is a route-value type, never the request body; the body"
            " parameter's type must conform to FromBody"
        )
        comptime assert not B == Request, (
            "Request is the whole request, not a body; a raw handler takes"
            " only the Request and returns Response"
        )
        comptime assert not conforms_to(B, _InjectedState), (
            "State is injected application state, not the request body;"
            " register the handler through app.with_state(state)"
        )
        comptime assert conforms_to(B, FromBody), (
            "the handler's parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _StateRoute(
                "POST",
                path,
                _Erased.__init__[call=_call_body[B, E, R, _converted[R]]](
                    handler
                ),
                body=True,
            )
        )

    def post[
        B: Movable & Deinitable, E: Deinitable, //, path: StaticString
    ](mut self, handler: def(Int, var B) thin raises E -> String):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert _path_params(path) + _query_params(path) == 1, (
            "handler takes one Int parameter and the request body; route must"
            " declare exactly one path or query parameter"
        )
        comptime assert not B == Int, (
            "Int is a route-value type, never the request body; the body"
            " parameter's type must conform to FromBody"
        )
        comptime assert not B == Request, (
            "Request is the whole request, not a body; a raw handler takes"
            " only the Request and returns Response"
        )
        comptime assert not conforms_to(B, _InjectedState), (
            "State is injected application state, not the request body;"
            " register the handler through app.with_state(state)"
        )
        comptime assert conforms_to(B, FromBody), (
            "the handler's last parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _StateRoute(
                "POST",
                path,
                _Erased.__init__[call=_call_int_body[B, E, String, _text]](
                    handler
                ),
                body=True,
            )
        )

    def post[
        B: Movable & Deinitable,
        E: Deinitable,
        R: ToResponse,
        //,
        path: StaticString,
    ](mut self, handler: def(Int, var B) thin raises E -> R):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert _path_params(path) + _query_params(path) == 1, (
            "handler takes one Int parameter and the request body; route must"
            " declare exactly one path or query parameter"
        )
        comptime assert not B == Int, (
            "Int is a route-value type, never the request body; the body"
            " parameter's type must conform to FromBody"
        )
        comptime assert not B == Request, (
            "Request is the whole request, not a body; a raw handler takes"
            " only the Request and returns Response"
        )
        comptime assert not conforms_to(B, _InjectedState), (
            "State is injected application state, not the request body;"
            " register the handler through app.with_state(state)"
        )
        comptime assert conforms_to(B, FromBody), (
            "the handler's last parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _StateRoute(
                "POST",
                path,
                _Erased.__init__[call=_call_int_body[B, E, R, _converted[R]]](
                    handler
                ),
                body=True,
            )
        )

    def post[
        E: Deinitable, //, path: StaticString
    ](mut self, handler: def(var Request) thin raises E -> Response):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert (
            _path_params(path) == 0
        ), "route declares a path parameter but the handler takes none"
        comptime assert (
            _query_params(path) == 0
        ), "route declares a query parameter but the handler takes none"
        self._routes.append(
            _StateRoute(
                "POST",
                path,
                _Erased.__init__[call=_call_raw[E]](handler),
                raw=True,
            )
        )

    def handle(self, request: Request) -> Response:
        var args = List[String]()
        # Indexed, not `for route in self._routes`: on Mojo 1.1.0 List
        # iteration requires a `Copyable` element, and routes are move-only
        # because each owns its handler box.
        for i in range(len(self._routes)):
            ref route = self._routes[i]
            if route.method != request.method or not _match(
                route.path, request.path, args
            ):
                continue
            if route.raw:
                args.append(request.method)
                args.append(request.path)
                args.append(request.query)
                args.append(request.body)
            else:
                if route.query_key:
                    try:
                        args.append(
                            _query_value(request.query, route.query_key)
                        )
                    except:
                        return _bad_request()
                if route.body:
                    args.append(request.body)
            # No adapter raises: each answers its own 400s and turns a
            # handler error into a response. A raise here is a server fault,
            # never a client error.
            try:
                return route.handler.invoke(args)
            except:
                return _internal_error()
        return Response.text("Not Found", status=404)
