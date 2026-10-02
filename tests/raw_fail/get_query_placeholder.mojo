# Must not compile: a raw route declaring a query parameter (M2-014).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: route declares a query parameter but the handler takes none

from muntin import Request, Response
from raw_spike import RawApp


def h(req: Request) -> Response:
    return Response.text(req.query)


def main():
    var app = RawApp()
    app.get["/hooks?{id}"](h)
