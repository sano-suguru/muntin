# Must not compile: a raw route with a malformed literal (M2-015): the
# raw overloads check the literal as `def()` handlers do.
# Expected diagnostic (checked by scripts/check.sh): malformed route literal

from muntin import App, Request, Response


def h(req: Request) -> Response:
    return Response.text(req.path)


def main():
    var app = App()
    app.post["hooks"](h)
