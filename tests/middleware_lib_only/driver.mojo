# Built by scripts/check.sh from a directory holding only this file and
# tests/middleware_spike.mojo, so the application module
# (tests/test_spike_middleware.mojo) is not on the include path. It registers
# a middleware function, a middleware struct with a runtime field (as a value
# and as a compile-time value) and a pair of hooks, all defined here, ones the
# library has never seen, and checks each one's answer. If the library named
# an application type in the code this instantiates, the build fails.

from std.os import abort

from muntin import App, Request, Response
from middleware_spike import Middleware, MwApp, Next


def hello() -> String:
    return "hello"


def mark(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    response.headers.add("X-Driver", "function")
    return response^


@fieldwise_init
struct Mark(ImplicitlyCopyable, Middleware):
    var value: String

    def handle(self, var request: Request, var next: Next) raises -> Response:
        var response = next^.run(request^)
        response.headers.add("X-Driver", self.value)
        return response^


def early(request: Request) raises -> Optional[Response]:
    return None


def late(request: Request, var response: Response) raises -> Response:
    response.headers.add("X-Driver", "hook")
    return response^


def _check(app: MwApp, expected: String) raises:
    var r = app.handle(Request("GET", "/hello"))
    if r.text() != "hello" or r.headers.get("X-Driver").or_else("") != expected:
        abort("unexpected answer for " + expected)


def main() raises:
    var app = App()
    app.get["/hello"](hello)
    var f = MwApp(app^)
    f.use(mark)
    _check(f, "function")
    var a = MwApp(App())
    a.app.get["/hello"](hello)
    a.use(Mark(String("value")))
    _check(a, "value")
    var a_static = MwApp(App())
    a_static.app.get["/hello"](hello)
    a_static.use[Mark("static")]()
    _check(a_static, "static")
    var h = MwApp(App())
    h.app.get["/hello"](hello)
    h.before(early)
    h.after(late)
    _check(h, "hook")
    print("middleware spike library: 4 candidates answered")
