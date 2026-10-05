# M3-014 registration-structure spike, library side. Not production code.
#
# Models the selected candidate (C4r, docs/ARCHITECTURE.md "Registration
# structure decision (M3-014)"): a registration method keeps one overload
# per request-slot arity (a stateful family keeps a fixed leading
# `State[S]`), and every request-derived parameter is a generic slot
# `var A` whose kind is decided at compile time from its type, instead of
# one overload per (shape, result policy). The result type `R` is generic
# too and its policy is chosen at compile time. `_Erased`, `_Bound`,
# `_handler_error` and the raw-argument transport are production's,
# unchanged.
#
#   Registrar.on[method, path]   arity 0..2, stateless and stateful (the
#                                state is the second argument, as today):
#                                six overloads where production has ten
#                                per method
#   _kind[A]                     Int or String (route values), Request
#                                (raw), Headers, State (only first, through
#                                the stateful overloads), FromBody or a
#                                WithHeaders carrier (body), anything else
#   where (R == String or ...)   the result rule, on every overload: a
#                                `where` clause is checked by identity at
#                                the call site, which a check in the body
#                                cannot do for `StaticString`
#                                (tests/registration_fail/
#                                immutable_origin_result_rejected.mojo)
#   _shape_ok / _check_shape     every other rule as one Bool and as asserts with
#                                Muntin's messages; the Bool guards the
#                                adapter instantiation, so a rejected shape
#                                reports the rule, not an adapter's failure
#                                (tests/registration_fail/
#                                slot_misuse_names_the_rule.mojo). The two
#                                must accept the same shapes: if the Bool
#                                is stricter, the guard's `else` aborts at
#                                registration instead of dropping the
#                                route (a compile-time `else` assert would
#                                be reported instead of the rule)
#   _as[T, A]                    the only `rebind_var`: type equality
#                                asserted first, because `rebind_var`
#                                reinterprets layout twins
#                                (tests/registration_known_gaps); exact for
#                                origin-free types, while generic `==`
#                                keeps an origin's mutability but not its
#                                identity
#
# Route literals, matching, JSON and carrier steps are production's and are
# not modelled here; the scratch copies of src/muntin measured them (the
# decision record). The application side is
# tests/test_spike_registration.mojo.

from std.builtin.rebind import rebind_var
from std.os import abort

from muntin import FromBody, Headers, Request, Response, State, ToResponse
from muntin._handler_storage import _Erased
from muntin.app import (
    _Bound,
    _bad_request,
    _handler_error,
    _internal_error,
    _parse_int,
    _path_params,
    _query_params,
)
from muntin.headers_body import _HeaderCarrier
from muntin.state import _InjectedState

comptime _ABSENT = -1
comptime _OTHER = 0
comptime _INT = 1
comptime _STRING = 2
comptime _BODY = 3
comptime _RAW = 4
comptime _HEADERS = 5
comptime _STATE = 6


def _kind[A: AnyType]() -> Int:
    """The slot kind of a handler parameter type. Type equality (exact
    here: these types carry no origin) for
    the stdlib and Muntin types that cannot conform to a Muntin trait;
    `conforms_to` for the rest."""
    comptime if A == Int:
        return _INT
    elif A == String:
        return _STRING
    elif A == Request:
        return _RAW
    elif A == Headers:
        return _HEADERS
    elif conforms_to(A, _InjectedState):
        return _STATE
    elif conforms_to(A, FromBody) or conforms_to(A, _HeaderCarrier):
        return _BODY
    else:
        return _OTHER


def _count[k: Int, k1: Int, k2: Int]() -> Int:
    var n = 0
    if k1 == k:
        n += 1
    if k2 == k:
        n += 1
    return n


def _values[k1: Int, k2: Int]() -> Int:
    return _count[_INT, k1, k2]() + _count[_STRING, k1, k2]()


def _last[k1: Int, k2: Int]() -> Int:
    if k2 != _ABSENT:
        return k2
    return k1


def _is_text[R: AnyType]() -> Bool:
    return R == String or R == StaticString


