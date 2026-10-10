# Must not compile on Mojo 1.1.0: a raw handler value whose type is spelled
# without `raises` does not convert to def(var Request) thin raises E ->
# Response with `E` inferred, the M2-011 limitation
# (storage_fail/typed_thin_value_handler.mojo) on the raw overload (M2-015).
# Spell the value's type `def(var Request) thin raises Never -> Response`.
# Expected diagnostic (checked by scripts/check.sh): TODO: function type conversions between closures not supported yet

from muntin import App, Request, Response


def h(var req: Request) -> Response:
    return Response(200, req.body.copy())


def main():
    var app = App()
    var f: def(var Request) thin -> Response = h
    app.get["/hooks"](f)
