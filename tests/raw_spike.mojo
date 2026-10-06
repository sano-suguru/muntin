# M2-014 raw-Request decision spike, library side. Not production code: it
# models production `App` with the selected raw `Request -> Response`
# registration added, separately from the application module
# (tests/test_spike_raw.mojo) that defines the handlers and error types. The
# eight typed overloads are production's as of M2-014, copied with their
# signatures and asserts unchanged, so overload resolution is measured against
# the real set; their adapters and response policies are local copies of
# production's as of M3-014 (below the imports), and route checks, matching,
# query gathering and `_handler_error` are imported from production. Handlers
# are stored in the production `_Erased` box, unchanged. check.sh builds it
# through that test (--Werror); test.sh runs it. Decision and evidence:
# docs/history/architecture-decisions.md, "Raw Request decision (M2-014)".
# Must-not-compile evidence: tests/raw_fail.
#
# What changes against production, and only that:
#
#   overloads  `get` and `post` each gain one overload taking
#              `def(var Request) thin raises E -> Response`. Its parameter
#              list `[E, //, path]` is shorter than the generic body
#              overload's `[B, E, R, //, path]`, which a raw handler also
#              satisfies (`B = Request`, `R = Response`); the documented
#              resolution rule "shorter parameter list" selects it.
#   route      `_RawRoute.raw`: `handle` passes the matched request's
#              method, path, query and body as the four raw argument
#              strings, and `_call_raw` rebuilds the `Request` through its
#              public initializer. No typed extraction runs.
#   guard      the four body overloads reject `B == Request` by type
#              equality (as they reject `Int`), so a raw-shaped handler
#              that matches no raw overload gets a raw-handler message
#              instead of the `FromBody` one. Selection is unaffected:
#              asserts run only on the selected overload.

from muntin import Request, Response, ToResponse
from muntin.body import FromBody
from muntin._handler_storage import _Erased
from muntin.app import _bad_request, _carrier_fields, _handler_error
from muntin.app import _internal_error, _json_answer, _json_status
from muntin.app import _match, _parse_int, _path_params, _query_params
from muntin.app import _query_value
from muntin.headers_body import _HeaderCarrier
from muntin.http import Headers
from muntin.json import _JsonBody

# Local copies of production's response policies and typed adapters as of M3-014
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


# Adapter parameters are explicit (no `//`): they are passed as `call=` to
# `_Erased.__init__`, where there is no runtime argument to infer them from.
# Each adapter answers its own request-side 400s, then calls the handler
# alone in a `try` (its error becomes `_handler_error`), then applies the
# response policy. None of them raises.


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
    """Answers 400 itself, without calling `handler`, if the one argument is
    not an integer."""
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
    """Converts the one argument, the request body, and moves the value
    into `handler`: an ordinary body with `B.from_body`; a `WithHeaders`
    carrier, after its fields are rebuilt, through `B._from_parts`, which
    converts the inner body (below). Answers 400 itself, without calling
    `handler`, if `from_body` raises. For a JSON body (`_JsonBody`) that is
    not a carrier it first answers 415 unless the arguments are exactly the
    body and the `Content-Type` verdict `"1"` (the arity check keeps a route registered
    without its `json` flag from reading a body `"1"` as the verdict), then
    413 for a body over 1 MiB, without parsing it (`_json_status`).

    For a `WithHeaders[B]` carrier (`_HeaderCarrier`) the arguments go on
    with the header fields' names and values. After the JSON steps for a
    `Json[T]` inner body (`_json_status` allows the trailing pairs), the
    fields are rebuilt into `Headers` (a failure is the fixed 500), then the
    carrier is built with `B._from_parts`, whose inner `from_body` raise is
    the same 400.

    `B` is refined here rather than bounded, as in `App.post`: forwarding a
    handler with an explicit `B` to a callee that requires `B: FromBody`
    fails on Mojo 1.1.0 (docs/history/architecture-decisions.md, "Argument extraction
    decision (M2-005)").
    """
    comptime assert conforms_to(B, FromBody) or conforms_to(B, _HeaderCarrier)
    comptime if conforms_to(B, _JsonBody):
        var status = _json_status[B](args, 0)
        if status != 0:
            return _json_answer(status)
    var body: B
    comptime if conforms_to(B, _HeaderCarrier):
        var fields: Headers
        try:
            fields = _carrier_fields[B](args, 0)
        except:
            return _internal_error()  # only the `_fields` gap gets here
        try:
            body = B._from_parts(args[0], fields^)
        except:
            return _bad_request()
    else:
        comptime assert conforms_to(B, FromBody)
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
    """Converts the route value (`args[0]`) as `_call_int` does, then the
    body (`args[1]`) as `_call_body` does, and calls `handler` with both, in
    that order.

    A bad route value answers 400 before the body is converted; a
    `from_body` raise answers 400. Neither calls `handler`. For a JSON body
    the 415 and 413 steps of `_call_body` run between the two. `B` is
    refined as in `_call_body`.
    """
    comptime assert conforms_to(B, FromBody) or conforms_to(B, _HeaderCarrier)
    var id: Int
    try:
        id = _parse_int(args[0])
    except:
        return _bad_request()
    comptime if conforms_to(B, _JsonBody):
        var status = _json_status[B](args, 1)
        if status != 0:
            return _json_answer(status)
    var body: B
    comptime if conforms_to(B, _HeaderCarrier):
        var fields: Headers
        try:
            fields = _carrier_fields[B](args, 1)
        except:
            return _internal_error()  # only the `_fields` gap gets here
        try:
            body = B._from_parts(args[1], fields^)
        except:
            return _bad_request()
    else:
        comptime assert conforms_to(B, FromBody)
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


