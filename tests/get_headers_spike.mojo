# M3-016 typed `get` header access decision spike, library side. Not
# production code: it models production `get` (M3-015's six arity overloads)
# with one more request-slot kind, a `Headers` slot, last. The application
# module (tests/test_spike_get_headers.mojo) defines the handlers.
#
# The six `get` overloads are free functions here (`get[path](app, h)`, with
# production's signatures and `where` clause, `mut self` becoming
# `mut app: App`), so overload resolution is measured against the same set.
# Registration appends to production `App._routes`, and requests go through
# production `App.handle`, unchanged: a `Headers` route sets the existing
# `_Route.headers` flag, and `App.handle` already appends each field's name
# and value after the route value on a route without a body. Production's
# `_kind`, placeholder counts, rule codes, `_Erased`, `_Bound`, the arity-0
# adapters, `_slot`, `_as`, `_rejected`, `_respond` and `_handler_error` are
# imported unchanged. Decision and evidence: docs/ARCHITECTURE.md, "Typed get
# header access decision (M3-016)". Must-not-compile evidence:
# tests/get_headers_fail.
#
# What changes against production `get`, and only that:
#
#   kind      `_kind_h`: `Headers`, by type equality, is the new kind
#             `_HEADERS`; every other type keeps production `_kind`.
#   rule      `_get_rule_h`: production `_get_rule` with one branch after
#             its `State`, `Request`, body and no-kind checks, so their
#             messages win unchanged: a `Headers` slot is accepted once, as
#             the last slot, after at most one `Int` route value, with the
#             placeholder rules of the route value it follows.
#   messages  `_check_h`: production's `get` messages (the slot-kind one
#             names `Headers` too), plus `_GET_HEADERS_LAST`.
#   slot      `_slot_h`: a `Headers` slot is rebuilt from the name and
#             value pairs from its own index on (only route values precede
#             it), through `Headers.add`; a failure (only the M3-002
#             `_fields` gap) is the fixed 500. Every other slot is
#             production `_slot`.
#   adapters  the four with slots are production's with `_slot_h`.

from std.os import abort

from muntin import App, Headers, Response, State, ToResponse
from muntin._handler_storage import _Erased
from muntin.app import _ABSENT, _BODY, _GET_BODY, _GET_INT_PLACES
from muntin.app import _GET_RAW, _GET_SLOT_KIND, _GET_STATE_ARGUMENT
from muntin.app import _GET_STATE_RAW, _GET_TWO_VALUES, _INT, _MALFORMED
from muntin.app import _NoSlot, _OK, _ONE_STATE, _OTHER, _PATH_TAKES_NONE
from muntin.app import _QUERY_TAKES_NONE, _RAW, _STATE, _GUARD_DRIFT
from muntin.app import _Bound, _Reject, _Route, _as, _call_0, _call_state_0
from muntin.app import _handler_error, _kind, _path_params, _query_params
from muntin.app import _rejected, _respond, _slot, _takes_none


comptime _HEADERS = 6
comptime _GET_HEADERS_LAST = 25


def _kind_h[A: AnyType]() -> Int:
    comptime if A == Headers:
        return _HEADERS
    else:
        return _kind[A]()


def _get_rule_h(
    stateful: Bool, k1: Int, k2: Int, response: Bool, paths: Int, queries: Int
) -> Int:
    """Production `_get_rule` as of M3-015 with the `Headers` branch."""
    if k1 == _STATE or k2 == _STATE:
        return _ONE_STATE if stateful else _GET_STATE_ARGUMENT
    if k1 == _RAW or k2 == _RAW:
        if k1 != _RAW or k2 != _ABSENT or not response:
            return _GET_STATE_RAW if stateful else _GET_RAW
        return _takes_none(paths, queries)
    if k1 == _BODY or k2 == _BODY:
        return _GET_BODY
    if k1 == _OTHER or k2 == _OTHER:
        return _GET_SLOT_KIND
    if k1 == _HEADERS:
        if k2 != _ABSENT:
            return _GET_HEADERS_LAST
        return _takes_none(paths, queries)
    if k2 == _HEADERS:
        return _OK if paths + queries == 1 else _GET_INT_PLACES
    if k2 == _INT:
        return _GET_TWO_VALUES
    if k1 == _INT:
        return _OK if paths + queries == 1 else _GET_INT_PLACES
    return _takes_none(paths, queries)


