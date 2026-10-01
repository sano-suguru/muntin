"""Muntin application: route registration and request dispatch."""

from .http import Request, Response


struct _Route(Copyable, Movable):
    var method: String
    var path: String
    var handler: def() thin -> String

    def __init__(
        out self, method: String, path: String, handler: def() thin -> String
    ):
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
        self._routes.append(_Route("GET", String(path), handler))

    def handle(self, request: Request) -> Response:
        """Dispatches `request` through the application's routes.

        This is the backend seam: every transport (the in-memory TestClient
        now, network adapters later) delivers requests through this method.
        """
        for route in self._routes:
            if route.method == request.method and route.path == request.path:
                return Response.text(route.handler())
        return Response.text("Not Found", status=404)
