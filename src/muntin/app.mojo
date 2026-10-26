"""Muntin application: route registration and request dispatch."""

from std.collections import Dict
from std.os import abort
from std.sys import is_defined
from std.reflection import reflect

from ._handler_storage import _Erased
from ._handler_storage import _build_record
from ._rebind import _as
from ._registration_rules import (
    _BODY,
    _HEADERS,
    _NoSlot,
    _OTHER,
    _RAW,
    _STATE,
    _admits,
    _check,
    _is_optional,
    _is_value,
    _is_param,
    _kind,
    _param_name,
    _path_params,
    _path_part,
    _query_items,
)
from .body import FromBody, FromBytes, _BodyFault, _NOT_UTF8, _body_text
from .headers_body import _HeaderCarrier, _convert_body
from .http import (
    Failure,
    Headers,
    Rejection,
    Request,
    Response,
    ToErrorResponse,
    ToResponse,
    _failed,
    _rejected_by,
)
from ._openapi import _merge, _operation
from .json import (
    JsonValue,
    JsonWriter,
    _JsonBody,
    _MAX_BODY_BYTES,
    _OBJECT,
    _json_content_type,
    _parse_json,
)
from .route_value import FromRouteValue, RouteValues, _NamedValue
from .state import State, _may_borrow

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
# below), a route-value record (`RouteValues`, M3-061: one slot carrying
# every route value, so a slot reads as many route values as its `_width`),
# a body (`FromBody`, `FromBytes` or a `WithHeaders` carrier, below), the
# raw `Request`, the request `Headers` (below), a misplaced `State`, or
# none.
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
# slot's raw argument index is the sum of the widths of the slots before it
# (`_width`: a bare value 1, a `RouteValues` record its field count, anything
# else 0), because the route values come first, before the body or the
# `Headers` slot.
# `comptime if A == Int` does not refine `A` on Mojo 1.1.0, so a parsed
# `Int`, a `String` route value, a rebuilt `Request` or `Headers` and a text
# result reach their generic type through the rebind helper `_as`
# (`_rebind.mojo`), which asserts type equality first (the rebind alone
# accepts a different type of the same layout; its pin is named there), and
# the confinement step of `scripts/check.sh` fails on any other rebind.
# The handler and its adapter are stored together in an `_Erased` box
# (`_handler_storage.mojo`), so dispatch is one call whatever the shape.
# Where a route value comes from (path segment or query key) is route data,
# not part of the shape. The request body never travels in the raw argument
# strings: `invoke` passes the request's body bytes beside them, borrowed
# (M3-040), and only a body slot or a raw `Request` slot reads them.
#
# Raw handlers (M2-014): `Request` is a slot kind, so a raw handler selects the
# arity-1 overload (after `State[S]` in the stateful family) like any one-slot
# handler, and its rule requires `Response` as the result and no placeholder. A
# raw route (`_Route.raw`) gets the request's method, path and query as its
# first three raw arguments, then each header field's name and value (M3-002,
# R1), and nothing else runs; `_raw_request` rebuilds the `Request` from them
# and a copy of the body bytes (M3-040), and the adapter moves it into the
# handler. A typed route gets header
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
# decided in `App.handle`, which appends a verdict at the body's position for
# a JSON route only (`"1"` when the request has exactly one `application/json`
# field, else empty; other routes' arguments are unchanged). The body slot, for
# a JSON body only, answers 415 unless the arguments end with the verdict `"1"`
# at the expected position (an exact arity check), then 413 when the body is
# over 1 MiB, after the route value and before `from_body`. Every text body
# slot then reads the body bytes as UTF-8 (`_body_text`, M3-040): bytes that are not
# are 400, as a `from_body` raise is. Order on a JSON body route: 404 or 405,
# query or capture 400 (`App.handle`), `Int` 400, 415, 413, UTF-8 400, JSON 400
# (`from_body`), handler.
#
# Header carriers (M3-012): `WithHeaders[B]` (`headers_body.mojo`) is a body
# slot without being a `FromBody` or a `FromBytes`: `_kind` accepts those or
# the private marker `_HeaderCarrier`, and the route sets `_Route.headers` for
# a carrier.
# For such a route, `App.handle` appends each request header field's name
# and value after the route values and the JSON verdict (the R1 transport raw
# routes use). The body slot then rebuilds the fields into a `Headers`
# (`_carrier_fields`; a failure, which only the M3-002 `_fields` gap can cause,
# is the fixed 500) and builds the carrier with `B._from_parts` from the
# borrowed body bytes, which converts them as a bare body of the inner type
# (M3-042): a `FromBody` reads them as UTF-8 (400 if they are not) and calls
# `from_body`, a `FromBytes` calls `from_bytes` on them unread and uncopied;
# a raise is 400. The carrier forwards
# `_JsonBody` exactly when its body does, so a `WithHeaders[Json[T]]` route
# keeps the order above; its arity check allows only name and value pairs after
# the verdict, and every other JSON body keeps the exact arity. Muntin chooses
# no status for the fields the handler reads and gives them no meaning; the
# `Content-Type` verdict for a `Json[T]` body (415), a bytes body's limit
# (413, M3-043, before the rebuild) and the rebuild failure (500) still
# answer before the handler.
#
# Bytes bodies (M3-041): a `FromBytes` type is a body slot too (`_kind`), on
# every shape that takes a `FromBody`, and `_slot` passes it the request's
# body bytes, borrowed from `invoke`, with no UTF-8 read and no copy; a raise
# is 400. It is never a JSON body, so `App.handle` appends nothing for it
# unless it is inside a carrier (M3-042), which receives the fields as any
# carrier does and no `Content-Type` verdict. A type that conforms to both
# `FromBody` and `FromBytes` is rejected by the rules, alone or in a carrier,
# so a body always has exactly one conversion.
#
# Bytes body limits (M3-043): every `FromBytes` type declares
# `comptime max_bytes` or inherits a refining trait's default; `_slot` answers a longer body 413 before
# `from_bytes`, after the route values, and in a carrier (through
# `_HeaderCarrier._max_bytes`) after the JSON steps and before the field
# rebuild. The length is the body `invoke` passes, after middleware; a
# negative limit is rejected at registration (`_kind`).
#
# Header slots (M3-016): on `get`, `delete` and bodyless handlers, `Headers`
# is a slot kind by exact type equality (no trait, so no application type is
# one), accepted
# once, as the last slot, after at most two route values. The route sets
# `_Route.headers`, so `App.handle` appends each field's name and value after
# the route values, and the slot rebuilds them into a fresh `Headers`
# (`_header_slot`; a failure, again only the `_fields` gap, is the fixed 500)
# that the handler owns or borrows. On `post`, `put` and `patch` a handler
# with a body takes no `Headers` slot: its fields come through the carrier,
# and `_post_rule` reports a `Headers` before the body as a type of no kind.
# A bodyless handler there (only route values and a `Headers` last) takes
# `get`'s shapes and rules (M3-048) and is dispatched as on `get`: no slot
# reads the body.
#
# Route values (M3-018): a route value is an `Int` or a `String` (`_TEXT`, by
# exact type equality) or an `Optional` of either (below), or an application
# type conforming to `FromRouteValue` (M3-055), at most two per handler
# (M3-022), never the body. They
# bind by position: the path captures left to right, then the query values
# in the literal's order; names are never compared with the handler's
# parameters. `App.handle` decodes each raw
# capture once (`_decode_value`), after matching on the raw path, before any
# conversion: path captures in place, then each query value as `_query_value`
# finds it; an empty value, a bad escape or decoded bytes that are not UTF-8
# are 400 there. The `String` slot takes the decoded text, the `Int` slot
# parses it and a `FromRouteValue` slot passes it to `from_route_value`.
# Query keys, `Request.path`, `Request.query` and raw routes stay undecoded.
#
# Optional values (M3-024): an `Optional[Int]` or `Optional[String]` slot is
# an optional route value, by exact type equality; it binds a query
# placeholder only (a path segment is never absent). `_route` marks the query
# keys whose values bind one (`_Route.query_optional`); for such a key,
# `App.handle` passes an absent key or an empty value on as `""`, which no
# decoded value is, and the slot gives `None` for it. A present value is
# decoded and converted as a required one, a repeated key is 400 for both.

# Guarded groups (M3-080): `App` and `Group` are one generic
# `_App[GS, GE, Ctx]`. `App` is the instantiation with no guard
# (`_NoContext`); a `Group` holds a guard `def(State[GS], Headers) raises GE
# -> Ctx` and one copy of its state until `mount` moves its routes into an
# `App`. The routes, their index, the middleware and the dispatch live in
# the non-generic `_Core`, which `Next` points to. Every registration
# overload serves both: its guarded branch, one `_guarded_*` helper per
# arity and family, sets a leading `Ctx` slot aside, applies the rules to
# the slots after it, and boxes the handler (or its `_Bound`) with the guard
# and a copy of the guard's state as one `_Guarded`, so the value the guard
# returns and the handler's parameter share one type statically and never
# cross an erasure. `Ctx` passes `State`'s name filter (`_may_borrow`,
# M3-074) and is no slot kind, so no overload is added for it. For a
# guarded route, `_dispatch` appends every header field and then a verdict
# (`"1"`, or `"0"` when gathering or decoding the route values failed, with
# the arguments replaced by the `Rejection`'s step, name and message, M3-084)
# after the arguments an unguarded route of the same slots receives. The
# guarded adapter's `_run_guard` rebuilds the fields, calls the guard (a
# raise is `_handler_error`, a fault in the rebuild the fixed 500), then
# answers a deferred 400, and passes on only the arguments
# the unguarded adapter would read; `_ctx_first` moves the guard's value
# into a first slot of type `Ctx`, or drops it and converts that slot as
# usual. Order on a guarded route: 404 or 405, route-value decoding, guard,
# a deferred 400, the conversions in the order above, handler.


def _match(route: String, path: String, mut args: List[String]) -> Bool:
    """Matches `path` against `route` segment by segment.

    Static segments must be equal; a `{name}` segment matches one non-empty
    segment, which is appended to `args` (cleared first), left to right. A
    typed route holds as many placeholders as its handler's route values
    and a raw route none (enforced at registration).
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


def _allowed(routes: List[_Route], path: String) -> List[String]:
    """The methods of the routes whose path `_match`es `path`, each once, in
    the order their first such route was registered, with `HEAD` right after
    `GET` (M3-030): `App.handle`'s `Allow` when it selects no route. Empty
    when no route matches the path. Nothing is decoded or converted."""
    var methods = List[String]()
    var scratch = List[String]()
    for i in range(len(routes)):
        ref route = routes[i]
        if route.method in methods or not _match(route.path, path, scratch):
            continue
        methods.append(route.method)
        if route.method == "GET":
            methods.append("HEAD")
    return methods^


def _segments(path: String) -> List[String]:
    """`path` split at `/`, as `_match` splits it."""
    var segments = List[String]()
    for segment in path.split("/"):
        segments.append(String(segment))
    return segments^


def _covers_segments(general: List[String], specific: List[String]) -> Bool:
    """`_covers` on split paths."""
    if len(general) != len(specific):
        return False
    for i in range(len(general)):
        if _is_param(general[i]):
            if specific[i].byte_length() == 0:
                return False
        elif _is_param(specific[i]) or general[i] != specific[i]:
            return False
    return True


def _overlaps_segments(a: List[String], b: List[String]) -> Bool:
    """`_overlaps` on split paths."""
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        var pa = _is_param(a[i])
        var pb = _is_param(b[i])
        if pa and pb:
            continue
        if pa or pb:
            if a[i].byte_length() == 0 or b[i].byte_length() == 0:
                return False
        elif a[i] != b[i]:
            return False
    return True


def _covers(general: String, specific: String) -> Bool:
    """Whether route path `general` matches every request path `specific`
    matches (M3-053): the same number of segments, and at each position the
    same static text in both, or a placeholder in `general` and a placeholder
    or a non-empty static segment in `specific` (a placeholder matches no
    empty segment, `_match`). Placeholder names are not compared."""
    return _covers_segments(_segments(general), _segments(specific))


def _overlaps(a: String, b: String) -> Bool:
    """Whether some request path matches both route paths `a` and `b`
    (M3-053): the same number of segments, and at each position the same
    static text in both, or a placeholder in one and a placeholder or a
    non-empty static segment in the other."""
    return _overlaps_segments(_segments(a), _segments(b))


def _refusal(
    method: String,
    path: String,
    earlier: String,
    new_covers: Bool,
    earlier_covers: Bool,
) -> String:
    """The abort message for a route `path` that overlaps the earlier route
    `earlier` of the same method, which is not more specific (M3-053)."""
    var new = method + " " + path
    var old = method + " " + earlier
    if new_covers:
        return (
            "route conflict: "
            + new
            + " matches the same requests as "
            + old
            + ", registered earlier (the query takes no part in selection)"
        )
    if earlier_covers:
        return (
            "route conflict: "
            + new
            + " is registered after "
            + old
            + ", which matches every request it matches; register "
            + new
            + " first"
        )
    return (
        "route conflict: "
        + new
        + " and "
        + old
        + ", registered earlier, both match some requests and neither"
        " is more specific"
    )


struct _Pattern(Copyable, Movable):
    """A registered route path with a placeholder, split once (M3-053)."""

    var index: Int
    """The route's position in `App._routes`."""
    var method: String
    var path: String
    var segments: List[String]

    def __init__(
        out self,
        index: Int,
        method: String,
        path: String,
        var segments: List[String],
    ):
        self.index = index
        self.method = method
        self.path = path
        self.segments = segments^


