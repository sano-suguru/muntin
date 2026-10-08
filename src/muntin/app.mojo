"""Muntin application: route registration and request dispatch."""

from std.builtin.rebind import rebind_var
from std.os import abort

from ._handler_storage import _Erased
from ._registration_rules import (
    _BODY,
    _HEADERS,
    _NoSlot,
    _RAW,
    _admits,
    _check,
    _is_optional,
    _is_param,
    _kind,
    _param_name,
    _path_params,
    _path_part,
    _query_items,
)
from .body import FromBody
from .headers_body import _HeaderCarrier
from .http import Headers, Request, Response, ToErrorResponse, ToResponse
from .json import _JsonBody, _MAX_BODY_BYTES, _json_content_type
from .state import State

# Tags such as (M3-014) name the item whose decision, in
# docs/history/architecture-decisions.md, explains the code they mark.
#
# Registration (M3-014): each registration method (`get`, `post`, and, since
# M3-020, `put`, `patch` and `delete`) has one overload per request-slot
# arity, 0 to 3 (M3-022), in a stateless and a stateful family. `put` and
# `patch` are copies of `post` and take its shapes, `delete` a copy of `get`;
# `_rule` picks the shape family from the method. A request slot is a handler
# parameter that comes from the request. The stateful family takes a fixed
# leading `State[S]`, which is not a slot, and the state as the
# registration's second argument, so the argument count separates the
# families and no two overloads of a method accept the same handler. Every
# slot is a generic `var A` (a plain `def` with a borrowed parameter converts
# to it too), and its kind is decided at compile time from its type alone
# (`_kind`): a route value (`Int`, `String` or an `Optional` of either,
# below), a body (`FromBody`, or a `WithHeaders` carrier, below), the raw
# `Request`, the request `Headers` (below), a misplaced `State`, or none.
#
# Mojo 1.1.0 function types spelled without `thin` are traits and cannot be
# stored, so the overloads take thin function values; ordinary `def`
# functions convert implicitly. Each function type is `thin raises E` with
# `E` inferred (M2-010, Mojo's "parametric raises"): `Never` for a
# non-raising handler, `Error` for `raises`, the application's type for
# `raises T`. An explicitly typed function value spells every slot `var`
# (`def(var Int) thin raises Never -> String`): a typed value with a
# borrowed parameter converts to no generic slot
# (tests/registration_fail/typed_value_to_owned_slot.mojo). A leading
# `State[S]` keeps its spelling.
#
# The result type `R` is generic. Every overload accepts it only through
# `where (R == String or R == StaticString or conforms_to(R, ToResponse))`,
# which the compiler checks by identity at the call site: a check in the
# body could not tell `StaticString` from other immutable-origin string
# slices, because generic `==` keeps an origin's mutability but not its
# identity (tests/registration_known_gaps/
# generic_equality_ignores_origin_identity.mojo). `_respond` picks the
# policy at compile time: `String` or `StaticString` is a 200 text
# response, a `ToResponse` converts itself after the handler returns.
#
# Rules (`_rule`, `_check`, `_admits`, with `_kind`, in
# `_registration_rules.mojo`): every other registration rule is a
# compile-time assert with Muntin's message (`_check`), and the same rules
# as one Bool (`_admits`) guard the adapter's instantiation. Without the
# guard Mojo 1.1.0 reports the adapter's own failure before the rule's
# message. Both read one ordered rule function, so they accept the same
# shapes; if they ever disagree, the guard's `else` aborts at registration
# rather than leaving a route unregistered. A call that selects no overload
# (a wrong `State` convention, too many parameters, a result type outside
# the `where` clause) keeps the compiler's candidate notes.
#
# Adapters: one per arity and family (`_call_0` to `_call_state_3`). Each
# converts its slots in order (`_slot`), so a route value is converted
# before the next one and before the body; calls the handler alone in a
# `try`, whose error becomes `_handler_error`; then applies `_respond`. A
# slot's raw argument index is its position, because the route values come
# first, before the body or the `Headers` slot.
# `comptime if A == Int` does not refine `A` on Mojo 1.1.0, so a parsed
# `Int`, a `String` route value, a rebuilt `Request` or `Headers` and a text
# result reach their generic type through the one rebind helper `_as`, which
# asserts type equality first (the rebind alone accepts a different type of
# the same layout: tests/registration_known_gaps/rebind_var_layout_twins.mojo),
# and the confinement step of `scripts/check.sh` fails on any other
# `rebind_var`.
# The handler and its adapter are stored together in an `_Erased` box
# (`_handler_storage.mojo`), so dispatch is one call whatever the shape.
# Where a route value comes from (path segment or query key) is route data,
# not part of the shape. Whether a route takes the request body is route
# data too (`_Route.body`): `App.handle` appends the body as the last raw
# argument, after the route values if there are any.
#
# Raw handlers (M2-014): `Request` is a slot kind, so a raw handler selects the
# arity-1 overload (after `State[S]` in the stateful family) like any one-slot
# handler, and its rule requires `Response` as the result and no placeholder. A
# raw route (`_Route.raw`) gets the request's method, path, query and body as
# its first four raw arguments, then each header field's name and value (M3-002,
# R1), and nothing else runs; `_raw_request` rebuilds the `Request`, headers
# included, and the adapter moves it into the handler. A typed route gets header
# strings only when its body is a `WithHeaders[B]` carrier or its last slot is
# `Headers` (below).
#
# Stateful handlers (M3-001): a registration with a second argument, `(handler,
# state: State[S])`, takes a handler whose first parameter is `State[S]` and
# whose slots follow, bound and checked as the stateless shape of the same
# slots. `S` is inferred from both arguments, so they must agree. The
# registration moves the handler and one copy of the handle into the route's
# `_Erased` box as one `_Bound[H, S]`; the stateful adapters borrow it and pass
# the handle by borrow, so a request copies nothing, changes no reference count
# and allocates nothing for the state. `State` conforms to the private marker
# `_InjectedState`, so a `State` in a slot (a stateful handler registered
# without its state, or a second `State`) is reported by its rule.
#
# Errors (M2-010): a request-side failure is answered by the step that fails,
# before the handler runs (query gathering and route-value decoding in
# `App.handle`, `_slot` in the adapters, which raises the status as a
# `_Reject`); a raw route has no such step except its rebuild, whose failure is
# the fixed 500. Only the handler call
# sits in an adapter's handler `try`; whatever it raises goes to
# `_handler_error[E]`, and the response policy runs only after it returns.
# `_handler_error` converts an error whose declared type `E` conforms to
# `ToErrorResponse` (M2-012) and answers every other one with a fixed 500.
#
# JSON bodies (M3-008): `Json[T]` is an ordinary `FromBody` body slot; a route
# whose body conforms to the private marker `_JsonBody` sets `_Route.json`.
# `FromBody.from_body` sees only the body, so the request `Content-Type` is
# decided in `App.handle`, which appends a verdict after the body for a JSON
# route only (`"1"` when the request has exactly one `application/json` field,
# else empty; other routes' arguments are unchanged). The body slot, for a JSON
# body only, answers 415 unless the arguments end with the verdict `"1"` at the
# expected position (an exact arity check, so a body can never stand in for a
# missing verdict), then 413 when the body is over 1 MiB, after the route value
# and before `from_body`. Order on a JSON body route: 404, query or capture 400
# (`App.handle`), `Int` 400, 415, 413, JSON 400 (`from_body`), handler.
#
# Header carriers (M3-012): `WithHeaders[B]` (`headers_body.mojo`) is a body
# slot without being a `FromBody`: `_kind` accepts `FromBody` or the private
# marker `_HeaderCarrier`, and the route sets `_Route.headers` for a carrier.
# For such a route, `App.handle` appends each request header field's name
# and value after the body and the JSON verdict (the R1 transport raw routes
# use). The body slot then rebuilds the fields into a `Headers`
# (`_carrier_fields`; a failure, which only the M3-002 `_fields` gap can cause,
# is the fixed 500) and builds the carrier with `B._from_parts`, which converts
# the body with the inner `from_body` (a raise: 400). The carrier forwards
# `_JsonBody` exactly when its body does, so a `WithHeaders[Json[T]]` route
# keeps the order above; its arity check allows only name and value pairs after
# the verdict, and every other JSON body keeps the exact arity. Muntin chooses
# no status for the fields the handler reads and gives them no meaning; the
# `Content-Type` verdict for a `Json[T]` body (415) and the rebuild failure
# (500) still answer before the handler.
#
# Header slots (M3-016): on `get` and `delete`, `Headers` is a slot kind by
# exact type equality (no trait, so no application type is one), accepted
# once, as the last slot, after at most two route values. The route sets
# `_Route.headers`, so `App.handle` appends each field's name and value after
# the route values, and the slot rebuilds them into a fresh `Headers`
# (`_header_slot`; a failure, again only the `_fields` gap, is the fixed 500)
# that the handler owns or borrows. `post`, `put` and `patch` take no
# `Headers` slot: their fields come through the carrier, and `_post_rule`
# reports a `Headers` slot as it reports a type of no kind.
#
# Route values (M3-018): a route value is an `Int` or a `String` (`_TEXT`, by
# exact type equality, so no application type is one) or an `Optional` of
# either (below), at most two per handler (M3-022), never the body. They
# bind by position: the path captures left to right, then the query values
# in the literal's order; names are never compared with the handler's
# parameters. `App.handle` decodes each raw
# capture once (`_decode_value`), after matching on the raw path, before any
# conversion: path captures in place, then each query value as `_query_value`
# finds it; an empty value, a bad escape or decoded bytes that are not UTF-8
# are 400 there. The `String` slot takes the decoded text and the `Int` slot
# parses it. Query keys, `Request.path`, `Request.query` and raw routes stay
# undecoded.
#
# Optional values (M3-024): an `Optional[Int]` or `Optional[String]` slot is
# an optional route value, by exact type equality; it binds a query
# placeholder only (a path segment is never absent). `_route` marks the query
# keys whose values bind one (`_Route.query_optional`); for such a key,
# `App.handle` passes an absent key or an empty value on as `""`, which no
# decoded value is, and the slot gives `None` for it. A present value is
# decoded and converted as a required one, a repeated key is 400 for both.


