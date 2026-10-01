"""Compile-only probe: Flare's server accepts `MuntinHandler` (M1-002).

Built by scripts/check_flare.sh with `--Werror`, and run without arguments,
which exits before binding. It type-checks handing an owned Muntin `App`
to `HttpServer.serve` and opens no socket. Serving for real is M1-003.
"""

from std.sys import argv

from flare.http import HttpServer
from flare.net import SocketAddr
from muntin import App
from muntin_flare import MuntinHandler


def hello() -> String:
    return "hello"


def main() raises:
    var app = App()
    app.get["/hello"](hello)
    var handler = MuntinHandler(app^)

    if len(argv()) > 1 and argv()[1] == "--serve":
        var server = HttpServer.bind(SocketAddr.localhost(0))
        server.serve(handler^)
    print("ok: HttpServer.serve accepts MuntinHandler")