struct _RouteIndex(Movable):
    """What `App._add` needs to refuse route conflicts (M3-053) without
    comparing a new route with every earlier one.

    Two routes without a placeholder overlap only when their paths are
    equal, and one without a placeholder that overlaps a later route with
    one is always the more specific of the two. So a new route conflicts
    with an earlier route without a placeholder only when its shape (its
    path with every placeholder written `{}`) is the same (`shapes`), and is
    compared one by one only with the earlier routes that have a placeholder
    (`patterns`), of any method. Each registration then costs one lookup
    plus one comparison per earlier route with a placeholder."""

    var methods: List[String]
    """Each registered route's method, in registration order."""
    var paths: List[String]
    """Each registered route's path, in registration order."""
    var shapes: Dict[String, Int]
    """Method, a space and shape, to the first such route's index."""
    var patterns: List[_Pattern]
    """The routes with a placeholder, in registration order."""

    def __init__(out self):
        self.methods = List[String]()
        self.paths = List[String]()
        self.shapes = Dict[String, Int]()
        self.patterns = List[_Pattern]()

    def refusal(self, method: String, path: String) -> String:
        """Why a route for `method` and `path` cannot be registered after
        the recorded ones, or empty if it can: `_conflict`'s answer."""
        var segments = _segments(path)
        var first = -1
        var same = self.shapes.get(method + " " + _shape(segments))
        if same:
            first = same.value()
        for j in range(len(self.patterns)):
            ref earlier = self.patterns[j]
            if first >= 0 and earlier.index > first:
                break
            if earlier.method != method or not _overlaps_segments(
                earlier.segments, segments
            ):
                continue
            if _covers_segments(segments, earlier.segments) and not (
                _covers_segments(earlier.segments, segments)
            ):
                continue
            first = earlier.index
            break
        if first < 0:
            return String()
        ref earlier = self.paths[first]
        var earlier_segments = _segments(earlier)
        return _refusal(
            method,
            path,
            earlier,
            _covers_segments(segments, earlier_segments),
            _covers_segments(earlier_segments, segments),
        )

    def add(mut self, method: String, path: String):
        """Records the next route, which `refusal` accepted."""
        var index = len(self.paths)
        self.methods.append(method)
        self.paths.append(path)
        var segments = _segments(path)
        var key = method + " " + _shape(segments)
        if key not in self.shapes:
            self.shapes[key] = index
        var has_param = False
        for segment in segments:
            if _is_param(segment):
                has_param = True
        if has_param:
            self.patterns.append(_Pattern(index, method, path, segments^))


def _shape(segments: List[String]) -> String:
    """A split route path with every placeholder written `{}`: two paths
    match the same requests exactly when their shapes are equal."""
    var shape = String()
    for i in range(len(segments)):
        if i > 0:
            shape += "/"
        shape += "{}" if _is_param(segments[i]) else segments[i]
    return shape^


def _conflict(
    methods: List[String], paths: List[String], method: String, path: String
) -> String:
    """Why a route for `method` and `path` cannot be registered after the
    routes of `methods` and `paths`, or empty if it can (M3-053). It can when every earlier route of
    the same method whose path overlaps `path` is more specific than it, so
    the first match `App.handle` selects is always the most specific one.
    The query takes no part, as in selection. The message names the first
    earlier route that conflicts. `App._add` gets the same answer from its
    `_RouteIndex`; this scan of every earlier route is its reference
    (`tests/test_route_conflicts.mojo`)."""
    for i in range(len(paths)):
        if methods[i] != method or not _overlaps(paths[i], path):
            continue
        var new_covers = _covers(path, paths[i])
        var earlier_covers = _covers(paths[i], path)
        if new_covers and not earlier_covers:
            continue
        return _refusal(method, path, paths[i], new_covers, earlier_covers)
    return String()


comptime _NOT_AN_INTEGER = "not an integer"
comptime _OUT_OF_RANGE = "out of Int range"


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
        raise Error(_NOT_AN_INTEGER)
    for i in range(start, len(b)):
        if Int(b[i]) < ord("0") or Int(b[i]) > ord("9"):
            raise Error(_NOT_AN_INTEGER)
    try:
        return Int(segment)
    except:
        # `Int`'s own message quotes the text, which the client sent.
        raise Error(_OUT_OF_RANGE)


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


comptime _LINEAR_QUERY_KEYS = 8
"""Up to this many query keys, `_query_spans` compares each pair's key with
every key; above it, it looks the key up in the route's `query_index`, so a
pair costs one lookup however many keys a route has."""


def _query_index(keys: List[String]) -> Dict[String, Int]:
    """Each of `keys` with its position, the index `_query_spans` looks keys
    up in; empty for `_LINEAR_QUERY_KEYS` keys or fewer, which it compares
    instead, so a route with few keys keeps no index."""
    var index = Dict[String, Int]()
    if len(keys) > _LINEAR_QUERY_KEYS:
        for k in range(len(keys)):
            index[keys[k]] = k
    return index^


def _query_spans(
    query: String, keys: List[String], index: Dict[String, Int]
) raises -> List[Int]:
    """`_query_spans_at` without the repeated key's position."""
    var repeated = -1
    return _query_spans_at(query, keys, index, repeated)


def _query_spans_at(
    query: String,
    keys: List[String],
    index: Dict[String, Int],
    mut repeated: Int,
) raises -> List[Int]:
    """Where the value of each of `keys` (distinct) lies in a raw query
    string, read as `_query_value` reads one, in one pass over the query and
    without copying any value: entries `2k` and `2k + 1` are the byte offsets
    where key `k`'s value starts and ends, both -1 when the key is absent
    (a pair without `=` has an empty value). `index` maps each key to its
    position (`_query_index`), consulted only for more than
    `_LINEAR_QUERY_KEYS` keys. Raises if
    one of `keys` appears more than once, with its position in `repeated`
    (M3-084), found in the same pass; other keys may repeat."""
    var spans = List[Int](length=2 * len(keys), fill=-1)
    if len(keys) == 0:
        return spans^
    var linear = len(keys) <= _LINEAR_QUERY_KEYS
    var start = 0
    for pair in query.split("&"):
        var eq = pair.find("=")
        var name = pair[byte=:eq] if eq >= 0 else pair[byte=:]
        var at = -1
        if linear:
            for k in range(len(keys)):
                if keys[k] == name:
                    at = k
                    break
        else:
            var found = index.get(String(name))
            if found:
                at = found.value()
        var end = start + pair.byte_length()
        if at >= 0:
            if spans[2 * at] >= 0:
                repeated = at
                raise Error("duplicate query key")
            spans[2 * at] = start + eq + 1 if eq >= 0 else end
            spans[2 * at + 1] = end
        start = end + 1
    return spans^


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
        raise Error("empty")
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
    try:
        return String(from_utf8=Span(out))
    except:
        raise Error(_NOT_UTF8)


comptime _MISSING = "missing"
comptime _REPEATED = "repeated"


def _bad_request() -> Response:
    return Response.text("Bad Request", status=400)


def _unsupported_media_type() -> Response:
    """A JSON body route's answer to a request whose `Content-Type` is not
    exactly one `application/json` field (M3-009)."""
    return Response.text("Unsupported Media Type", status=415)


def _content_too_large() -> Response:
    """A JSON body route's answer to a body over 1 MiB (M3-009), and a
    `FromBytes` body route's to a body over its type's `max_bytes`, bare or
    carried (M3-043)."""
    return Response.text("Content Too Large", status=413)


def _internal_error() -> Response:
    """The fixed 500 without a report. `src/muntin` answers with `_failed`,
    which carries one (M3-058); this stays for the spikes under `tests/`
    that import it."""
    return Response.text("Internal Server Error", status=500)


comptime _REBUILD_FAILED = "the request's header fields could not be rebuilt"
"""The report of a `_Reject(500)`: `_slot` drops the rebuild's error, which
only the M3-002 `_fields` gap raises."""


def _error_text[E: AnyType](e: E) -> String:
    """A `Failure`'s message for a caught `e` (M3-058): its text when `E` is
    `Writable` (`Error` included), else `<`, `E`'s module-qualified name and
    `>`."""
    comptime if conforms_to(E, Writable):
        return String(e)
    else:
        return "<" + reflect[E].name() + ">"


def _handler_error[E: Deinitable](var e: E) -> Response:
    """What a handler error of type `E` becomes.

    `E` is the handler's declared error type: `Never` for a non-raising
    handler, `Error` for `raises`, the application's type for `raises T`.
    If `E` conforms to `ToErrorResponse`, the error converts itself, once,
    by move. Otherwise the answer is the fixed 500 carrying a
    `Failure.HANDLER` report of its text or type name (`_error_text`,
    M3-058), and the value is dropped: an `Error`'s message may carry
    internal details and never reaches the client, and `ToResponse` alone
    does not convert a raised value (a returned value of that type
    converts; a raised one does not). Resolved at compile time per
    instantiation, so no error type must conform to anything.
    """
    comptime if conforms_to(E, ToErrorResponse):
        return e^.to_error_response()
    else:
        return _failed(Failure.HANDLER, _error_text(e))


comptime _GUARD_DRIFT = "registration rule check and guard disagree"
"""The guard's `else`: `_admits` rejected a shape `_check` accepted."""


def _json_status[
    B: AnyType
](args: List[String], body_at: Int, body_length: Int) -> Int:
    """For a JSON body (`_JsonBody`): 0 when the body may be converted,
    else the status to answer, 415 or 413, without parsing.

    The `Content-Type` verdict is at the body's position (`args[body_at]`;
    the body itself travels as bytes, M3-040) and must be `"1"`. For any
    other JSON body the arguments end there (an exact arity check); a
    carrier route (`_HeaderCarrier`) allows only header name and value pairs
    after it, an even count. Then a body over 1 MiB (`body_length` bytes) is
    413."""
    var verdict = body_at
    if len(args) <= verdict or args[verdict] != "1":
        return 415
    comptime if conforms_to(B, _HeaderCarrier):
        if (len(args) - verdict - 1) % 2 != 0:
            return 415
    else:
        if len(args) != verdict + 1:
            return 415
    if body_length > _MAX_BODY_BYTES:
        return 413
    return 0


def _body_rejection_answer(status: Int) -> Response:
    """The response for a body slot's 415 or 413 before conversion: a
    nonzero `_json_status`, or a `FromBytes` body over its `max_bytes`
    (M3-043). Named for the body, not JSON, since both use it."""
    if status == 415:
        return _unsupported_media_type()
    return _content_too_large()


def _carrier_fields[
    B: AnyType
](args: List[String], body_at: Int) raises -> Headers:
    """Rebuilds a carrier route's header fields from the name and value
    pairs from the body's position on (after the verdict, for a JSON body),
    in order. `Headers.add` validates each field again: fields that came
    from a `Headers` pass, so only the M3-002 `_fields` gap can make this
    raise, and the adapters answer that with the fixed 500, never 400."""
    var i = body_at
    comptime if conforms_to(B, _JsonBody):
        i += 1
    var headers = Headers()
    while i + 1 < len(args):
        headers.add(args[i], args[i + 1])
        i += 2
    return headers^