def _rule_h[
    stateful: Bool, path: StaticString, R: AnyType, A: AnyType, B: AnyType
]() -> Int:
    var paths = _path_params(path)
    var queries = _query_params(path)
    if paths < 0 or queries < 0:
        return _MALFORMED
    return _get_rule_h(
        stateful, _kind_h[A](), _kind_h[B](), R == Response, paths, queries
    )


def _admits_h[
    stateful: Bool, path: StaticString, R: AnyType, A: AnyType, B: AnyType
]() -> Bool:
    return _rule_h[stateful, path, R, A, B]() == _OK


def _check_h[
    stateful: Bool, path: StaticString, R: AnyType, A: AnyType, B: AnyType
]():
    """Production's `get` messages as of M3-015, the slot-kind one naming
    `Headers` too, and the `Headers` placement message."""
    comptime rule = _rule_h[stateful, path, R, A, B]()
    comptime assert rule != _MALFORMED, "malformed route literal"
    comptime assert (
        rule != _PATH_TAKES_NONE
    ), "route declares a path parameter but the handler takes none"
    comptime assert (
        rule != _QUERY_TAKES_NONE
    ), "route declares a query parameter but the handler takes none"
    comptime assert rule != _GET_INT_PLACES, (
        "handler takes one Int parameter; route must declare exactly one"
        " path or query parameter"
    )
    comptime assert rule != _GET_STATE_ARGUMENT, (
        "State is injected application state; a stateful get handler takes"
        " State first, and the state is the registration's second argument"
    )
    comptime assert (
        rule != _GET_RAW
    ), "a raw get handler takes only the Request and returns Response"
    comptime assert rule != _GET_STATE_RAW, (
        "a stateful raw get handler takes State first, then only the"
        " Request, and returns Response"
    )
    comptime assert rule != _GET_BODY, "a get handler takes no request body"
    comptime assert rule != _GET_SLOT_KIND, (
        "a get handler's parameter is an Int route value, the request"
        " Headers or, for a raw handler, the Request"
    )
    comptime assert (
        rule != _GET_TWO_VALUES
    ), "a get handler takes at most one Int route value"
    comptime assert (
        rule != _ONE_STATE
    ), "a handler takes at most one State, as its first parameter"
    comptime assert (
        rule != _GET_HEADERS_LAST
    ), "a get handler takes one Headers, as its last parameter"
    comptime assert rule == _OK, "internal: a registration rule has no message"


def _header_slot(args: List[String], at: Int) raises -> Headers:
    """The fields of a `Headers` slot: the name and value pairs from
    `args[at]` on, in order, rebuilt through `Headers.add`."""
    var headers = Headers()
    var i = at
    while i + 1 < len(args):
        headers.add(args[i], args[i + 1])
        i += 2
    return headers^


def _slot_h[
    A: Movable & Deinitable, at: Int
](args: List[String]) raises _Reject -> A:
    comptime if A == Headers:
        try:
            return _as[Headers, A](_header_slot(args, at))
        except:
            raise _Reject(500)  # only the `_fields` gap gets here
    else:
        return _slot[A, at](args)


