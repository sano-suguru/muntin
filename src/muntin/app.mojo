"""Muntin application: route registration and request dispatch."""

from ._handler_storage import _Erased
from .body import FromBody
from .headers_body import _HeaderCarrier
from .http import Headers, Request, Response, ToErrorResponse, ToResponse
from .json import _JsonBody, _MAX_BODY_BYTES, _json_content_type
from .state import State, _InjectedState

# Argument shapes App accepts: `def()` and `def(Int)` for GET, and `def(B)`
# (M2-006) and `def(Int, B)` (M2-009) for POST with `B: FromBody` (or,
# since M3-013, a `WithHeaders[B]` carrier, below); and on
# both, the raw `def(var Request) -> Response` (M2-015). Mojo 1.1.0
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
# Raw handlers (M2-015, docs/ARCHITECTURE.md "Raw Request decision
# (M2-014)"): the `get`/`post` overload taking `def(var Request) thin raises
# E -> Response` has the parameter list `[E, path]`. On `post` a raw handler
# also satisfies the generic body overload (`B = Request`, `R = Response`,
# list `[B, E, R, path]`); Mojo's documented rule "shorter parameter list"
# selects the raw overload (equal lists are ambiguous:
# tests/raw_fail/equal_parameter_lists.mojo), so each raw overload's list
# must stay strictly shorter than every body overload a raw handler can
# satisfy. A raw route (`_Route.raw`) gets the request's method, path,
# query and body as its first four raw arguments, then each header field's
# name and value (M3-005; docs/ARCHITECTURE.md "Headers decision (M3-002)",
# R1), and nothing else runs; `_call_raw` rebuilds the `Request`, headers
# included, and moves it into the handler. A typed route gets header
# strings only when its body is a `WithHeaders[B]` carrier (below). The
# body overloads' `not B == Request` guard only improves the message for
# calls no overload accepts; it takes no part in selection.
#
# Stateful handlers (M3-003 for `get`, M3-006 for `post`;
# docs/ARCHITECTURE.md "Application state decision (M3-001)"): a `get` or
# `post` registration with a second argument, `(handler, state: State[S])`,
# takes a handler whose first parameter is `State[S]` and whose rest is the
# `def()` or `def(Int)` shape on `get`, or the `def(var B)` or
# `def(Int, var B)` shape on `post`, bound and checked as its stateless
# twin (plus the `State` guard below). Every M2 registration passes one
# argument, so the two families never compete in overload resolution: the
# argument count separates them, not ranking. `S` is inferred from both
# arguments, so they must agree. The registration moves the handler and one
# copy of the handle into the route's `_Erased` box as one `_Bound[H, S]`;
# the stateful adapters borrow it and pass the handle by borrow, so a
# request copies nothing, changes no reference count and allocates nothing
# for the state. `State` conforms to the private marker `_InjectedState`:
# the four stateless body overloads reject it as a body (a stateful handler
# registered on `post` without its state), and the four stateful ones reject
# a second `State` in the body slot. Like the `Request` guard, the marker
# only improves the message of calls that already fail.
#
# Stateful raw handlers (M3-007): `get` and `post` each take
# `(handler: def(State[S], var Request) thin raises E -> Response, state)`,
# the raw shape with the state first, stored as `_Bound[H, S]` on a raw
# route; `_call_state_raw` rebuilds the `Request` as `_call_raw` does
# (`_raw_request`) and passes the handle by borrow. On `post` such a
# handler also satisfies the stateful `ToResponse` body overload
# (`B = Request`, `R = Response`, list `[S, B, E, R, path]`); the raw
# overload's `[S, E, path]` is shorter, so the same rule selects it. On
# `get` no other stateful overload takes a `Request`.
#
# Errors (M2-010, docs/ARCHITECTURE.md "Application-error decision"): a
# request-side failure is answered 400 by the step that fails, before the
# handler runs (query gathering in `App.handle`, `_parse_int` and
# `from_body` in the adapters); a raw route has no such step. Only the
# handler call sits in an adapter's handler `try`; whatever it raises goes to `_handler_error[E]`, and the
# response policy runs only after it returns. `_handler_error` converts an
# error whose declared type `E` conforms to `ToErrorResponse` (M2-012,
# "Error-response decision") and answers every other one with a fixed 500.
#
# JSON bodies (M3-009, docs/ARCHITECTURE.md "JSON codec decision (M3-008)"):
# `Json[T]` is an ordinary `FromBody`, so the eight body overloads register
# it unchanged; each sets `_Route.json` when `B` conforms to the private
# marker `_JsonBody`. `FromBody.from_body` sees only the body, so the
# request `Content-Type` is decided in `App.handle`, which appends a verdict
# after the body for a JSON route only (`"1"` when the request has exactly
# one `application/json` field, else empty; other routes' arguments are
# unchanged). The four body adapters, for a JSON body only, answer 415
# unless the arguments end with the verdict `"1"` at the expected position
# (an exact arity check, so a body can never stand in for a missing
# verdict), then 413 when the body is over 1 MiB, after the route value and
# before `from_body`. Order on a JSON body route: 404, query 400
# (`App.handle`), route-value 400, 415, 413, JSON 400 (`from_body`), handler.
#
# Header carriers (M3-013, docs/ARCHITECTURE.md "Typed header access decision
# (M3-012)"): `WithHeaders[B]` (`headers_body.mojo`) is accepted in the body
# slot of the eight body overloads without being a `FromBody`: their last
# assert accepts `FromBody` or the private marker `_HeaderCarrier`, with its
# message unchanged, and each sets `_Route.headers` for a carrier. For such
# a route only, `App.handle` appends each request header field's name and
# value after the body and the JSON verdict (the R1 transport raw routes
# use). The four body adapters then rebuild the fields into a `Headers`
# (`_carrier_fields`; a failure, which only the M3-002 `_fields` gap can
# cause, is the fixed 500) and build the carrier with `B._from_parts`, which
# converts the body with the inner `from_body` (a raise: 400). The carrier
# forwards `_JsonBody` exactly when its body does, so a
# `WithHeaders[Json[T]]` route keeps the order above; its arity check
# allows only name and value pairs after the verdict, and every other JSON
# body keeps the exact arity. Muntin chooses no status for the fields the
# handler reads and gives them no meaning; the `Content-Type` verdict for a
# `Json[T]` body (415) and the rebuild failure (500) still answer before the
# handler.


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


