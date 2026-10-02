# M3-001 application-state decision spike, library side. Not production
# code: it models production `App` with the selected state registration
# added, separately from the application module (tests/test_spike_state.mojo)
# that defines the state types and handlers. Production's ten overloads are
# copied with their signatures and asserts unchanged (docstrings dropped),
# so overload resolution is measured against the real set; adapters, route
# checks, matching, query gathering and `_handler_error` are imported from
# production. Handlers are stored in the production `_Erased` box,
# unchanged. check.sh builds it through that test (--Werror) and through
# tests/state_lib_only/driver.mojo; test.sh runs it. Decision and evidence:
# docs/ARCHITECTURE.md, "Application state decision (M3-001)".
# Must-not-compile evidence: tests/state_fail.
#
# What changes against production, and only that:
#
#   State[S]   a Muntin-owned, shared, read-only handle to one application
#              value `S` (an `ArcPointer[S]` inside; safe stdlib, no unsafe
#              operation). `state[]` is an immutable reference, also through
#              a `mut` or owned `State`.
#   overloads  `get` and `post` each gain a second family whose call takes
#              two arguments, `(handler, state)`. The handler's first
#              parameter is `State[S]`; the rest is exactly one of the M2
#              shapes. `S` is inferred from both arguments. Every existing
#              call passes one argument, so the two families never compete
#              (argument count, not ranking, separates them).
#   box        the handler and a copy of the handle are moved into the
#              production `_Erased` as one `_Bound[H, S]` value; the
#              stateful adapters borrow both per request (no copy, no
#              refcount change, no allocation).
#   guard      production's four body overloads reject a `State` body by
#              conformance to the private marker `_InjectedState`, so a
#              stateful handler registered without its state gets a state
#              message instead of the `FromBody` one (diagnostics only).

from std.memory import ArcPointer

from muntin import Request, Response, ToResponse
from muntin.body import FromBody
from muntin._handler_storage import _Erased
from muntin.app import _bad_request, _converted, _handler_error, _text
from muntin.app import _call_body, _call_int, _call_int_body, _call_none
from muntin.app import _call_raw, _internal_error, _match, _parse_int
from muntin.app import _path_params, _query_params, _query_value


trait _InjectedState:
    """Marks `State`; lets the body overloads name it in a guard."""

    pass


struct State[S: Movable & Deinitable](Copyable, Movable, _InjectedState):
    """A shared, read-only handle to one application value of type `S`.

    The application builds it once, `State(Users(...))`, and passes it at
    every registration whose handler takes it. Copies share the one value
    (reference counted); the value is destroyed when the last handle, the
    application's or a route's, goes away. Handlers borrow the route's
    handle, so a request copies nothing.

    `state[]` is an immutable reference to the value through any handle,
    borrowed, `mut` or owned: Muntin never hands out mutable access. A value
    that must change while the application serves keeps that mutability in
    its own fields, under its own rules.
    """

    var _shared: ArcPointer[Self.S]

    def __init__(out self, var value: Self.S):
        self._shared = ArcPointer(value^)

    def __getitem__(self) -> ref[self._shared] Self.S:
        return self._shared[]


struct _Bound[H: Movable & Deinitable, S: Movable & Deinitable](Movable):
    """A stateful handler and its route's copy of the state handle, boxed
    together as one `_Erased` value."""

    var handler: Self.H
    var state: State[Self.S]

    def __init__(out self, var handler: Self.H, state: State[Self.S]):
        self.handler = handler^
        self.state = state.copy()


# Stateful adapters: production's adapters with the state passed first.
# Each answers its own request-side 400s exactly where production's twin
# does, then calls the handler alone in a `try`.


def _call_state_none[
    S: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    respond: def(var R) thin -> Response,
](
    bound: _Bound[def(State[S]) thin raises E -> R, S], args: List[String]
) -> Response:
    var result: R
    try:
        result = bound.handler(bound.state)
    except e:
        return _handler_error(e^)
    return respond(result^)


def _call_state_int[
    S: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    respond: def(var R) thin -> Response,
](
    bound: _Bound[def(State[S], Int) thin raises E -> R, S],
    args: List[String],
) -> Response:
    var id: Int
    try:
        id = _parse_int(args[0])
    except:
        return _bad_request()
    var result: R
    try:
        result = bound.handler(bound.state, id)
    except e:
        return _handler_error(e^)
    return respond(result^)


def _call_state_body[
    S: Movable & Deinitable,
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    respond: def(var R) thin -> Response,
](
    bound: _Bound[def(State[S], var B) thin raises E -> R, S],
    args: List[String],
) -> Response:
    comptime assert conforms_to(B, FromBody)
    var body: B
    try:
        body = B.from_body(args[0])
    except:
        return _bad_request()
    var result: R
    try:
        result = bound.handler(bound.state, body^)
    except e:
        return _handler_error(e^)
    return respond(result^)


def _call_state_int_body[
    S: Movable & Deinitable,
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    respond: def(var R) thin -> Response,
](
    bound: _Bound[def(State[S], Int, var B) thin raises E -> R, S],
    args: List[String],
) -> Response:
    comptime assert conforms_to(B, FromBody)
    var id: Int
    try:
        id = _parse_int(args[0])
    except:
        return _bad_request()
    var body: B
    try:
        body = B.from_body(args[1])
    except:
        return _bad_request()
    var result: R
    try:
        result = bound.handler(bound.state, id, body^)
    except e:
        return _handler_error(e^)
    return respond(result^)


