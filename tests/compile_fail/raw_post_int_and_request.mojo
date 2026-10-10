# Must not compile: a route value and a Request on App.post. A raw handler
# takes only the Request (M2-015); the generic (Int, B) overload's guard
# names the raw shape.
# Expected diagnostic (checked by scripts/check.sh): Request is the whole request, not a body; a raw handler takes only the Request and returns Response

from muntin import App, Request, Response


def h(id: Int, req: Request) -> Response:
    return Response(200, req.body.copy())


def main():
    var app = App()
    app.post["/hooks/{id}"](h)
