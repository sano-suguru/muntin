"""In-memory backend for driving a Muntin application without a network."""

from .app import App
from .http import Headers, Request, Response


struct TestClient[origin: Origin[mut=False]]:
    """Sends requests to a borrowed `App` through `App.handle`, in memory."""

    var _app: Pointer[App, Self.origin]

    def __init__(out self, ref[Self.origin] app: App):
        self._app = Pointer(to=app)

    def get(
        self, target: String, *, var headers: Headers = Headers()
    ) -> Response:
        """Sends `GET target`; `target` is a path with an optional query.
        `headers` are the request's header fields, moved into the `Request`
        as given (pass `headers=h^` or `headers=h.copy()`); none are sent by
        default."""
        return self._app[].handle(Request("GET", target, "", headers^))

    def post(
        self,
        target: String,
        body: String,
        *,
        var headers: Headers = Headers(),
    ) -> Response:
        """Sends `POST target` with `body`; `target` is a path with an
        optional query. `headers` are the request's header fields, moved
        into the `Request` as given (pass `headers=h^` or
        `headers=h.copy()`); none are sent by default."""
        return self._app[].handle(Request("POST", target, body, headers^))
