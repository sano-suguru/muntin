# Built by scripts/check.sh from a directory holding only this file and
# tests/error_spike.mojo, so the application module
# (tests/test_spike_error.mojo) is not on the include path. It registers
# handlers raising an error type the library has never seen, next to
# non-raising and `raises` handlers; if the library named an application
# type in the code this instantiates, the build fails. (Mojo 1.1.0 resolves
# imports lazily: an import that nothing uses is not an error, so a bare
# `import` would not catch that.)

from std.os import abort

from muntin import Request
from error_spike import ErrorApp


@fieldwise_init
struct Missing(Movable):
    var id: Int


def hello() -> String:
    return "hello"


def fail(id: Int) raises -> String:
    raise Error("boom")


def find(id: Int) raises Missing -> String:
    if id == 0:
        raise Missing(id)
    return "found"


def main() raises:
    var app = ErrorApp()
    app.get["/hello"](hello)
    app.get["/fail/{id}"](fail)
    app.get["/find/{id}"](find)
    var ok = app.handle(Request("GET", "/find/1"))
    var missing = app.handle(Request("GET", "/find/0"))
    var failed = app.handle(Request("GET", "/fail/1"))
    var bad = app.handle(Request("GET", "/find/x"))
    var plain = app.handle(Request("GET", "/hello"))
    if (
        ok.status != 200
        or ok.text() != "found"
        or missing.status != 500
        or missing.text() != "Internal Server Error"
        or failed.status != 500
        or bad.status != 400
        or plain.text() != "hello"
    ):
        print("unexpected response")
        abort()
