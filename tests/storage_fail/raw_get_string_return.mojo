# Must not compile: a raw handler returning String on App.get. Raw handlers
# return Response only (M2-015); no GET overload takes a Request with a String
# result, so overload resolution fails with a note for the raw candidate.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(req: Request) thin -> String' to 'def(var Request) raises Never thin -> Response'

from muntin import App, Request


def h(req: Request) -> String:
    return req.body


def main():
    var app = App()
    app.get["/hooks"](h)