def _shape_ok[
    method: StaticString, path: StaticString, R: AnyType, k1: Int, k2: Int
]() -> Bool:
    """`_check_shape` as one Bool, evaluated before any adapter is named."""
    if _path_params(path) < 0 or _query_params(path) < 0:
        return False
    if _count[_OTHER, k1, k2]() + _count[_STATE, k1, k2]() != 0:
        return False
    var places = _path_params(path) + _query_params(path)
    if _count[_RAW, k1, k2]() > 0:
        return k2 == _ABSENT and R == Response and places == 0
    var nbody = _count[_BODY, k1, k2]()
    if nbody > 1 or places != _values[k1, k2]():
        return False
    if nbody == 1:
        return _last[k1, k2]() == _BODY and method != "GET"
    return method != "POST"


def _check_shape[
    method: StaticString, path: StaticString, R: AnyType, k1: Int, k2: Int
]():
    """Every registration rule, as compile-time asserts with a message."""
    comptime assert (
        _path_params(path) >= 0 and _query_params(path) >= 0
    ), "malformed route literal"
    comptime assert _count[_OTHER, k1, k2]() == 0, (
        "a handler parameter is not a route value (Int, String), a request"
        " body (FromBody, WithHeaders), Headers or Request"
    )
    comptime assert _count[_STATE, k1, k2]() == 0, (
        "State is injected application state; it is the handler's first"
        " parameter and the state is the registration's second argument"
    )
    comptime places = _path_params(path) + _query_params(path)
    comptime if _count[_RAW, k1, k2]() > 0:
        comptime assert k2 == _ABSENT, (
            "Request is the whole request; a raw handler takes only the"
            " Request and returns Response"
        )
        comptime assert R == Response, "a raw handler returns Response"
        comptime assert places == 0, "a raw route declares no parameter"
    else:
        comptime assert (
            _count[_BODY, k1, k2]() <= 1
        ), "a handler takes at most one request body"
        comptime assert places == _values[k1, k2](), (
            "the route's placeholders must match the handler's route-value"
            " parameters"
        )
        comptime if _count[_BODY, k1, k2]() == 1:
            comptime assert (
                _last[k1, k2]() == _BODY
            ), "the request body is the handler's last parameter"
            comptime assert (
                method != "GET"
            ), "a GET handler takes no request body"
        else:
            comptime assert (
                method != "POST"
            ), "a POST handler takes the request body as its last parameter"


def _as[T: Movable, A: Movable](var value: T) -> A:
    """`value` as `A`, which must equal `T` (exactly, for origin-free
    types; generic `==` ignores which origin a slice has). `comptime if A == Int`
    does not refine `A` on Mojo 1.1.0
    (tests/header_access_fail/generic_slot_does_not_refine.mojo), and
    `rebind_var` alone also accepts a different type with the same layout
    (tests/registration_known_gaps/rebind_var_layout_twins.mojo), so the
    equality is asserted here, the one place the spike rebinds."""
    comptime assert A == T, "rebind requires generic type equality"
    return rebind_var[A](value^)


@fieldwise_init
struct _Reject(Movable):
    var status: Int


def _reject(r: _Reject) -> Response:
    if r.status == 400:
        return _bad_request()
    return _internal_error()


def _respond[R: Movable & Deinitable](var result: R) -> Response:
    """The result policy, chosen at compile time from `R`."""
    comptime if R == String:
        return Response.text(_as[R, String](result^))
    elif R == StaticString:
        return Response.text(String(_as[R, StaticString](result^)))
    else:
        comptime assert conforms_to(R, ToResponse)
        return result^.to_response()


