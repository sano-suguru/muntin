# Must not compile: a raising handler with a typed result (M2-008). The
# ToResponse overloads, like the String ones, take non-raising handlers only.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def teapot() raises thin -> Response' to 'def() thin -> Response'

from muntin import App, Response


def teapot() raises -> Response:
    return Response.text("tea", status=418)


def main():
    var app = App()
    app.get["/teapot"](teapot)
