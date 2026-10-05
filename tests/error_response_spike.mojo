# M2-012 error-response decision spike, library side. Not production code:
# it models what Muntin's library could contain, separately from the
# application module (tests/test_spike_error_response.mojo) that defines
# handlers and error types, so an opted-in error type crosses a module
# boundary as it would in a real application and this module never names
# it. Handlers are stored in the production `_Erased` box, unchanged; route
# matching, `Int` conversion, query gathering, `FromBody`, `ToResponse` and
# the response policies are local copies of production's as of M3-014
# (below the imports). check.sh builds it through
# that test (--Werror) and, without the application module, through
# tests/error_response_lib_only/driver.mojo; test.sh runs it. Decision and
# evidence: docs/ARCHITECTURE.md, "Error-response decision (M2-012)".
# Must-not-compile evidence: tests/error_response_fail.
#
# What changes against production, and only that: `_handler_error[E]`
# converts a caught `e: E` with `to_error_response` when `E` conforms to
# the dedicated `ToErrorResponse` trait, and answers the fixed 500
# otherwise. The overloads, adapters, storage and `App.handle` are
# production's (two argument shapes are enough: the mechanism is one
# function every adapter calls, independent of shape and result policy).

from muntin import FromBody, Request, Response, ToResponse
from muntin._handler_storage import _Erased
from muntin.app import _bad_request
from muntin.app import _match, _parse_int, _path_params, _query_params
from muntin.app import _query_value

# Local copies of production's response policies as of M3-014
# (src/muntin/app.mojo before M3-015 replaced them with one adapter per
# request-slot arity), unchanged.


comptime _Respond[R: AnyType] = def(var R) thin -> Response
"""How an adapter turns a handler result of type `R` into a `Response`."""


def _text(var result: String) -> Response:
    """The `String` policy: a 200 text response."""
    return Response.text(result^)


def _converted[R: ToResponse](var result: R) -> Response:
    """The `ToResponse` policy: the result converts itself, by move."""
    return result^.to_response()


trait ToErrorResponse(Deinitable):
    """The candidate contract: an error type the application raises from a
    handler (`raises T`) and wants answered with its own response, instead
    of the fixed 500, declares conformance to this trait.

    Separate from `ToResponse`: a returned value converts with
    `to_response`, a raised one with `to_error_response`, so a type
    conforming to both answers each channel with its own method, and
    conforming to `ToResponse` alone never changes what a raise becomes.
    Refines only `Deinitable`, as the handler's `E` does: the conversion
    consumes the caught value, so move-only error types conform and no
    type must declare `Movable` (Mojo 1.1.0 makes every struct `Movable`). Non-raising: a fallible conversion is deferred.
    """

    def to_error_response(var self) -> Response:
        """The response for this error. Runs once, after the handler raised;
        consumes the error."""
        ...


def _internal_error() -> Response:
    return Response.text("Internal Server Error", status=500)


def _handler_error[E: Deinitable](var e: E) -> Response:
    """What a handler error of type `E` becomes. `E` is the handler's
    declared error type (`Never`, `Error`, or the application's `T`): if it
    conforms to `ToErrorResponse`, the error converts itself; otherwise the
    fixed 500, the error dropped unread, as in production.

    `conforms_to` is resolved at compile time per instantiation, so there is
    one function and no overload: an `E` that does not conform needs
    nothing, and nothing else (a `ToResponse` conformance, a method of the
    same name) selects the conversion.
    """
    comptime if conforms_to(E, ToErrorResponse):
        return e^.to_error_response()
    else:
        return _internal_error()


# ---------------------------------------------------------------------------
# Adapters: production's, calling the `_handler_error` above.


def _call_int[
    E: Deinitable, R: Movable & Deinitable, respond: _Respond[R]
](handler: def(Int) thin raises E -> R, args: List[String]) -> Response:
    var id: Int
    try:
        id = _parse_int(args[0])
    except:
        return _bad_request()
    var result: R
    try:
        result = handler(id)
    except e:
        return _handler_error(e^)
    return respond(result^)


def _call_int_body[
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    respond: _Respond[R],
](handler: def(Int, var B) thin raises E -> R, args: List[String]) -> Response:
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
        result = handler(id, body^)
    except e:
        return _handler_error(e^)
    return respond(result^)


struct _ERoute(Movable):
    var method: String
    var path: String
    var query_key: String
    var body: Bool
    var handler: _Erased

    def __init__(
        out self,
        method: String,
        route: StaticString,
        var handler: _Erased,
        body: Bool = False,
    ):
        self.method = method
        self.body = body
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


struct ErrorResponseApp(Movable):
    """Production `App`'s GET `def(Int)` and POST `def(Int, var B)`
    overloads, both result policies, unchanged signatures (inferred
    `E: Deinitable`), and production's `handle`. Route-literal checks are
    reduced to arity."""

    var _routes: List[_ERoute]

    def __init__(out self):
        self._routes = List[_ERoute]()

    def get[
        E: Deinitable, //, path: StaticString
    ](mut self, handler: def(Int) thin raises E -> String):
        comptime assert _path_params(path) + _query_params(path) == 1
        self._routes.append(
            _ERoute(
                "GET",
                path,
                _Erased.__init__[call=_call_int[E, String, _text]](handler),
            )
        )

    def get[
        E: Deinitable, R: ToResponse, //, path: StaticString
    ](mut self, handler: def(Int) thin raises E -> R):
        comptime assert _path_params(path) + _query_params(path) == 1
        self._routes.append(
            _ERoute(
                "GET",
                path,
                _Erased.__init__[call=_call_int[E, R, _converted[R]]](handler),
            )
        )

    def post[
        B: Movable & Deinitable, E: Deinitable, //, path: StaticString
    ](mut self, handler: def(Int, var B) thin raises E -> String):
        comptime assert _path_params(path) + _query_params(path) == 1
        comptime assert not B == Int
        comptime assert conforms_to(B, FromBody)
        self._routes.append(
            _ERoute(
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
        comptime assert _path_params(path) + _query_params(path) == 1
        comptime assert not B == Int
        comptime assert conforms_to(B, FromBody)
        self._routes.append(
            _ERoute(
                "POST",
                path,
                _Erased.__init__[call=_call_int_body[B, E, R, _converted[R]]](
                    handler
                ),
                body=True,
            )
        )

    def handle(self, request: Request) -> Response:
        var args = List[String]()
        for i in range(len(self._routes)):
            ref route = self._routes[i]
            if route.method != request.method or not _match(
                route.path, request.path, args
            ):
                continue
            if route.query_key:
                try:
                    args.append(_query_value(request.query, route.query_key))
                except:
                    return _bad_request()
            if route.body:
                args.append(request.body)
            try:
                return route.handler.invoke(args)
            except:
                return _internal_error()
        return Response.text("Not Found", status=404)