def _raw_request(args: List[String], body: List[UInt8]) raises -> Request:
    """Rebuilds a raw route's `Request` from its method, path and query
    (`args[0]` to `args[2]`), its header fields (name and value pairs from
    `args[3]` on, in order) and a copy of the request's body bytes, which
    no step reads or converts (M3-040).

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
    var i = 3
    while i + 1 < len(args):
        headers.add(args[i], args[i + 1])
        i += 2
    return Request(args[0], target, body.copy(), headers^)


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


struct _Reject(Movable):
    """A request-side failure: the status answered before the handler runs
    (400, 413, 415, or 500 for a rebuild failure) and, for a 400, its
    `Rejection` step, the route value's position (`at`, -1 for the body) and
    message (M3-084)."""

    var status: Int
    var step: String
    var at: Int
    var message: String

    def __init__(
        out self,
        status: Int,
        step: String = "",
        at: Int = -1,
        message: String = "",
    ):
        self.status = status
        self.step = step
        self.at = at
        self.message = message


def _rejected(r: _Reject) -> Response:
    """The response for a `_Reject`: a 400 carries its `Rejection`, named by
    `App.handle` from `at` (M3-084); a 500 a `Failure.MUNTIN` report naming
    the rebuild (M3-058)."""
    if r.status == 400:
        return _rejected_by(r.step, "", r.message, r.at)
    if r.status == 500:
        return _failed(Failure.MUNTIN, _REBUILD_FAILED)
    return _body_rejection_answer(r.status)


def _slot[
    A: Movable & Deinitable, at: Int
](args: List[String], body: List[UInt8]) raises _Reject -> A:
    """Converts the request slot of type `A` whose raw argument is
    `args[at]`, already decoded if it is a route value (`App.handle`); a
    body slot reads `body`, the request's bytes, instead (M3-040). An
    `Int` route value is parsed (`_parse_int`; 400 if invalid); a `String`
    route value is a copy of the decoded text. An `Optional[Int]` or
    `Optional[String]` is `None` for `""`, which `App.handle` passes for an
    absent or empty optional value (M3-025), and otherwise converts as the
    required slot of its type. A `FromRouteValue` value (M3-055) is
    `A.from_route_value` of the decoded text (400 if it raises). A raw
    `Request` is rebuilt
    from all the arguments and the body bytes (`_raw_request`; a failure is
    the fixed 500). A `Headers` slot is rebuilt from the field pairs from
    `args[at]` on (`_header_slot`; a failure is the fixed 500). A
    `FromBody` body is read as UTF-8 (`_body_text`; 400 if it is not) and converted with
    `A.from_body` (400 if it raises); for a JSON body (`_JsonBody`) the 415
    and 413 steps run first (`_json_status`); a `WithHeaders` carrier has
    its header fields rebuilt (the fixed 500 on failure), then is built
    through `A._from_parts` from the borrowed bytes, which converts them as
    a bare body of the carried type (M3-042: a UTF-8 read and `from_body`,
    or `from_bytes` on them unread), a failure being the same 400. A `FromBytes` body (M3-041) is converted with
    `A.from_bytes(body)`, the borrowed bytes unread and uncopied by Muntin
    (400 if it raises); the rules reject a type that is also a `FromBody`.
    A `FromBytes` body longer than its type's `max_bytes`, bare or carried
    (`A._max_bytes()`, checked before the rebuild), is 413 before any of
    that (M3-043). A `RouteValues` record (M3-061) is built by
    `_build_record`, never by its own initializers: field `i` is converted
    as a bare slot of its type from `args[at + i]` (`_record_field`), in
    field order, so the first invalid one is 400 and nothing after it is
    converted.

    `A` is refined here rather than bounded: forwarding a handler with an
    explicit body type to a callee that requires `FromBody` fails on Mojo
    1.1.0 (docs/history/architecture-decisions.md, "Argument extraction decision (M2-005)").
    """
    comptime if conforms_to(A, RouteValues):
        return _build_record[A, _Reject, _record_field, at](args, body)
    elif conforms_to(A, _NamedValue):
        # A `Param` (M3-050): its value converted as a bare slot of its type.
        # Only an exact `Param` reaches here: `_kind` gives any other type
        # conforming to the private marker no kind, so `_admits` refuses it
        # (tests/named_values_api_fail/marker_only_type.mojo).
        var value = _slot[A._Value, at](args, body)
        return A._wrap(value^)
    elif A == Int:
        try:
            return _as[Int, A](_parse_int(args[at]))
        except e:
            raise _Reject(400, Rejection.PATH, at, String(e))
    elif A == String:
        return _as[String, A](args[at].copy())
    elif A == Optional[Int]:
        if args[at].byte_length() == 0:
            return _as[Optional[Int], A](None)
        try:
            return _as[Optional[Int], A](_parse_int(args[at]))
        except e:
            raise _Reject(400, Rejection.PATH, at, String(e))
    elif A == Optional[String]:
        if args[at].byte_length() == 0:
            return _as[Optional[String], A](None)
        return _as[Optional[String], A](args[at].copy())
    elif conforms_to(A, FromRouteValue):
        try:
            return A.from_route_value(args[at])
        except e:
            raise _Reject(400, Rejection.FROM_ROUTE_VALUE, at, String(e))
    elif A == Request:
        try:
            return _as[Request, A](_raw_request(args, body))
        except:
            raise _Reject(500)
    elif A == Headers:
        try:
            return _as[Headers, A](_header_slot(args, at))
        except:
            raise _Reject(500)  # only the `_fields` gap gets here
    elif conforms_to(A, FromBytes):
        # The type's limit first (M3-043), then the bytes as received,
        # borrowed: no UTF-8 read, no copy (M3-041).
        if len(body) > A.max_bytes:
            raise _Reject(413)
        try:
            return _convert_body[A](body)
        except f:
            raise _Reject(400, f.step, -1, f.message)
    else:
        comptime assert conforms_to(A, FromBody) or conforms_to(
            A, _HeaderCarrier
        )
        comptime if conforms_to(A, _JsonBody):
            var status = _json_status[A](args, at, len(body))
            if status != 0:
                raise _Reject(status)
        comptime if conforms_to(A, _HeaderCarrier):
            # The carried `FromBytes` type's limit, before the rebuild
            # (M3-043); `Int.MAX`, no limit, for a text body.
            if len(body) > A._max_bytes():
                raise _Reject(413)
            var fields: Headers
            try:
                fields = _carrier_fields[A](args, at)
            except:
                raise _Reject(500)  # only the `_fields` gap gets here
            try:
                return A._from_parts(body, fields^)
            except f:
                raise _Reject(400, f.step, -1, f.message)
        else:
            comptime assert conforms_to(A, FromBody)
            try:
                return _convert_body[A](body)
            except f:
                raise _Reject(400, f.step, -1, f.message)


def _record_field[
    F: Movable & Deinitable, i: Int
](args: List[String], body: List[UInt8]) raises _Reject -> F:
    """A field of a `RouteValues` record (M3-061): the bare slot of type `F`
    at `args[i]`, converted by `_slot`. The registration rules accept only
    route values as fields, so `body` is never read."""
    return _slot[F, i](args, body)


def _width[A: AnyType]() -> Int:
    """How many route values a request slot of type `A` reads (M3-061): a
    record its field count, a bare route value (a `Param` included) one,
    any other slot (a body, `Headers`, the `Request`) none. A slot's first
    route value is at the sum of the widths of the slots before it, which
    is also where a `Headers` slot's fields or a JSON body's verdict
    start."""
    comptime if conforms_to(A, RouteValues):
        return reflect[A].field_count()
    elif _is_value(_kind[A]()):
        return 1
    else:
        return 0


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
](
    handler: def() thin raises E -> R, args: List[String], body: List[UInt8]
) -> Response:
    var result: R
    try:
        result = handler()
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_1[
    A: Movable & Deinitable, E: Deinitable, R: Movable & Deinitable
](
    handler: def(var A) thin raises E -> R,
    args: List[String],
    body: List[UInt8],
) -> Response:
    """Converts the one slot (`_slot`) and moves it into `handler`; a
    failure answers without calling it."""
    var a: A
    try:
        a = _slot[A, 0](args, body)
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
    handler: def(var A, var B) thin raises E -> R,
    args: List[String],
    body: List[UInt8],
) -> Response:
    """Converts the two slots in order, so a bad route value answers before
    the body is converted, and moves both into `handler`."""
    var a: A
    var b: B
    try:
        a = _slot[A, 0](args, body)
        b = _slot[B, _width[A]()](args, body)
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
    handler: def(var A, var B, var C) thin raises E -> R,
    args: List[String],
    body: List[UInt8],
) -> Response:
    """Converts the three slots in order, so a bad route value answers
    before the next value, the body or the `Headers` is converted, and
    moves them into `handler`."""
    var a: A
    var b: B
    var c: C
    try:
        a = _slot[A, 0](args, body)
        b = _slot[B, _width[A]()](args, body)
        c = _slot[C, _width[A]() + _width[B]()](args, body)
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
    bound: _Bound[def(State[S]) thin raises E -> R, S],
    args: List[String],
    body: List[UInt8],
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
    body: List[UInt8],
) -> Response:
    """`_call_1` with the route's state handle passed first, by borrow."""
    var a: A
    try:
        a = _slot[A, 0](args, body)
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
    body: List[UInt8],
) -> Response:
    """`_call_2` with the route's state handle passed first, by borrow."""
    var a: A
    var b: B
    try:
        a = _slot[A, 0](args, body)
        b = _slot[B, _width[A]()](args, body)
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
    body: List[UInt8],
) -> Response:
    """`_call_3` with the route's state handle passed first, by borrow."""
    var a: A
    var b: B
    var c: C
    try:
        a = _slot[A, 0](args, body)
        b = _slot[B, _width[A]()](args, body)
        c = _slot[C, _width[A]() + _width[B]()](args, body)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = bound.handler(bound.state, a^, b^, c^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


# Guarded routes (M3-080): see "Guarded groups" in the header above.


struct _NoContext(Movable):
    """The context type of a root `App`: no guard, no context."""

    pass


struct _NoGuardState(Movable):
    """The guard state type of a root `App`."""

    pass


struct _Guarded[
    F: Movable & Deinitable,
    GS: Movable & Deinitable,
    GE: Deinitable,
    Ctx: Movable & Deinitable,
](Movable):
    """A route's handler (or `_Bound`), its group's guard and one copy of
    the guard's state, boxed together as one `_Erased` value."""

    var inner: Self.F
    var guard: def(State[Self.GS], Headers) thin raises Self.GE -> Self.Ctx
    var guard_state: State[Self.GS]

    def __init__(
        out self,
        var inner: Self.F,
        guard: def(State[Self.GS], Headers) thin raises Self.GE -> Self.Ctx,
        guard_state: State[Self.GS],
    ):
        self.inner = inner^
        self.guard = guard
        self.guard_state = guard_state.copy()


struct _Answer(Movable):
    """An answer made before the handler: the guard's refusal, or a deferred
    400."""

    var response: Response

    def __init__(out self, var response: Response):
        self.response = response^

    def take(deinit self) -> Response:
        return self.response^


def _guarded_at[A: AnyType, B: AnyType, C: AnyType]() -> Int:
    """Where the header fields start for a guarded route whose route values
    were decoded: after the route values and a JSON verdict; 3 for a raw
    route (method, path, query)."""
    comptime if _kind[A]() == _RAW:
        return 3
    var at = _width[A]() + _width[B]() + _width[C]()
    comptime if (
        conforms_to(A, _JsonBody)
        or conforms_to(B, _JsonBody)
        or conforms_to(C, _JsonBody)
    ):
        at += 1
    return at


def _keeps_fields[A: AnyType, B: AnyType, C: AnyType]() -> Bool:
    """Whether the handler's own slots read the header fields."""
    return (
        conforms_to(A, _HeaderCarrier)
        or conforms_to(B, _HeaderCarrier)
        or conforms_to(C, _HeaderCarrier)
        or _kind[A]() == _HEADERS
        or _kind[B]() == _HEADERS
        or _kind[C]() == _HEADERS
        or _kind[A]() == _RAW
    )


def _run_guard[
    A: AnyType,
    B: AnyType,
    C: AnyType,
    F: Movable & Deinitable,
    GS: Movable & Deinitable,
    GE: Deinitable,
    Ctx: Movable & Deinitable,
](
    g: _Guarded[F, GS, GE, Ctx], args: List[String], mut inner: List[String]
) raises _Answer -> Ctx:
    """Runs the guard on the request's header fields, then answers a
    deferred route-value 400; fills `inner` with the arguments the handler's
    slots read, as an unguarded route would receive them."""
    var ok = args[len(args) - 1] == "1"
    # A deferred 400's `Rejection` (step, name, message) comes first.
    # The route's arguments are those of the slots after a context slot.
    comptime ctx_first = A == Ctx
    var at: Int
    var keeps: Bool
    comptime if ctx_first:
        at = _guarded_at[B, C, _NoSlot]() if ok else 3
        keeps = _keeps_fields[B, C, _NoSlot]()
    else:
        at = _guarded_at[A, B, C]() if ok else 3
        keeps = _keeps_fields[A, B, C]()
    var fields: Headers
    try:
        fields = _header_slot(args, at)
    except:
        raise _Answer(_failed(Failure.MUNTIN, _REBUILD_FAILED))
    var ctx: Ctx
    try:
        ctx = g.guard(g.guard_state, fields)
    except e:
        raise _Answer(_handler_error(e^))
    if not ok:
        raise _Answer(_rejected_by(args[0], args[1], args[2]))
    var end = len(args) - 1 if keeps else at
    for i in range(end):
        inner.append(args[i])
    return ctx^


def _ctx_first[
    A: Movable & Deinitable, Ctx: Movable & Deinitable
](var ctx: Ctx, args: List[String], body: List[UInt8]) raises _Reject -> A:
    """The first slot: the guard's value when its type is the context type,
    else the slot converted as usual (the value is then dropped)."""
    comptime if A == Ctx:
        return _as[Ctx, A](ctx^)
    else:
        _ = ctx^
        return _slot[A, 0](args, body)


def _call_guarded_0[
    E: Deinitable,
    R: Movable & Deinitable,
    GS: Movable & Deinitable,
    GE: Deinitable,
    Ctx: Movable & Deinitable,
](
    g: _Guarded[def() thin raises E -> R, GS, GE, Ctx],
    args: List[String],
    body: List[UInt8],
) -> Response:
    var inner = List[String]()
    try:
        _ = _run_guard[_NoSlot, _NoSlot, _NoSlot](g, args, inner)
    except a:
        return a^.take()
    var result: R
    try:
        result = g.inner()
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_guarded_1[
    A: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    GS: Movable & Deinitable,
    GE: Deinitable,
    Ctx: Movable & Deinitable,
](
    g: _Guarded[def(var A) thin raises E -> R, GS, GE, Ctx],
    args: List[String],
    body: List[UInt8],
) -> Response:
    var inner = List[String]()
    var ctx: Ctx
    try:
        ctx = _run_guard[A, _NoSlot, _NoSlot](g, args, inner)
    except a:
        return a^.take()
    var a: A
    try:
        a = _ctx_first[A, Ctx](ctx^, inner, body)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = g.inner(a^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_guarded_2[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    GS: Movable & Deinitable,
    GE: Deinitable,
    Ctx: Movable & Deinitable,
](
    g: _Guarded[def(var A, var B) thin raises E -> R, GS, GE, Ctx],
    args: List[String],
    body: List[UInt8],
) -> Response:
    var inner = List[String]()
    var ctx: Ctx
    try:
        ctx = _run_guard[A, B, _NoSlot](g, args, inner)
    except a:
        return a^.take()
    var a: A
    var b: B
    try:
        a = _ctx_first[A, Ctx](ctx^, inner, body)
        b = _slot[B, _width[A]()](inner, body)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = g.inner(a^, b^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_guarded_3[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    C: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    GS: Movable & Deinitable,
    GE: Deinitable,
    Ctx: Movable & Deinitable,
](
    g: _Guarded[def(var A, var B, var C) thin raises E -> R, GS, GE, Ctx],
    args: List[String],
    body: List[UInt8],
) -> Response:
    var inner = List[String]()
    var ctx: Ctx
    try:
        ctx = _run_guard[A, B, C](g, args, inner)
    except a:
        return a^.take()
    var a: A
    var b: B
    var c: C
    try:
        a = _ctx_first[A, Ctx](ctx^, inner, body)
        b = _slot[B, _width[A]()](inner, body)
        c = _slot[C, _width[A]() + _width[B]()](inner, body)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = g.inner(a^, b^, c^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_guarded_state_0[
    S: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    GS: Movable & Deinitable,
    GE: Deinitable,
    Ctx: Movable & Deinitable,
](
    g: _Guarded[_Bound[def(State[S]) thin raises E -> R, S], GS, GE, Ctx],
    args: List[String],
    body: List[UInt8],
) -> Response:
    var inner = List[String]()
    try:
        _ = _run_guard[_NoSlot, _NoSlot, _NoSlot](g, args, inner)
    except a:
        return a^.take()
    var result: R
    try:
        result = g.inner.handler(g.inner.state)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_guarded_state_1[
    S: Movable & Deinitable,
    A: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    GS: Movable & Deinitable,
    GE: Deinitable,
    Ctx: Movable & Deinitable,
](
    g: _Guarded[
        _Bound[def(State[S], var A) thin raises E -> R, S], GS, GE, Ctx
    ],
    args: List[String],
    body: List[UInt8],
) -> Response:
    var inner = List[String]()
    var ctx: Ctx
    try:
        ctx = _run_guard[A, _NoSlot, _NoSlot](g, args, inner)
    except a:
        return a^.take()
    var a: A
    try:
        a = _ctx_first[A, Ctx](ctx^, inner, body)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = g.inner.handler(g.inner.state, a^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_guarded_state_2[
    S: Movable & Deinitable,
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    GS: Movable & Deinitable,
    GE: Deinitable,
    Ctx: Movable & Deinitable,
](
    g: _Guarded[
        _Bound[def(State[S], var A, var B) thin raises E -> R, S], GS, GE, Ctx
    ],
    args: List[String],
    body: List[UInt8],
) -> Response:
    var inner = List[String]()
    var ctx: Ctx
    try:
        ctx = _run_guard[A, B, _NoSlot](g, args, inner)
    except a:
        return a^.take()
    var a: A
    var b: B
    try:
        a = _ctx_first[A, Ctx](ctx^, inner, body)
        b = _slot[B, _width[A]()](inner, body)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = g.inner.handler(g.inner.state, a^, b^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _call_guarded_state_3[
    S: Movable & Deinitable,
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    C: Movable & Deinitable,
    E: Deinitable,
    R: Movable & Deinitable,
    GS: Movable & Deinitable,
    GE: Deinitable,
    Ctx: Movable & Deinitable,
](
    g: _Guarded[
        _Bound[def(State[S], var A, var B, var C) thin raises E -> R, S],
        GS,
        GE,
        Ctx,
    ],
    args: List[String],
    body: List[UInt8],
) -> Response:
    var inner = List[String]()
    var ctx: Ctx
    try:
        ctx = _run_guard[A, B, C](g, args, inner)
    except a:
        return a^.take()
    var a: A
    var b: B
    var c: C
    try:
        a = _ctx_first[A, Ctx](ctx^, inner, body)
        b = _slot[B, _width[A]()](inner, body)
        c = _slot[C, _width[A]() + _width[B]()](inner, body)
    except r:
        return _rejected(r)
    var result: R
    try:
        result = g.inner.handler(g.inner.state, a^, b^, c^)
    except e:
        return _handler_error(e^)
    return _respond(result^)


def _route[
    A: AnyType, B: AnyType, C: AnyType, R: AnyType
](method: String, path: StaticString, var handler: _Erased) -> _Route:
    """The route for an accepted handler whose request slots have types `A`,
    `B` and `C` (`_NoSlot` where there is none): a JSON route when its body
    is a `Json[T]`, raw when its slot is the `Request`, and a route that
    receives the header fields for a carrier or a `Headers` slot. A body, a `Headers` or a `Request` slot is always the
    last one, so the flags read every slot. Each query key whose value binds
    an `Optional` slot or record field is marked optional (M3-025, M3-061):
    route values come first, a record's fields in field order, so the value
    at position `j` binds query key `j - paths`."""
    var route = _Route(
        method,
        path,
        handler^,
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
    # Only a build that may call `App.openapi` links the operations.
    comptime if is_defined["MUNTIN_OPENAPI"]():
        route.describe = _operation[A, B, C, R]
    var paths = _path_params(path)
    var kinds = List[Int]()
    comptime if conforms_to(A, RouteValues):
        comptime types = reflect[A].field_types()
        comptime for i in range(reflect[A].field_count()):
            kinds.append(_kind[types[i]]())
    else:
        kinds.append(_kind[A]())
    kinds.append(_kind[B]())
    kinds.append(_kind[C]())
    for j in range(len(kinds)):
        if _is_optional(kinds[j]):
            route.query_optional[j - paths] = True
    return route^


def _no_operation(
    mut out: JsonWriter, literal: StaticString, extra: Optional[JsonValue]
) raises:
    """No operation: `_route` stores `_operation` only under `-D
    MUNTIN_OPENAPI`, which `App.openapi` requires (so a route built
    without types, as two tests do, is never described)."""
    raise Error("openapi: no operation")


struct _Route(Movable):
    var method: String
    var path: String
    """Path part of the route literal; the only part requests are matched
    against."""
    var query_keys: List[String]
    """Keys of the route's `{key}` query parameters, in the literal's order
    (none if it has no query part)."""
    var query_index: Dict[String, Int]
    """`_query_index` of `query_keys`: empty unless the route has more than
    `_LINEAR_QUERY_KEYS` query keys (a `RouteValues` record's)."""
    var query_optional: List[Bool]
    """For each of `query_keys`, whether its value binds an `Optional` slot
    (M3-025): `App.handle` then passes an absent key or an empty value on
    as `""` instead of answering 400. All `False` until `_route` sets them."""
    var json: Bool
    """Whether the handler's body is a `Json[T]` (`_JsonBody`): `App.handle`
    then appends the request's `Content-Type` verdict at the body's
    position, and the adapter answers 415 and 413 before `from_body`
    (M3-009)."""
    var headers: Bool
    """Whether the handler receives the request's header fields: its body
    is a `WithHeaders[B]` carrier (`_HeaderCarrier`, M3-013) or its last
    slot is `Headers` (M3-016). `App.handle` then appends each field's name
    and value after the route values and any verdict, and the adapter
    rebuilds the fields into the carrier or the `Headers` slot."""
    var raw: Bool
    """Whether the handler receives the whole request (a `Request`
    slot): its raw arguments are the request's method, path and query,
    then each header field's name and value; the body comes as bytes
    beside them (M3-040)."""
    var guarded: Bool
    """Whether the route belongs to a `Group` (M3-080): its box runs the
    group's guard before any type conversion. `App.handle` then defers a
    route-value 400 until after the guard, and appends the header fields
    and a verdict (`"1"`, or `"0"` for a deferred 400) last."""
    var handler: _Erased
    var literal: StaticString
    """The route literal as registered (M3-091 prototype)."""
    var describe: def(
        mut JsonWriter, StaticString, Optional[JsonValue]
    ) thin raises
    """Writes the route's OpenAPI operation from its literal and the
    application's additions (M3-091 prototype): `_operation` of the
    handler's slot and result types."""

    def __init__(
        out self,
        method: String,
        route: StaticString,
        var handler: _Erased,
        json: Bool = False,
        headers: Bool = False,
        raw: Bool = False,
        describe: def(
            mut JsonWriter, StaticString, Optional[JsonValue]
        ) thin raises = _no_operation,
    ):
        """Splits `route` into its path part and query keys with the
        route-literal grammar's primitives (`_registration_rules.mojo`); the
        literal is well formed (checked at registration)."""
        self.method = method
        self.json = json
        self.headers = headers
        self.raw = raw
        self.guarded = False
        self.path = String(_path_part(route))
        self.query_keys = List[String]()
        for item in _query_items(route):
            self.query_keys.append(String(_param_name(item)))
        self.query_index = _query_index(self.query_keys)
        self.query_optional = List[Bool](
            length=len(self.query_keys), fill=False
        )
        self.handler = handler^
        self.literal = route
        self.describe = describe


def _sent_as_written(text: String, query: Bool) -> Bool:
    """Whether common clients send `text` as written, so that Muntin's byte
    comparison sees it: a query key of letters, digits and `-._` alone (a
    form serializer encodes the rest of a parameter's name, `~` included),
    a static path segment of RFC 3986 `pchar` (unreserved characters,
    sub-delimiters, `:`, `@` and a `%` with two hexadecimal digits, which a
    client sends as written), except `.` and `..`, which a client
    removes."""
    if not query and (text == "." or text == ".."):
        return False
    var bytes = text.as_bytes()
    var i = 0
    while i < len(bytes):
        var c = Int(bytes[i])
        i += 1
        if (
            not query
            and c == ord("%")
            and i + 1 < len(bytes)
            and _hex_digit(bytes[i]) >= 0
            and _hex_digit(bytes[i + 1]) >= 0
        ):
            i += 2
            continue
        if (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("A") and c <= ord("Z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord("-")
            or c == ord(".")
            or c == ord("_")
        ):
            continue
        if not query and String(chr(c)) in "~!$&'()*+,;=:@":
            continue
        return False
    return True


def _object(text: String, what: String) raises -> JsonValue:
    """`text` parsed as a JSON object; raises naming `what` otherwise."""
    var value: JsonValue
    try:
        value = _parse_json(text)
    except e:
        raise Error("openapi: " + what + " is not JSON: " + String(e))
    if value._kind() != _OBJECT:
        raise Error("openapi: " + what + " is not a JSON object")
    return value^


def _document(
    routes: List[_Route],
    title: String,
    version: String,
    document: String,
    operations: Dict[String, String],
) raises -> String:
    var paths = List[String]()
    var shapes = List[String]()
    for i in range(len(routes)):
        for key in routes[i].query_keys:
            if not _sent_as_written(key, True):
                raise Error(
                    "openapi: route "
                    + String(routes[i].literal)
                    + ": a client may not send the query key "
                    + key
                    + " as written, and Muntin compares it undecoded"
                )
        var p = routes[i].path
        var seen = False
        for q in paths:
            if q == p:
                seen = True
        if seen:
            continue
        var segments = _segments(p)
        var shape = _shape(segments)
        for k in range(len(shapes)):
            if shapes[k] == shape:
                raise Error(
                    "openapi: routes "
                    + paths[k]
                    + " and "
                    + p
                    + " differ only in placeholder names, which OpenAPI"
                    + " treats as one path"
                )
        var names = List[String]()
        for segment in segments:
            if not _is_param(segment):
                if not _sent_as_written(segment, False):
                    raise Error(
                        "openapi: route "
                        + p
                        + ": a client may not send the segment "
                        + segment
                        + " as written, and Muntin matches it undecoded"
                    )
                continue
            var name = String(segment[byte = 1 : segment.byte_length() - 1])
            for n in names:
                if n == name:
                    raise Error(
                        "openapi: route "
                        + p
                        + " repeats the placeholder {"
                        + name
                        + "}, which OpenAPI does not allow"
                    )
            names.append(name)
        paths.append(p)
        shapes.append(shape^)
    # Each key of `operations` names a route's operation, as `METHOD path`
    # with the document's path (the literal's path part).
    for entry in operations.items():
        var found = False
        for i in range(len(routes)):
            if routes[i].method + " " + routes[i].path == entry.key:
                found = True
        if not found:
            raise Error("openapi: operations: no route " + entry.key)
    var top = Optional[JsonValue]()
    if document.byte_length() > 0:
        top = _object(document, "document")
    var out = JsonWriter()
    out.begin_object()
    out.field("openapi", "3.1.0")
    out.name("info")
    out.begin_object()
    out.field("title", title)
    out.field("version", version)
    if top:
        var info = top.value().get("info")
        if info:
            try:
                _merge(out, info.value(), False)
            except e:
                raise Error("openapi: document: info: " + String(e))
    out.end_object()
    out.name("paths")
    out.begin_object()
    for p in paths:
        out.name(p)
        out.begin_object()
        for i in range(len(routes)):
            if routes[i].path == p:
                var key = routes[i].method + " " + p
                var extra = Optional[JsonValue]()
                var text = operations.get(key)
                if text:
                    extra = _object(text.value(), "operations[" + key + "]")
                out.name(routes[i].method.lower())
                try:
                    routes[i].describe(out, routes[i].literal, extra)
                except e:
                    raise Error(
                        "openapi: operations[" + key + "]: " + String(e)
                    )
        out.end_object()
    out.end_object()
    if top:
        # `openapi` and `paths` are derived, and `info` merged above.
        for i in range(len(top.value())):
            var member = top.value()._child(i)
            var name = member._name()
            if name == "info":
                continue
            if out._holds(name):
                raise Error("openapi: document: " + name + " is derived")
            out.name(name)
            out._copy(member)
    out.end_object()
    return out^._finish()


struct Next[o: Origin[mut=False]](Movable):
    """The rest of the request handling after one middleware, for the
    duration of that middleware's call (M3-034).

    A middleware receives it as `var next: Next` and runs the rest at most
    once, as `next^.run(request^)`. It holds an immutable pointer to the
    borrowed `App` with that borrow's origin `o`, so it cannot outlive the
    call, and the index of the next middleware. It is `Movable`, not
    `Copyable`, and has no plain call: `run` consumes it, so a second use of
    the same `next` does not compile. Its initializer takes only
    `_`-prefixed keyword arguments, so no public spelling builds one.
    """

    var _app: Pointer[_Core, Self.o]
    var _index: Int

    def __init__(out self, *, ref[Self.o] _app: _Core, _index: Int):
        self._app = Pointer(to=_app)
        self._index = _index

    def run(deinit self, var request: Request) -> Response:
        """Runs the rest on `request`, the next middleware or, after the
        last, the routes, and returns its answer. Consumes `self`: call it
        as `next^.run(request^)`."""
        return self._app[]._run(self._index, request^)


comptime Middleware = def[o: Origin[mut=False]](
    var Request, var Next[o]
) raises thin -> Response
"""A middleware function, registered with `App.use` (M3-034). An
application `def(var request: Request, var next: Next) raises -> Response`
converts to it, as does one that borrows the request or does not raise."""


struct _Core(Movable):
    """The routes, their index and the middleware of an `App`, and the
    dispatch, which no guard type parameterizes; `Next` points here, so the
    generic `_App` needs no cast to run the chain (M3-080)."""

    var _routes: List[_Route]
    var _route_index: _RouteIndex
    var _middleware: List[Middleware]

    def __init__(out self):
        self._routes = List[_Route]()
        self._route_index = _RouteIndex()
        self._middleware = List[Middleware]()

    def _add(mut self, var route: _Route):
        """Appends `route` to the routes, or aborts at this registration with
        `_conflict`'s message when an earlier route of the same method
        overlaps it and is not more specific (M3-053), found through
        `_route_index`."""
        var refused = self._route_index.refusal(route.method, route.path)
        if refused.byte_length() > 0:
            abort(refused)
        self._route_index.add(route.method, route.path)
        self._routes.append(route^)

    def handle(self, request: Request) -> Response:
        """`App.handle` on a lent request."""
        if len(self._middleware) == 0:
            return self._dispatch(request)
        return self._run(0, request.copy())

    def handle(self, var request: Request) -> Response:
        """Answers `request` as the borrowing `handle` does, taking it from
        the caller (M3-064): with middleware registered, the request itself,
        its body buffer included, is moved to the first middleware instead of
        copied. Mojo picks this overload for a temporary or `request^`, the
        borrowing one for a named value. Without middleware both answer
        through the same `_dispatch`."""
        if len(self._middleware) == 0:
            return self._dispatch(request)
        return self._run(0, request^)

    def _run(self, index: Int, var request: Request) -> Response:
        """The answer of the middleware at `index` and everything after it;
        past the last middleware, the routes'. A raise out of the middleware
        is the fixed 500 here, at its own call, carrying a
        `Failure.MIDDLEWARE` report of the error's text (M3-058), so the
        middleware outside it receives an ordinary response from its `next`
        (M3-034)."""
        if index == len(self._middleware):
            return self._dispatch(request)
        try:
            return self._middleware[index](
                request^, Next(_app=self, _index=index + 1)
            )
        except e:
            return _failed(Failure.MIDDLEWARE, String(e))

    def _dispatch(self, request: Request) -> Response:
        """The routes' answer to `request`, as `handle` describes it."""
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
            var deferred = False
            if route.raw:
                args.append(request.method)
                args.append(request.path)
                args.append(request.query)
                for h in range(len(request.headers)):
                    args.append(request.headers.name(h))
                    args.append(request.headers.value(h))
                if route.guarded:
                    args.append("1")
            else:
                # The route values, decoded once here at capture (M3-018);
                # a failure names its value (M3-084).
                try:
                    _route_values(route, request, args)
                except r:
                    var step = r.step
                    var name = _value_name(route, r.at, step)
                    # A guarded route answers its guard first, so its 400
                    # waits in the verdict below (M3-080), its `Rejection`
                    # first in the arguments.
                    if not route.guarded:
                        return _rejected_by(step, name, r.message)
                    deferred = True
                    args.clear()
                    args.append(step)
                    args.append(name)
                    args.append(r.message)
                if route.json and not deferred:
                    args.append(
                        "1" if _json_content_type(request.headers) else ""
                    )
                if route.headers or route.guarded:
                    for h in range(len(request.headers)):
                        args.append(request.headers.name(h))
                        args.append(request.headers.value(h))
                if route.guarded:
                    args.append("0" if deferred else "1")
            # No adapter raises: each answers its own 400s and turns a
            # handler error into a response. A raise here is a server fault,
            # never a client error.
            var response: Response
            try:
                response = route.handler.invoke(args, request.body)
            except e:
                return _failed(Failure.MUNTIN, String(e))
            _name_rejected_value(response, route)
            return response^
        # No route selected: 405 when some route matches the path (M3-030).
        var allowed = _allowed(self._routes, request.path)
        if len(allowed) == 0:
            return Response.text("Not Found", status=404)
        var response = Response.text("Method Not Allowed", status=405)
        try:
            response.headers.add("Allow", ", ".join(allowed))
        except e:
            return _failed(Failure.MUNTIN, String(e))
        return response^


def _route_values(
    route: _Route, request: Request, mut args: List[String]
) raises _Reject:
    """Decodes the path captures in `args` in place, then appends each query
    value as gathered, in the literal's order (M3-018, M3-022). An optional
    value's absent key or empty value is passed on as `""`, which no decoded
    value is (M3-025). A failure raises its `Rejection` step, the value's
    position among the route values and Muntin's fixed message (M3-084)."""
    var paths = len(args)
    for j in range(paths):
        try:
            args[j] = _decode_value(args[j], query=False)
        except e:
            raise _Reject(400, Rejection.PATH, j, String(e))
    # One pass finds every value without copying any; they are copied in
    # key order after it, so a missing key answers 400 before any later
    # value is copied.
    var spans: List[Int]
    var repeated = -1
    try:
        spans = _query_spans_at(
            request.query, route.query_keys, route.query_index, repeated
        )
    except:
        raise _Reject(400, Rejection.QUERY, paths + repeated, _REPEATED)
    for k in range(len(route.query_keys)):
        var start = spans[2 * k]
        var end = spans[2 * k + 1]
        if route.query_optional[k] and (start < 0 or start == end):
            args.append("")
        elif start < 0:
            raise _Reject(400, Rejection.QUERY, paths + k, _MISSING)
        else:
            try:
                args.append(
                    _decode_value(
                        String(request.query[byte=start:end]), query=True
                    )
                )
            except e:
                raise _Reject(400, Rejection.QUERY, paths + k, String(e))


def _value_name(route: _Route, at: Int, mut step: String) -> String:
    """The placeholder name of the route value at position `at` (the path
    captures, then the query keys), or `""` for `at < 0`; a `PATH` step at
    a query value becomes `QUERY` (M3-084)."""
    if at < 0:
        return ""
    var j = 0
    for segment in route.path.split("/"):
        if segment.startswith("{"):
            if j == at:
                return String(segment[byte = 1 : segment.byte_length() - 1])
            j += 1
    if step == Rejection.PATH:
        step = Rejection.QUERY
    return route.query_keys[at - j].copy()


def _name_rejected_value(mut response: Response, route: _Route):
    """Names the route value a slot rejected (`_Reject.at`), which only the
    route knows (M3-084)."""
    if not response._report or response._report[0].at < 0:
        return
    ref report = response._report[0]
    var step = report.rejection[0].step
    report.rejection[0].name = _value_name(route, report.at, step)
    report.rejection[0].step = step
    report.at = -1


comptime App = _App[_NoGuardState, Never, _NoContext]
"""A Muntin application: a set of routes and the dispatch entry point."""

comptime Group = _App
"""A group of routes behind one guard (M3-080): `Group(guard, state)`,
registered like an `App`'s routes and moved into one with
`app.mount(group^)`."""


struct _App[
    GS: Movable & Deinitable, GE: Deinitable, Ctx: Movable & Deinitable
](Movable):
    """A Muntin application (`App`, with no guard) or a group of routes
    behind one guard (`Group`), M3-080. Every registration method serves
    both; each overload's guarded branch is one `_guarded_*` helper of its
    arity and family."""

    var _core: _Core
    var _guard: Optional[
        def(State[Self.GS], Headers) thin raises Self.GE -> Self.Ctx
    ]
    var _guard_state: Optional[State[Self.GS]]

    def __init__(out self):
        """An application with no routes and no middleware."""
        comptime assert (
            Self.Ctx == _NoContext
        ), "a Group is built from its guard and the guard's state"
        self._core = _Core()
        self._guard = None
        self._guard_state = None

    def __init__(
        out self,
        guard: def(State[Self.GS], Headers) thin raises Self.GE -> Self.Ctx,
        state: State[Self.GS],
    ):
        """A group whose every route runs `guard` on the request's header
        fields after routing and percent-decoding, before any type
        conversion or the body. A raise answers as a handler's would; the
        value it returns is moved to a handler whose first request
        parameter has its type, and dropped otherwise. The group keeps one
        copy of `state`, and each of its routes one more."""
        comptime assert Self.Ctx != _NoContext, "a Group needs a context type"
        comptime assert not _may_borrow[Self.Ctx](), (
            "a Group's context type must own its data; its name shows an"
            " origin or a parameter pack: "
            + reflect[Self.Ctx].name()
        )
        comptime assert _kind[Self.Ctx]() == _OTHER, (
            "a Group's context type must not be a request slot kind (a route"
            " value, a body, Headers, Request or State): "
            + reflect[Self.Ctx].name()
        )
        self._core = _Core()
        self._guard = guard
        self._guard_state = state.copy()

    def mount[
        GS2: Movable & Deinitable, GE2: Deinitable, Ctx2: Movable & Deinitable
    ](mut self, var group: _App[GS2, GE2, Ctx2]):
        """Moves every route of `group` into this `App`, in registration
        order, each checked for a conflict as its own registration on the
        `App` would be (M3-053)."""
        comptime assert Self.Ctx == _NoContext, "mount: a Group mounts no Group"
        comptime assert Ctx2 != _NoContext, "mount takes a Group"
        # Reversed once, then taken from the end: linear, and in
        # registration order, which the conflict checks depend on.
        group._core._routes.reverse()
        while len(group._core._routes) > 0:
            self._add(group._core._routes.pop())

    def openapi(
        self,
        *,
        title: String,
        version: String,
        document: String = "",
        operations: Dict[String, String] = Dict[String, String](),
    ) raises -> String:
        """The OpenAPI 3.1 document of this `App`'s routes, as JSON text
        (M3-091 prototype): one path item per route path, in registration
        order, one operation per route, each described from the handler's
        types alone. Only a build with `-D MUNTIN_OPENAPI` compiles a call
        (and links the operations, so other builds pay for none). What the
        types cannot say the application adds as JSON
        objects, written into the document as given: `document`'s members
        at the top level (`info`'s into `info`), say `servers`, `security`
        and `components`; `operations["GET /notes/{id}"]`'s into that
        operation (`METHOD` and the document's path), say `security`,
        `summary` or a `responses` entry of another status.

        Raises when a route cannot be described truly: a path placeholder
        name repeated in it, two route paths that differ only in their
        placeholder names, or a query key or static segment a client may
        not send as written (`_sent_as_written`), which Muntin compares
        undecoded. Raises, too, when an addition is no JSON object, names
        no route, or repeats a derived member: `openapi`, `paths`, `info`'s
        `title` and `version`, an operation's `parameters`, its
        `requestBody` when the handler takes a body, the status its result
        gives."""
        comptime assert Self.Ctx == _NoContext, "openapi: mount the Group first"
        comptime assert is_defined[
            "MUNTIN_OPENAPI"
        ](), "openapi: build with -D MUNTIN_OPENAPI"
        return _document(
            self._core._routes, title, version, document, operations
        )

    def _add_guarded[
        F: Movable & Deinitable,
        //,
        method: StaticString,
        stateful: Bool,
        path: StaticString,
        R: AnyType,
        A: AnyType,
        B: AnyType,
        C: AnyType,
        call: def(
            _Guarded[F, Self.GS, Self.GE, Self.Ctx], List[String], List[UInt8]
        ) thin -> Response,
    ](mut self, var value: F):
        """Registers a route of this group: a leading context slot is set
        aside, and the rules apply to the slots after it as to an `App`'s
        handler of those slots."""
        # A misplaced `State` first (a stateful handler registered without
        # its state) gets the rules' message about the state instead.
        comptime assert _kind[A]() == _STATE or not (
            B == Self.Ctx or C == Self.Ctx
        ), (
            "a Group's handler takes the group's context type once, as its"
            " first request parameter (after State, if any): "
            + reflect[Self.Ctx].name()
        )
        comptime if A == Self.Ctx:
            _check[method, stateful, path, R, B, C, _NoSlot]()
            comptime if _admits[method, stateful, path, R, B, C, _NoSlot]():
                self._add_guarded_route[B, C, _NoSlot, R, call](
                    String(method), path, value^
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            _check[method, stateful, path, R, A, B, C]()
            comptime if _admits[method, stateful, path, R, A, B, C]():
                self._add_guarded_route[A, B, C, R, call](
                    String(method), path, value^
                )
            else:
                abort(_GUARD_DRIFT)

    def _add_guarded_route[
        F: Movable & Deinitable,
        //,
        A: AnyType,
        B: AnyType,
        C: AnyType,
        R: AnyType,
        call: def(
            _Guarded[F, Self.GS, Self.GE, Self.Ctx], List[String], List[UInt8]
        ) thin -> Response,
    ](mut self, method: String, path: StaticString, var value: F):
        """Boxes `value` with the guard and a copy of its state, as the
        route of slots `A`, `B` and `C`, marked guarded."""
        var route = _route[A, B, C, R](
            method,
            path,
            _Erased.__init__[call=call](
                _Guarded(value^, self._guard.value(), self._guard_state.value())
            ),
        )
        route.guarded = True
        self._add(route^)

    # One guarded registration per arity and family: the second branch of
    # every `get`, `post`, `put`, `patch` and `delete` overload of the same
    # arity and family.

    def _guarded_0[
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        method: StaticString,
        path: StaticString,
    ](mut self, handler: def() thin raises E -> R):
        self._add_guarded[
            method,
            False,
            path,
            R,
            _NoSlot,
            _NoSlot,
            _NoSlot,
            _call_guarded_0[E, R, Self.GS, Self.GE, Self.Ctx],
        ](handler)

    def _guarded_1[
        A: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        method: StaticString,
        path: StaticString,
    ](mut self, handler: def(var A) thin raises E -> R):
        self._add_guarded[
            method,
            False,
            path,
            R,
            A,
            _NoSlot,
            _NoSlot,
            _call_guarded_1[A, E, R, Self.GS, Self.GE, Self.Ctx],
        ](handler)

    def _guarded_2[
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        method: StaticString,
        path: StaticString,
    ](mut self, handler: def(var A, var B) thin raises E -> R):
        self._add_guarded[
            method,
            False,
            path,
            R,
            A,
            B,
            _NoSlot,
            _call_guarded_2[A, B, E, R, Self.GS, Self.GE, Self.Ctx],
        ](handler)

    def _guarded_3[
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        C: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        method: StaticString,
        path: StaticString,
    ](mut self, handler: def(var A, var B, var C) thin raises E -> R):
        self._add_guarded[
            method,
            False,
            path,
            R,
            A,
            B,
            C,
            _call_guarded_3[A, B, C, E, R, Self.GS, Self.GE, Self.Ctx],
        ](handler)

    def _guarded_state_0[
        S: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        method: StaticString,
        path: StaticString,
    ](mut self, handler: def(State[S]) thin raises E -> R, state: State[S]):
        self._add_guarded[
            method,
            True,
            path,
            R,
            _NoSlot,
            _NoSlot,
            _NoSlot,
            _call_guarded_state_0[S, E, R, Self.GS, Self.GE, Self.Ctx],
        ](_Bound(handler, state))

    def _guarded_state_1[
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
    ):
        self._add_guarded[
            method,
            True,
            path,
            R,
            A,
            _NoSlot,
            _NoSlot,
            _call_guarded_state_1[S, A, E, R, Self.GS, Self.GE, Self.Ctx],
        ](_Bound(handler, state))

    def _guarded_state_2[
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
    ):
        self._add_guarded[
            method,
            True,
            path,
            R,
            A,
            B,
            _NoSlot,
            _call_guarded_state_2[S, A, B, E, R, Self.GS, Self.GE, Self.Ctx],
        ](_Bound(handler, state))

    def _guarded_state_3[
        S: Movable & Deinitable,
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        C: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        method: StaticString,
        path: StaticString,
    ](
        mut self,
        handler: def(State[S], var A, var B, var C) thin raises E -> R,
        state: State[S],
    ):
        self._add_guarded[
            method,
            True,
            path,
            R,
            A,
            B,
            C,
            _call_guarded_state_3[S, A, B, C, E, R, Self.GS, Self.GE, Self.Ctx],
        ](_Bound(handler, state))

    def use(mut self, middleware: Middleware):
        """Registers `middleware` around every request `App.handle`
        receives, after the middleware registered before it (M3-034).

        Middleware runs in registration order, outermost first, whether
        `use` comes before or after the routes are registered. A raise out of
        a middleware is the fixed 500 at that middleware's call; the
        middleware outside it receives that 500 from its `next`. A `Group`
        takes none: middleware registered on the `App` wraps its mounted
        routes too.
        """
        comptime assert (
            Self.Ctx == _NoContext
        ), "a Group takes no middleware: register it on the App"
        self._core._middleware.append(middleware)

    def _add(mut self, var route: _Route):
        self._core._add(route^)

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
        comptime if Self.Ctx == _NoContext:
            _check["GET", False, path, R, _NoSlot, _NoSlot, _NoSlot]()
            comptime if _admits[
                "GET", False, path, R, _NoSlot, _NoSlot, _NoSlot
            ]():
                self._add(
                    _route[_NoSlot, _NoSlot, _NoSlot, R](
                        "GET",
                        path,
                        _Erased.__init__[call=_call_0[E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_0["GET", path](handler)

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
        comptime if Self.Ctx == _NoContext:
            _check["GET", False, path, R, A, _NoSlot, _NoSlot]()
            comptime if _admits["GET", False, path, R, A, _NoSlot, _NoSlot]():
                self._add(
                    _route[A, _NoSlot, _NoSlot, R](
                        "GET",
                        path,
                        _Erased.__init__[call=_call_1[A, E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_1["GET", path](handler)

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
        comptime if Self.Ctx == _NoContext:
            _check["GET", False, path, R, A, B, _NoSlot]()
            comptime if _admits["GET", False, path, R, A, B, _NoSlot]():
                self._add(
                    _route[A, B, _NoSlot, R](
                        "GET",
                        path,
                        _Erased.__init__[call=_call_2[A, B, E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_2["GET", path](handler)

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
        comptime if Self.Ctx == _NoContext:
            _check["GET", False, path, R, A, B, C]()
            comptime if _admits["GET", False, path, R, A, B, C]():
                self._add(
                    _route[A, B, C, R](
                        "GET",
                        path,
                        _Erased.__init__[call=_call_3[A, B, C, E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_3["GET", path](handler)

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
        comptime if Self.Ctx == _NoContext:
            _check["GET", True, path, R, _NoSlot, _NoSlot, _NoSlot]()
            comptime if _admits[
                "GET", True, path, R, _NoSlot, _NoSlot, _NoSlot
            ]():
                self._add(
                    _route[_NoSlot, _NoSlot, _NoSlot, R](
                        "GET",
                        path,
                        _Erased.__init__[call=_call_state_0[S, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_0["GET", path](handler, state)

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
        comptime if Self.Ctx == _NoContext:
            _check["GET", True, path, R, A, _NoSlot, _NoSlot]()
            comptime if _admits["GET", True, path, R, A, _NoSlot, _NoSlot]():
                self._add(
                    _route[A, _NoSlot, _NoSlot, R](
                        "GET",
                        path,
                        _Erased.__init__[call=_call_state_1[S, A, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_1["GET", path](handler, state)

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
        comptime if Self.Ctx == _NoContext:
            _check["GET", True, path, R, A, B, _NoSlot]()
            comptime if _admits["GET", True, path, R, A, B, _NoSlot]():
                self._add(
                    _route[A, B, _NoSlot, R](
                        "GET",
                        path,
                        _Erased.__init__[call=_call_state_2[S, A, B, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_2["GET", path](handler, state)

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
        comptime if Self.Ctx == _NoContext:
            _check["GET", True, path, R, A, B, C]()
            comptime if _admits["GET", True, path, R, A, B, C]():
                self._add(
                    _route[A, B, C, R](
                        "GET",
                        path,
                        _Erased.__init__[call=_call_state_3[S, A, B, C, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_3["GET", path](handler, state)

    def post[
        E: Deinitable, R: Movable & Deinitable, //, path: StaticString
    ](mut self, handler: def() thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers a parameterless `handler` for `POST path`, as `get`
        on `def()` (M3-048): `path` declares no parameter, and the request's
        body is not read."""
        comptime if Self.Ctx == _NoContext:
            _check["POST", False, path, R, _NoSlot, _NoSlot, _NoSlot]()
            comptime if _admits[
                "POST", False, path, R, _NoSlot, _NoSlot, _NoSlot
            ]():
                self._add(
                    _route[_NoSlot, _NoSlot, _NoSlot, R](
                        "POST",
                        path,
                        _Erased.__init__[call=_call_0[E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_0["POST", path](handler)

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
        `WithHeaders[B2]` carrier with `B2` a `FromBody` or a `FromBytes`,
        which has no conversion of its own: its fields are rebuilt (the
        fixed 500 on failure) and it is built through `_from_parts`, which
        converts the inner body as a bare `B2` is (400 on failure, M3-042);
        the handler also receives the request's header fields, for which
        Muntin chooses no status. A
        `Json[T]` body, alone or in a carrier, is first answered 415 unless
        the request has exactly one `application/json` `Content-Type`, then
        413 when it is over 1 MiB. Every text body's bytes are read as
        UTF-8 before `from_body` (400 if they are not, M3-040). A type
        conforming to `FromBytes` instead receives the body's bytes,
        whatever they are and unread, in `from_bytes` (400 if it raises,
        M3-041; 413 first when they are longer than its `max_bytes`,
        M3-043), alone or in a carrier; a type conforming to both traits is
        rejected. The body may be
        declared `body: B` or
        `var body: B`, and `B` may be move-only. A `Request` parameter
        instead makes a raw handler, as for `get`. Results and raises are
        handled as for `get` on `def()`; this holds for every body shape,
        stateless or stateful.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["POST", False, path, R, A, _NoSlot, _NoSlot]()
            comptime if _admits["POST", False, path, R, A, _NoSlot, _NoSlot]():
                self._add(
                    _route[A, _NoSlot, _NoSlot, R](
                        "POST",
                        path,
                        _Erased.__init__[call=_call_1[A, E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_1["POST", path](handler)

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
        `def()`.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["POST", False, path, R, A, B, _NoSlot]()
            comptime if _admits["POST", False, path, R, A, B, _NoSlot]():
                self._add(
                    _route[A, B, _NoSlot, R](
                        "POST",
                        path,
                        _Erased.__init__[call=_call_2[A, B, E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_2["POST", path](handler)

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
        `handler`. Results and raises as for `get` on `def()`.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["POST", False, path, R, A, B, C]()
            comptime if _admits["POST", False, path, R, A, B, C]():
                self._add(
                    _route[A, B, C, R](
                        "POST",
                        path,
                        _Erased.__init__[call=_call_3[A, B, C, E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_3["POST", path](handler)

    def post[
        S: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self, handler: def(State[S]) thin raises E -> R, state: State[S]
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers a stateful parameterless `handler` for `POST path`,
        as `get` on `def(State[S])` (M3-048); the request's body is not
        read."""
        comptime if Self.Ctx == _NoContext:
            _check["POST", True, path, R, _NoSlot, _NoSlot, _NoSlot]()
            comptime if _admits[
                "POST", True, path, R, _NoSlot, _NoSlot, _NoSlot
            ]():
                self._add(
                    _route[_NoSlot, _NoSlot, _NoSlot, R](
                        "POST",
                        path,
                        _Erased.__init__[call=_call_state_0[S, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_0["POST", path](handler, state)

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
        `state`, and each request passes it to `handler` by borrow.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["POST", True, path, R, A, _NoSlot, _NoSlot]()
            comptime if _admits["POST", True, path, R, A, _NoSlot, _NoSlot]():
                self._add(
                    _route[A, _NoSlot, _NoSlot, R](
                        "POST",
                        path,
                        _Erased.__init__[call=_call_state_1[S, A, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_1["POST", path](handler, state)

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
        body. The state is passed as for `post` on `def(State[S], var A)`.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["POST", True, path, R, A, B, _NoSlot]()
            comptime if _admits["POST", True, path, R, A, B, _NoSlot]():
                self._add(
                    _route[A, B, _NoSlot, R](
                        "POST",
                        path,
                        _Erased.__init__[call=_call_state_2[S, A, B, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_2["POST", path](handler, state)

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
        `def(State[S], var A)`.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["POST", True, path, R, A, B, C]()
            comptime if _admits["POST", True, path, R, A, B, C]():
                self._add(
                    _route[A, B, C, R](
                        "POST",
                        path,
                        _Erased.__init__[call=_call_state_3[S, A, B, C, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_3["POST", path](handler, state)

    def put[
        E: Deinitable, R: Movable & Deinitable, //, path: StaticString
    ](mut self, handler: def() thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers a parameterless `handler` for `PUT path`, as `get`
        on `def()` (M3-048): `path` declares no parameter, and the request's
        body is not read."""
        comptime if Self.Ctx == _NoContext:
            _check["PUT", False, path, R, _NoSlot, _NoSlot, _NoSlot]()
            comptime if _admits[
                "PUT", False, path, R, _NoSlot, _NoSlot, _NoSlot
            ]():
                self._add(
                    _route[_NoSlot, _NoSlot, _NoSlot, R](
                        "PUT",
                        path,
                        _Erased.__init__[call=_call_0[E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_0["PUT", path](handler)

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
        `WithHeaders[B2]` carrier with `B2` a `FromBody` or a `FromBytes`,
        which has no conversion of its own: its fields are rebuilt (the
        fixed 500 on failure) and it is built through `_from_parts`, which
        converts the inner body as a bare `B2` is (400 on failure, M3-042);
        the handler also receives the request's header fields, for which
        Muntin chooses no status. A
        `Json[T]` body, alone or in a carrier, is first answered 415 unless
        the request has exactly one `application/json` `Content-Type`, then
        413 when it is over 1 MiB. Every text body's bytes are read as
        UTF-8 before `from_body` (400 if they are not, M3-040). A type
        conforming to `FromBytes` instead receives the body's bytes,
        whatever they are and unread, in `from_bytes` (400 if it raises,
        M3-041; 413 first when they are longer than its `max_bytes`,
        M3-043), alone or in a carrier; a type conforming to both traits is
        rejected. The body may be
        declared `body: B` or
        `var body: B`, and `B` may be move-only. A `Request` parameter
        instead makes a raw handler, as for `get`. Results and raises are
        handled as for `get` on `def()`; this holds for every body shape,
        stateless or stateful.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["PUT", False, path, R, A, _NoSlot, _NoSlot]()
            comptime if _admits["PUT", False, path, R, A, _NoSlot, _NoSlot]():
                self._add(
                    _route[A, _NoSlot, _NoSlot, R](
                        "PUT",
                        path,
                        _Erased.__init__[call=_call_1[A, E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_1["PUT", path](handler)

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
        `def()`.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["PUT", False, path, R, A, B, _NoSlot]()
            comptime if _admits["PUT", False, path, R, A, B, _NoSlot]():
                self._add(
                    _route[A, B, _NoSlot, R](
                        "PUT",
                        path,
                        _Erased.__init__[call=_call_2[A, B, E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_2["PUT", path](handler)

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
        `handler`. Results and raises as for `get` on `def()`.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["PUT", False, path, R, A, B, C]()
            comptime if _admits["PUT", False, path, R, A, B, C]():
                self._add(
                    _route[A, B, C, R](
                        "PUT",
                        path,
                        _Erased.__init__[call=_call_3[A, B, C, E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_3["PUT", path](handler)

    def put[
        S: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self, handler: def(State[S]) thin raises E -> R, state: State[S]
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers a stateful parameterless `handler` for `PUT path`,
        as `get` on `def(State[S])` (M3-048); the request's body is not
        read."""
        comptime if Self.Ctx == _NoContext:
            _check["PUT", True, path, R, _NoSlot, _NoSlot, _NoSlot]()
            comptime if _admits[
                "PUT", True, path, R, _NoSlot, _NoSlot, _NoSlot
            ]():
                self._add(
                    _route[_NoSlot, _NoSlot, _NoSlot, R](
                        "PUT",
                        path,
                        _Erased.__init__[call=_call_state_0[S, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_0["PUT", path](handler, state)

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
        `state`, and each request passes it to `handler` by borrow.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["PUT", True, path, R, A, _NoSlot, _NoSlot]()
            comptime if _admits["PUT", True, path, R, A, _NoSlot, _NoSlot]():
                self._add(
                    _route[A, _NoSlot, _NoSlot, R](
                        "PUT",
                        path,
                        _Erased.__init__[call=_call_state_1[S, A, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_1["PUT", path](handler, state)

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
        body. The state is passed as for `put` on `def(State[S], var A)`.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["PUT", True, path, R, A, B, _NoSlot]()
            comptime if _admits["PUT", True, path, R, A, B, _NoSlot]():
                self._add(
                    _route[A, B, _NoSlot, R](
                        "PUT",
                        path,
                        _Erased.__init__[call=_call_state_2[S, A, B, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_2["PUT", path](handler, state)

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
        `def(State[S], var A)`.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["PUT", True, path, R, A, B, C]()
            comptime if _admits["PUT", True, path, R, A, B, C]():
                self._add(
                    _route[A, B, C, R](
                        "PUT",
                        path,
                        _Erased.__init__[call=_call_state_3[S, A, B, C, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_3["PUT", path](handler, state)

    def patch[
        E: Deinitable, R: Movable & Deinitable, //, path: StaticString
    ](mut self, handler: def() thin raises E -> R) where (
        R == String or R == StaticString or conforms_to(R, ToResponse)
    ):
        """Registers a parameterless `handler` for `PATCH path`, as `get`
        on `def()` (M3-048): `path` declares no parameter, and the request's
        body is not read."""
        comptime if Self.Ctx == _NoContext:
            _check["PATCH", False, path, R, _NoSlot, _NoSlot, _NoSlot]()
            comptime if _admits[
                "PATCH", False, path, R, _NoSlot, _NoSlot, _NoSlot
            ]():
                self._add(
                    _route[_NoSlot, _NoSlot, _NoSlot, R](
                        "PATCH",
                        path,
                        _Erased.__init__[call=_call_0[E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_0["PATCH", path](handler)

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
        `WithHeaders[B2]` carrier with `B2` a `FromBody` or a `FromBytes`,
        which has no conversion of its own: its fields are rebuilt (the
        fixed 500 on failure) and it is built through `_from_parts`, which
        converts the inner body as a bare `B2` is (400 on failure, M3-042);
        the handler also receives the request's header fields, for which
        Muntin chooses no status. A
        `Json[T]` body, alone or in a carrier, is first answered 415 unless
        the request has exactly one `application/json` `Content-Type`, then
        413 when it is over 1 MiB. Every text body's bytes are read as
        UTF-8 before `from_body` (400 if they are not, M3-040). A type
        conforming to `FromBytes` instead receives the body's bytes,
        whatever they are and unread, in `from_bytes` (400 if it raises,
        M3-041; 413 first when they are longer than its `max_bytes`,
        M3-043), alone or in a carrier; a type conforming to both traits is
        rejected. The body may be
        declared `body: B` or
        `var body: B`, and `B` may be move-only. A `Request` parameter
        instead makes a raw handler, as for `get`. Results and raises are
        handled as for `get` on `def()`; this holds for every body shape,
        stateless or stateful.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["PATCH", False, path, R, A, _NoSlot, _NoSlot]()
            comptime if _admits["PATCH", False, path, R, A, _NoSlot, _NoSlot]():
                self._add(
                    _route[A, _NoSlot, _NoSlot, R](
                        "PATCH",
                        path,
                        _Erased.__init__[call=_call_1[A, E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_1["PATCH", path](handler)

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
        `def()`.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["PATCH", False, path, R, A, B, _NoSlot]()
            comptime if _admits["PATCH", False, path, R, A, B, _NoSlot]():
                self._add(
                    _route[A, B, _NoSlot, R](
                        "PATCH",
                        path,
                        _Erased.__init__[call=_call_2[A, B, E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_2["PATCH", path](handler)

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
        `handler`. Results and raises as for `get` on `def()`.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["PATCH", False, path, R, A, B, C]()
            comptime if _admits["PATCH", False, path, R, A, B, C]():
                self._add(
                    _route[A, B, C, R](
                        "PATCH",
                        path,
                        _Erased.__init__[call=_call_3[A, B, C, E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_3["PATCH", path](handler)

    def patch[
        S: Movable & Deinitable,
        E: Deinitable,
        R: Movable & Deinitable,
        //,
        path: StaticString,
    ](
        mut self, handler: def(State[S]) thin raises E -> R, state: State[S]
    ) where (R == String or R == StaticString or conforms_to(R, ToResponse)):
        """Registers a stateful parameterless `handler` for `PATCH path`,
        as `get` on `def(State[S])` (M3-048); the request's body is not
        read."""
        comptime if Self.Ctx == _NoContext:
            _check["PATCH", True, path, R, _NoSlot, _NoSlot, _NoSlot]()
            comptime if _admits[
                "PATCH", True, path, R, _NoSlot, _NoSlot, _NoSlot
            ]():
                self._add(
                    _route[_NoSlot, _NoSlot, _NoSlot, R](
                        "PATCH",
                        path,
                        _Erased.__init__[call=_call_state_0[S, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_0["PATCH", path](handler, state)

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
        `state`, and each request passes it to `handler` by borrow.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["PATCH", True, path, R, A, _NoSlot, _NoSlot]()
            comptime if _admits["PATCH", True, path, R, A, _NoSlot, _NoSlot]():
                self._add(
                    _route[A, _NoSlot, _NoSlot, R](
                        "PATCH",
                        path,
                        _Erased.__init__[call=_call_state_1[S, A, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_1["PATCH", path](handler, state)

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
        body. The state is passed as for `patch` on `def(State[S], var A)`.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["PATCH", True, path, R, A, B, _NoSlot]()
            comptime if _admits["PATCH", True, path, R, A, B, _NoSlot]():
                self._add(
                    _route[A, B, _NoSlot, R](
                        "PATCH",
                        path,
                        _Erased.__init__[call=_call_state_2[S, A, B, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_2["PATCH", path](handler, state)

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
        `def(State[S], var A)`.

        A handler whose parameters are only route values and a `Headers`
        last is bodyless and takes `get`'s shape of this arity instead
        (M3-048)."""
        comptime if Self.Ctx == _NoContext:
            _check["PATCH", True, path, R, A, B, C]()
            comptime if _admits["PATCH", True, path, R, A, B, C]():
                self._add(
                    _route[A, B, C, R](
                        "PATCH",
                        path,
                        _Erased.__init__[call=_call_state_3[S, A, B, C, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_3["PATCH", path](handler, state)

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
        comptime if Self.Ctx == _NoContext:
            _check["DELETE", False, path, R, _NoSlot, _NoSlot, _NoSlot]()
            comptime if _admits[
                "DELETE", False, path, R, _NoSlot, _NoSlot, _NoSlot
            ]():
                self._add(
                    _route[_NoSlot, _NoSlot, _NoSlot, R](
                        "DELETE",
                        path,
                        _Erased.__init__[call=_call_0[E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_0["DELETE", path](handler)

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
        comptime if Self.Ctx == _NoContext:
            _check["DELETE", False, path, R, A, _NoSlot, _NoSlot]()
            comptime if _admits[
                "DELETE", False, path, R, A, _NoSlot, _NoSlot
            ]():
                self._add(
                    _route[A, _NoSlot, _NoSlot, R](
                        "DELETE",
                        path,
                        _Erased.__init__[call=_call_1[A, E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_1["DELETE", path](handler)

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
        comptime if Self.Ctx == _NoContext:
            _check["DELETE", False, path, R, A, B, _NoSlot]()
            comptime if _admits["DELETE", False, path, R, A, B, _NoSlot]():
                self._add(
                    _route[A, B, _NoSlot, R](
                        "DELETE",
                        path,
                        _Erased.__init__[call=_call_2[A, B, E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_2["DELETE", path](handler)

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
        comptime if Self.Ctx == _NoContext:
            _check["DELETE", False, path, R, A, B, C]()
            comptime if _admits["DELETE", False, path, R, A, B, C]():
                self._add(
                    _route[A, B, C, R](
                        "DELETE",
                        path,
                        _Erased.__init__[call=_call_3[A, B, C, E, R]](handler),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_3["DELETE", path](handler)

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
        comptime if Self.Ctx == _NoContext:
            _check["DELETE", True, path, R, _NoSlot, _NoSlot, _NoSlot]()
            comptime if _admits[
                "DELETE", True, path, R, _NoSlot, _NoSlot, _NoSlot
            ]():
                self._add(
                    _route[_NoSlot, _NoSlot, _NoSlot, R](
                        "DELETE",
                        path,
                        _Erased.__init__[call=_call_state_0[S, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_0["DELETE", path](handler, state)

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
        comptime if Self.Ctx == _NoContext:
            _check["DELETE", True, path, R, A, _NoSlot, _NoSlot]()
            comptime if _admits["DELETE", True, path, R, A, _NoSlot, _NoSlot]():
                self._add(
                    _route[A, _NoSlot, _NoSlot, R](
                        "DELETE",
                        path,
                        _Erased.__init__[call=_call_state_1[S, A, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_1["DELETE", path](handler, state)

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
        comptime if Self.Ctx == _NoContext:
            _check["DELETE", True, path, R, A, B, _NoSlot]()
            comptime if _admits["DELETE", True, path, R, A, B, _NoSlot]():
                self._add(
                    _route[A, B, _NoSlot, R](
                        "DELETE",
                        path,
                        _Erased.__init__[call=_call_state_2[S, A, B, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_2["DELETE", path](handler, state)

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
        comptime if Self.Ctx == _NoContext:
            _check["DELETE", True, path, R, A, B, C]()
            comptime if _admits["DELETE", True, path, R, A, B, C]():
                self._add(
                    _route[A, B, C, R](
                        "DELETE",
                        path,
                        _Erased.__init__[call=_call_state_3[S, A, B, C, E, R]](
                            _Bound(handler, state)
                        ),
                    )
                )
            else:
                abort(_GUARD_DRIFT)
        else:
            self._guarded_state_3["DELETE", path](handler, state)

    def handle(self, request: Request) -> Response:
        """Answers `request` through the application's middleware and routes.

        This is the backend seam: every transport (the in-memory TestClient,
        network adapters) delivers requests through this method or its owning
        overload below. With no middleware registered, the routes answer the
        borrowed request directly (`_dispatch`). Otherwise the request is
        copied once, its body bytes included, and passed to the first
        middleware; each `Next.run` passes it on to the next one, and the last
        one's to the routes (`_run`, M3-034). What follows is the routes'
        answer.

        The first registered route whose method and path match handles the
        request, raw or typed; the query takes no part in selecting it.
        Registration refuses a route that an earlier, not more specific route
        of its method overlaps (`_add`, M3-053), so that route is the most
        specific match. Methods match
        byte for byte, except that a `HEAD` request also matches a `GET`
        route and runs the `GET` route's steps: a typed handler receives the
        same arguments as for the `GET`, a raw handler the `HEAD` request
        itself. The answer keeps its body; keeping the content off the wire
        is the backend's (M3-026). Every route receives `request.body`, the
        body bytes, borrowed beside its raw arguments; nothing here reads or
        converts them (M3-040). A raw route
        receives `request.method`, `path` and `query`, then each
        header field's name and value, as its raw arguments, and nothing else
        runs (no query gathering, no conversion); the adapter's `Request`
        slot rebuilds the `Request` with a copy of the body bytes
        (`_raw_request`). A typed
        route receives no headers unless its body is a `WithHeaders[B]`
        carrier, its last slot is `Headers` (`_Route.headers`) or it belongs
        to a `Group` (`_Route.guarded`, M3-080), whose route also receives a
        verdict last and answers the 400s below only after its guard. A text
        body route's adapter reads the body bytes as UTF-8 in its body slot
        (`_slot`), converts the text and answers 400 itself if either fails;
        a `FromBytes` body route's adapter, bare or in a carrier, answers
        413 when they are longer than the type's `max_bytes` (M3-043), then
        passes them to `from_bytes` unread and answers 400 if it raises
        (M3-041, M3-042).
        A JSON body route (`_Route.json`) also receives the request's
        `Content-Type` verdict after its route values, for the body slot's
        415 step. A carrier route then receives each header field's name
        and value, in order, after its route values and any verdict; a
        `Headers` route, after its route values if it has any.

        A typed route's route values are percent-decoded once here, after
        matching on the raw path and before any conversion (`_decode_value`):
        the path captures in place, left to right, then each query value
        after `_query_value` finds it, in the literal's order (M3-022). For
        a key whose value binds an `Optional` slot (`_Route.query_optional`,
        M3-025), an absent key or an empty value is passed on as `""`
        instead. Query keys, `request.path`, `request.query` and raw routes
        are never decoded.

        When no route matches the method and path, the answer is 405
        `Method Not Allowed` if some route matches the path (`_match`), with
        one `Allow` field listing those routes' methods once, in the order
        their first such route was registered, `HEAD` right after `GET`
        (`_allowed`, M3-030); otherwise it is 404 `Not Found`. Neither
        decodes, converts or runs a handler. A duplicated query key, a
        missing or empty required value, a bad escape or decoded text that
        is not UTF-8 is 400 here; the adapter answers its own 400s and turns
        a handler error into a response (`_handler_error`). A raise out of
        `invoke` is 500, never 400.
        """
        comptime assert Self.Ctx == _NoContext, "a Group is mounted, not served"
        return self._core.handle(request)

    def handle(self, var request: Request) -> Response:
        """Answers `request` as the borrowing `handle` does, taking it from
        the caller (M3-064): with middleware registered, the request itself,
        its body buffer included, is moved to the first middleware instead of
        copied. Mojo picks this overload for a temporary or `request^`, the
        borrowing one for a named value. Without middleware both answer
        through the same `_dispatch`."""
        comptime assert Self.Ctx == _NoContext, "a Group is mounted, not served"
        return self._core.handle(request^)