def _match(route: String, path: String, mut args: List[String]) -> Bool:
    """Matches `path` against `route` segment by segment.

    Static segments must be equal; a `{name}` segment matches one non-empty
    segment, which is appended to `args` (cleared first), left to right. A
    typed route holds at most two placeholders and a raw route none
    (enforced at registration).
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
    """Converts a route value's decoded text to `Int`: an optional `-`
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


def _query_value(query: String, key: String) raises -> Optional[String]:
    """The value of `key` in a raw query string, or `None` if `key` is
    absent. Raises if `key` appears more than once.

    Pairs are separated by `&`; a pair's key and value split at its first
    `=`, and a pair without `=` has an empty value. Keys compare byte for
    byte. Nothing is percent-decoded and `+` is not a space.
    """
    var value = Optional[String]()
    for pair in query.split("&"):
        var eq = pair.find("=")
        var name = pair[byte=:eq] if eq >= 0 else pair[byte=:]
        if name != key:
            continue
        if value:
            raise Error("duplicate query key")
        value = String(pair[byte = eq + 1 :]) if eq >= 0 else String()
    return value^


def _hex_digit(b: Byte) -> Int:
    """The value of the ASCII hex digit `b` (either case), or -1."""
    var c = Int(b)
    if c >= ord("0") and c <= ord("9"):
        return c - ord("0")
    if c >= ord("a") and c <= ord("f"):
        return c - ord("a") + 10
    if c >= ord("A") and c <= ord("F"):
        return c - ord("A") + 10
    return -1


def _decode_value(raw: String, query: Bool) raises -> String:
    """A captured route value's text (M3-018): `raw` percent-decoded once.

    Each `%` followed by two hex digits (either case) becomes that byte and
    every other byte is kept; in a query value (`query`) a `+` is a space
    first, in a path value it is literal. Nothing is normalized. Raises,
    for the caller's 400, on an empty value, a `%` not followed by two hex
    digits, or decoded bytes that are not UTF-8; any other valid UTF-8,
    control characters included, is a value.
    """
    var src = raw.as_bytes()
    if len(src) == 0:
        raise Error("empty route value")
    var out = List[Byte](capacity=len(src))
    var i = 0
    while i < len(src):
        var b = src[i]
        if Int(b) == ord("%"):
            if i + 2 >= len(src):
                raise Error("truncated percent escape")
            var hi = _hex_digit(src[i + 1])
            var lo = _hex_digit(src[i + 2])
            if hi < 0 or lo < 0:
                raise Error("bad percent escape")
            out.append(Byte(hi * 16 + lo))
            i += 3
        elif query and Int(b) == ord("+"):
            out.append(Byte(ord(" ")))
            i += 1
        else:
            out.append(b)
            i += 1
    return String(from_utf8=Span(out))


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


comptime _GUARD_DRIFT = "registration rule check and guard disagree"
"""The guard's `else`: `_admits` rejected a shape `_check` accepted."""


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


def _header_slot(args: List[String], at: Int) raises -> Headers:
    """Rebuilds a `Headers` slot's fields from the name and value pairs
    from `args[at]` on, in order (only route values precede them).
    `Headers.add` validates each field again, so only the M3-002 `_fields`
    gap can make this raise, and `_slot` answers that with the fixed 500."""
    var headers = Headers()
    var i = at
    while i + 1 < len(args):
        headers.add(args[i], args[i + 1])
        i += 2
    return headers^


def _as[T: Movable, A: Movable](var value: T) -> A:
    """`value` as `A`, which must equal `T`: the one `rebind_var` in
    `src/muntin`.

    `comptime if A == Int` does not refine `A` on Mojo 1.1.0
    (tests/header_access_fail/generic_slot_does_not_refine.mojo), so a
    generic slot or result reaches its type through a rebind, and the rebind
    alone also accepts a different type with the same layout
    (tests/registration_known_gaps/rebind_var_layout_twins.mojo). The
    equality asserted here is exact for origin-free types (`Int`,
    `String`, their `Optional`s, `Request`, `Headers`); generic `==`
    ignores which origin a slice has, so for a `StaticString` result
    exactness comes from the overloads' `where` clause. The confinement
    step of `scripts/check.sh` requires the `rebind_var` on the line after
    this assert and nowhere else."""
    comptime assert A == T, "rebind requires generic type equality"
    return rebind_var[A](value^)


@fieldwise_init
struct _Reject(Movable):
    """A slot's request-side failure: the status answered before the
    handler runs (400, 413, 415, or 500 for a rebuild failure)."""

    var status: Int


def _rejected(r: _Reject) -> Response:
    """The response for a `_Reject`."""
    if r.status == 400:
        return _bad_request()
    if r.status == 500:
        return _internal_error()
    return _json_answer(r.status)


