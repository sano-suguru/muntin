# M3-012 typed header access decision spike, library side. Not production
# code: a minimal model of the selected design, a body carrier that also
# holds the request's header fields, on three production-shaped `post`
# overloads (body only, route value then body, and the stateful body-only
# shape), each with production's guards (some messages shortened) and the
# one relaxed assert the slice adds. Adapters, matching, the JSON
# `Content-Type` verdict, the body cap, `_Bound` and `_handler_error` are
# production's, imported. test.sh builds it through
# tests/test_spike_header_access.mojo (--Werror) and runs it. Decision and
# evidence: docs/ARCHITECTURE.md, "Typed header access decision (M3-012)".
# Must-not-compile evidence: tests/header_access_fail.
#
# What the model adds against production, and only that:
#
#   SpikeWithHeaders[B]  a Muntin-owned carrier: `headers` (the request's
#              fields, as `Headers`) and `body` (a `B: FromBody`, converted
#              by `B.from_body`). It is not itself a `FromBody`: a body
#              alone cannot build it. It conforms to the private `_JsonBody`
#              exactly when `B` does (conditional conformance), so a
#              `SpikeWithHeaders[Json[T]]` body keeps the 415/413 steps.
#   assert     the body overloads accept `B: FromBody` or a carrier (same
#              message); every other guard is production's.
#   transport  `CarrierApp.handle` appends, for a carrier route only, each
#              header field's name and value after the body and the JSON
#              verdict; other routes' arguments are production's.
#   adapters   production's body adapters plus one branch: for a carrier,
#              the fields are rebuilt first (a field `add` refuses, which
#              only the M3-002 `_fields` gap can produce: the fixed 500, as
#              `_raw_request`), then the carrier is built with
#              `B.from_body` (a raise: 400). The JSON arity check allows
#              the trailing pairs on a carrier route only: the verdict
#              stays at its fixed index and the count after it must be
#              even; a plain `Json[T]` route keeps the exact arity.
#
# Only `ToResponse` results are modelled; `String` results take the same
# adapters through production's `_text` policy.

from muntin import Headers, Request, Response, State, ToResponse
from muntin.body import FromBody
from muntin.json import _JsonBody, _MAX_BODY_BYTES, _json_content_type
from muntin.state import _InjectedState
from muntin._handler_storage import _Erased
from muntin.app import _Bound, _Respond, _bad_request, _converted
from muntin.app import _content_too_large, _handler_error, _internal_error
from muntin.app import _match, _parse_int, _path_params, _query_params
from muntin.app import _unsupported_media_type


trait _HeaderCarrier(Deinitable, Movable):
    """Marks the carrier, so the overloads and adapters can name it."""

    @staticmethod
    def _from_parts(body: String, var headers: Headers) raises -> Self:
        ...


struct SpikeWithHeaders[B: FromBody](
    Deinitable,
    Movable,
    _HeaderCarrier,
    _JsonBody where conforms_to(B, _JsonBody),
):
    """A request body and the request's header fields."""

    var headers: Headers
    var body: Self.B

    def __init__(out self, var body: Self.B, var headers: Headers):
        self.body = body^
        self.headers = headers^

    def take_body(deinit self) -> Self.B:
        """Moves the body out (a field cannot be moved out of the middle)."""
        return self.body^

    @staticmethod
    def _from_parts(body: String, var headers: Headers) raises -> Self:
        return Self(Self.B.from_body(body), headers^)


def _first_field[B: AnyType](after_body: Int) -> Int:
    """Index of the first header name on a carrier route: after the body,
    and after the JSON verdict when the body is JSON."""
    comptime if conforms_to(B, _JsonBody):
        return after_body + 1
    else:
        return after_body


def _fields(args: List[String], start: Int) raises -> Headers:
    var headers = Headers()
    var i = start
    while i + 1 < len(args):
        headers.add(args[i], args[i + 1])
        i += 2
    return headers^


def _json_steps[B: AnyType](args: List[String], body_at: Int) -> Int:
    """0 when a JSON body may be converted, else the status to answer.

    The verdict is at its fixed index after the body. A plain `Json[T]`
    route keeps production's exact arity; a carrier route allows only
    name/value pairs after the verdict (an even count)."""
    var verdict = body_at + 1
    if len(args) <= verdict or args[verdict] != "1":
        return 415
    comptime if conforms_to(B, _HeaderCarrier):
        if (len(args) - verdict - 1) % 2 != 0:
            return 415
    else:
        if len(args) != verdict + 1:
            return 415
    if args[body_at].byte_length() > _MAX_BODY_BYTES:
        return 413
    return 0


def _convert[
    B: Movable & Deinitable
](body: String, var fields: Headers) raises -> B:
    """Builds the body slot's value; raises only when `from_body` raises.
    A carrier takes `fields`; any other body ignores them (empty)."""
    comptime if conforms_to(B, _HeaderCarrier):
        return B._from_parts(body, fields^)
    else:
        comptime assert conforms_to(B, FromBody)
        return B.from_body(body)


def _call_c_body[
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    respond: _Respond[R],
](handler: def(var B) thin raises E -> R, args: List[String]) -> Response:
    comptime if conforms_to(B, _JsonBody):
        var status = _json_steps[B](args, 0)
        if status == 415:
            return _unsupported_media_type()
        if status == 413:
            return _content_too_large()
    var fields = Headers()
    comptime if conforms_to(B, _HeaderCarrier):
        try:
            fields = _fields(args, _first_field[B](1))
        except:
            return _internal_error()  # a field `add` refuses (the _fields gap)
    var body: B
    try:
        body = _convert[B](args[0], fields^)
    except:
        return _bad_request()
    var result: R
    try:
        result = handler(body^)
    except e:
        return _handler_error(e^)
    return respond(result^)


