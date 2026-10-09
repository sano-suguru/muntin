# Must not compile (M3-034): candidate F takes only a function shaped
# `def(var Request, var Next) raises -> Response`; one without `next` is not middleware.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def no_next(var request: Request) raises thin -> Response' to 'MiddlewareFn'
from muntin import App, Request, Response
from middleware_spike import MwApp


def no_next(var request: Request) raises -> Response:
    return Response.text("x")


def main():
    var app = MwApp(App())
    app.use(no_next)