def _slot[
    A: Movable & Deinitable, at: Int
](args: List[String]) raises _Reject -> A:
    """One handler argument from the raw arguments: a route value at its
    index among the values; the body after the values (a `WithHeaders`
    carrier with the name and value pairs after it); a raw `Request` from
    method, path and body; `Headers` from the pairs at its index."""
    comptime if A == Int:
        try:
            return _as[Int, A](_parse_int(args[at]))
        except:
            raise _Reject(400)
    elif A == String:
        return _as[String, A](args[at])
    elif A == Request:
        return _as[Request, A](Request(args[0], args[1], args[2]))
    elif A == Headers:
        var headers = Headers()
        var i = at
        try:
            while i + 1 < len(args):
                headers.add(args[i], args[i + 1])
                i += 2
        except:
            raise _Reject(500)
        return _as[Headers, A](headers^)
    elif conforms_to(A, _HeaderCarrier):
        var fields = Headers()
        var i = at + 1
        try:
            while i + 1 < len(args):
                fields.add(args[i], args[i + 1])
                i += 2
        except:
            raise _Reject(500)
        try:
            return A._from_parts(args[at], fields^)
        except:
            raise _Reject(400)
    else:
        comptime assert conforms_to(A, FromBody)
        try:
            return A.from_body(args[at])
        except:
            raise _Reject(400)


def _index[k: Int, before: Int, k1: Int, k2: Int]() -> Int:
    """A slot's raw index: a route value's position among the values
    (`before` is how many come earlier); the body after every value;
    Headers' name and value pairs after the values and the body."""
    if k == _INT or k == _STRING:
        return before
    if k == _BODY:
        return _values[k1, k2]()
    return _values[k1, k2]() + _count[_BODY, k1, k2]()


