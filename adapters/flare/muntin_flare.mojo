"""Flare transport adapter for Muntin (M1-002). Not part of Muntin core.

Depends inward on Muntin's backend seam, `App.handle(Request) -> Response`,
and never routes on its own. Builds only in the `flare` pixi environment.

Conversion policy (M1; target handling restated for M2-002):
- method: copied verbatim.
- request target: Flare's `url` (path plus any query, undecoded) passed
  verbatim to Muntin's `Request`, which splits path from query, exactly as
  for the in-memory backend. The adapter does not split, parse or decode the
  query, and does not use Flare's query helpers.
- request body: bytes copied into a `String`, decoded as UTF-8 with invalid
  sequences replaced by U+FFFD (Flare's `Request.text()`).
- headers, version and peer: dropped; Muntin `Request` has none.
- response: status and body bytes copied; reason left unset, so Flare's
  default applies; no headers set (Muntin `Response` has none).
"""

from flare.http import (
    Handler,
    Request as FlareRequest,
    Response as FlareResponse,
)
from muntin import App, Request, Response


def to_muntin_request(request: FlareRequest) -> Request:
    return Request(request.method, request.url, request.text())


def to_flare_response(response: Response) -> FlareResponse:
    return FlareResponse(
        status=response.status, body=List(response.body.as_bytes())
    )


struct MuntinHandler(Handler):
    """Serves a Muntin `App` as a Flare handler."""

    var app: App

    def __init__(out self, var app: App):
        self.app = app^

    def serve(self, request: FlareRequest) -> FlareResponse:
        return to_flare_response(self.app.handle(to_muntin_request(request)))
