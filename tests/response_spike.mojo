# M2-007 typed-response decision spike, library side. Not production code: it
# models what Muntin's library could contain, separately from the application
# module (tests/test_spike_response.mojo) that defines the return types, so
# `User` crosses a module boundary as it would in a real application and this
# module never names it. Handlers are stored in the production `_Erased` box,
# unchanged; route matching, `Int` conversion and body conversion are
# production's own helpers and production `FromBody`. check.sh builds it through
# that test (--Werror) and, without the application module, through
# tests/response_lib_only/driver.mojo; test.sh runs it. Decision and evidence:
# docs/history/architecture-decisions.md, "Typed response decision (M2-007)".
# Must-not-compile evidence: tests/response_fail.
#
# Two independent concerns, two independent places in this file:
#
#   extraction  how a matched route's raw strings become handler arguments:
#               one adapter per argument shape (`_call_none`, `_call_int`,
#               `_call_body`), as in production until M3-015.
#   response    how the handler's result becomes a `Response`: a compile-time
#               parameter `respond` of every adapter. `String` results use
#               `_text`; results of a type conforming to `ToResponse` use
#               `_converted[R]`. The adapters never look at `R`.

from muntin import FromBody, Request, Response
from muntin._handler_storage import _Erased
from muntin._registration_rules import _path_params, _query_params
from muntin.app import _match, _parse_int
from muntin.app import _query_value


trait ToResponse(Deinitable, Movable):
    """An application type that a handler can return.

    The application type conforms itself, in its own module, and decides
    the status and body; Muntin never names it. `var self`: Muntin owns the
    handler's result and hands it over, so a conversion can move fields into
    the `Response` (a move-only type works); an implementation that
    declares a borrowed `self` also satisfies this requirement.
    Non-raising: what a failed conversion means belongs to the
    application-error model, which does not exist yet.
    """

    def to_response(var self) -> Response:
        ...


trait ToResponseRaising(Deinitable, Movable):
    """The same requirement widened to `raises`, as the application-error
    model might need. Evidence only: an existing non-raising
    `to_response` satisfies it unchanged, so existing conformances would
    survive; callers of `to_response()` through the trait would not."""

    def to_response(var self) raises -> Response:
        ...


comptime _Respond[R: AnyType] = def(var R) thin -> Response
"""How an adapter turns a handler result of type `R` into a `Response`."""


def _text(var result: String) -> Response:
    """The `String` policy: a 200 text response, as production gave until
    M3-015."""
    return Response.text(result^)


def _converted[R: ToResponse](var result: R) -> Response:
    """The `ToResponse` policy: the result converts itself, by move."""
    return result^.to_response()


def _bad_request() -> Response:
    return Response.text("Bad Request", status=400)


# ---------------------------------------------------------------------------
# Extraction adapters, generic over the result type and its policy. Every
# parameter is explicit (no `//`): they are passed as `call=` to
# `_Erased.__init__`, where there is no runtime argument to infer them from.


def _call_none[
    R: Movable & Deinitable, respond: _Respond[R]
](handler: def() thin -> R, args: List[String]) -> Response:
    return respond(handler())


def _call_int[
    R: Movable & Deinitable, respond: _Respond[R]
](handler: def(Int) thin -> R, args: List[String]) raises -> Response:
    """Raises, without calling `handler`, if the argument is not an
    integer (the contract of production's `_call_int` until M3-015)."""
    return respond(handler(_parse_int(args[0])))


def _call_body[
    B: Movable & Deinitable, R: Movable & Deinitable, respond: _Respond[R]
](handler: def(var B) thin -> R, args: List[String]) -> Response:
    """Converts the body with `B.from_body` (400 itself on a raise, handler
    not called), then moves the value in (the contract of production's
    `_call_body` until M3-015)."""
    comptime assert conforms_to(B, FromBody)
    var body: B
    try:
        body = B.from_body(args[0])
    except:
        return _bad_request()
    return respond(handler(body^))


struct _RRoute(Movable):
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


