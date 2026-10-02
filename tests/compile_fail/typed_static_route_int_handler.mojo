# Must not compile: a static route, a `-> Response` handler taking one Int
# (ToResponse overload, M2-008).
# Expected diagnostic (checked by scripts/check.sh): handler takes one Int parameter; route must declare exactly one path or query parameter

from muntin import App, Response


def item(id: Int) -> Response:
    return Response.text(String(id), status=202)


def main():
    var app = App()
    app.get["/items"](item)
