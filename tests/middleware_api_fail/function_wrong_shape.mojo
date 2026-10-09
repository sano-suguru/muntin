# Must not build (M3-035): `App.use` takes only a function shaped
# `def(var Request, var Next) raises -> Response`; one without `next` is not
# middleware.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def no_next(var request: Request) raises thin -> Response' to 'Middleware'
from muntin import App, Request, Response


def no_next(var request: Request) raises -> Response:
    return Response.text("x")


def main():
    var app = App()
    app.use(no_next)