def _call_raw[
    E: Deinitable
](
    handler: def(var Request) thin raises E -> Response,
    args: List[String],
) -> Response:
    """Rebuilds the matched `Request` from its method, path, query and body
    (`args[0]` to `args[3]`) and moves it into `handler`.

    `Request` splits its target at the first `?`, so the path never
    contains one, and `path + "?" + query` splits back into the same
    fields; an empty query is rebuilt without `?`, which gives the same
    fields as a target ending in `?`. A raise becomes `_handler_error[E]`,
    as for every typed shape; the result is the response, unconverted.
    """
    var target = args[1]
    if args[2].byte_length() > 0:
        target += "?" + args[2]
    var request = Request(args[0], target, args[3])
    var result: Response
    try:
        result = handler(request^)
    except e:
        return _handler_error(e^)
    return result^


struct _RawRoute(Movable):
    var method: String
    var path: String
    var query_key: String
    var body: Bool
    var raw: Bool
    """Whether the handler receives the whole request (`_call_raw`)."""
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


struct RawApp(Movable):
    """Production `App` as of M2-014 plus the raw overloads and the `Request`
    guard."""

    var _routes: List[_RawRoute]

    def __init__(out self):
        self._routes = List[_RawRoute]()

    # Raw overloads (new).

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
            _RawRoute(
                "GET",
                path,
                _Erased.__init__[call=_call_raw[E]](handler),
                raw=True,
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
            _RawRoute(
                "POST",
                path,
                _Erased.__init__[call=_call_raw[E]](handler),
                raw=True,
            )
        )

    # Production's eight overloads as of M2-014, signatures and asserts
    # unchanged; the four body overloads gain the `Request` guard.

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
            _RawRoute(
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
            _RawRoute(
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
            _RawRoute(
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
            _RawRoute(
                "GET",
                path,
                _Erased.__init__[call=_call_int[E, R, _converted[R]]](handler),
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
        comptime assert conforms_to(B, FromBody), (
            "the handler's parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _RawRoute(
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
        comptime assert conforms_to(B, FromBody), (
            "the handler's parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _RawRoute(
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
        comptime assert conforms_to(B, FromBody), (
            "the handler's last parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _RawRoute(
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
        comptime assert conforms_to(B, FromBody), (
            "the handler's last parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _RawRoute(
                "POST",
                path,
                _Erased.__init__[call=_call_int_body[B, E, R, _converted[R]]](
                    handler
                ),
                body=True,
            )
        )

    def handle(self, request: Request) -> Response:
        """Production's `App.handle` plus one branch: a raw route, once
        selected by method and path, gets the request's four fields as its
        raw arguments and nothing else runs (no query gathering, no body
        conversion)."""
        var args = List[String]()
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
