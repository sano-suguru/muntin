# Must not compile: a raw Request handler. Not a supported shape yet.
# Expected diagnostic (checked by scripts/check.sh): value passed to 'handler' cannot be converted from 'def raw(req: Request) thin -> String' to 'def(Int) raises Never thin -> String'

from muntin import App, Request


def raw(req: Request) -> String:
    return req.path


def main():
    var app = App()
    app.get["/raw"](raw)
