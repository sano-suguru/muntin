"""Registration rules: the checks of a handler's shape and route literal
that `App`'s registration overloads (`app.mojo`) run, and the route-literal
grammar they share with route construction and request matching.

`_kind` classifies a request slot from its type alone; `_rule` returns the
first registration rule a shape breaks; `_check` states each rule as a
compile-time assert with Muntin's message, and `_admits`, the same rules as
one Bool, guards the adapter's instantiation.

The route-literal grammar is the primitives `_split_literal` (the path and
query parts, at the first `?`); `_path_part` (the path part) and `_query_items`
(the query part split at `&`), which read that split; `_is_param` (whether a
segment or item has a placeholder's outer shape: `{`, a non-empty interior,
`}`); and `_param_name` (the text between those braces). `_is_param` recognizes
the brace shape and `_param_name` strips it, so both know it; a test checks
that they agree. The rules' parsers (`_path_params`, `_query_params`,
`_distinct_query_keys`) validate and count through them at compile time, and
`_route` in `app.mojo` also calls `_path_params` at registration;
`_Route.__init__` in `app.mojo` splits a literal into its matched path and
query keys through `_path_part`, `_query_items` and `_param_name` at
registration; and `_match` in `app.mojo` classifies each route segment with
`_is_param` per request. The `/` segment separator is written both in
`_path_params` and in `_match`, which splits the request path with it too.
"""

from .body import FromBody, FromBytes
from .headers_body import _HeaderCarrier
from .http import Headers, Request, Response
from .state import _InjectedState


def _split_literal(
    route: StaticString,
) -> Tuple[StaticString, Optional[StaticString]]:
    """A route literal's path part and query part, split at its first `?`:
    the query part is `None` without a `?`, and empty for a `?` with nothing
    after it. `_path_part` and `_query_items` read the split from here."""
    var mark = route.find("?")
    if mark < 0:
        return (route, None)
    return (route[byte=:mark], route[byte = mark + 1 :])


def _path_part(route: StaticString) -> StaticString:
    """The path part of a route literal (`_split_literal`). Requests are
    matched against it."""
    return _split_literal(route)[0]


def _query_items(route: StaticString) -> List[StaticString]:
    """The query part of a route literal (`_split_literal`) split at `&`, in
    the literal's order. Empty without a query part; an empty query part
    gives one empty item, which no `{key}` is."""
    var query = _split_literal(route)[1]
    if not query:
        return List[StaticString]()
    return query.value().split("&")


def _is_param(segment: StringSlice) -> Bool:
    """Whether a path segment or query item has a placeholder's outer shape:
    `{`, a non-empty interior, `}`; the parsers check the rest of validity.

    The classification the registration rules' parsers (`_path_params`,
    `_query_params`) and `_match` (for every request) share, so registration
    and dispatch agree on how many values a route captures.
    """
    var b = segment.as_bytes()
    return (
        len(b) > 2 and Int(b[0]) == ord("{") and Int(b[len(b) - 1]) == ord("}")
    )


def _param_name(item: StaticString) -> StaticString:
    """The text between the outer braces of an item `_is_param` accepts: a
    placeholder's name once the parsers accepted it."""
    return item[byte = 1 : item.byte_length() - 1]


def _path_params(route: StaticString) -> Int:
    """Number of `{name}` segments in the path part of a route literal (the
    text before any `?`), or -1 if malformed.

    The path starts with `/`; a segment containing `{` or `}` must be exactly
    `{name}` with a non-empty name.
    """
    var path = _path_part(route)
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
    var n = 0
    for item in _query_items(route):
        if not _is_param(item):
            return -1
        var key = _param_name(item)
        for b in key.as_bytes():
            if Int(b) < ord("!") or Int(b) > ord("~"):
                return -1
        for c in ["{", "}", "=", "&", "?", "#"]:
            if key.find(c) >= 0:
                return -1
        n += 1
    return n


def _distinct_query_keys(route: StaticString) -> Bool:
    """Whether the `{key}` items of a well-formed route literal's query part
    all differ (M3-022). Keys compare byte for byte, undecoded, as requests'
    keys do; path names are not compared."""
    var keys = _query_items(route)
    for i in range(len(keys)):
        for j in range(i):
            if keys[i] == keys[j]:
                return False
    return True


struct _NoSlot:
    """Stands for an absent request slot in `_rule`'s parameters."""

    pass