def _call_c_int_body[
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    respond: _Respond[R],
](handler: def(Int, var B) thin raises E -> R, args: List[String]) -> Response:
    var id: Int
    try:
        id = _parse_int(args[0])
    except:
        return _bad_request()
    comptime if conforms_to(B, _JsonBody):
        var status = _json_steps[B](args, 1)
        if status == 415:
            return _unsupported_media_type()
        if status == 413:
            return _content_too_large()
    var fields = Headers()
    comptime if conforms_to(B, _HeaderCarrier):
        try:
            fields = _fields(args, _first_field[B](2))
        except:
            return _internal_error()  # a field `add` refuses (the _fields gap)
    var body: B
    try:
        body = _convert[B](args[1], fields^)
    except:
        return _bad_request()
    var result: R
    try:
        result = handler(id, body^)
    except e:
        return _handler_error(e^)
    return respond(result^)


def _call_c_state_body[
    S: Movable & Deinitable,
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    respond: _Respond[R],
](
    bound: _Bound[def(State[S], var B) thin raises E -> R, S],
    args: List[String],
) -> Response:
    comptime if conforms_to(B, _JsonBody):
        var status = _json_steps[B](args, 0)
        if status == 415:
            return _unsupported_media_type()
        if status == 413:
            return _content_too_large()
    var fields = Headers()
    comptime if conforms_to(B, _HeaderCarrier):
        try:
            fields = _fields(args, _first_field[B](1))
        except:
            return _internal_error()  # a field `add` refuses (the _fields gap)
    var body: B
    try:
        body = _convert[B](args[0], fields^)
    except:
        return _bad_request()
    var result: R
    try:
        result = bound.handler(bound.state, body^)
    except e:
        return _handler_error(e^)
    return respond(result^)


struct _CRoute(Movable):
    var path: String
    var json: Bool
    var headers: Bool
    var handler: _Erased

    def __init__(
        out self,
        path: StaticString,
        var handler: _Erased,
        json: Bool,
        headers: Bool,
    ):
        self.path = String(path)
        self.json = json
        self.headers = headers
        self.handler = handler^


struct CarrierApp(Movable):
    """Production's `post` registration and `App.handle` request steps,
    reduced to path routes and `ToResponse` results, with the carrier."""

    var _routes: List[_CRoute]

    def __init__(out self):
        self._routes = List[_CRoute]()

    def post[
        B: Movable & Deinitable,
        E: Deinitable,
        R: ToResponse,
        //,
        path: StaticString,
    ](mut self, handler: def(var B) thin raises E -> R):
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) == 0
        ), "malformed route literal"
        comptime assert (
            _path_params(path) == 0
        ), "route declares a path parameter but the handler takes only a body"
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
        ), "State is injected application state, not the request body"
        comptime assert conforms_to(B, FromBody) or conforms_to(
            B, _HeaderCarrier
        ), (
            "the handler's last parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _CRoute(
                path,
                _Erased.__init__[call=_call_c_body[B, E, R, _converted[R]]](
                    handler
                ),
                json=conforms_to(B, _JsonBody),
                headers=conforms_to(B, _HeaderCarrier),
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
            _path_params(path) == 1 and _query_params(path) == 0
        ), "route must declare exactly one path parameter"
        comptime assert not B == Int, (
            "Int is a route-value type, never the request body; the body"
            " parameter's type must conform to FromBody"
        )
        comptime assert not conforms_to(
            B, _InjectedState
        ), "State is injected application state, not the request body"
        comptime assert conforms_to(B, FromBody) or conforms_to(
            B, _HeaderCarrier
        ), (
            "the handler's last parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _CRoute(
                path,
                _Erased.__init__[call=_call_c_int_body[B, E, R, _converted[R]]](
                    handler
                ),
                json=conforms_to(B, _JsonBody),
                headers=conforms_to(B, _HeaderCarrier),
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
            _path_params(path) == 0 and _query_params(path) == 0
        ), "route declares a parameter but the handler takes only a body"
        comptime assert not conforms_to(
            B, _InjectedState
        ), "a handler takes at most one State, as its first parameter"
        comptime assert conforms_to(B, FromBody) or conforms_to(
            B, _HeaderCarrier
        ), (
            "the handler's last parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _CRoute(
                path,
                _Erased.__init__[
                    call=_call_c_state_body[S, B, E, R, _converted[R]]
                ](_Bound(handler, state)),
                json=conforms_to(B, _JsonBody),
                headers=conforms_to(B, _HeaderCarrier),
            )
        )

    def handle(self, request: Request) -> Response:
        """`App.handle`'s typed-route steps for `POST`: match, route value,
        body, JSON verdict, then (carrier routes only) the header fields."""
        var args = List[String]()
        for i in range(len(self._routes)):
            ref route = self._routes[i]
            if request.method != "POST" or not _match(
                route.path, request.path, args
            ):
                continue
            args.append(request.body)
            if route.json:
                args.append("1" if _json_content_type(request.headers) else "")
            if route.headers:
                for h in range(len(request.headers)):
                    args.append(request.headers.name(h))
                    args.append(request.headers.value(h))
            try:
                return route.handler.invoke(args)
            except:
                return _internal_error()
        return Response.text("Not Found", status=404)
