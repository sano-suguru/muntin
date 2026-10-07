# M2-010 application-error decision spike, library side. Not production code: it
# models what Muntin's library could contain, separately from the application
# module (tests/test_spike_error.mojo) that defines handlers and their error
# types, so a typed error crosses a module boundary as it would in a real
# application and this module never names it. Handlers are stored in the
# production `_Erased` box, unchanged; route matching, `Int` conversion, query
# gathering, `FromBody` and `ToResponse` are production's own, and the response
# policies are local copies of production's as of M3-014 (below the imports).
# check.sh builds it through that test (--Werror) and, without the application
# module, through tests/error_lib_only/driver.mojo; test.sh runs it. Decision
# and evidence: docs/history/architecture-decisions.md, "Application-error
# decision (M2-010)". Must-not- compile evidence: tests/error_fail.
#
# What changes against production, and only that:
#
#   handler type  `def(...) thin -> R` becomes `def(...) thin raises E -> R`
#                 with `E: Deinitable` inferred (Mojo's documented
#                 "parametric raises"): `Never` for a non-raising handler,
#                 `Error` for `raises`, the application's type for
#                 `raises NotFound`. Same overloads, same registration
#                 syntax.
#   boundary      every request-side failure is answered 400 where it
#                 happens (query gathering in `handle`, `_parse_int` and
#                 `from_body` in the adapters), before the handler; only the
#                 handler call sits in the adapter's `try`, and its error
#                 becomes a fixed 500 (`_handler_error`). The response
#                 policy runs outside that `try`.

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


def _internal_error() -> Response:
    """The fixed answer to a handler error: status 500 and a fixed body.
    The error's own text never reaches the client."""
    return Response.text("Internal Server Error", status=500)


def _handler_error[E: Deinitable](var e: E) -> Response:
    """What a handler error of type `E` becomes: always `_internal_error()`.

    `E` is `Error` for a `raises` handler and the application's type for a
    `raises T` handler. The value is dropped unread, whatever traits `E`
    has: an `Error`'s message may carry internal details, no observability
    hook exists yet, and a raised value is an error even if its type also
    conforms to `ToResponse` (a returned value of that type converts; a
    raised one does not).
    """
    return _internal_error()


# ---------------------------------------------------------------------------
# Adapters: production's extraction steps, each answering its own 400,
# then the handler call alone in a `try`. Every parameter is explicit (no
# `//`): they are passed as `call=` to `_Erased.__init__`. None of them
# raises, so `invoke` raises only if an adapter breaks this rule.


def _call_none[
    E: Deinitable, R: Movable & Deinitable, respond: _Respond[R]
](handler: def() thin raises E -> R, args: List[String]) -> Response:
    var result: R
    try:
        result = handler()
    except e:
        return _handler_error(e^)
    return respond(result^)


def _call_int[
    E: Deinitable, R: Movable & Deinitable, respond: _Respond[R]
](handler: def(Int) thin raises E -> R, args: List[String]) -> Response:
    """Answers 400 itself, without calling `handler`, if the argument is
    not an integer (production raises into `App.handle` instead)."""
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


def _call_body[
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    respond: _Respond[R],
](handler: def(var B) thin raises E -> R, args: List[String]) -> Response:
    comptime assert conforms_to(B, FromBody)
    var body: B
    try:
        body = B.from_body(args[0])
    except:
        return _bad_request()
    var result: R
    try:
        result = handler(body^)
    except e:
        return _handler_error(e^)
    return respond(result^)


def _call_int_body[
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    respond: _Respond[R],
](handler: def(Int, var B) thin raises E -> R, args: List[String]) -> Response:
    """Route value, then body, each answering its own 400, then the
    handler (production's order)."""
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


