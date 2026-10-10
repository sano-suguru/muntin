# Built by scripts/check.sh from a directory holding only this file and
# tests/error_response_spike.mojo, so the application module
# (tests/test_spike_error_response.mojo) is not on the include path. It
# registers a handler raising a move-only error type that opts into
# `ToErrorResponse` here, one the library has never seen, next to a type
# that does not opt in and a bare `raises` handler. The library's
# `conforms_to` sees the conformance across the module boundary; if it
# named an application type in the code this instantiates, the build
# fails. (Mojo 1.1.0 resolves imports lazily, so a bare `import` would not
# catch that.)

from std.os import abort

from muntin import Request, Response
from error_response_spike import ErrorResponseApp, ToErrorResponse


@fieldwise_init
struct Missing(Movable, ToErrorResponse):
    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("missing " + String(self.id), status=404)


@fieldwise_init
struct Opaque(Movable):
    var id: Int


def find(id: Int) raises Missing -> String:
    if id == 0:
        raise Missing(id)
    return "found"


def hide(id: Int) raises Opaque -> String:
    raise Opaque(id)


def fail(id: Int) raises -> String:
    raise Error("boom")


def main() raises:
    var app = ErrorResponseApp()
    app.get["/find/{id}"](find)
    app.get["/hide/{id}"](hide)
    app.get["/fail/{id}"](fail)
    var ok = app.handle(Request("GET", "/find/1"))
    var missing = app.handle(Request("GET", "/find/0"))
    var hidden = app.handle(Request("GET", "/hide/0"))
    var failed = app.handle(Request("GET", "/fail/0"))
    var bad = app.handle(Request("GET", "/find/x"))
    if (
        ok.status != 200
        or ok.text() != "found"
        or missing.status != 404
        or missing.text() != "missing 0"
        or hidden.status != 500
        or hidden.text() != "Internal Server Error"
        or failed.status != 500
        or bad.status != 400
    ):
        print("unexpected response")
        abort()