# Request-slot kinds (`_kind`).
comptime _ABSENT = 0
comptime _INT = 1
comptime _BODY = 2
comptime _RAW = 3
comptime _STATE = 4
comptime _OTHER = 5
comptime _HEADERS = 6
comptime _TEXT = 7
comptime _OPT_INT = 8
comptime _OPT_TEXT = 9
comptime _TWO_BODIES = 10


def _kind[A: AnyType]() -> Int:
    """The kind of a request slot of type `A`, from its type alone: type
    equality (exact here, as these types carry no origin) for the types
    that cannot conform to a Muntin trait, `conforms_to` for the rest. A
    body is a `FromBody`, a `FromBytes` (M3-041) or a carrier; a type that
    is both a `FromBody` and a `FromBytes` is a body with two conversions
    (`_TWO_BODIES`), which the rules reject wherever a body is."""
    comptime if A == _NoSlot:
        return _ABSENT
    elif A == Int:
        return _INT
    elif A == Request:
        return _RAW
    elif A == Headers:
        return _HEADERS
    elif A == String:
        return _TEXT
    elif A == Optional[Int]:
        return _OPT_INT
    elif A == Optional[String]:
        return _OPT_TEXT
    elif conforms_to(A, _InjectedState):
        return _STATE
    elif conforms_to(A, FromBody) and conforms_to(A, FromBytes):
        return _TWO_BODIES
    elif (
        conforms_to(A, FromBody)
        or conforms_to(A, FromBytes)
        or conforms_to(A, _HeaderCarrier)
    ):
        return _BODY
    else:
        return _OTHER


# Registration rules (`_rule`): `_OK`, or the first rule a shape breaks.
comptime _OK = 0
comptime _MALFORMED = 1
comptime _PATH_TAKES_NONE = 2
comptime _QUERY_TAKES_NONE = 3
comptime _GET_INT_PLACES = 4
comptime _GET_STATE_ARGUMENT = 5
comptime _GET_RAW = 6
comptime _GET_STATE_RAW = 7
comptime _GET_BODY = 8
comptime _GET_SLOT_KIND = 9
comptime _POST_NO_BODY = 11
comptime _POST_BODY_PLACES = 12
comptime _POST_INT_BODY_PLACES = 13
comptime _INT_AS_BODY = 14
comptime _REQUEST_AS_BODY = 15
comptime _STATE_REQUEST_AS_BODY = 16
comptime _POST_STATE_ARGUMENT = 17
comptime _ONE_STATE = 18
comptime _BODY_TYPE = 19
comptime _LAST_BODY_TYPE = 20
comptime _POST_RAW = 21
comptime _POST_STATE_RAW = 22
comptime _POST_BODY_LAST = 23
comptime _POST_SLOT_KIND = 24
comptime _GET_HEADERS_LAST = 25
comptime _GET_TEXT_PLACES = 26
comptime _POST_TEXT_BODY_PLACES = 28
comptime _GET_TWO_PLACES = 29
comptime _POST_TWO_PLACES = 30
comptime _GET_THREE_VALUES = 31
comptime _QUERY_TWICE = 32
comptime _GET_OPTIONAL_PLACES = 33
comptime _POST_OPTIONAL_BODY_PLACES = 34
comptime _OPTIONAL_AT_PATH = 35
comptime _BODY_TWO_CONVERSIONS = 36


def _takes_none(paths: Int, queries: Int) -> Int:
    """The placeholder rule for a handler that takes no route value."""
    if paths != 0:
        return _PATH_TAKES_NONE
    if queries != 0:
        return _QUERY_TAKES_NONE
    return _OK


def _is_body(k: Int) -> Bool:
    """Whether slot kind `k` is a body, with one conversion or two."""
    return k == _BODY or k == _TWO_BODIES


def _is_value(k: Int) -> Bool:
    """Whether slot kind `k` is a route value (`Int`, `String` or an
    `Optional` of either)."""
    return k == _INT or k == _TEXT or _is_optional(k)


def _is_optional(k: Int) -> Bool:
    """Whether slot kind `k` is an optional route value (M3-024)."""
    return k == _OPT_INT or k == _OPT_TEXT


def _optional_at_path(k1: Int, k2: Int, paths: Int) -> Bool:
    """Whether an optional value among two (`k1`, `k2`) would bind a path
    placeholder: the value at position `j` binds one when `j < paths`."""
    return (_is_optional(k1) and paths > 0) or (_is_optional(k2) and paths > 1)


