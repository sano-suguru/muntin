# M2-005 argument-extraction decision spike, library side. Not production code:
# it models what Muntin's library could contain, separately from the application
# module (tests/test_spike_extraction.mojo) that defines the body type, so
# `CreateUser` crosses a module boundary as it would in a real application and
# this module never names it. Handlers are stored in the production `_Erased`
# box, unchanged; route matching and `Int` conversion are production's own
# helpers. check.sh builds it through that test (--Werror) and test.sh runs it.
# Decision and evidence: docs/history/architecture-decisions.md, "Argument
# extraction decision". Must-not-compile evidence: tests/extraction_fail.
#
# Two separate questions, two separate places in this file:
#
#   source binding  which request source fills handler slot N. Route data
#                   (`_XRoute.path`, `.query_key`, `.body`), decided at
#                   registration from the route literal and the overload;
#                   `ExtractApp.handle` gathers raw strings in slot order:
#                   path captures, then the query value, then the body.
#   conversion      how a raw string becomes the slot's type. The adapters
#                   (`_call_*`): route values through `_parse_int` whatever
#                   their source, the body through the type's own `FromBody`.

from muntin import Request, Response
from muntin._handler_storage import _Erased
from muntin.app import (
    _match,
    _parse_int,
    _path_params,
    _query_params,
    _query_value,
)


trait FromBody(Deinitable, Movable):
    """An application type that can be built from a request body.

    The application type conforms itself, in its own module. A route-value
    type (`Int`) is never a body type: registration rejects it by type
    equality (`_ROUTE_VALUE_BODY`), not by relying on it lacking a
    conformance, because on 1.1.0 an `__extension SIMD(FromBody)` in the
    module that declares the trait does give `Int` the trait bound (only
    cross-module extensions fail, and `conforms_to` does not see extension
    conformances; tests/extraction_fail/builtin_body_via_extension.mojo,
    extension_invisible_to_conforms_to.mojo). `Deinitable`: Muntin may have
    to drop a converted value (a borrowed `def(B)` call leaves a temporary
    that is "abandoned without being explicitly destroyed" otherwise), and
    it keeps linear types out.
    """

    @staticmethod
    def from_body(body: String) raises -> Self:
        """Builds the value from the request body, borrowed from the
        `Request`. Raising rejects the request with 400 before the handler
        runs."""
        ...


# ---------------------------------------------------------------------------
# Conversion: per-slot adapters. Each converts every slot before calling the
# handler and answers 400 itself if one does not convert, so an error that
# leaves an adapter was raised by the handler. The body parameter is
# `def(var B)`: a handler declaring `body: B` (borrowed) or `var body: B`
# (owned) converts to it, and the adapter moves the value in, so `B` may be
# move-only. Offering both `def(B)` and `def(var B)` is ambiguous for a
# borrowed handler (tests/extraction_fail/borrowed_and_owned_overloads.mojo).
# `B` is generic over `Movable & Deinitable` and refined with
# `comptime assert conforms_to(B, FromBody)`, the documented 1.1.0 mechanism
# (release notes: `trait_downcast` removed in its favour); no `downcast` or
# `rebind_var`. The adapter that calls `from_body` refines `B` itself:
# forwarding the handler with an explicit `inner[B](handler, raw)` to a
# function that requires `B: FromBody` fails on 1.1.0 ("function type
# conversions between closures not supported yet"; letting `B` be inferred
# compiles).


def _bad_request() -> Response:
    return Response.text("Bad Request", status=400)


def _call_int(
    handler: def(Int) raises thin -> String, raw: List[String]
) raises -> Response:
    """Slot 0: a route value."""
    var id: Int
    try:
        id = _parse_int(raw[0])
    except:
        return _bad_request()
    return Response.text(handler(id))


def _call_body[
    B: Movable & Deinitable
](
    handler: def(var B) raises thin -> String, raw: List[String]
) raises -> Response:
    """Slot 0: the body."""
    comptime assert conforms_to(B, FromBody)
    var body: B
    try:
        body = B.from_body(raw[0])
    except:
        return _bad_request()
    return Response.text(handler(body^))


def _call_int_body[
    B: Movable & Deinitable
](
    handler: def(Int, var B) raises thin -> String, raw: List[String]
) raises -> Response:
    """Slot 0: a route value; slot 1: the body."""
    comptime assert conforms_to(B, FromBody)
    var id: Int
    var body: B
    try:
        id = _parse_int(raw[0])
        body = B.from_body(raw[1])
    except:
        return _bad_request()
    return Response.text(handler(id, body^))


# ---------------------------------------------------------------------------
# Source binding: the route literal declares the route values in order (path
# segments, then the query key); a handler with one parameter more than the
# literal declares takes the body in that last position. At most one body.
# Every mismatch is a compile error at the registration call, because a slot
# whose source is the route accepts only `Int` and the body slot accepts only
# `FromBody` types.


comptime _ROUTE_VALUE_BODY = (
    "Int is a route-value type, never the request body; declare a path or"
    " query parameter for every Int parameter"
)


def _route_values(route: StaticString) -> Int:
    """Path plus query placeholders, or -1 if the literal is malformed."""
    var path = _path_params(route)
    var query = _query_params(route)
    if path < 0 or query < 0:
        return -1
    return path + query


