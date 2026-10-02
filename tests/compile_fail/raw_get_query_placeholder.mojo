# Must not compile: a raw route on App.get declaring a query parameter. A raw
# handler receives the whole Request and no route value, so the rule and
# message are the ones for `def()` handlers (M2-015).
# Expected diagnostic (checked by scripts/check.sh): route declares a query parameter but the handler takes none

from muntin import App, Request, Response


def h(req: Request) -> Response:
    return Response.text(req.path + req.query)


def main():
    var app = App()
    app.get["/hooks?{id}"](h)
