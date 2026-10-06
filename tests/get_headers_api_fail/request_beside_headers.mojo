# Must not compile: a raw handler takes only the `Request`, which already
# holds the fields, so a `Headers` beside it keeps the raw rule's message (the
# `Request` rule runs before the `Headers` rule). Decision:
# docs/history/architecture-decisions.md, "Typed get header access decision
# (M3-016)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a raw get handler takes only the Request and returns Response
from muntin import App, Headers, Request, Response


def h(req: Request, headers: Headers) -> Response:
    return Response.text("x")


def main():
    var app = App()
    app.get["/x"](h)
