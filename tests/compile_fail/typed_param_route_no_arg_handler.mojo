# Must not compile: a route with a path parameter, a `-> Response` handler
# that takes none. The ToResponse overloads (M2-008) keep the String
# overloads' route checks.
# Expected diagnostic (checked by scripts/check.sh): route declares a path parameter but the handler takes none

from muntin import App, Response


def teapot() -> Response:
    return Response.text("tea", status=418)


def main():
    var app = App()
    app.get["/users/{id}"](teapot)