def _get_rule(
    stateful: Bool,
    k1: Int,
    k2: Int,
    k3: Int,
    response: Bool,
    paths: Int,
    queries: Int,
) -> Int:
    """`get`'s rules for slot kinds `k1`, `k2`, `k3` (`_ABSENT` when
    missing): `def()` or `def(Headers)` with no placeholder, `def(V)` or
    `def(V, Headers)` with exactly one, `def(V, V)` or `def(V, V, Headers)`
    with exactly two (M3-022), `V` an `Int` or `String` route value or an
    `Optional` of either (M3-024), or the raw `def(Request) -> Response`
    with none. A `State` slot comes first, then a `Request` anywhere, a
    body, a parameter of no kind, a misplaced `Headers`, three route values,
    then the placeholder count: for one value with the `Int`, `String` or
    `Optional` message (an optional value needs exactly one query
    placeholder and no path one), for two with one message whatever their
    types, then an optional value at a path position."""
    if k1 == _STATE or k2 == _STATE or k3 == _STATE:
        return _ONE_STATE if stateful else _GET_STATE_ARGUMENT
    if k1 == _RAW or k2 == _RAW or k3 == _RAW:
        if k1 != _RAW or k2 != _ABSENT or not response:
            return _GET_STATE_RAW if stateful else _GET_RAW
        return _takes_none(paths, queries)
    if _is_body(k1) or _is_body(k2) or _is_body(k3):
        return _GET_BODY
    if k1 == _OTHER or k2 == _OTHER or k3 == _OTHER:
        return _GET_SLOT_KIND
    if (k1 == _HEADERS and k2 != _ABSENT) or (k2 == _HEADERS and k3 != _ABSENT):
        return _GET_HEADERS_LAST
    # Every slot is now a route value, or `Headers` last.
    if _is_value(k3):
        return _GET_THREE_VALUES
    if _is_value(k2):  # two values, alone or before `Headers`
        if paths + queries != 2:
            return _GET_TWO_PLACES
        if _optional_at_path(k1, k2, paths):
            return _OPTIONAL_AT_PATH
        return _OK
    if _is_value(k1):  # one value, alone or before `Headers`
        if _is_optional(k1):
            if paths == 0 and queries == 1:
                return _OK
            return _GET_OPTIONAL_PLACES
        if paths + queries == 1:
            return _OK
        return _GET_INT_PLACES if k1 == _INT else _GET_TEXT_PLACES
    return _takes_none(paths, queries)


def _post_rule(
    stateful: Bool,
    k1: Int,
    k2: Int,
    k3: Int,
    response: Bool,
    paths: Int,
    queries: Int,
) -> Int:
    """`post`'s rules for slot kinds `k1`, `k2`, `k3` (`_ABSENT` when
    missing): `def(B)` with no placeholder, `def(V, B)` with exactly one,
    `def(V, V, B)` with exactly two (M3-022), `V` an `Int` or `String` route
    value or an `Optional` of either (M3-024), or the raw
    `def(Request) -> Response` with none. The order
    decides which message a shape that breaks several rules gets: a raw
    handler returning `Response` gets the raw placeholder messages; for any
    other `def(X)` (a `Request` or a `String` included), the placeholders
    and then `X`. With more slots, each rule is checked over every slot
    before the last before the next rule: a `Request`, a `State`, a body, a
    slot of no kind or a `Headers`; then the placeholders, with the `Int`,
    `String` or `Optional` message for one value, and for two one message,
    then an optional value at a path position; then the last slot `X`,
    which is the body position, where a type with two body conversions
    (`_TWO_BODIES`) gets its own message."""
    if k1 == _ABSENT:
        return _POST_NO_BODY
    if k1 == _RAW and k2 == _ABSENT:
        if response:
            return _takes_none(paths, queries)
        if paths + queries != 0:
            return _POST_BODY_PLACES
        return _STATE_REQUEST_AS_BODY if stateful else _REQUEST_AS_BODY
    # The slots before the last one (`_ABSENT` where there is none).
    var a = k1 if k2 != _ABSENT else _ABSENT
    var b = k2 if k3 != _ABSENT else _ABSENT
    var body = k3 if k3 != _ABSENT else (k2 if k2 != _ABSENT else k1)
    if a == _RAW or b == _RAW:
        return _POST_STATE_RAW if stateful else _POST_RAW
    if a == _STATE or b == _STATE:
        return _ONE_STATE if stateful else _POST_STATE_ARGUMENT
    if _is_body(a) or _is_body(b):
        return _POST_BODY_LAST
    if a == _OTHER or a == _HEADERS or b == _OTHER or b == _HEADERS:
        return _POST_SLOT_KIND
    if b != _ABSENT:  # two route values
        if paths + queries != 2:
            return _POST_TWO_PLACES
        if _optional_at_path(a, b, paths):
            return _OPTIONAL_AT_PATH
    elif a != _ABSENT:  # one route value
        if _is_optional(a):
            if paths != 0 or queries != 1:
                return _POST_OPTIONAL_BODY_PLACES
        elif paths + queries != 1:
            return (
                _POST_INT_BODY_PLACES if k1 == _INT else _POST_TEXT_BODY_PLACES
            )
    elif paths + queries != 0:
        return _POST_BODY_PLACES
    if body == _INT:
        return _INT_AS_BODY
    if body == _RAW:
        return _STATE_REQUEST_AS_BODY if stateful else _REQUEST_AS_BODY
    if body == _STATE:
        return _ONE_STATE if stateful else _POST_STATE_ARGUMENT
    if body == _TWO_BODIES:
        return _BODY_TWO_CONVERSIONS
    if body != _BODY:
        return _LAST_BODY_TYPE if stateful or k2 != _ABSENT else _BODY_TYPE
    return _OK


