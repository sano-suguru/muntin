# Must not compile: a raw handler with a second parameter on App.post. It
# selects post's two-slot overload, whose rule check reports that a raw
# handler takes only the Request (M3-015).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a raw post handler takes only the Request and returns Response

from muntin import App, Request, Response


def h(req: Request, n: Int) -> Response:
    return Response(200, req.body.copy())


def main():
    var app = App()
    app.post["/hooks/{n}"](h)