def _unsupported_media_type() -> Response:
    """A JSON body route's answer to a request whose `Content-Type` is not
    exactly one `application/json` field (M3-009)."""
    return Response.text("Unsupported Media Type", status=415)


def _content_too_large() -> Response:
    """A JSON body route's answer to a body over 1 MiB (M3-009)."""
    return Response.text("Content Too Large", status=413)


def _internal_error() -> Response:
    """The fixed answer to a handler error: status 500 and a fixed body.
    The error's own text never reaches the client."""
    return Response.text("Internal Server Error", status=500)


def _handler_error[E: Deinitable](var e: E) -> Response:
    """What a handler error of type `E` becomes.

    `E` is the handler's declared error type: `Never` for a non-raising
    handler, `Error` for `raises`, the application's type for `raises T`.
    If `E` conforms to `ToErrorResponse`, the error converts itself, once,
    by move. Otherwise the answer is `_internal_error()` and the value is
    dropped unread: an `Error`'s message may carry internal details and is
    never mapped, no observability hook exists yet, and `ToResponse` alone
    does not convert a raised value (a returned value of that type
    converts; a raised one does not). Resolved at compile time per
    instantiation, so no error type must conform to anything.
    """
    comptime if conforms_to(E, ToErrorResponse):
        return e^.to_error_response()
    else:
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