def _call_state_raw[
    S: Movable & Deinitable, E: Deinitable
](
    bound: _Bound[def(State[S], var Request) thin raises E -> Response, S],
    args: List[String],
) -> Response:
    var target = args[1]
    if args[2].byte_length() > 0:
        target += "?" + args[2]
    var request = Request(args[0], target, args[3])
    var result: Response
    try:
        result = bound.handler(bound.state, request^)
    except e:
        return _handler_error(e^)
    return result^


struct _StateRoute(Movable):
    var method: String
    var path: String
    var query_key: String
    var body: Bool
    var raw: Bool
    var handler: _Erased

    def __init__(
        out self,
        method: String,
        route: StaticString,
        var handler: _Erased,
        body: Bool = False,
        raw: Bool = False,
    ):
        self.method = method
        self.body = body
        self.raw = raw
        var mark = route.find("?")
        if mark < 0:
            self.path = String(route)
            self.query_key = String()
        else:
            self.path = String(route[byte=:mark])
            self.query_key = String(
                route[byte = mark + 2 : route.byte_length() - 1]
            )
        self.handler = handler^


struct StateApp(Movable):
    """Production `App` plus the stateful registration family."""

    var _routes: List[_StateRoute]

    def __init__(out self):
        self._routes = List[_StateRoute]()

    # Stateful family (new): two arguments, `(handler, state)`.

    def get[
        S: Movable & Deinitable, E: Deinitable, //, path: StaticString
    ](
        mut self,
        handler: def(State[S]) thin raises E -> String,
        state: State[S],
    ):
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
                _Erased.__init__[call=_call_state_none[S, E, String, _text]](
                    _Bound(handler, state)
                ),
            )
        )

    def get[
        S: Movable & Deinitable,
        E: Deinitable,
        R: ToResponse,
        //,
        path: StaticString,
    ](mut self, handler: def(State[S]) thin raises E -> R, state: State[S],):
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
                _Erased.__init__[call=_call_state_none[S, E, R, _converted[R]]](
                    _Bound(handler, state)
                ),
            )
        )

    def get[
        S: Movable & Deinitable, E: Deinitable, //, path: StaticString
    ](
        mut self,
        handler: def(State[S], Int) thin raises E -> String,
        state: State[S],
    ):
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
                _Erased.__init__[call=_call_state_int[S, E, String, _text]](
                    _Bound(handler, state)
                ),
            )
        )

    def get[
        S: Movable & Deinitable,
        E: Deinitable,
        R: ToResponse,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], Int) thin raises E -> R,
        state: State[S],
    ):
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
                _Erased.__init__[call=_call_state_int[S, E, R, _converted[R]]](
                    _Bound(handler, state)
                ),
            )
        )

    def get[
        S: Movable & Deinitable, E: Deinitable, //, path: StaticString
    ](
        mut self,
        handler: def(State[S], var Request) thin raises E -> Response,
        state: State[S],
    ):
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
                _Erased.__init__[call=_call_state_raw[S, E]](
                    _Bound(handler, state)
                ),
                raw=True,
            )
        )

    def post[
        S: Movable & Deinitable,
        B: Movable & Deinitable,
        E: Deinitable,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var B) thin raises E -> String,
        state: State[S],
    ):
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
        self._routes.append(
            _StateRoute(
                "POST",
                path,
                _Erased.__init__[call=_call_state_body[S, B, E, String, _text]](
                    _Bound(handler, state)
                ),
                body=True,
            )
        )

    def post[
        S: Movable & Deinitable,
        B: Movable & Deinitable,
        E: Deinitable,
        R: ToResponse,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var B) thin raises E -> R,
        state: State[S],
    ):
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
        self._routes.append(
            _StateRoute(
                "POST",
                path,
                _Erased.__init__[
                    call=_call_state_body[S, B, E, R, _converted[R]]
                ](_Bound(handler, state)),
                body=True,
            )
        )

    def post[
        S: Movable & Deinitable,
        B: Movable & Deinitable,
        E: Deinitable,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], Int, var B) thin raises E -> String,
        state: State[S],
    ):
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
        self._routes.append(
            _StateRoute(
                "POST",
                path,
                _Erased.__init__[
                    call=_call_state_int_body[S, B, E, String, _text]
                ](_Bound(handler, state)),
                body=True,
            )
        )

    def post[
        S: Movable & Deinitable,
        B: Movable & Deinitable,
        E: Deinitable,
        R: ToResponse,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], Int, var B) thin raises E -> R,
        state: State[S],
    ):
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
        self._routes.append(
            _StateRoute(
                "POST",
                path,
                _Erased.__init__[
                    call=_call_state_int_body[S, B, E, R, _converted[R]]
                ](_Bound(handler, state)),
                body=True,
            )
        )

    def post[
        S: Movable & Deinitable, E: Deinitable, //, path: StaticString
    ](
        mut self,
        handler: def(State[S], var Request) thin raises E -> Response,
        state: State[S],
    ):
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
                _Erased.__init__[call=_call_state_raw[S, E]](
                    _Bound(handler, state)
                ),
                raw=True,
            )
        )

    # Production's ten overloads, signatures and asserts unchanged; the
    # four body overloads gain the `State` guard.

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
            "State is injected application state, not the request body; pass"
            " the state as the registration's second argument"
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
            "State is injected application state, not the request body; pass"
            " the state as the registration's second argument"
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
            "State is injected application state, not the request body; pass"
            " the state as the registration's second argument"
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
            "State is injected application state, not the request body; pass"
            " the state as the registration's second argument"
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
