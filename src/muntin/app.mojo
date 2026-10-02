"""Muntin application: route registration and request dispatch."""

from ._handler_storage import _Erased
from .body import FromBody
from .http import Request, Response, ToResponse

# Argument shapes App accepts: `def()` and `def(Int)` for GET, and `def(B)`
# (M2-006) and `def(Int, B)` (M2-009) for POST with `B: FromBody`. Mojo 1.1.0
# function types spelled without `thin` are traits and cannot be stored, so
# `App.get` takes thin function values; ordinary `def` functions convert
# implicitly. Each function type is `thin raises E` with the error type `E`
# inferred (M2-011, Mojo's "parametric raises"): `Never` for a non-raising
# handler, `Error` for `raises`, the application's type for `raises T`.
# `E` is inferred in every overload, so it never decides between them.
# Each argument shape has one adapter below, which converts a matched
# route's raw argument strings and calls the handler, and two registration
# overloads, one per return policy (M2-008): a handler whose function type
# converts to `def(...) thin -> String` (declared `-> String`, or
# `-> StaticString` by implicit conversion) gets a 200 text response
# (`_text`); a handler returning `R: ToResponse` (an application type, or
# `Response`) gets `R.to_response()` (`_converted[R]`). The policy is a
# compile-time parameter of the adapter, so extraction never looks at the
# result type. The generic overloads bound `R` by the trait, so a
# `String`-compatible result is never a candidate for them. The handler and
# its adapter are stored together in an `_Erased` box
# (`_handler_storage.mojo`), so dispatch is one call whatever the shape. Where a value comes from (path segment or query
# key) is route data, not part of the shape, so `_call_int` serves both
# `/users/{id}` and `/items?{limit}`. Whether a route takes the request body
# is route data too (`_Route.body`): `App.handle` appends the body as the
# last raw argument, after the route value if there is one, and
# `_call_body`/`_call_int_body` convert it.
#
# Errors (M2-010, docs/ARCHITECTURE.md "Application-error decision"): a
# request-side failure is answered 400 by the step that fails, before the
# handler runs (query gathering in `App.handle`, `_parse_int` and
# `from_body` in the adapters). Only the handler call sits in an adapter's
# handler `try`; whatever it raises becomes a fixed 500
# (`_handler_error`), and the response policy runs only after it returns.


def _is_param(segment: StringSlice) -> Bool:
    """Whether a route segment is a `{name}` path parameter.

    The single classification used both by the compile-time route checks in
    `App.get` and by runtime matching, so the two always agree on how many
    values a route captures.
    """
    var b = segment.as_bytes()
    return (
        len(b) > 2 and Int(b[0]) == ord("{") and Int(b[len(b) - 1]) == ord("}")
    )


def _path_params(route: StaticString) -> Int:
    """Number of `{name}` segments in the path part of a route literal (the
    text before any `?`), or -1 if malformed.

    The path starts with `/`; a segment containing `{` or `}` must be exactly
    `{name}` with a non-empty name.
    """
    var mark = route.find("?")
    var path = route[byte=:mark] if mark >= 0 else route[byte=:]
    if not path.startswith("/"):
        return -1
    var n = 0
    for segment in path.split("/"):
        var braces = segment.count("{") + segment.count("}")
        if braces == 2 and _is_param(segment):
            n += 1
        elif braces != 0:
            return -1
    return n


def _query_params(route: StaticString) -> Int:
    """Number of `{key}` items in the query part of a route literal (the text
    after its first `?`; none means 0), or -1 if malformed.

    The query part is one or more `{key}` items separated by `&`. A key is
    non-empty, visible ASCII (`!` to `~`), and contains none of `{}=&?#`.
    Visible ASCII is what an HTTP request target can carry, so a key with a
    space or any other byte could match through `TestClient` but never over
    a real connection. Braces and `=`/`&` would be ambiguous with the
    literal's own syntax and the request's pair syntax; `?`/`#` are rejected
    to keep keys plain (a request key could contain them, since only the
    first `?` splits the target and `#` is not special).
    """
    var mark = route.find("?")
    if mark < 0:
        return 0
    var query = route[byte = mark + 1 :]
    if query.byte_length() == 0:
        return -1
    var n = 0
    for item in query.split("&"):
        if not _is_param(item):
            return -1
        var key = item[byte = 1 : item.byte_length() - 1]
        for b in key.as_bytes():
            if Int(b) < ord("!") or Int(b) > ord("~"):
                return -1
        for c in ["{", "}", "=", "&", "?", "#"]:
            if key.find(c) >= 0:
                return -1
        n += 1
    return n


