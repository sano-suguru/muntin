# Must not compile on Mojo 1.1.0: an explicitly typed function value with a
# borrowed Request does not convert to the registered
# def(var Request) thin raises E -> Response (a plain `def h(req: Request)`
# does). An explicit value is spelled
# `def(var Request) thin raises Never -> Response`; the M2-011 limitation
# for values typed without `raises` applies as well (M2-014).
# Expected diagnostic (checked by scripts/check.sh): TODO: function type conversions between closures not supported yet

from muntin import Request, Response
from raw_spike import RawApp


def h(req: Request) -> Response:
    return Response(200, req.body.copy())


def main():
    var app = RawApp()
    var f: def(Request) thin raises Never -> Response = h
    app.post["/hooks"](f)