def _slot[
    A: Movable & Deinitable, at: Int
](args: List[String]) raises _Reject -> A:
    """Converts the request slot of type `A` whose raw argument is
    `args[at]`, already decoded if it is a route value (`App.handle`). An
    `Int` route value is parsed (`_parse_int`; 400 if invalid); a `String`
    route value is a copy of the decoded text. An `Optional[Int]` or
    `Optional[String]` is `None` for `""`, which `App.handle` passes for an
    absent or empty optional value (M3-025), and otherwise converts as the
    required slot of its type. A raw `Request` is rebuilt
    from all the arguments (`_raw_request`; a failure is the fixed 500). A
    `Headers` slot is rebuilt from the field pairs from `args[at]` on
    (`_header_slot`; a failure is the fixed 500). A body is converted with
    `A.from_body` (400 if it raises); for a JSON body (`_JsonBody`) the 415
    and 413 steps run first (`_json_status`); a `WithHeaders` carrier has
    its header fields rebuilt (the fixed 500 on failure) and is built
    through `A._from_parts`, whose inner `from_body` raise is the same 400.

    `A` is refined here rather than bounded: forwarding a handler with an
    explicit body type to a callee that requires `FromBody` fails on Mojo
    1.1.0 (docs/history/architecture-decisions.md, "Argument extraction decision (M2-005)").
    """
    comptime if A == Int:
        try:
            return _as[Int, A](_parse_int(args[at]))
        except:
            raise _Reject(400)
    elif A == String:
        return _as[String, A](args[at].copy())
    elif A == Optional[Int]:
        if args[at].byte_length() == 0:
            return _as[Optional[Int], A](None)
        try:
            return _as[Optional[Int], A](_parse_int(args[at]))
        except:
            raise _Reject(400)
    elif A == Optional[String]:
        if args[at].byte_length() == 0:
            return _as[Optional[String], A](None)
        return _as[Optional[String], A](args[at].copy())
    elif A == Request:
        try:
            return _as[Request, A](_raw_request(args))
        except:
            raise _Reject(500)
    elif A == Headers:
        try:
            return _as[Headers, A](_header_slot(args, at))
        except:
            raise _Reject(500)  # only the `_fields` gap gets here
    else:
        comptime assert conforms_to(A, FromBody) or conforms_to(
            A, _HeaderCarrier
        )
        comptime if conforms_to(A, _JsonBody):
            var status = _json_status[A](args, at)
            if status != 0:
                raise _Reject(status)
        comptime if conforms_to(A, _HeaderCarrier):
            var fields: Headers
            try:
                fields = _carrier_fields[A](args, at)
            except:
                raise _Reject(500)  # only the `_fields` gap gets here
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


def _respond[R: Movable & Deinitable](var result: R) -> Response:
    """The result policy, chosen at compile time from `R`: `String` or
    `StaticString` is a 200 text response, a `ToResponse` converts itself
    by move (a `Response` unchanged). The overloads' `where` clause admits
    no other `R`."""
    comptime if R == String:
        return Response.text(_as[R, String](result^))
    elif R == StaticString:
        return Response.text(String(_as[R, StaticString](result^)))
    else:
        comptime assert conforms_to(R, ToResponse)
        return result^.to_response()


# Adapter parameters are explicit (no `//`): they are passed as `call=` to
# `_Erased.__init__`, where there is no runtime argument to infer them from.
# Each adapter answers its slots' request-side failures, then calls the
# handler alone in a `try` (its error becomes `_handler_error`), then
# applies `_respond`. None of them raises.