struct _XRoute(Movable):
    var method: String
    var path: String
    var query_key: String
    var body: Bool
    """Whether the handler's last slot is the request body."""
    var handler: _Erased

    def __init__(
        out self,
        method: String,
        route: StaticString,
        body: Bool,
        var handler: _Erased,
    ):
        self.method = method
        var mark = route.find("?")
        if mark < 0:
            self.path = String(route)
            self.query_key = String()
        else:
            self.path = String(route[byte=:mark])
            self.query_key = String(
                route[byte = mark + 2 : route.byte_length() - 1]
            )
        self.body = body
        self.handler = handler^


struct ExtractApp(Movable):
    """`app.post[route](handler)` with route values and one body slot."""

    var _routes: List[_XRoute]

    def __init__(out self):
        self._routes = List[_XRoute]()

    def post[
        path: StaticString
    ](mut self, handler: def(Int) raises thin -> String):
        comptime assert _route_values(path) >= 0, "malformed route literal"
        comptime assert _route_values(path) == 1, (
            "handler takes one Int parameter; route must declare exactly one"
            " path or query parameter"
        )
        self._routes.append(
            _XRoute(
                "POST", path, False, _Erased.__init__[call=_call_int](handler)
            )
        )

    def post[
        B: Movable & Deinitable, //, path: StaticString
    ](mut self, handler: def(var B) raises thin -> String):
        comptime assert _route_values(path) >= 0, "malformed route literal"
        comptime if _route_values(path) == 0:
            comptime assert not B == Int, _ROUTE_VALUE_BODY
            comptime assert conforms_to(B, FromBody), (
                "the handler's parameter is the request body; its type must"
                " conform to FromBody"
            )
        elif _route_values(path) == 1:
            comptime assert not B == Int, (
                "an owned (`var`) Int parameter is not supported; declare it"
                " borrowed (`id: Int`)"
            )
            comptime assert False, (
                "route declares a path or query parameter; the handler"
                " parameter bound to it must be Int"
            )
        else:
            comptime assert False, (
                "handler takes one parameter; route declares more than one"
                " path or query parameter"
            )
        self._routes.append(
            _XRoute(
                "POST",
                path,
                True,
                _Erased.__init__[call=_call_body[B]](handler),
            )
        )

    def post[
        B: Movable & Deinitable, //, path: StaticString
    ](mut self, handler: def(Int, var B) raises thin -> String):
        comptime assert _route_values(path) >= 0, "malformed route literal"
        comptime assert _route_values(path) == 1, (
            "handler takes a route value and a body; route must declare"
            " exactly one path or query parameter"
        )
        comptime assert not B == Int, _ROUTE_VALUE_BODY
        comptime assert conforms_to(B, FromBody), (
            "the handler's last parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _XRoute(
                "POST",
                path,
                True,
                _Erased.__init__[call=_call_int_body[B]](handler),
            )
        )

    def handle(self, request: Request) -> Response:
        var raw = List[String]()
        for i in range(len(self._routes)):
            ref route = self._routes[i]
            if route.method != request.method or not _match(
                route.path, request.path, raw
            ):
                continue
            # Source binding: raw strings in slot order. A missing or
            # duplicated query value is an extraction failure.
            try:
                if route.query_key:
                    # An absent key is `None` since M3-025; a repeat still raises.
                    var value = _query_value(request.query, route.query_key)
                    if not value:
                        raise Error("missing query key")
                    raw.append(value.value())
            except:
                return _bad_request()
            if route.body:
                # One copy of the owned body String; the box's raw-input type
                # (`List[String]`) is unchanged.
                raw.append(request.body)
            # Conversion and the call. Adapters answer 400 for a value that
            # does not convert, so a raise here came from the handler. 500 is
            # a spike placeholder for the future application-error model.
            try:
                return route.handler.invoke(raw)
            except:
                return Response.text("Handler Error", status=500)
        return Response.text("Not Found", status=404)


# ---------------------------------------------------------------------------
# Rejected alternatives that compile on 1.1.0. Kept as small, executable
# evidence that their rejection is about DX, not feasibility.


struct Body[T: FromBody](Movable):
    """Candidate C: a parameter wrapper. `T` is inferred through `Body[T]`,
    but the handler reads `body.value.name` instead of `body.name`."""

    var value: Self.T

    def __init__(out self, var value: Self.T):
        self.value = value^


def call_wrapped[
    T: FromBody
](
    handler: def(var Body[T]) raises thin -> String, raw: String
) raises -> String:
    return handler(Body(T.from_body(raw)))


@fieldwise_init
struct _Decoded[B: Movable & Deinitable](Movable):
    """Candidate 2: a decoder supplied at registration, boxed together with
    the handler as one value of one type, so the box itself is unchanged."""

    var handler: def(var Self.B) raises thin -> String
    var decode: def(String) raises thin -> Self.B


def _call_decoded[
    B: Movable & Deinitable
](pair: _Decoded[B], raw: List[String]) raises -> Response:
    return Response.text(pair.handler(pair.decode(raw[0])))


def box_with_decoder[
    B: Movable & Deinitable
](
    handler: def(var B) raises thin -> String,
    decode: def(String) raises thin -> B,
) -> _Erased:
    return _Erased.__init__[call=_call_decoded[B]](_Decoded[B](handler, decode))