def _json_status[B: AnyType](args: List[String], body_at: Int) -> Int:
    """For a JSON body (`_JsonBody`): 0 when the body may be converted,
    else the status to answer, 415 or 413, without parsing.

    The `Content-Type` verdict follows the body (`args[body_at + 1]`) and
    must be `"1"`. For any other JSON body the arguments end there (an exact
    arity check, so a body can never stand in for a missing verdict); a
    carrier route (`_HeaderCarrier`) allows only header name and value pairs
    after it, an even count. Then a body over 1 MiB is 413."""
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


def _json_answer(status: Int) -> Response:
    """The response for a nonzero `_json_status`."""
    if status == 415:
        return _unsupported_media_type()
    return _content_too_large()


def _carrier_fields[
    B: AnyType
](args: List[String], body_at: Int) raises -> Headers:
    """Rebuilds a carrier route's header fields from the name and value
    pairs after the body (and after the verdict, for a JSON body), in
    order. `Headers.add` validates each field again: fields that came from
    a `Headers` pass, so only the M3-002 `_fields` gap can make this raise,
    and the adapters answer that with the fixed 500, never 400."""
    var i = body_at + 1
    comptime if conforms_to(B, _JsonBody):
        i += 1
    var headers = Headers()
    while i + 1 < len(args):
        headers.add(args[i], args[i + 1])
        i += 2
    return headers^


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
    with the header fields' names and values: they are rebuilt into
    `Headers` first (a failure is the fixed 500), then the carrier is built
    with `B._from_parts`, whose inner `from_body` raise is the same 400.

    `B` is refined here rather than bounded, as in `App.post`: forwarding a
    handler with an explicit `B` to a callee that requires `B: FromBody`
    fails on Mojo 1.1.0 (docs/ARCHITECTURE.md, "Argument extraction
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


def _raw_request(args: List[String]) raises -> Request:
    """Rebuilds a raw route's `Request` from its method, path, query and
    body (`args[0]` to `args[3]`) and its header fields (name and value
    pairs from `args[4]` on, in order).

    `Request` splits its target at the first `?`, so the path never
    contains one, and `path + "?" + query` splits back into the same
    fields; an empty query is rebuilt without `?`, which gives the same
    fields as a target ending in `?`. The fields came from a `Headers`, so
    rebuilding them cannot fail; if it did, this would raise.
    """
    var target = args[1]
    if args[2].byte_length() > 0:
        target += "?" + args[2]
    var headers = Headers()
    var i = 4
    while i + 1 < len(args):
        headers.add(args[i], args[i + 1])
        i += 2
    return Request(args[0], target, args[3], headers^)


def _call_raw[
    E: Deinitable
](
    handler: def(var Request) thin raises E -> Response,
    args: List[String],
) -> Response:
    """Rebuilds the matched `Request` (`_raw_request`) and moves it into
    `handler`; no typed extraction runs, so this adapter answers no 400 of
    its own. A rebuild failure is the fixed 500. A raise becomes
    `_handler_error[E]`, as for every typed shape; the result is the
    response, unconverted.
    """
    var request: Request
    try:
        request = _raw_request(args)
    except:
        return _internal_error()
    var result: Response
    try:
        result = handler(request^)
    except e:
        return _handler_error(e^)
    return result^


struct _Bound[H: Movable & Deinitable, S: Movable & Deinitable](Movable):
    """A stateful handler and its route's copy of the state handle, boxed
    together as one `_Erased` value."""

    var handler: Self.H
    var state: State[Self.S]

    def __init__(out self, var handler: Self.H, state: State[Self.S]):
        """Takes `handler` and copies the handle: the one copy a
        registration makes."""
        self.handler = handler^
        self.state = state.copy()


def _call_state_none[
    S: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    respond: _Respond[R],
](
    bound: _Bound[def(State[S]) thin raises E -> R, S], args: List[String]
) -> Response:
    """`_call_none` with the route's state handle passed first, by borrow."""
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
    respond: _Respond[R],
](
    bound: _Bound[def(State[S], Int) thin raises E -> R, S],
    args: List[String],
) -> Response:
    """`_call_int` with the route's state handle passed first, by borrow:
    answers 400 itself, without calling `handler`, if the one argument is
    not an integer."""
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
    respond: _Respond[R],
](
    bound: _Bound[def(State[S], var B) thin raises E -> R, S],
    args: List[String],
) -> Response:
    """`_call_body` with the route's state handle passed first, by borrow:
    answers 400 itself, without calling `handler`, if `from_body` raises,
    after the same 415 and 413 steps for a JSON body."""
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
        result = bound.handler(bound.state, body^)
    except e:
        return _handler_error(e^)
    return respond(result^)


