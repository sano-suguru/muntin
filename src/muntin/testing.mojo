"""In-memory backend for driving a Muntin application without a network."""

from .app import App
from .http import Request, Response


struct TestClient[origin: Origin[mut=False]]:
    """Sends requests to a borrowed `App` through `App.handle`, in memory."""

    var _app: Pointer[App, Self.origin]

    def __init__(out self, ref[Self.origin] app: App):
        self._app = Pointer(to=app)

    def get(self, path: String) -> Response:
        return self._app[].handle(Request("GET", path))