def _match(route: String, path: String, mut args: List[String]) -> Bool:
    """Matches `path` against `route` segment by segment.

    Static segments must be equal; a `{name}` segment matches one non-empty
    segment, which is appended to `args` (cleared first). Routes hold at most
    one parameter (enforced at registration).
    """
    args.clear()
    var want = route.split("/")
    var got = path.split("/")
    if len(want) != len(got):
        return False
    for i in range(len(want)):
        if _is_param(want[i]):
            if got[i].byte_length() == 0:
                return False
            args.append(String(got[i]))
        elif want[i] != got[i]:
            return False
    return True


def _parse_int(segment: String) raises -> Int:
    """Converts a path segment or query value to `Int`: an optional `-`
    followed by one or more ASCII digits, within `Int` range. Anything else
    raises.

    `Int(String)` alone also accepts `+`, surrounding whitespace and `_`
    separators, which Muntin does not accept in path or query values.
    """
    var b = segment.as_bytes()
    var start = 1 if len(b) > 0 and Int(b[0]) == ord("-") else 0
    if len(b) == start:
        raise Error("not an integer")
    for i in range(start, len(b)):
        if Int(b[i]) < ord("0") or Int(b[i]) > ord("9"):
            raise Error("not an integer")
    return Int(segment)


def _query_value(query: String, key: String) raises -> String:
    """The value of `key` in a raw query string. Raises if `key` is absent or
    appears more than once.

    Pairs are separated by `&`; a pair's key and value split at its first
    `=`, and a pair without `=` has an empty value. Keys compare byte for
    byte. Nothing is percent-decoded and `+` is not a space.
    """
    var value = String()
    var found = False
    for pair in query.split("&"):
        var eq = pair.find("=")
        var name = pair[byte=:eq] if eq >= 0 else pair[byte=:]
        if name != key:
            continue
        if found:
            raise Error("duplicate query key")
        found = True
        if eq >= 0:
            value = String(pair[byte = eq + 1 :])
    if not found:
        raise Error("missing query key")
    return value


def _bad_request() -> Response:
    return Response.text("Bad Request", status=400)


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
    """Converts the one argument, the request body, with `B.from_body` and
    moves the value into `handler`; answers 400 itself, without calling
    `handler`, if `from_body` raises.

    `B` is refined here rather than bounded, as in `App.post`: forwarding a
    handler with an explicit `B` to a callee that requires `B: FromBody`
    fails on Mojo 1.1.0 (docs/ARCHITECTURE.md, "Argument extraction
    decision (M2-005)").
    """
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
    """Converts the route value (`args[0]`) as `_call_int` does, then the
    body (`args[1]`) as `_call_body` does, and calls `handler` with both, in
    that order.

    A bad route value answers 400 before the body is converted; a
    `from_body` raise answers 400. Neither calls `handler`. `B` is refined
    as in `_call_body`.
    """
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


struct _Route(Movable):
    var method: String
    var path: String
    """Path part of the route literal; the only part requests are matched
    against."""
    var query_key: String
    """Key of the route's `{key}` query parameter, or empty if it has none."""
    var body: Bool
    """Whether the handler's last argument is the request body."""
    var handler: _Erased

    def __init__(
        out self,
        method: String,
        route: StaticString,
        var handler: _Erased,
        body: Bool = False,
    ):
        """Splits `route` like `Request` splits a target: at its first `?`."""
        self.method = method
        self.body = body
        var mark = route.find("?")
        if mark < 0:
            self.path = String(route)
            self.query_key = String()
        else:
            self.path = String(route[byte=:mark])
            # The query part is exactly one `{key}` (checked at registration).
            self.query_key = String(
                route[byte = mark + 2 : route.byte_length() - 1]
            )
        self.handler = handler^


