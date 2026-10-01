"""Muntin application: route registration and request dispatch."""

from std.os import abort
from std.utils import Variant

from .http import Request, Response

# Handler shapes App can store. Mojo 1.1.0 function types spelled without
# `thin` are traits and cannot be stored, so handlers are thin function values;
# ordinary `def` functions convert implicitly. The set is closed: a Variant
# holds each shape with its own static type, so no handler is ever erased or
# reinterpreted. Each new shape is a new arm here and in `App.handle`. Where
# a value comes from (path segment or query key) is route data, not part of
# the shape, so `_IntArg` serves both `/users/{id}` and `/items?{limit}`.
comptime _NoArgs = def() thin -> String
comptime _IntArg = def(Int) thin -> String
comptime _Handler = Variant[_NoArgs, _IntArg]


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
    non-empty and contains none of `{}=&?#`, since a key containing those
    could never equal a key in a request's query.
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
        for c in ["{", "}", "=", "&", "?", "#"]:
            if key.find(c) >= 0:
                return -1
        n += 1
    return n


def _match(route: String, path: String, mut captured: String) -> Bool:
    """Matches `path` against `route` segment by segment.

    Static segments must be equal; a `{name}` segment matches one non-empty
    segment, which is stored in `captured`. Routes hold at most one parameter
    (enforced at registration).
    """
    var want = route.split("/")
    var got = path.split("/")
    if len(want) != len(got):
        return False
    for i in range(len(want)):
        if _is_param(want[i]):
            if got[i].byte_length() == 0:
                return False
            captured = String(got[i])
        elif want[i] != got[i]:
            return False
    return True


def _parse_int(segment: String) raises -> Int:
    """Converts a path segment to `Int`: an optional `-` followed by one or
    more ASCII digits, within `Int` range. Anything else raises.

    `Int(String)` alone also accepts `+`, surrounding whitespace and `_`
    separators, which are not part of Muntin's path syntax.
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


struct _Route(Copyable, Movable):
    var method: String
    var path: String
    """Path part of the route literal; the only part requests are matched
    against."""
    var query_key: String
    """Key of the route's `{key}` query parameter, or empty if it has none."""
    var handler: _Handler

    def __init__(
        out self, method: String, route: StaticString, handler: _Handler
    ):
        """Splits `route` like `Request` splits a target: at its first `?`."""
        self.method = method
        var mark = route.find("?")
        if mark < 0:
            self.path = String(route)
            self.query_key = String()
        else:
            self.path = String(route[byte=:mark])
            # The query part is exactly one `{key}` (checked in `App.get`).
            self.query_key = String(
                route[byte = mark + 2 : route.byte_length() - 1]
            )
        self.handler = handler


struct App(Movable):
    """A Muntin application: a set of routes and the dispatch entry point."""

    var _routes: List[_Route]

    def __init__(out self):
        self._routes = List[_Route]()

    def get[path: StaticString](mut self, handler: def() thin -> String):
        """Registers `handler` for `GET path`; its String result becomes a
        200 text response."""
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert (
            _path_params(path) == 0
        ), "route declares a path parameter but the handler takes none"
        comptime assert (
            _query_params(path) == 0
        ), "route declares a query parameter but the handler takes none"
        self._routes.append(_Route("GET", path, handler))

    def get[path: StaticString](mut self, handler: def(Int) thin -> String):
        """Registers `handler` for `GET path`, where `path` declares exactly
        one parameter: a `{name}` segment (`/users/{id}`) or a `{key}` query
        item (`/items?{limit}`). Its value is converted to `Int` and passed
        to `handler` by position (names are not checked against the handler);
        a missing, duplicated or non-integer value yields 400 without calling
        `handler`."""
        comptime assert (
            _path_params(path) >= 0 and _query_params(path) >= 0
        ), "malformed route literal"
        comptime assert _path_params(path) + _query_params(path) == 1, (
            "handler takes one Int parameter; route must declare exactly one"
            " path or query parameter"
        )
        self._routes.append(_Route("GET", path, handler))

    def handle(self, request: Request) -> Response:
        """Dispatches `request` through the application's routes.

        This is the backend seam: every transport (the in-memory TestClient,
        network adapters) delivers requests through this method. The first
        registered route whose method and path match handles the request;
        the query takes no part in selecting it.
        """
        var captured = String()
        for route in self._routes:
            if route.method != request.method or not _match(
                route.path, request.path, captured
            ):
                continue
            if route.handler.isa[_NoArgs]():
                return Response.text(route.handler[_NoArgs]())
            if route.handler.isa[_IntArg]():
                var value: Int
                try:
                    if route.query_key:
                        value = _parse_int(
                            _query_value(request.query, route.query_key)
                        )
                    else:
                        value = _parse_int(captured)
                except:
                    return Response.text("Bad Request", status=400)
                return Response.text(route.handler[_IntArg](value))
            abort("muntin: unhandled handler shape")
        return Response.text("Not Found", status=404)