def _call_h_1[
    A: Movable & Deinitable, E: Deinitable, R: Movable & Deinitable
](handler: def(var A) thin raises E -> R, args: List[String]) -> Response:
    var a: A
    try:
        a = _slot_h[A, 0](args)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = handler(a^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_h_2[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
](
    handler: def(var A, var B) thin raises E -> R, args: List[String]
) -> Response:
    var a: A
    var b: B
    try:
        a = _slot_h[A, 0](args)
        b = _slot_h[B, 1](args)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = handler(a^, b^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_h_state_1[
    S: Movable & Deinitable,
    A: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
](
    bound: _Bound[def(State[S], var A) thin raises E -> R, S],
    args: List[String],
) -> Response:
    var a: A
    try:
        a = _slot_h[A, 0](args)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = bound.handler(bound.state, a^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_h_state_2[
    S: Movable & Deinitable,
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
](
    bound: _Bound[def(State[S], var A, var B) thin raises E -> R, S],
    args: List[String],
) -> Response:
    var a: A
    var b: B
    try:
        a = _slot_h[A, 0](args)
        b = _slot_h[B, 1](args)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = bound.handler(bound.state, a^, b^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _route_h[Last: AnyType](path: StaticString, var box: _Erased) -> _Route:
    """Production `_route` for a `get` handler: no body, raw for a
    `Request`, and the existing `headers` flag for a `Headers` slot."""
    return _Route(
        "GET",
        path,
        box^,
        headers=_kind_h[Last]() == _HEADERS,
        raw=_kind_h[Last]() == _RAW,
    )


def get[
    E: Deinitable, R: Movable & Deinitable, //, path: StaticString
](mut app: App, handler: def() thin raises E -> R) where (
    R == String or R == StaticString or conforms_to(R, ToResponse)
):
    _check_h[False, path, R, _NoSlot, _NoSlot]()
    comptime if _admits_h[False, path, R, _NoSlot, _NoSlot]():
        app._routes.append(
            _route_h[_NoSlot](
                path, _Erased.__init__[call=_call_0[E, R]](handler)
            )
        )
    else:
        abort(_GUARD_DRIFT)


def get[
    A: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    //,
    path: StaticString,
](mut app: App, handler: def(var A) thin raises E -> R) where (
    R == String or R == StaticString or conforms_to(R, ToResponse)
):
    _check_h[False, path, R, A, _NoSlot]()
    comptime if _admits_h[False, path, R, A, _NoSlot]():
        app._routes.append(
            _route_h[A](
                path, _Erased.__init__[call=_call_h_1[A, E, R]](handler)
            )
        )
    else:
        abort(_GUARD_DRIFT)


def get[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    //,
    path: StaticString,
](mut app: App, handler: def(var A, var B) thin raises E -> R) where (
    R == String or R == StaticString or conforms_to(R, ToResponse)
):
    _check_h[False, path, R, A, B]()
    comptime if _admits_h[False, path, R, A, B]():
        app._routes.append(
            _route_h[B](
                path, _Erased.__init__[call=_call_h_2[A, B, E, R]](handler)
            )
        )
    else:
        abort(_GUARD_DRIFT)


def get[
    S: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    //,
    path: StaticString,
](
    mut app: App, handler: def(State[S]) thin raises E -> R, state: State[S]
) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
    _check_h[True, path, R, _NoSlot, _NoSlot]()
    comptime if _admits_h[True, path, R, _NoSlot, _NoSlot]():
        app._routes.append(
            _route_h[_NoSlot](
                path,
                _Erased.__init__[call=_call_state_0[S, E, R]](
                    _Bound(handler, state)
                ),
            )
        )
    else:
        abort(_GUARD_DRIFT)


def get[
    S: Movable & Deinitable,
    A: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    //,
    path: StaticString,
](
    mut app: App,
    handler: def(State[S], var A) thin raises E -> R,
    state: State[S],
) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
    _check_h[True, path, R, A, _NoSlot]()
    comptime if _admits_h[True, path, R, A, _NoSlot]():
        app._routes.append(
            _route_h[A](
                path,
                _Erased.__init__[call=_call_h_state_1[S, A, E, R]](
                    _Bound(handler, state)
                ),
            )
        )
    else:
        abort(_GUARD_DRIFT)


def get[
    S: Movable & Deinitable,
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    //,
    path: StaticString,
](
    mut app: App,
    handler: def(State[S], var A, var B) thin raises E -> R,
    state: State[S],
) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
    _check_h[True, path, R, A, B]()
    comptime if _admits_h[True, path, R, A, B]():
        app._routes.append(
            _route_h[B](
                path,
                _Erased.__init__[call=_call_h_state_2[S, A, B, E, R]](
                    _Bound(handler, state)
                ),
            )
        )
    else:
        abort(_GUARD_DRIFT)