def _call_0[
    E: Deinitable, R: Movable & Deinitable
](handler: def() thin raises E -> R, args: List[String]) -> Response:
    var result: R
    try:
        result = handler()
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_1[
    A: Movable & Deinitable, E: Deinitable, R: Movable & Deinitable
](handler: def(var A) thin raises E -> R, args: List[String]) -> Response:
    """Converts the one slot (`_slot`) and moves it into `handler`; a
    failure answers without calling it."""
    var a: A
    try:
        a = _slot[A, 0](args)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = handler(a^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_2[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
](
    handler: def(var A, var B) thin raises E -> R, args: List[String]
) -> Response:
    """Converts the two slots in order, so a bad route value answers before
    the body is converted, and moves both into `handler`."""
    var a: A
    var b: B
    try:
        a = _slot[A, 0](args)
        b = _slot[B, 1](args)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = handler(a^, b^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_3[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    C: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
](
    handler: def(var A, var B, var C) thin raises E -> R, args: List[String]
) -> Response:
    """Converts the three slots in order, so a bad route value answers
    before the next value, the body or the `Headers` is converted, and
    moves them into `handler`."""
    var a: A
    var b: B
    var c: C
    try:
        a = _slot[A, 0](args)
        b = _slot[B, 1](args)
        c = _slot[C, 2](args)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = handler(a^, b^, c^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


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


def _call_state_0[
    S: Movable & Deinitable, E: Deinitable, R: Movable & Deinitable
](
    bound: _Bound[def(State[S]) thin raises E -> R, S], args: List[String]
) -> Response:
    """`_call_0` with the route's state handle passed first, by borrow."""
    var result: R
    try:
        result = bound.handler(bound.state)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_state_1[
    S: Movable & Deinitable,
    A: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
](
    bound: _Bound[def(State[S], var A) thin raises E -> R, S],
    args: List[String],
) -> Response:
    """`_call_1` with the route's state handle passed first, by borrow."""
    var a: A
    try:
        a = _slot[A, 0](args)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = bound.handler(bound.state, a^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_state_2[
    S: Movable & Deinitable,
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
](
    bound: _Bound[def(State[S], var A, var B) thin raises E -> R, S],
    args: List[String],
) -> Response:
    """`_call_2` with the route's state handle passed first, by borrow."""
    var a: A
    var b: B
    try:
        a = _slot[A, 0](args)
        b = _slot[B, 1](args)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = bound.handler(bound.state, a^, b^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_state_3[
    S: Movable & Deinitable,
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    C: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
](
    bound: _Bound[def(State[S], var A, var B, var C) thin raises E -> R, S],
    args: List[String],
) -> Response:
    """`_call_3` with the route's state handle passed first, by borrow."""
    var a: A
    var b: B
    var c: C
    try:
        a = _slot[A, 0](args)
        b = _slot[B, 1](args)
        c = _slot[C, 2](args)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = bound.handler(bound.state, a^, b^, c^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _route[
    A: AnyType, B: AnyType, C: AnyType
](method: String, path: StaticString, var handler: _Erased) -> _Route:
    """The route for an accepted handler whose request slots have types `A`,
    `B` and `C` (`_NoSlot` where there is none): a body route, JSON or
    carrier when its body is such a body, raw when its slot is the
    `Request`, and a route that receives the header fields for a carrier or
    a `Headers` slot. A body, a `Headers` or a `Request` slot is always the
    last one, so the flags read every slot. Each query key whose value binds
    an `Optional` slot is marked optional (M3-025): route values come first,
    so the value at position `j` binds query key `j - paths`."""
    var route = _Route(
        method,
        path,
        handler^,
        body=_kind[A]() == _BODY or _kind[B]() == _BODY or _kind[C]() == _BODY,
        json=conforms_to(A, _JsonBody)
        or conforms_to(B, _JsonBody)
        or conforms_to(C, _JsonBody),
        headers=conforms_to(A, _HeaderCarrier)
        or conforms_to(B, _HeaderCarrier)
        or conforms_to(C, _HeaderCarrier)
        or _kind[A]() == _HEADERS
        or _kind[B]() == _HEADERS
        or _kind[C]() == _HEADERS,
        raw=_kind[A]() == _RAW,
    )
    var paths = _path_params(path)
    var kinds = [_kind[A](), _kind[B](), _kind[C]()]
    for j in range(len(kinds)):
        if _is_optional(kinds[j]):
            route.query_optional[j - paths] = True
    return route^


struct _Route(Movable):
    var method: String
    var path: String
    """Path part of the route literal; the only part requests are matched
    against."""
    var query_keys: List[String]
    """Keys of the route's `{key}` query parameters, in the literal's order
    (none if it has no query part)."""
    var query_optional: List[Bool]
    """For each of `query_keys`, whether its value binds an `Optional` slot
    (M3-025): `App.handle` then passes an absent key or an empty value on
    as `""` instead of answering 400. All `False` until `_route` sets them."""
    var body: Bool
    """Whether the handler's last argument is the request body."""
    var json: Bool
    """Whether that body is a `Json[T]` (`_JsonBody`): `App.handle` then
    appends the request's `Content-Type` verdict after the body, and the
    adapter answers 415 and 413 before `from_body` (M3-009)."""
    var headers: Bool
    """Whether the handler receives the request's header fields: its body
    is a `WithHeaders[B]` carrier (`_HeaderCarrier`, M3-013) or its last
    slot is `Headers` (M3-016). `App.handle` then appends each field's name
    and value after the body and any verdict, or, on a `Headers` route,
    after its route values if it has any, and the adapter rebuilds the
    fields into the carrier or the `Headers` slot."""
    var raw: Bool
    """Whether the handler receives the whole request (a `Request`
    slot): its raw arguments are the request's method, path, query and
    body, then each header field's name and value."""
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
        """Splits `route` into its path part and query keys with the
        route-literal grammar's primitives (`_registration_rules.mojo`); the
        literal is well formed (checked at registration)."""
        self.method = method
        self.body = body
        self.json = json
        self.headers = headers
        self.raw = raw
        self.path = String(_path_part(route))
        self.query_keys = List[String]()
        for item in _query_items(route):
            self.query_keys.append(String(_param_name(item)))
        self.query_optional = List[Bool](
            length=len(self.query_keys), fill=False
        )
        self.handler = handler^


struct App(Movable):
    """A Muntin application: a set of routes and the dispatch entry point."""

    var _routes: List[_Route]

    def __init__(out self):
        self._routes = List[_Route]()

    def get[
        E: Deinitable, R: Movable & Deinitable, //, path: StaticString
    ](mut self, handler: def() thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler`, which takes no parameter, for `GET path`;
        `path` declares no path or query parameter.

        A `String` or `StaticString` result becomes a 200 text response; a
        result conforming to `ToResponse` (an application type, or
        `Response`) converts itself with `to_response()` after `handler`
        returns. `handler` may be non-raising or declare `raises` or
        `raises T`. A raise skips the result conversion and is answered by
        the error's `to_error_response()` if the declared error type `E`
        conforms to `ToErrorResponse`; anything else it raises becomes a
        fixed 500 `Internal Server Error` (the error's text is never sent).
        """
        _check["GET", False, path, R, _NoSlot, _NoSlot, _NoSlot]()
        comptime if _admits["GET", False, path, R, _NoSlot, _NoSlot, _NoSlot]():
            self._routes.append(
                _route[_NoSlot, _NoSlot, _NoSlot](
                    "GET", path, _Erased.__init__[call=_call_0[E, R]](handler)
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
    ](mut self, handler: def(var A) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler`, which takes one request parameter, for
        `GET path`.

        An `Int` or `String` parameter is a route value: `path` declares
        exactly one parameter, a `{name}` segment (`/users/{id}`) or a `{key}`
        query item (`/items?{limit}`), whose value is percent-decoded once (`+`
        is a space in a query value only), then converted to `Int` or passed as
        the decoded `String`, by position (names are not checked against the
        handler); a missing, duplicated or empty value, a bad escape, text that
        is not UTF-8, or, for an `Int`, a non-integer yields 400 without
        calling `handler`. An `Optional[Int]` or `Optional[String]` parameter
        is an optional route value (M3-025): `path` declares exactly one
        `{key}` query item and no path parameter, and an absent key, an empty
        value or a pair without `=` gives `None`; a present value follows the
        rules above, so a duplicated key is still 400. A `Headers` parameter
        receives the request's header fields (`path` declares no parameter): a
        fresh `Headers` with every field in order, rebuilt from the request's;
        Muntin chooses no status for a field, and only a field held invalidly
        in memory (the M3-002 `_fields` gap) is answered before `handler`, with
        the fixed 500. A `Request` parameter makes a raw handler, which returns
        `Response`: `path` declares no parameter, the handler receives the
        whole request (method, path, query, body and header fields as
        received), Muntin runs no typed extraction, so it answers no 400 before
        `handler`, and the `Response` is the answer. The parameter may be
        borrowed or `var`; an explicitly typed function value spells it `var`
        (`def(var Int) thin raises Never -> String`). Results and raises are
        handled as for `get` on `def()`."""
        _check["GET", False, path, R, A, _NoSlot, _NoSlot]()
        comptime if _admits["GET", False, path, R, A, _NoSlot, _NoSlot]():
            self._routes.append(
                _route[A, _NoSlot, _NoSlot](
                    "GET",
                    path,
                    _Erased.__init__[call=_call_1[A, E, R]](handler),
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
    ](mut self, handler: def(var A, var B) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler` for `GET path` with a route value and then the
        request's `Headers`, where `path` declares exactly one route value, as
        for `get` on `def(var A)`; or with two route values (M3-022), where
        `path` declares exactly two: two `{name}` segments, two `{key}` query
        items, or one of each (`/users/{uid}/posts/{pid}`,
        `/users/{id}?{fields}`). Binding is positional: the path values left to
        right, then the query values in the literal's order, fill the
        parameters in order; names are never compared, so two values of one
        type declared in the other order receive each other's values. An
        optional value binds a `{key}` item: one at a path position is
        rejected. The values are converted first, in order, so an invalid one
        is 400 before the next one or the fields are converted. Every other
        two-parameter shape is rejected (a `get` handler takes no request body
        and one `Headers`, last); a registration reports the rule it breaks."""
        _check["GET", False, path, R, A, B, _NoSlot]()
        comptime if _admits["GET", False, path, R, A, B, _NoSlot]():
            self._routes.append(
                _route[A, B, _NoSlot](
                    "GET",
                    path,
                    _Erased.__init__[call=_call_2[A, B, E, R]](handler),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def get[
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        C: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](mut self, handler: def(var A, var B, var C) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler` for `GET path` with two route values and then
        the request's `Headers` (M3-022), where `path` declares exactly two
        route values, as for `get` on `def(var A, var B)`. Both values are
        converted first, in order, so an invalid one is 400 before the fields
        are rebuilt. Every other three-parameter shape is rejected (a `get`
        handler takes at most two route values, no request body, and one
        `Headers`, last); a registration reports the rule it breaks."""
        _check["GET", False, path, R, A, B, C]()
        comptime if _admits["GET", False, path, R, A, B, C]():
            self._routes.append(
                _route[A, B, C](
                    "GET",
                    path,
                    _Erased.__init__[call=_call_3[A, B, C, E, R]](handler),
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
        mut self, handler: def(State[S]) thin raises E -> R, state: State[S]
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `GET path`, as `get` on
        `def()`. `handler`'s one parameter is `State[S]`, the type of
        `state`; the route keeps one copy of `state`, and each request
        passes it to `handler` by borrow."""
        _check["GET", True, path, R, _NoSlot, _NoSlot, _NoSlot]()
        comptime if _admits["GET", True, path, R, _NoSlot, _NoSlot, _NoSlot]():
            self._routes.append(
                _route[_NoSlot, _NoSlot, _NoSlot](
                    "GET",
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
        mut self,
        handler: def(State[S], var A) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `GET path`, as `get` on
        `def(var A)` after the state: a route value, the request's `Headers`,
        or the raw `Request` returning `Response`. The state is passed as for
        `get` on `def(State[S])`; a leading `State[S]` keeps its spelling in a
        typed function value."""
        _check["GET", True, path, R, A, _NoSlot, _NoSlot]()
        comptime if _admits["GET", True, path, R, A, _NoSlot, _NoSlot]():
            self._routes.append(
                _route[A, _NoSlot, _NoSlot](
                    "GET",
                    path,
                    _Erased.__init__[call=_call_state_1[S, A, E, R]](
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
        mut self,
        handler: def(State[S], var A, var B) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `GET path`, as `get` on
        `def(var A, var B)` after the state: a route value, then the request's
        `Headers`, or two route values. The state is passed as for `get` on
        `def(State[S])`."""
        _check["GET", True, path, R, A, B, _NoSlot]()
        comptime if _admits["GET", True, path, R, A, B, _NoSlot]():
            self._routes.append(
                _route[A, B, _NoSlot](
                    "GET",
                    path,
                    _Erased.__init__[call=_call_state_2[S, A, B, E, R]](
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
        C: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var A, var B, var C) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `GET path`, as `get` on
        `def(var A, var B, var C)` after the state: two route values, then the
        request's `Headers`. The state is passed as for `get` on
        `def(State[S])`."""
        _check["GET", True, path, R, A, B, C]()
        comptime if _admits["GET", True, path, R, A, B, C]():
            self._routes.append(
                _route[A, B, C](
                    "GET",
                    path,
                    _Erased.__init__[call=_call_state_3[S, A, B, C, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def post[
        E: Deinitable, R: Movable & Deinitable, //, path: StaticString
    ](mut self, handler: def() thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """The parameterless `post` shape. No such handler is accepted
        today (a `post` handler takes the request body last, or is raw); a
        registration reports that rule."""
        _check["POST", False, path, R, _NoSlot, _NoSlot, _NoSlot]()
        comptime if _admits[
            "POST", False, path, R, _NoSlot, _NoSlot, _NoSlot
        ]():
            self._routes.append(
                _route[_NoSlot, _NoSlot, _NoSlot](
                    "POST", path, _Erased.__init__[call=_call_0[E, R]](handler)
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def post[
        A: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](mut self, handler: def(var A) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler`, which takes one request parameter, for
        `POST path`; `path` declares no path or query parameter.

        The parameter is the request body: an application type conforming
        to `FromBody`, converted with `from_body` before `handler` runs (a
        conversion failure yields 400 without calling `handler`), or a
        `WithHeaders[B2]` carrier with `B2: FromBody`, which has no
        `from_body`: its fields are rebuilt (the fixed 500 on failure) and
        it is built through `_from_parts`, which converts the inner body
        with `B2.from_body` (400 on failure); the handler also receives the
        request's header fields, for which Muntin chooses no status. A
        `Json[T]` body, alone or in a carrier, is first answered 415 unless
        the request has exactly one `application/json` `Content-Type`, then
        413 when it is over 1 MiB. The body may be declared `body: B` or
        `var body: B`, and `B` may be move-only. A `Request` parameter
        instead makes a raw handler, as for `get`. Results and raises are
        handled as for `get` on `def()`; this holds for every body shape,
        stateless or stateful."""
        _check["POST", False, path, R, A, _NoSlot, _NoSlot]()
        comptime if _admits["POST", False, path, R, A, _NoSlot, _NoSlot]():
            self._routes.append(
                _route[A, _NoSlot, _NoSlot](
                    "POST",
                    path,
                    _Erased.__init__[call=_call_1[A, E, R]](handler),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def post[
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](mut self, handler: def(var A, var B) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler` for `POST path` with a route value and then the
        request body, where `path` declares exactly one route value, a `{name}`
        segment (`/users/{id}`) or a `{key}` query item (`/users?{id}`; for an
        optional value, a `{key}` item only). Binding is positional: the route
        value is the first parameter, decoded and converted as for `get`, and
        the body the second, as for `post` on `def(var A)`; a `String` is never
        the body. An invalid matched path value, or a query value that `get`
        answers 400 for (a missing, duplicated, empty or invalid one; for an
        optional value, a duplicated or invalid one), yields 400 before the
        body is converted (a missing path segment does not match the route:
        404); the body's own steps follow; neither calls `handler`. The route
        value may be borrowed or `var`; an explicitly typed function value
        spells both parameters `var`. Results and raises as for `get` on
        `def()`."""
        _check["POST", False, path, R, A, B, _NoSlot]()
        comptime if _admits["POST", False, path, R, A, B, _NoSlot]():
            self._routes.append(
                _route[A, B, _NoSlot](
                    "POST",
                    path,
                    _Erased.__init__[call=_call_2[A, B, E, R]](handler),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def post[
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        C: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](mut self, handler: def(var A, var B, var C) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler` for `POST path` with two route values and then
        the request body (M3-022), where `path` declares exactly two route
        values: two `{name}` segments, two `{key}` query items, or one of each
        (`/users/{uid}/posts/{pid}`, `/users/{id}?{fields}`). Binding is
        positional: the path values left to right, then the query values in the
        literal's order, fill the first two parameters, each decoded and
        converted as for `get`; the body is the third, as for `post` on
        `def(var A)`. An optional value binds a `{key}` item: one at a path
        position is rejected. An invalid value yields 400 before the next value
        or the body is converted; the body's own steps follow; neither calls
        `handler`. Results and raises as for `get` on `def()`."""
        _check["POST", False, path, R, A, B, C]()
        comptime if _admits["POST", False, path, R, A, B, C]():
            self._routes.append(
                _route[A, B, C](
                    "POST",
                    path,
                    _Erased.__init__[call=_call_3[A, B, C, E, R]](handler),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def post[
        S: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self, handler: def(State[S]) thin raises E -> R, state: State[S]
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """The stateful parameterless `post` shape. No such handler is
        accepted today; a registration reports the body rule."""
        _check["POST", True, path, R, _NoSlot, _NoSlot, _NoSlot]()
        comptime if _admits["POST", True, path, R, _NoSlot, _NoSlot, _NoSlot]():
            self._routes.append(
                _route[_NoSlot, _NoSlot, _NoSlot](
                    "POST",
                    path,
                    _Erased.__init__[call=_call_state_0[S, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def post[
        S: Movable & Deinitable,
        A: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var A) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `POST path`, as `post` on
        `def(var A)` after the state: the request body, or the raw
        `Request` returning `Response`. `handler`'s first parameter is
        `State[S]`, the type of `state`; the route keeps one copy of
        `state`, and each request passes it to `handler` by borrow."""
        _check["POST", True, path, R, A, _NoSlot, _NoSlot]()
        comptime if _admits["POST", True, path, R, A, _NoSlot, _NoSlot]():
            self._routes.append(
                _route[A, _NoSlot, _NoSlot](
                    "POST",
                    path,
                    _Erased.__init__[call=_call_state_1[S, A, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def post[
        S: Movable & Deinitable,
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var A, var B) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `POST path`, as `post` on
        `def(var A, var B)` after the state: a route value, then the request
        body. The state is passed as for `post` on `def(State[S], var A)`."""
        _check["POST", True, path, R, A, B, _NoSlot]()
        comptime if _admits["POST", True, path, R, A, B, _NoSlot]():
            self._routes.append(
                _route[A, B, _NoSlot](
                    "POST",
                    path,
                    _Erased.__init__[call=_call_state_2[S, A, B, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def post[
        S: Movable & Deinitable,
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        C: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var A, var B, var C) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `POST path`, as `post` on
        `def(var A, var B, var C)` after the state: two route values, then the
        request body. The state is passed as for `post` on
        `def(State[S], var A)`."""
        _check["POST", True, path, R, A, B, C]()
        comptime if _admits["POST", True, path, R, A, B, C]():
            self._routes.append(
                _route[A, B, C](
                    "POST",
                    path,
                    _Erased.__init__[call=_call_state_3[S, A, B, C, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def put[
        E: Deinitable, R: Movable & Deinitable, //, path: StaticString
    ](mut self, handler: def() thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """The parameterless `put` shape. No such handler is accepted
        today (a `put` handler takes the request body last, or is raw); a
        registration reports that rule."""
        _check["PUT", False, path, R, _NoSlot, _NoSlot, _NoSlot]()
        comptime if _admits["PUT", False, path, R, _NoSlot, _NoSlot, _NoSlot]():
            self._routes.append(
                _route[_NoSlot, _NoSlot, _NoSlot](
                    "PUT", path, _Erased.__init__[call=_call_0[E, R]](handler)
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def put[
        A: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](mut self, handler: def(var A) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler`, which takes one request parameter, for
        `PUT path`; `path` declares no path or query parameter.

        The parameter is the request body: an application type conforming
        to `FromBody`, converted with `from_body` before `handler` runs (a
        conversion failure yields 400 without calling `handler`), or a
        `WithHeaders[B2]` carrier with `B2: FromBody`, which has no
        `from_body`: its fields are rebuilt (the fixed 500 on failure) and
        it is built through `_from_parts`, which converts the inner body
        with `B2.from_body` (400 on failure); the handler also receives the
        request's header fields, for which Muntin chooses no status. A
        `Json[T]` body, alone or in a carrier, is first answered 415 unless
        the request has exactly one `application/json` `Content-Type`, then
        413 when it is over 1 MiB. The body may be declared `body: B` or
        `var body: B`, and `B` may be move-only. A `Request` parameter
        instead makes a raw handler, as for `get`. Results and raises are
        handled as for `get` on `def()`; this holds for every body shape,
        stateless or stateful."""
        _check["PUT", False, path, R, A, _NoSlot, _NoSlot]()
        comptime if _admits["PUT", False, path, R, A, _NoSlot, _NoSlot]():
            self._routes.append(
                _route[A, _NoSlot, _NoSlot](
                    "PUT",
                    path,
                    _Erased.__init__[call=_call_1[A, E, R]](handler),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def put[
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](mut self, handler: def(var A, var B) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler` for `PUT path` with a route value and then the
        request body, where `path` declares exactly one route value, a `{name}`
        segment (`/users/{id}`) or a `{key}` query item (`/users?{id}`; for an
        optional value, a `{key}` item only). Binding is positional: the route
        value is the first parameter, decoded and converted as for `get`, and
        the body the second, as for `put` on `def(var A)`; a `String` is never
        the body. An invalid matched path value, or a query value that `get`
        answers 400 for (a missing, duplicated, empty or invalid one; for an
        optional value, a duplicated or invalid one), yields 400 before the
        body is converted (a missing path segment does not match the route:
        404); the body's own steps follow; neither calls `handler`. The route
        value may be borrowed or `var`; an explicitly typed function value
        spells both parameters `var`. Results and raises as for `get` on
        `def()`."""
        _check["PUT", False, path, R, A, B, _NoSlot]()
        comptime if _admits["PUT", False, path, R, A, B, _NoSlot]():
            self._routes.append(
                _route[A, B, _NoSlot](
                    "PUT",
                    path,
                    _Erased.__init__[call=_call_2[A, B, E, R]](handler),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def put[
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        C: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](mut self, handler: def(var A, var B, var C) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler` for `PUT path` with two route values and then
        the request body (M3-022), where `path` declares exactly two route
        values: two `{name}` segments, two `{key}` query items, or one of each
        (`/users/{uid}/posts/{pid}`, `/users/{id}?{fields}`). Binding is
        positional: the path values left to right, then the query values in the
        literal's order, fill the first two parameters, each decoded and
        converted as for `get`; the body is the third, as for `put` on
        `def(var A)`. An optional value binds a `{key}` item: one at a path
        position is rejected. An invalid value yields 400 before the next value
        or the body is converted; the body's own steps follow; neither calls
        `handler`. Results and raises as for `get` on `def()`."""
        _check["PUT", False, path, R, A, B, C]()
        comptime if _admits["PUT", False, path, R, A, B, C]():
            self._routes.append(
                _route[A, B, C](
                    "PUT",
                    path,
                    _Erased.__init__[call=_call_3[A, B, C, E, R]](handler),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def put[
        S: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self, handler: def(State[S]) thin raises E -> R, state: State[S]
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """The stateful parameterless `put` shape. No such handler is
        accepted today; a registration reports the body rule."""
        _check["PUT", True, path, R, _NoSlot, _NoSlot, _NoSlot]()
        comptime if _admits["PUT", True, path, R, _NoSlot, _NoSlot, _NoSlot]():
            self._routes.append(
                _route[_NoSlot, _NoSlot, _NoSlot](
                    "PUT",
                    path,
                    _Erased.__init__[call=_call_state_0[S, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def put[
        S: Movable & Deinitable,
        A: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var A) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `PUT path`, as `put` on
        `def(var A)` after the state: the request body, or the raw
        `Request` returning `Response`. `handler`'s first parameter is
        `State[S]`, the type of `state`; the route keeps one copy of
        `state`, and each request passes it to `handler` by borrow."""
        _check["PUT", True, path, R, A, _NoSlot, _NoSlot]()
        comptime if _admits["PUT", True, path, R, A, _NoSlot, _NoSlot]():
            self._routes.append(
                _route[A, _NoSlot, _NoSlot](
                    "PUT",
                    path,
                    _Erased.__init__[call=_call_state_1[S, A, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def put[
        S: Movable & Deinitable,
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var A, var B) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `PUT path`, as `put` on
        `def(var A, var B)` after the state: a route value, then the request
        body. The state is passed as for `put` on `def(State[S], var A)`."""
        _check["PUT", True, path, R, A, B, _NoSlot]()
        comptime if _admits["PUT", True, path, R, A, B, _NoSlot]():
            self._routes.append(
                _route[A, B, _NoSlot](
                    "PUT",
                    path,
                    _Erased.__init__[call=_call_state_2[S, A, B, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def put[
        S: Movable & Deinitable,
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        C: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var A, var B, var C) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `PUT path`, as `put` on
        `def(var A, var B, var C)` after the state: two route values, then the
        request body. The state is passed as for `put` on
        `def(State[S], var A)`."""
        _check["PUT", True, path, R, A, B, C]()
        comptime if _admits["PUT", True, path, R, A, B, C]():
            self._routes.append(
                _route[A, B, C](
                    "PUT",
                    path,
                    _Erased.__init__[call=_call_state_3[S, A, B, C, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def patch[
        E: Deinitable, R: Movable & Deinitable, //, path: StaticString
    ](mut self, handler: def() thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """The parameterless `patch` shape. No such handler is accepted
        today (a `patch` handler takes the request body last, or is raw); a
        registration reports that rule."""
        _check["PATCH", False, path, R, _NoSlot, _NoSlot, _NoSlot]()
        comptime if _admits[
            "PATCH", False, path, R, _NoSlot, _NoSlot, _NoSlot
        ]():
            self._routes.append(
                _route[_NoSlot, _NoSlot, _NoSlot](
                    "PATCH", path, _Erased.__init__[call=_call_0[E, R]](handler)
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def patch[
        A: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](mut self, handler: def(var A) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler`, which takes one request parameter, for
        `PATCH path`; `path` declares no path or query parameter.

        The parameter is the request body: an application type conforming
        to `FromBody`, converted with `from_body` before `handler` runs (a
        conversion failure yields 400 without calling `handler`), or a
        `WithHeaders[B2]` carrier with `B2: FromBody`, which has no
        `from_body`: its fields are rebuilt (the fixed 500 on failure) and
        it is built through `_from_parts`, which converts the inner body
        with `B2.from_body` (400 on failure); the handler also receives the
        request's header fields, for which Muntin chooses no status. A
        `Json[T]` body, alone or in a carrier, is first answered 415 unless
        the request has exactly one `application/json` `Content-Type`, then
        413 when it is over 1 MiB. The body may be declared `body: B` or
        `var body: B`, and `B` may be move-only. A `Request` parameter
        instead makes a raw handler, as for `get`. Results and raises are
        handled as for `get` on `def()`; this holds for every body shape,
        stateless or stateful."""
        _check["PATCH", False, path, R, A, _NoSlot, _NoSlot]()
        comptime if _admits["PATCH", False, path, R, A, _NoSlot, _NoSlot]():
            self._routes.append(
                _route[A, _NoSlot, _NoSlot](
                    "PATCH",
                    path,
                    _Erased.__init__[call=_call_1[A, E, R]](handler),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def patch[
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](mut self, handler: def(var A, var B) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler` for `PATCH path` with a route value and then the
        request body, where `path` declares exactly one route value, a `{name}`
        segment (`/users/{id}`) or a `{key}` query item (`/users?{id}`; for an
        optional value, a `{key}` item only). Binding is positional: the route
        value is the first parameter, decoded and converted as for `get`, and
        the body the second, as for `patch` on `def(var A)`; a `String` is
        never the body. An invalid matched path value, or a query value that
        `get` answers 400 for (a missing, duplicated, empty or invalid one; for
        an optional value, a duplicated or invalid one), yields 400 before the
        body is converted (a missing path segment does not match the route:
        404); the body's own steps follow; neither calls `handler`. The route
        value may be borrowed or `var`; an explicitly typed function value
        spells both parameters `var`. Results and raises as for `get` on
        `def()`."""
        _check["PATCH", False, path, R, A, B, _NoSlot]()
        comptime if _admits["PATCH", False, path, R, A, B, _NoSlot]():
            self._routes.append(
                _route[A, B, _NoSlot](
                    "PATCH",
                    path,
                    _Erased.__init__[call=_call_2[A, B, E, R]](handler),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def patch[
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        C: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](mut self, handler: def(var A, var B, var C) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler` for `PATCH path` with two route values and then
        the request body (M3-022), where `path` declares exactly two route
        values: two `{name}` segments, two `{key}` query items, or one of each
        (`/users/{uid}/posts/{pid}`, `/users/{id}?{fields}`). Binding is
        positional: the path values left to right, then the query values in the
        literal's order, fill the first two parameters, each decoded and
        converted as for `get`; the body is the third, as for `patch` on
        `def(var A)`. An optional value binds a `{key}` item: one at a path
        position is rejected. An invalid value yields 400 before the next value
        or the body is converted; the body's own steps follow; neither calls
        `handler`. Results and raises as for `get` on `def()`."""
        _check["PATCH", False, path, R, A, B, C]()
        comptime if _admits["PATCH", False, path, R, A, B, C]():
            self._routes.append(
                _route[A, B, C](
                    "PATCH",
                    path,
                    _Erased.__init__[call=_call_3[A, B, C, E, R]](handler),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def patch[
        S: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self, handler: def(State[S]) thin raises E -> R, state: State[S]
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """The stateful parameterless `patch` shape. No such handler is
        accepted today; a registration reports the body rule."""
        _check["PATCH", True, path, R, _NoSlot, _NoSlot, _NoSlot]()
        comptime if _admits[
            "PATCH", True, path, R, _NoSlot, _NoSlot, _NoSlot
        ]():
            self._routes.append(
                _route[_NoSlot, _NoSlot, _NoSlot](
                    "PATCH",
                    path,
                    _Erased.__init__[call=_call_state_0[S, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def patch[
        S: Movable & Deinitable,
        A: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var A) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `PATCH path`, as `patch` on
        `def(var A)` after the state: the request body, or the raw
        `Request` returning `Response`. `handler`'s first parameter is
        `State[S]`, the type of `state`; the route keeps one copy of
        `state`, and each request passes it to `handler` by borrow."""
        _check["PATCH", True, path, R, A, _NoSlot, _NoSlot]()
        comptime if _admits["PATCH", True, path, R, A, _NoSlot, _NoSlot]():
            self._routes.append(
                _route[A, _NoSlot, _NoSlot](
                    "PATCH",
                    path,
                    _Erased.__init__[call=_call_state_1[S, A, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def patch[
        S: Movable & Deinitable,
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var A, var B) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `PATCH path`, as `patch` on
        `def(var A, var B)` after the state: a route value, then the request
        body. The state is passed as for `patch` on `def(State[S], var A)`."""
        _check["PATCH", True, path, R, A, B, _NoSlot]()
        comptime if _admits["PATCH", True, path, R, A, B, _NoSlot]():
            self._routes.append(
                _route[A, B, _NoSlot](
                    "PATCH",
                    path,
                    _Erased.__init__[call=_call_state_2[S, A, B, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def patch[
        S: Movable & Deinitable,
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        C: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var A, var B, var C) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `PATCH path`, as `patch` on
        `def(var A, var B, var C)` after the state: two route values, then the
        request body. The state is passed as for `patch` on
        `def(State[S], var A)`."""
        _check["PATCH", True, path, R, A, B, C]()
        comptime if _admits["PATCH", True, path, R, A, B, C]():
            self._routes.append(
                _route[A, B, C](
                    "PATCH",
                    path,
                    _Erased.__init__[call=_call_state_3[S, A, B, C, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def delete[
        E: Deinitable, R: Movable & Deinitable, //, path: StaticString
    ](mut self, handler: def() thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler`, which takes no parameter, for `DELETE path`;
        `path` declares no path or query parameter.

        A `String` or `StaticString` result becomes a 200 text response; a
        result conforming to `ToResponse` (an application type, or
        `Response`) converts itself with `to_response()` after `handler`
        returns. `handler` may be non-raising or declare `raises` or
        `raises T`. A raise skips the result conversion and is answered by
        the error's `to_error_response()` if the declared error type `E`
        conforms to `ToErrorResponse`; anything else it raises becomes a
        fixed 500 `Internal Server Error` (the error's text is never sent).
        """
        _check["DELETE", False, path, R, _NoSlot, _NoSlot, _NoSlot]()
        comptime if _admits[
            "DELETE", False, path, R, _NoSlot, _NoSlot, _NoSlot
        ]():
            self._routes.append(
                _route[_NoSlot, _NoSlot, _NoSlot](
                    "DELETE",
                    path,
                    _Erased.__init__[call=_call_0[E, R]](handler),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def delete[
        A: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](mut self, handler: def(var A) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler`, which takes one request parameter, for
        `DELETE path`.

        An `Int` or `String` parameter is a route value: `path` declares
        exactly one parameter, a `{name}` segment (`/users/{id}`) or a `{key}`
        query item (`/items?{limit}`), whose value is percent-decoded once (`+`
        is a space in a query value only), then converted to `Int` or passed as
        the decoded `String`, by position (names are not checked against the
        handler); a missing, duplicated or empty value, a bad escape, text that
        is not UTF-8, or, for an `Int`, a non-integer yields 400 without
        calling `handler`. An `Optional[Int]` or `Optional[String]` parameter
        is an optional route value (M3-025): `path` declares exactly one
        `{key}` query item and no path parameter, and an absent key, an empty
        value or a pair without `=` gives `None`; a present value follows the
        rules above, so a duplicated key is still 400. A `Headers` parameter
        receives the request's header fields (`path` declares no parameter): a
        fresh `Headers` with every field in order, rebuilt from the request's;
        Muntin chooses no status for a field, and only a field held invalidly
        in memory (the M3-002 `_fields` gap) is answered before `handler`, with
        the fixed 500. A `Request` parameter makes a raw handler, which returns
        `Response`: `path` declares no parameter, the handler receives the
        whole request (method, path, query, body and header fields as
        received), Muntin runs no typed extraction, so it answers no 400 before
        `handler`, and the `Response` is the answer. The parameter may be
        borrowed or `var`; an explicitly typed function value spells it `var`
        (`def(var Int) thin raises Never -> String`). Results and raises are
        handled as for `delete` on `def()`."""
        _check["DELETE", False, path, R, A, _NoSlot, _NoSlot]()
        comptime if _admits["DELETE", False, path, R, A, _NoSlot, _NoSlot]():
            self._routes.append(
                _route[A, _NoSlot, _NoSlot](
                    "DELETE",
                    path,
                    _Erased.__init__[call=_call_1[A, E, R]](handler),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def delete[
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](mut self, handler: def(var A, var B) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler` for `DELETE path` with a route value and then
        the request's `Headers`, where `path` declares exactly one route value,
        as for `delete` on `def(var A)`; or with two route values (M3-022),
        where `path` declares exactly two: two `{name}` segments, two `{key}`
        query items, or one of each (`/users/{uid}/posts/{pid}`,
        `/users/{id}?{fields}`). Binding is positional: the path values left to
        right, then the query values in the literal's order, fill the
        parameters in order; names are never compared, so two values of one
        type declared in the other order receive each other's values. An
        optional value binds a `{key}` item: one at a path position is
        rejected. The values are converted first, in order, so an invalid one
        is 400 before the next one or the fields are converted. Every other
        two-parameter shape is rejected (a `delete` handler takes no request
        body and one `Headers`, last); a registration reports the rule it
        breaks."""
        _check["DELETE", False, path, R, A, B, _NoSlot]()
        comptime if _admits["DELETE", False, path, R, A, B, _NoSlot]():
            self._routes.append(
                _route[A, B, _NoSlot](
                    "DELETE",
                    path,
                    _Erased.__init__[call=_call_2[A, B, E, R]](handler),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def delete[
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        C: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](mut self, handler: def(var A, var B, var C) thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers `handler` for `DELETE path` with two route values and then
        the request's `Headers` (M3-022), where `path` declares exactly two
        route values, as for `delete` on `def(var A, var B)`. Both values are
        converted first, in order, so an invalid one is 400 before the fields
        are rebuilt. Every other three-parameter shape is rejected (a `delete`
        handler takes at most two route values, no request body, and one
        `Headers`, last); a registration reports the rule it breaks."""
        _check["DELETE", False, path, R, A, B, C]()
        comptime if _admits["DELETE", False, path, R, A, B, C]():
            self._routes.append(
                _route[A, B, C](
                    "DELETE",
                    path,
                    _Erased.__init__[call=_call_3[A, B, C, E, R]](handler),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def delete[
        S: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self, handler: def(State[S]) thin raises E -> R, state: State[S]
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `DELETE path`, as `delete` on
        `def()`. `handler`'s one parameter is `State[S]`, the type of
        `state`; the route keeps one copy of `state`, and each request
        passes it to `handler` by borrow."""
        _check["DELETE", True, path, R, _NoSlot, _NoSlot, _NoSlot]()
        comptime if _admits[
            "DELETE", True, path, R, _NoSlot, _NoSlot, _NoSlot
        ]():
            self._routes.append(
                _route[_NoSlot, _NoSlot, _NoSlot](
                    "DELETE",
                    path,
                    _Erased.__init__[call=_call_state_0[S, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def delete[
        S: Movable & Deinitable,
        A: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var A) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `DELETE path`, as `delete` on
        `def(var A)` after the state: a route value, the request's `Headers`,
        or the raw `Request` returning `Response`. The state is passed as for
        `delete` on `def(State[S])`; a leading `State[S]` keeps its spelling in
        a typed function value."""
        _check["DELETE", True, path, R, A, _NoSlot, _NoSlot]()
        comptime if _admits["DELETE", True, path, R, A, _NoSlot, _NoSlot]():
            self._routes.append(
                _route[A, _NoSlot, _NoSlot](
                    "DELETE",
                    path,
                    _Erased.__init__[call=_call_state_1[S, A, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def delete[
        S: Movable & Deinitable,
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var A, var B) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `DELETE path`, as `delete` on
        `def(var A, var B)` after the state: a route value, then the request's
        `Headers`, or two route values. The state is passed as for `delete` on
        `def(State[S])`."""
        _check["DELETE", True, path, R, A, B, _NoSlot]()
        comptime if _admits["DELETE", True, path, R, A, B, _NoSlot]():
            self._routes.append(
                _route[A, B, _NoSlot](
                    "DELETE",
                    path,
                    _Erased.__init__[call=_call_state_2[S, A, B, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def delete[
        S: Movable & Deinitable,
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        C: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var A, var B, var C) thin raises E -> R,
        state: State[S],
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers the stateful `handler` for `DELETE path`, as `delete` on
        `def(var A, var B, var C)` after the state: two route values, then the
        request's `Headers`. The state is passed as for `delete` on
        `def(State[S])`."""
        _check["DELETE", True, path, R, A, B, C]()
        comptime if _admits["DELETE", True, path, R, A, B, C]():
            self._routes.append(
                _route[A, B, C](
                    "DELETE",
                    path,
                    _Erased.__init__[call=_call_state_3[S, A, B, C, E, R]](
                        _Bound(handler, state)
                    ),
                )
            )
        else:
            abort(_GUARD_DRIFT)

    def handle(self, request: Request) -> Response:
        """Dispatches `request` through the application's routes.

        This is the backend seam: every transport (the in-memory TestClient,
        network adapters) delivers requests through this method. The first
        registered route whose method and path match handles the request,
        raw or typed; the query takes no part in selecting it. Methods match
        byte for byte, except that a `HEAD` request also matches a `GET`
        route and runs the `GET` route's steps: a typed handler receives the
        same arguments as for the `GET`, a raw handler the `HEAD` request
        itself. The answer keeps its body; keeping the content off the wire
        is the backend's (M3-026). A raw route
        receives `request.method`, `path`, `query` and `body`, then each
        header field's name and value, as its raw arguments, and nothing else
        runs (no query gathering, no conversion); the adapter's `Request`
        slot rebuilds the `Request` (`_raw_request`). A typed
        route receives no headers unless its body is a `WithHeaders[B]`
        carrier or its last slot is `Headers` (`_Route.headers`). A body
        route receives
        `request.body` as its last raw argument, after its route values if
        it has any; its adapter's body slot (`_slot`) converts it and answers
        400 itself if that fails. A JSON body route (`_Route.json`) also
        receives the request's `Content-Type` verdict after the body, for
        the body slot's 415 step. A carrier route then
        receives each header field's name and value, in order, after the
        body and any verdict; a `Headers` route, after its route values if
        it has any.

        A typed route's route values are percent-decoded once here, after
        matching on the raw path and before any conversion (`_decode_value`):
        the path captures in place, left to right, then each query value
        after `_query_value` finds it, in the literal's order (M3-022). For
        a key whose value binds an `Optional` slot (`_Route.query_optional`,
        M3-025), an absent key or an empty value is passed on as `""`
        instead. Query keys, `request.path`, `request.query` and raw routes
        are never decoded.

        No matching route is 404. A duplicated query key, a missing or empty
        required value, a bad escape or decoded text that is not UTF-8 is 400
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
            # `HEAD` also matches `GET` routes (M3-026).
            var method_matches = route.method == request.method or (
                request.method == "HEAD" and route.method == "GET"
            )
            if not method_matches or not _match(route.path, request.path, args):
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
                # The route values, decoded once here at capture (M3-018):
                # the path captures in place, then each query value as
                # gathered, in the literal's order (M3-022). An optional
                # value's absent key or empty value is passed on as `""`,
                # which no decoded value is (M3-025).
                try:
                    for j in range(len(args)):
                        args[j] = _decode_value(args[j], query=False)
                    for k in range(len(route.query_keys)):
                        var raw = _query_value(
                            request.query, route.query_keys[k]
                        )
                        if route.query_optional[k] and (
                            not raw or raw.value().byte_length() == 0
                        ):
                            args.append("")
                        elif not raw:
                            raise Error("missing query key")
                        else:
                            args.append(_decode_value(raw.value(), query=True))
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
