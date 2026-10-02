# Must not compile on Mojo 1.1.0: an explicitly typed function value with a
# borrowed Request does not convert to the registered
# def(var Request) thin raises E -> Response (a plain `def h(req: Request)`
# does). An explicit value is spelled
# `def(var Request) thin raises Never -> Response` (tests/test_raw.mojo). If
# this compiles, revisit docs/ARCHITECTURE.md "Raw Request decision (M2-014)".
# Expected diagnostic (checked by scripts/check.sh): TODO: function type conversions between closures not supported yet

from muntin import App, Request, Response


def h(req: Request) -> Response:
    return Response.text(req.body)


def main():
    var app = App()
    var f: def(Request) thin raises Never -> Response = h
    app.post["/hooks"](f)