def _rule[
    method: StaticString,
    stateful: Bool,
    path: StaticString,
    R: AnyType,
    A: AnyType,
    B: AnyType,
    C: AnyType,
]() -> Int:
    """The first registration rule a handler breaks, or `_OK`: `method` is
    the registration's HTTP method, `stateful` the family, `A`, `B` and `C`
    the request slots' types (`_NoSlot` when absent) and `R` the result
    type. `"GET"` and `"DELETE"` take `get`'s rules, `"POST"`, `"PUT"` and
    `"PATCH"` take `post`'s (M3-020). A shape that passes them all on a
    literal that repeats a query key breaks the last rule (M3-022). The
    result rule itself is each overload's `where` clause."""
    var paths = _path_params(path)
    var queries = _query_params(path)
    if paths < 0 or queries < 0:
        return _MALFORMED
    var k1 = _kind[A]()
    var k2 = _kind[B]()
    var k3 = _kind[C]()
    var rule: Int
    if method == "GET" or method == "DELETE":
        rule = _get_rule(stateful, k1, k2, k3, R == Response, paths, queries)
    else:
        rule = _post_rule(stateful, k1, k2, k3, R == Response, paths, queries)
    if rule == _OK and not _distinct_query_keys(path):
        return _QUERY_TWICE
    return rule


def _admits[
    method: StaticString,
    stateful: Bool,
    path: StaticString,
    R: AnyType,
    A: AnyType,
    B: AnyType,
    C: AnyType,
]() -> Bool:
    """`_check` as one Bool: the guard of the adapter's instantiation."""
    return _rule[method, stateful, path, R, A, B, C]() == _OK