struct ErrorApp(Movable):
    """Production `App`'s eight registration overloads as of M2-010, with each handler
    function type widened by an inferred error type `E`, and production's
    dispatch with the 400/500 boundary above.

    Route-literal checks are reduced to arity (production's are unaffected
    by `E`). The `String` overloads still see a `String`-compatible result
    (`-> StaticString` by implicit conversion) and the `R: ToResponse`
    bound still keeps such results off the generic ones; `E` is inferred
    in both, so it never decides between them.
    """

    var _routes: List[_ERoute]

    def __init__(out self):
        self._routes = List[_ERoute]()

    def get[
        E: Deinitable, //, path: StaticString
    ](mut self, handler: def() thin raises E -> String):
        comptime assert _path_params(path) + _query_params(path) == 0
        self._routes.append(
            _ERoute(
                "GET",
                path,
                _Erased.__init__[call=_call_none[E, String, _text]](handler),
            )
        )

    def get[
        E: Deinitable, R: ToResponse, //, path: StaticString
    ](mut self, handler: def() thin raises E -> R):
        comptime assert _path_params(path) + _query_params(path) == 0
        self._routes.append(
            _ERoute(
                "GET",
                path,
                _Erased.__init__[call=_call_none[E, R, _converted[R]]](handler),
            )
        )

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
    ](mut self, handler: def(var B) thin raises E -> String):
        comptime assert _path_params(path) + _query_params(path) == 0
        comptime assert not B == Int
        comptime assert conforms_to(B, FromBody)
        self._routes.append(
            _ERoute(
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
        comptime assert _path_params(path) + _query_params(path) == 0
        comptime assert not B == Int
        comptime assert conforms_to(B, FromBody)
        self._routes.append(
            _ERoute(
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

    def get_widened[
        path: StaticString
    ](mut self, handler: def(Int) raises thin -> String):
        """Candidate 1, rejected: the function type widened to a bare
        `raises` (error type `Error`). Accepts non-raising and `raises`
        handlers, but no `raises T` handler
        (tests/error_fail/typed_error_to_widened_type.mojo)."""
        comptime assert _path_params(path) + _query_params(path) == 1
        self._routes.append(
            _ERoute(
                "GET",
                path,
                _Erased.__init__[call=_call_int[Error, String, _text]](handler),
            )
        )

    def handle(self, request: Request) -> Response:
        """Production `App.handle` with the boundary split: query gathering
        answers its own 400, and a raise out of `invoke` (which no adapter
        here does) is a server error, never a 400."""
        var args = List[String]()
        for i in range(len(self._routes)):
            ref route = self._routes[i]
            if route.method != request.method or not _match(
                route.path, request.path, args
            ):
                continue
            if route.query_key:
                try:
                    # An absent key is `None` since M3-025; a repeat still raises.
                    var value = _query_value(request.query, route.query_key)
                    if not value:
                        raise Error("missing query key")
                    args.append(value.value())
                except:
                    return _bad_request()
            if route.body:
                args.append(request.body)
            try:
                return route.handler.invoke(args)
            except:
                return _internal_error()
        return Response.text("Not Found", status=404)


# ---------------------------------------------------------------------------
# What Mojo exposes at the catch boundary. Evidence for the deferred
# candidate 4 (application-defined error conversion); not used by
# `ErrorApp`.


def catch_converting[
    E: Deinitable, R: ToResponse, //
](handler: def() thin raises E -> R) -> Response:
    """What a typed error exposes at the catch: a value of the application's
    type, which the documented 1.1.0 `comptime if conforms_to` refinement
    can convert. Evidence only, for the deferred candidate 4; not a
    proposed contract (a later conversion would be an explicit opt-in, not
    implied by `ToResponse`)."""
    var result: R
    try:
        result = handler()
    except e:
        comptime if conforms_to(E, ToResponse):
            return e^.to_response()
        else:
            return _internal_error()
    return result^.to_response()


def caught_text[
    E: Deinitable & Writable, //
](handler: def() thin raises E -> String) -> String:
    """The text a `Writable` error carries at the catch boundary (for
    `Error`, its message): what a 500 that echoed the error would expose."""
    try:
        return handler()
    except e:
        return String(e)
