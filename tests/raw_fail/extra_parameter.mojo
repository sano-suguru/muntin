# Must not compile: a raw handler with a second parameter. No overload
# takes it; the raw candidate's note names the accepted function type.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(req: Request, n: Int) thin -> Response' to 'def(var Request) raises Never thin -> Response'

from muntin import Request, Response
from raw_spike import RawApp


def h(req: Request, n: Int) -> Response:
    return Response(200, req.body.copy())


def main():
    var app = RawApp()
    app.post["/hooks/{n}"](h)