def _call_state_int_body[
    S: Movable & Deinitable,
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    respond: _Respond[R],
](
    bound: _Bound[def(State[S], Int, var B) thin raises E -> R, S],
    args: List[String],
) -> Response:
    """`_call_int_body` with the route's state handle passed first, by
    borrow: a bad route value (`args[0]`) answers 400 before the body
    (`args[1]`) is converted, then a JSON body gets the 415 and 413 steps,
    a `from_body` raise answers 400, and none calls `handler`."""
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
    """`_call_raw` with the route's state handle passed first, by borrow:
    the same rebuilt `Request`, moved into the handler, no 400 of its own,
    and the response unconverted."""
    var request: Request
    try:
        request = _raw_request(args)
    except:
        return _internal_error()
    var result: Response
    try:
        result = bound.handler(bound.state, request^)
    except e:
        return _handler_error(e^)
    return result^


struct _Route(Movable):
    var method: String
    var path: String
    """Path part of the route literal; the only part requests are matched
    against."""
    var query_key: String
    """Key of the route's `{key}` query parameter, or empty if it has none."""
    var body: Bool
    """Whether the handler's last argument is the request body."""
    var json: Bool
    """Whether that body is a `Json[T]` (`_JsonBody`): `App.handle` then
    appends the request's `Content-Type` verdict after the body, and the
    adapter answers 415 and 413 before `from_body` (M3-009)."""
    var headers: Bool
    """Whether that body is a `WithHeaders[B]` carrier (`_HeaderCarrier`):
    `App.handle` then appends each request header field's name and value
    after the body and any verdict, and the adapter rebuilds the fields
    into the carrier (M3-013)."""
    var raw: Bool
    """Whether the handler receives the whole request (`_call_raw`,
    `_call_state_raw`): its raw
    arguments are the request's method, path, query and body, then each
    header field's name and value."""
    var handler: _Erased

    def __init__(
        out self,
        method: String,
        route: StaticString,
        var handler: _Erased,
        body: Bool = False,
        json: Bool = False,
        headers: Bool = False,
        raw: Bool = False,
    ):
        """Splits `route` like `Request` splits a target: at its first `?`."""
        self.method = method
        self.body = body
        self.json = json
        self.headers = headers
        self.raw = raw
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
        or `raises T`. A raise is answered by the error's
        `to_error_response()` if the declared error type `E` conforms to
        `ToErrorResponse`; anything else it raises becomes a fixed 500
        `Internal Server Error` (the error's text is never sent)."""
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
        `handler` raises, the result conversion does not run: the error
        converts if its declared type conforms to `ToErrorResponse`, else
        the response is the fixed 500, even if the raised value conforms to
        `ToResponse`."""
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
        `handler`. A raise is converted or the fixed 500, as for `get` on
        `def()`."""
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
        conversion; a raise from `handler` skips the conversion and is
        converted by `ToErrorResponse` or the fixed 500."""
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

    def get[
        E: Deinitable, //, path: StaticString
    ](mut self, handler: def(var Request) thin raises E -> Response):
        """Registers the raw `handler` for `GET path`: it receives the
        whole `Request` (`method`, `path`, `query` and `body` as received)
        and its `Response` is the answer, unconverted. `handler` may declare
        `req: Request` or `var req: Request`. `path` declares no path or
        query parameter; Muntin runs no typed extraction after the route
        matches, so it answers no 400 before `handler`. A raise is converted
        or the fixed 500, as for `get` on `def()`.

        Keep this overload's parameter list strictly shorter than every body
        overload a `Request -> Response` handler satisfies: Mojo selects it
        over them by the shorter list (module comment)."""
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
                _Erased.__init__[call=_call_raw[E]](handler),
                raw=True,
            )
        )

    def get[
        S: Movable & Deinitable, E: Deinitable, //, path: StaticString
    ](
        mut self,
        handler: def(State[S]) thin raises E -> String,
        state: State[S],
    ):
        """Registers the stateful `handler` for `GET path`, as `get` on
        `def()`: its String result becomes a 200 text response, and a raise
        is converted or the fixed 500. `handler`'s one parameter is
        `State[S]`, the type of `state`; the route keeps one copy of
        `state`, and each request passes it to `handler` by borrow."""
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
    ](mut self, handler: def(State[S]) thin raises E -> R, state: State[S]):
        """Registers the stateful `handler` for `GET path`, as the `String`
        overload; its result converts itself with `R.to_response()` after
        `handler` returns, as for `get` on `def() -> R`."""
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
        """Registers the stateful `handler` for `GET path`, as `get` on
        `def(Int)`: `path` declares exactly one path or query parameter,
        converted to `Int` and passed after the state, and a missing,
        duplicated or non-integer value yields 400 without calling
        `handler`. The state is passed as for `get` on `def(State[S])`."""
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
        """Registers the stateful `handler` for `GET path` with one `Int`
        route value, as the `String` overload; its result converts itself
        with `R.to_response()` after `handler` returns. A 400 calls neither
        `handler` nor the conversion; a raise skips the conversion."""
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
        """Registers the stateful raw `handler` for `GET path`, as the raw
        `get`: it receives the whole `Request` after the state and its
        `Response` is the answer, unconverted; `path` declares no path or
        query parameter, and no typed extraction runs. `handler`'s first
        parameter is `State[S]`, the type of `state`; the route keeps one
        copy of `state`, and each request passes it to `handler` by
        borrow."""
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
                _Erased.__init__[call=_call_state_raw[S, E]](
                    _Bound(handler, state)
                ),
                raw=True,
            )
        )

    def post[
        B: Movable & Deinitable, E: Deinitable, //, path: StaticString
    ](mut self, handler: def(var B) thin raises E -> String):
        """Registers `handler` for `POST path`, where `handler`'s one
        parameter is the request body and `path` declares no path or query
        parameter. An ordinary body `B` is an application type conforming
        to `FromBody`, converted with `B.from_body` before `handler` runs; a
        conversion failure yields 400 without calling `handler`. A handler
        may declare `body: B` or `var body: B`; `B` may be move-only. A
        raise is converted or the fixed 500, as for `get` on `def()`.

        `B` may instead be a `WithHeaders[B2]` carrier with `B2: FromBody`,
        which has no `from_body`: its fields are rebuilt (the fixed 500 on
        failure) and it is built through `_from_parts`, which converts the
        inner body with `B2.from_body` (400 on failure). The handler also
        receives the request's header fields, for which Muntin chooses no
        status (a `Json[T]` inner body keeps its `Content-Type` 415 step).
        This holds for every body overload, stateless or stateful."""
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
            "State is injected application state, not the request body; a"
            " stateful post handler takes State first and the body last, and"
            " the state is the registration's second argument"
        )
        comptime assert conforms_to(B, FromBody) or conforms_to(
            B, _HeaderCarrier
        ), (
            "the handler's parameter is the request body; its type must"
            " conform to FromBody"
        )
        self._routes.append(
            _Route(
                "POST",
                path,
                _Erased.__init__[call=_call_body[B, E, String, _text]](handler),
                body=True,
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
    ](mut self, handler: def(var B) thin raises E -> R):
        """Registers `handler` for `POST path` with the request body as its
        one parameter, as the `String` overload; its result converts itself
        with `R.to_response()` after `handler` returns. A conversion failure
        of the body yields 400 without calling `handler` or the result
        conversion; a raise from `handler` skips the conversion and is
        converted by `ToErrorResponse` or the fixed 500."""
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
            "State is injected application state, not the request body; a"
            " stateful post handler takes State first and the body last, and"
            " the state is the registration's second argument"
        )
        comptime assert conforms_to(B, FromBody) or conforms_to(
            B, _HeaderCarrier
        ), (
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
                json=conforms_to(B, _JsonBody),
                headers=conforms_to(B, _HeaderCarrier),
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
        conversion failure yields 400; neither calls `handler`. A raise is
        converted or the fixed 500, as for `get` on `def()`."""
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
            "State is injected application state, not the request body; a"
            " stateful post handler takes State first and the body last, and"
            " the state is the registration's second argument"
        )
        comptime assert conforms_to(B, FromBody) or conforms_to(
            B, _HeaderCarrier
        ), (
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
        """Registers `handler` for `POST path` with one route value and the
        request body, as the `String` overload; its result converts itself
        with `R.to_response()` after `handler` returns. A 400 calls neither
        `handler` nor the result conversion; a raise from `handler` skips
        the conversion and is converted by `ToErrorResponse` or the fixed
        500."""
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
            "State is injected application state, not the request body; a"
            " stateful post handler takes State first and the body last, and"
            " the state is the registration's second argument"
        )
        comptime assert conforms_to(B, FromBody) or conforms_to(
            B, _HeaderCarrier
        ), (
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
                json=conforms_to(B, _JsonBody),
                headers=conforms_to(B, _HeaderCarrier),
            )
        )

    def post[
        E: Deinitable, //, path: StaticString
    ](mut self, handler: def(var Request) thin raises E -> Response):
        """Registers the raw `handler` for `POST path`: it receives the
        whole `Request` (`method`, `path`, `query` and `body` as received)
        and its `Response` is the answer, unconverted. `handler` may declare
        `req: Request` or `var req: Request`. `path` declares no path or
        query parameter; Muntin runs no typed extraction after the route
        matches, so it answers no 400 before `handler`. A raise is converted
        or the fixed 500, as for `get` on `def()`.

        Keep this overload's parameter list strictly shorter than every body
        overload a `Request -> Response` handler satisfies: Mojo selects it
        over them by the shorter list (module comment)."""
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
                "POST",
                path,
                _Erased.__init__[call=_call_raw[E]](handler),
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
        """Registers the stateful `handler` for `POST path`, as `post` on
        `def(var B)`: the request body is converted before `handler` runs
        (an ordinary body with `B.from_body`, a carrier as there; 400
        without calling it on failure), its
        String result becomes a 200 text response, and a raise is converted
        or the fixed 500. `handler`'s first parameter is `State[S]`, the
        type of `state`, and its last the body; the route keeps one copy of
        `state`, and each request passes it to `handler` by borrow."""
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
            "Request is the whole request, not a body; a stateful raw handler"
            " takes State first, then only the Request, and returns Response"
        )
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
            _Route(
                "POST",
                path,
                _Erased.__init__[call=_call_state_body[S, B, E, String, _text]](
                    _Bound(handler, state)
                ),
                body=True,
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
        """Registers the stateful `handler` for `POST path` with the request
        body after the state, as the `String` overload; its result converts
        itself with `R.to_response()` after `handler` returns, as for `post`
        on `def(var B) -> R`."""
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
            "Request is the whole request, not a body; a stateful raw handler"
            " takes State first, then only the Request, and returns Response"
        )
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
            _Route(
                "POST",
                path,
                _Erased.__init__[
                    call=_call_state_body[S, B, E, R, _converted[R]]
                ](_Bound(handler, state)),
                body=True,
                json=conforms_to(B, _JsonBody),
                headers=conforms_to(B, _HeaderCarrier),
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
        """Registers the stateful `handler` for `POST path`, as `post` on
        `def(Int, var B)`: `path` declares exactly one path or query
        parameter, converted to `Int` and passed after the state, and the
        body comes last. An invalid route value yields 400 before the body
        is converted; a body conversion failure yields 400; neither calls
        `handler`. The state is passed as for `post` on
        `def(State[S], var B)`."""
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
            "Request is the whole request, not a body; a stateful raw handler"
            " takes State first, then only the Request, and returns Response"
        )
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
            _Route(
                "POST",
                path,
                _Erased.__init__[
                    call=_call_state_int_body[S, B, E, String, _text]
                ](_Bound(handler, state)),
                body=True,
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
        handler: def(State[S], Int, var B) thin raises E -> R,
        state: State[S],
    ):
        """Registers the stateful `handler` for `POST path` with one route
        value and the request body after the state, as the `String`
        overload; its result converts itself with `R.to_response()` after
        `handler` returns. A 400 calls neither `handler` nor the result
        conversion; a raise skips the conversion."""
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
            "Request is the whole request, not a body; a stateful raw handler"
            " takes State first, then only the Request, and returns Response"
        )
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
            _Route(
                "POST",
                path,
                _Erased.__init__[
                    call=_call_state_int_body[S, B, E, R, _converted[R]]
                ](_Bound(handler, state)),
                body=True,
                json=conforms_to(B, _JsonBody),
                headers=conforms_to(B, _HeaderCarrier),
            )
        )

    def post[
        S: Movable & Deinitable, E: Deinitable, //, path: StaticString
    ](
        mut self,
        handler: def(State[S], var Request) thin raises E -> Response,
        state: State[S],
    ):
        """Registers the stateful raw `handler` for `POST path`, as the raw
        `post`: it receives the whole `Request` after the state and its
        `Response` is the answer, unconverted; `path` declares no path or
        query parameter, and no typed extraction runs. The state is passed
        as for `get` on `def(State[S], var Request)`.

        Keep this overload's parameter list strictly shorter than the
        stateful body overloads' a `(State[S], Request) -> Response` handler
        satisfies: Mojo selects it over them by the shorter list (module
        comment)."""
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
                "POST",
                path,
                _Erased.__init__[call=_call_state_raw[S, E]](
                    _Bound(handler, state)
                ),
                raw=True,
            )
        )

    def handle(self, request: Request) -> Response:
        """Dispatches `request` through the application's routes.

        This is the backend seam: every transport (the in-memory TestClient,
        network adapters) delivers requests through this method. The first
        registered route whose method and path match handles the request,
        raw or typed; the query takes no part in selecting it. A raw route
        receives `request.method`, `path`, `query` and `body`, then each
        header field's name and value, as its raw arguments, and nothing else
        runs (no query gathering, no conversion); `_call_raw` or
        `_call_state_raw` rebuilds the `Request` (`_raw_request`). A typed
        route receives no headers unless its body is a `WithHeaders[B]`
        carrier (`_Route.headers`). A body route receives
        `request.body` as its last raw argument, after its route value if it
        has one; its call trampoline (`_call_body`, `_call_int_body`)
        converts it and answers 400 itself if that fails. A JSON body route
        (`_Route.json`) also receives the request's `Content-Type` verdict
        after the body, for the trampoline's 415 step. A carrier route then
        receives each header field's name and value, in order, after the
        body and any verdict.

        No matching route is 404. A missing or duplicated query value is 400
        here; the adapter answers its own 400s and turns a handler error
        into a response (`_handler_error`). A raise out of `invoke` is 500,
        never 400.
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
            if route.raw:
                args.append(request.method)
                args.append(request.path)
                args.append(request.query)
                args.append(request.body)
                for h in range(len(request.headers)):
                    args.append(request.headers.name(h))
                    args.append(request.headers.value(h))
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
                if route.json:
                    args.append(
                        "1" if _json_content_type(request.headers) else ""
                    )
                if route.headers:
                    for h in range(len(request.headers)):
                        args.append(request.headers.name(h))
                        args.append(request.headers.value(h))
            # No adapter raises: each answers its own 400s and turns a
            # handler error into a response. A raise here is a server fault,
            # never a client error.
            try:
                return route.handler.invoke(args)
            except:
                return _internal_error()
        return Response.text("Not Found", status=404)
