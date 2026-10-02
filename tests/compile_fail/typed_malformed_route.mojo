# Must not compile: a malformed route literal on the ToResponse overload for
# `def()` handlers (M2-008).
# Expected diagnostic (checked by scripts/check.sh): malformed route literal

from muntin import App, Response


def teapot() -> Response:
    return Response.text("tea", status=418)


def main():
    var app = App()
    app.get["teapot"](teapot)
