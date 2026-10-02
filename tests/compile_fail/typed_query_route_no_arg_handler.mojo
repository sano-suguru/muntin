# Must not compile: a route with a query parameter, a `-> Response` handler
# that takes none (ToResponse overload, M2-008).
# Expected diagnostic (checked by scripts/check.sh): route declares a query parameter but the handler takes none

from muntin import App, Response


def teapot() -> Response:
    return Response.text("tea", status=418)


def main():
    var app = App()
    app.get["/items?{limit}"](teapot)