struct App(Movable):
    """A Muntin application: a set of routes and the dispatch entry point."""

    var _routes: List[_Route]

    def __init__(out self):
        self._routes = List[_Route]()

    def get[
        E: Deinitable, //, path: StaticString
    ](mut self, handler: def() thin raises E -> String):
        """Registers `handler` for `GET path`; its String result becomes a
        200 text response. `handler` may be non-raising or declare `raises`
        or `raises T`; anything it raises becomes a fixed 500 `Internal
        Server Error` (the error's text is never sent)."""
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
            _Route(
                "GET",
                path,
                _Erased.__init__[call=_call_none[E, String, _text]](handler),
            )
        )

    def get[
        E: Deinitable, R: ToResponse, //, path: StaticString
    ](mut self, handler: def() thin raises E -> R):
        """Registers `handler` for `GET path`; its result converts itself
        with `R.to_response()` after `handler` returns. `R` is an
        application type conforming to `ToResponse`, or `Response`. If
        `handler` raises, the response is the fixed 500 and nothing is
        converted, even if the raised value conforms to `ToResponse`."""
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
            _Route(
                "GET",
                path,
                _Erased.__init__[call=_call_none[E, R, _converted[R]]](handler),
            )
        )

    def get[
        E: Deinitable, //, path: StaticString
    ](mut self, handler: def(Int) thin raises E -> String):
        """Registers `handler` for `GET path`, where `path` declares exactly
        one parameter: a `{name}` segment (`/users/{id}`) or a `{key}` query
        item (`/items?{limit}`). Its value is converted to `Int` and passed
        to `handler` by position (names are not checked against the handler);
        a missing, duplicated or non-integer value yields 400 without calling
        `handler`. Anything `handler` raises becomes the fixed 500."""
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert _path_params(path) + _query_params(path) == 1, (
            "handler takes one Int parameter; route must declare exactly one"
            " path or query parameter"
        )
        self._routes.append(
            _Route(
                "GET",
                path,
                _Erased.__init__[call=_call_int[E, String, _text]](handler),
            )
        )

    def get[
        E: Deinitable, R: ToResponse, //, path: StaticString
    ](mut self, handler: def(Int) thin raises E -> R):
        """Registers `handler` for `GET path` with one `Int` route value, as
        the `String` overload; its result converts itself with
        `R.to_response()` after `handler` returns. A missing, duplicated or
        non-integer value yields 400 without calling `handler` or the
        conversion; a raise from `handler` yields the fixed 500 without the
        conversion."""
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert _path_params(path) + _query_params(path) == 1, (
            "handler takes one Int parameter; route must declare exactly one"
            " path or query parameter"
        )
        self._routes.append(
            _Route(
                "GET",
                path,
                _Erased.__init__[call=_call_int[E, R, _converted[R]]](handler),
            )
        )

    def post[
        B: Movable & Deinitable, E: Deinitable, //, path: StaticString
    ](mut self, handler: def(var B) thin raises E -> String):
        """Registers `handler` for `POST path`, where `handler`'s one
        parameter is the request body and `path` declares no path or query
        parameter. `B` is an application type conforming to `FromBody`; the
        body is converted with `B.from_body` before `handler` runs, and a
        conversion failure yields 400 without calling `handler`. A handler
        may declare `body: B` or `var body: B`; `B` may be move-only.
        Anything `handler` raises becomes the fixed 500."""
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
        comptime assert conforms_to(B, FromBody), (
            "the handler's parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _Route(
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
        """Registers `handler` for `POST path` with the request body as its
        one parameter, as the `String` overload; its result converts itself
        with `R.to_response()` after `handler` returns. A conversion failure
        of the body yields 400 without calling `handler` or the result
        conversion; a raise from `handler` yields the fixed 500 without the
        conversion."""
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
        comptime assert conforms_to(B, FromBody), (
            "the handler's parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _Route(
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
        """Registers `handler` for `POST path`, where `path` declares exactly
        one route value, a `{name}` segment (`/users/{id}`) or a `{key}`
        query item (`/users?{id}`), and the request body follows it. Binding
        is positional: the route value is the first parameter, as for
        `get`, and the body the second, as for the body-only `post`. An
        invalid matched path value, or a missing, duplicated, empty or
        invalid query value, yields 400 before the body is converted (a
        missing path segment does not match the route: 404); a body
        conversion failure yields 400; neither calls `handler`. Anything
        `handler` raises becomes the fixed 500."""
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
        comptime assert conforms_to(B, FromBody), (
            "the handler's last parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _Route(
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
        """Registers `handler` for `POST path` with one route value and the
        request body, as the `String` overload; its result converts itself
        with `R.to_response()` after `handler` returns. A 400 calls neither
        `handler` nor the result conversion; a raise from `handler` yields
        the fixed 500 without the conversion."""
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
        comptime assert conforms_to(B, FromBody), (
            "the handler's last parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _Route(
                "POST",
                path,
                _Erased.__init__[call=_call_int_body[B, E, R, _converted[R]]](
                    handler
                ),
                body=True,
            )
        )

    def handle(self, request: Request) -> Response:
        """Dispatches `request` through the application's routes.

        This is the backend seam: every transport (the in-memory TestClient,
        network adapters) delivers requests through this method. The first
        registered route whose method and path match handles the request;
        the query takes no part in selecting it. A body route receives
        `request.body` as its last raw argument, after its route value if it
        has one; its call trampoline (`_call_body`, `_call_int_body`)
        converts it and answers 400 itself if that fails.

        No matching route is 404. A missing or duplicated query value is 400
        here; the adapter answers its own 400s and turns a handler error
        into 500. A raise out of `invoke` is 500, never 400.
        """
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
            if route.query_key:
                try:
                    args.append(_query_value(request.query, route.query_key))
                except:
                    return _bad_request()
            if route.body:
                args.append(request.body)
            # No adapter raises: each answers its own 400s and turns a
            # handler error into 500. A raise here is a server fault, never
            # a client error.
            try:
                return route.handler.invoke(args)
            except:
                return _internal_error()
        return Response.text("Not Found", status=404)
