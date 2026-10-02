# Must not compile: a Request handler returning String on App.get. Raw
# handlers return Response only (M2-015,
# storage_fail/raw_get_string_return.mojo has the raw candidate's note).
# Expected diagnostic (checked by scripts/check.sh): value passed to 'handler' cannot be converted from 'def raw(req: Request) thin -> String' to 'def(Int) raises Never thin -> String'

from muntin import App, Request


def raw(req: Request) -> String:
    return req.path


def main():
    var app = App()
    app.get["/raw"](raw)
