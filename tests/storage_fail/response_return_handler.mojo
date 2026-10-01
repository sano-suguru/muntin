# Must not compile: a handler returning Response. Only `-> String` is a
# supported return type.
# Expected diagnostic (checked by scripts/check.sh): value passed to 'handler' cannot be converted from 'def raw() thin -> Response' to 'def() thin -> String'

from muntin import App, Response


def raw() -> Response:
    return Response.text("raw")


def main():
    var app = App()
    app.get["/raw"](raw)
