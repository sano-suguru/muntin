# Must not compile: a raw route declaring a path parameter. A raw handler
# receives the whole Request and no route value, so the rule is the one
# for `def()` handlers (M2-014).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: route declares a path parameter but the handler takes none

from muntin import Request, Response
from raw_spike import RawApp


def h(req: Request) -> Response:
    return Response.text(req.path)


def main():
    var app = RawApp()
    app.post["/hooks/{id}"](h)
