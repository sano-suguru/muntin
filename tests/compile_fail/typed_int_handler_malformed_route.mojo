# Must not compile: a malformed route literal on the ToResponse overload for
# `def(Int)` handlers (M2-008).
# Expected diagnostic (checked by scripts/check.sh): malformed route literal

from muntin import App, Response


def item(id: Int) -> Response:
    return Response.text(String(id), status=202)


def main():
    var app = App()
    app.get["/items/{}"](item)
