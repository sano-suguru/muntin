"""Muntin application: route registration and request dispatch."""

from std.utils import Variant

from .http import Request, Response

# Handler shapes App can store. Mojo 1.1.0 function types spelled without
# `thin` are traits and cannot be stored, so handlers are thin function values;
# ordinary `def` functions convert implicitly. The set is closed: a Variant
# holds each shape with its own static type, so no handler is ever erased or
# reinterpreted. Each new shape is a new arm here and in `App.handle`.
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


def _route_params(path: StaticString) -> Int:
    """Number of `{name}` segments in a route literal, or -1 if malformed.

    A route starts with `/`; a segment containing `{` or `}` must be exactly
    `{name}` with a non-empty name.
    """
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


struct _Route(Copyable, Movable):
    var method: String
    var path: String
    var handler: _Handler

    def __init__(out self, method: String, path: String, handler: _Handler):
        self.method = method
        self.path = path
        self.handler = handler


struct App(Movable):
    """A Muntin application: a set of routes and the dispatch entry point."""

    var _routes: List[_Route]

    def __init__(out self):
        self._routes = List[_Route]()

    def get[path: StaticString](mut self, handler: def() thin -> String):
        """Registers `handler` for `GET path`; its String result becomes a
        200 text response."""
        comptime assert _route_params(path) >= 0, "malformed route literal"
        comptime assert (
            _route_params(path) == 0
        ), "route declares a path parameter but the handler takes none"
        self._routes.append(_Route("GET", String(path), handler))

    def get[path: StaticString](mut self, handler: def(Int) thin -> String):
        """Registers `handler` for `GET path`, where `path` has exactly one
        `{name}` segment. The segment is converted to `Int` and passed to
        `handler` by position (the name is not checked); a segment that is
        not an integer yields 400 without calling `handler`."""
        comptime assert _route_params(path) >= 0, "malformed route literal"
        comptime assert (
            _route_params(path) == 1
        ), "handler takes one Int path parameter; route must declare one"
        self._routes.append(_Route("GET", String(path), handler))

    def handle(self, request: Request) -> Response:
        """Dispatches `request` through the application's routes.

        This is the backend seam: every transport (the in-memory TestClient,
        network adapters) delivers requests through this method. The first
        registered route whose method and path match handles the request.
        """
        var captured = String()
        for route in self._routes:
            if route.method != request.method or not _match(
                route.path, request.path, captured
            ):
                continue
            if route.handler.isa[_NoArgs]():
                return Response.text(route.handler[_NoArgs]())
            var value: Int
            try:
                value = _parse_int(captured)
            except:
                return Response.text("Bad Request", status=400)
            return Response.text(route.handler[_IntArg](value))
        return Response.text("Not Found", status=404)