struct ResponseApp(Movable):
    """Production `App`'s registration syntax and dispatch, plus one generic
    overload per shape for results conforming to `ToResponse`.

    The `String` overloads keep the exact signatures production had until
    M3-015, so a handler
    whose function type is compatible with `def(...) thin -> String` (a
    declared `-> String`, or `-> StaticString` through Mojo's implicit
    conversion) still resolves to them. The generic overloads bind `R` with
    a trait bound, so a `String`-compatible result is never viable for them
    and their presence cannot move such a handler, whatever the compiler's
    ranking between implicit conversion and parameter inference. Route
    literal checks are omitted (production's are unaffected by the result
    type).
    """

    var _routes: List[_RRoute]

    def __init__(out self):
        self._routes = List[_RRoute]()

    def get[path: StaticString](mut self, handler: def() thin -> String):
        self._routes.append(
            _RRoute(
                "GET",
                path,
                _Erased.__init__[call=_call_none[String, _text]](handler),
            )
        )

    def get[
        R: ToResponse, //, path: StaticString
    ](mut self, handler: def() thin -> R):
        self._routes.append(
            _RRoute(
                "GET",
                path,
                _Erased.__init__[call=_call_none[R, _converted[R]]](handler),
            )
        )

    def get[path: StaticString](mut self, handler: def(Int) thin -> String):
        comptime assert _path_params(path) + _query_params(path) == 1
        self._routes.append(
            _RRoute(
                "GET",
                path,
                _Erased.__init__[call=_call_int[String, _text]](handler),
            )
        )

    def get[
        R: ToResponse, //, path: StaticString
    ](mut self, handler: def(Int) thin -> R):
        comptime assert _path_params(path) + _query_params(path) == 1
        self._routes.append(
            _RRoute(
                "GET",
                path,
                _Erased.__init__[call=_call_int[R, _converted[R]]](handler),
            )
        )

    def post[
        B: Movable & Deinitable, //, path: StaticString
    ](mut self, handler: def(var B) thin -> String):
        comptime assert not B == Int
        comptime assert conforms_to(B, FromBody)
        self._routes.append(
            _RRoute(
                "POST",
                path,
                _Erased.__init__[call=_call_body[B, String, _text]](handler),
                body=True,
            )
        )

    def post[
        B: Movable & Deinitable, R: ToResponse, //, path: StaticString
    ](mut self, handler: def(var B) thin -> R):
        comptime assert not B == Int
        comptime assert conforms_to(B, FromBody)
        self._routes.append(
            _RRoute(
                "POST",
                path,
                _Erased.__init__[call=_call_body[B, R, _converted[R]]](handler),
                body=True,
            )
        )

    def get_converted[
        R: Movable & Deinitable, //, path: StaticString
    ](mut self, handler: def(Int) thin -> R, convert: _Respond[R]):
        """Candidate 2: an explicit converter at registration (see
        `_Converted`)."""
        self._routes.append(
            _RRoute(
                "GET",
                path,
                _Erased.__init__[call=_call_converted[R]](
                    _Converted[R](handler, convert)
                ),
            )
        )

    def handle(self, request: Request) -> Response:
        """Production `App.handle`, unchanged."""
        var args = List[String]()
        for i in range(len(self._routes)):
            ref route = self._routes[i]
            if route.method != request.method or not _match(
                route.path, request.path, args
            ):
                continue
            try:
                if route.query_key:
                    # An absent key is `None` since M3-025; a repeat still raises.
                    var value = _query_value(request.query, route.query_key)
                    if not value:
                        raise Error("missing query key")
                    args.append(value.value())
                if route.body:
                    args.append(request.body)
                return route.handler.invoke(args)
            except:
                return _bad_request()
        return Response.text("Not Found", status=404)


# ---------------------------------------------------------------------------
# Rejected alternative that compiles on 1.1.0. Kept as small, executable
# evidence that its rejection is about DX, not feasibility.


@fieldwise_init
struct _Converted[R: Movable & Deinitable](Movable):
    """Candidate 2: the handler and a converter supplied at registration,
    boxed together as one value of one type, so the box is unchanged (as
    M2-005's decoder alternative)."""

    var handler: def(Int) thin -> Self.R
    var convert: _Respond[Self.R]


def _call_converted[
    R: Movable & Deinitable
](pair: _Converted[R], args: List[String]) raises -> Response:
    return pair.convert(pair.handler(_parse_int(args[0])))