def _call0[
    E: Deinitable, R: Movable & Deinitable
](handler: def() thin raises E -> R, args: List[String]) -> Response:
    var result: R
    try:
        result = handler()
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call1[
    A: Movable & Deinitable, E: Deinitable, R: Movable & Deinitable, a: Int
](handler: def(var A) thin raises E -> R, args: List[String]) -> Response:
    var x: A
    try:
        x = _slot[A, a](args)
    except r:
        return _reject(r)
    var result: R
    try:
        result = handler(x^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call2[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    a: Int,
    b: Int,
](
    handler: def(var A, var B) thin raises E -> R, args: List[String]
) -> Response:
    var x: A
    var y: B
    try:
        x = _slot[A, a](args)
        y = _slot[B, b](args)
    except r:
        return _reject(r)
    var result: R
    try:
        result = handler(x^, y^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _scall1[
    S: Movable & Deinitable,
    A: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    a: Int,
](
    bound: _Bound[def(State[S], var A) thin raises E -> R, S],
    args: List[String],
) -> Response:
    var x: A
    try:
        x = _slot[A, a](args)
    except r:
        return _reject(r)
    var result: R
    try:
        result = bound.handler(bound.state, x^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _shape_name[k: Int]() -> String:
    comptime if k == _INT:
        return "Int"
    elif k == _STRING:
        return "String"
    elif k == _BODY:
        return "body"
    elif k == _RAW:
        return "Request"
    elif k == _HEADERS:
        return "Headers"
    return "?"


def _result_name[R: AnyType]() -> String:
    comptime if _is_text[R]():
        return "text"
    return "converted"


struct Registrar(Movable):
    """Records each registration's method, slot kinds and result policy,
    and keeps its box for `invoke` (raw arguments as production builds
    them; matching is not modelled)."""

    var shapes: List[String]
    var _boxes: List[_Erased]

    def __init__(out self):
        self.shapes = List[String]()
        self._boxes = List[_Erased]()

    def invoke(self, i: Int, args: List[String]) raises -> Response:
        return self._boxes[i].invoke(args)

    def on[
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        method: StaticString,
        path: StaticString,
    ](mut self, handler: def() thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        _check_shape[method, path, R, _ABSENT, _ABSENT]()
        comptime if _shape_ok[method, path, R, _ABSENT, _ABSENT]():
            self.shapes.append(String(method, " () -> ", _result_name[R]()))
            self._boxes.append(_Erased.__init__[call=_call0[E, R]](handler))
        else:
            abort("registration rule check and guard disagree")

    def on[
        A: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        method: StaticString,
        path: StaticString,
    ](mut self, handler: def(var A) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        comptime k1 = _kind[A]()
        _check_shape[method, path, R, k1, _ABSENT]()
        comptime if _shape_ok[method, path, R, k1, _ABSENT]():
            self.shapes.append(
                String(
                    method,
                    " (",
                    _shape_name[k1](),
                    ") -> ",
                    _result_name[R](),
                )
            )
            self._boxes.append(
                _Erased.__init__[
                    call=_call1[A, E, R, _index[k1, 0, k1, _ABSENT]()]
                ](handler)
            )
        else:
            abort("registration rule check and guard disagree")

    def on[
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        method: StaticString,
        path: StaticString,
    ](mut self, handler: def(var A, var B) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        comptime k1 = _kind[A]()
        comptime k2 = _kind[B]()
        _check_shape[method, path, R, k1, k2]()
        comptime if _shape_ok[method, path, R, k1, k2]():
            comptime v1 = _values[k1, _ABSENT]()
            comptime a = _index[k1, 0, k1, k2]()
            comptime b = _index[k2, v1, k1, k2]()
            self.shapes.append(
                String(
                    method,
                    " (",
                    _shape_name[k1](),
                    ", ",
                    _shape_name[k2](),
                    ") -> ",
                    _result_name[R](),
                )
            )
            self._boxes.append(
                _Erased.__init__[call=_call2[A, B, E, R, a, b]](handler)
            )
        else:
            abort("registration rule check and guard disagree")

    def on[
        S: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        method: StaticString,
        path: StaticString,
    ](
        mut self, handler: def(State[S]) thin raises E -> R, state: State[S]
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Stateful arity 0: the state is the registration's second
        argument, so this family never competes with the stateless one."""
        _check_shape[method, path, R, _ABSENT, _ABSENT]()
        comptime if _shape_ok[method, path, R, _ABSENT, _ABSENT]():
            self.shapes.append(
                String(method, " (State) -> ", _result_name[R]())
            )
            self._boxes.append(
                _Erased.__init__[call=_scall0[S, E, R]](_Bound(handler, state))
            )
        else:
            abort("registration rule check and guard disagree")

    def on[
        S: Movable & Deinitable,
        A: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        method: StaticString,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var A) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        comptime k1 = _kind[A]()
        _check_shape[method, path, R, k1, _ABSENT]()
        comptime if _shape_ok[method, path, R, k1, _ABSENT]():
            self.shapes.append(
                String(
                    method,
                    " (State, ",
                    _shape_name[k1](),
                    ") -> ",
                    _result_name[R](),
                )
            )
            self._boxes.append(
                _Erased.__init__[
                    call=_scall1[S, A, E, R, _index[k1, 0, k1, _ABSENT]()]
                ](_Bound(handler, state))
            )
        else:
            abort("registration rule check and guard disagree")

    def on[
        S: Movable & Deinitable,
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        method: StaticString,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var A, var B) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        comptime k1 = _kind[A]()
        comptime k2 = _kind[B]()
        _check_shape[method, path, R, k1, k2]()
        comptime if _shape_ok[method, path, R, k1, k2]():
            self.shapes.append(
                String(
                    method,
                    " (State, ",
                    _shape_name[k1](),
                    ", ",
                    _shape_name[k2](),
                    ") -> ",
                    _result_name[R](),
                )
            )
            comptime v1 = _values[k1, _ABSENT]()
            comptime a = _index[k1, 0, k1, k2]()
            comptime b = _index[k2, v1, k1, k2]()
            self._boxes.append(
                _Erased.__init__[call=_scall2[S, A, B, E, R, a, b]](
                    _Bound(handler, state)
                )
            )
        else:
            abort("registration rule check and guard disagree")


def _scall2[
    S: Movable & Deinitable,
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    a: Int,
    b: Int,
](
    bound: _Bound[def(State[S], var A, var B) thin raises E -> R, S],
    args: List[String],
) -> Response:
    var x: A
    var y: B
    try:
        x = _slot[A, a](args)
        y = _slot[B, b](args)
    except r:
        return _reject(r)
    var result: R
    try:
        result = bound.handler(bound.state, x^, y^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _scall0[
    S: Movable & Deinitable, E: Deinitable, R: Movable & Deinitable
](
    bound: _Bound[def(State[S]) thin raises E -> R, S], args: List[String]
) -> Response:
    var result: R
    try:
        result = bound.handler(bound.state)
    except e:
        return _handler_error(e^)
    return _respond(result^)
