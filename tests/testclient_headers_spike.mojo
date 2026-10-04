# M3-010 TestClient request-headers decision spike, library side. Not
# production code: `SpikeClient` is `muntin.testing.TestClient` with the
# selected change (candidate A: a last, defaulted `var headers: Headers =
# Headers()` argument on `get` and `post`, moved into the `Request`), built on
# production `App`, `Request` and `Headers`. `AutoTypeClient` models rejected
# candidate D2 (a `Content-Type` the client adds by looking at the body), so
# the parity break that rules it out is executable. test.sh runs both through
# tests/test_spike_testclient_headers.mojo. Decision and evidence:
# docs/ARCHITECTURE.md, "TestClient request headers decision (M3-010)".
# Must-not-compile evidence: tests/testclient_headers_fail.

from muntin import App, Headers, Request, Response


struct SpikeClient[origin: Origin[mut=False]]:
    """`TestClient` as decided in M3-010: the bare forms are unchanged, and
    an optional last argument carries the request's header fields."""

    var _app: Pointer[App, Self.origin]

    def __init__(out self, ref[Self.origin] app: App):
        self._app = Pointer(to=app)

    def get(self, target: String, var headers: Headers = Headers()) -> Response:
        """Sends `GET target` with `headers` (none by default), moved into
        the `Request` (pass `headers^` or `headers.copy()`)."""
        return self._app[].handle(Request("GET", target, "", headers^))

    def post(
        self, target: String, body: String, var headers: Headers = Headers()
    ) -> Response:
        """Sends `POST target` with `body` and `headers` (none by default),
        moved into the `Request`."""
        return self._app[].handle(Request("POST", target, body, headers^))


struct AutoTypeClient[origin: Origin[mut=False]]:
    """Rejected candidate D2: `post` adds `Content-Type: application/json`
    when the body looks like JSON."""

    var _app: Pointer[App, Self.origin]

    def __init__(out self, ref[Self.origin] app: App):
        self._app = Pointer(to=app)

    def post(self, target: String, body: String) raises -> Response:
        var headers = Headers()
        if body.startswith("{") or body.startswith("["):
            headers.add("Content-Type", "application/json")
        return self._app[].handle(Request("POST", target, body, headers^))
