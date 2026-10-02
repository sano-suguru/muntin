# Must not compile: a raw handler returning String on GET. Raw handlers
# return Response only (M2-014); no GET overload takes a Request, so the
# call fails overload resolution with a note for the raw candidate.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(req: Request) thin -> String' to 'def(var Request) raises Never thin -> Response'

from muntin import Request, Response
from raw_spike import RawApp


def h(req: Request) -> String:
    return req.body


def main():
    var app = RawApp()
    app.get["/hooks"](h)