def _check[
    method: StaticString,
    stateful: Bool,
    path: StaticString,
    R: AnyType,
    A: AnyType,
    B: AnyType,
    C: AnyType,
]():
    """Every registration rule as a compile-time assert with Muntin's
    message. A message that names the method names the registration's
    (`get`, `delete`, `post`, `put`, `patch`; M3-020)."""
    comptime rule = _rule[method, stateful, path, R, A, B, C]()
    comptime name = String(method).lower()
    comptime assert rule != _MALFORMED, "malformed route literal"
    comptime assert (
        rule != _PATH_TAKES_NONE
    ), "route declares a path parameter but the handler takes none"
    comptime assert (
        rule != _QUERY_TAKES_NONE
    ), "route declares a query parameter but the handler takes none"
    comptime assert rule != _GET_INT_PLACES, (
        "handler takes one Int parameter; route must declare exactly one"
        " path or query parameter"
    )
    comptime assert rule != _GET_STATE_ARGUMENT, (
        "State is injected application state; a stateful "
        + name
        + " handler takes State first, and the state is the registration's"
        " second argument"
    )
    comptime assert rule != _GET_RAW, (
        "a raw " + name + " handler takes only the Request and returns Response"
    )
    comptime assert rule != _GET_STATE_RAW, (
        "a stateful raw "
        + name
        + " handler takes State first, then only the Request, and returns"
        " Response"
    )
    comptime assert rule != _GET_BODY, (
        "a " + name + " handler takes no request body"
    )
    comptime assert rule != _GET_SLOT_KIND, (
        "a "
        + name
        + " handler's parameter is an Int or String route value, an Optional"
        " of one, the request Headers or, for a raw handler, the Request"
    )
    comptime assert rule != _POST_NO_BODY, (
        "a " + name + " handler takes the request body as its last parameter"
    )
    comptime assert rule != _POST_BODY_PLACES, (
        "handler takes only the request body; route must declare no path"
        " or query parameter"
    )
    comptime assert rule != _POST_INT_BODY_PLACES, (
        "handler takes one Int parameter and the request body; route must"
        " declare exactly one path or query parameter"
    )
    comptime assert rule != _INT_AS_BODY, (
        "Int is a route-value type, never the request body; the body"
        " parameter's type must conform to FromBody or FromBytes"
    )
    comptime assert rule != _REQUEST_AS_BODY, (
        "Request is the whole request, not a body; a raw handler takes"
        " only the Request and returns Response"
    )
    comptime assert rule != _STATE_REQUEST_AS_BODY, (
        "Request is the whole request, not a body; a stateful raw handler"
        " takes State first, then only the Request, and returns Response"
    )
    comptime assert rule != _POST_STATE_ARGUMENT, (
        "State is injected application state, not the request body; a stateful "
        + name
        + " handler takes State first and the body last, and the state is"
        " the registration's second argument"
    )
    comptime assert (
        rule != _ONE_STATE
    ), "a handler takes at most one State, as its first parameter"
    comptime assert rule != _BODY_TYPE, (
        "the handler's parameter is the request body; its type must"
        " conform to FromBody or FromBytes"
    )
    comptime assert rule != _LAST_BODY_TYPE, (
        "the handler's last parameter is the request body; its type must"
        " conform to FromBody or FromBytes"
    )
    comptime assert rule != _POST_RAW, (
        "a raw " + name + " handler takes only the Request and returns Response"
    )
    comptime assert rule != _POST_STATE_RAW, (
        "a stateful raw "
        + name
        + " handler takes State first, then only the Request, and returns"
        " Response"
    )
    comptime assert rule != _POST_BODY_LAST, (
        "a " + name + " handler takes one request body, as its last parameter"
    )
    comptime assert rule != _POST_SLOT_KIND, (
        "a "
        + name
        + " handler's parameter before the body is a route value: an Int, a"
        " String or an Optional of either"
    )
    comptime assert rule != _GET_HEADERS_LAST, (
        "a " + name + " handler takes one Headers, as its last parameter"
    )
    comptime assert rule != _GET_TEXT_PLACES, (
        "handler takes one String parameter; route must declare exactly one"
        " path or query parameter"
    )
    comptime assert rule != _POST_TEXT_BODY_PLACES, (
        "handler takes one String parameter and the request body; route"
        " must declare exactly one path or query parameter"
    )
    comptime assert rule != _GET_TWO_PLACES, (
        "handler takes two route values; route must declare exactly two path"
        " or query parameters"
    )
    comptime assert rule != _POST_TWO_PLACES, (
        "handler takes two route values and the request body; route must"
        " declare exactly two path or query parameters"
    )
    comptime assert rule != _GET_THREE_VALUES, (
        "a " + name + " handler takes at most two route values"
    )
    comptime assert (
        rule != _QUERY_TWICE
    ), "route declares a query parameter twice"
    comptime assert rule != _GET_OPTIONAL_PLACES, (
        "handler takes one Optional route value; route must declare exactly"
        " one query parameter and no path parameter"
    )
    comptime assert rule != _POST_OPTIONAL_BODY_PLACES, (
        "handler takes one Optional route value and the request body; route"
        " must declare exactly one query parameter and no path parameter"
    )
    comptime assert rule != _OPTIONAL_AT_PATH, (
        "an Optional route value binds a query parameter; route values bind"
        " the path parameters first, then the query parameters"
    )
    comptime assert rule != _BODY_TWO_CONVERSIONS, (
        "the request body's type conforms to both FromBody and FromBytes;"
        " a body type conforms to one of them"
    )
    comptime assert rule == _OK, "internal: a registration rule has no message"
