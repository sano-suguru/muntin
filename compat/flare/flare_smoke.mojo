"""Flare compatibility fixture for M1-001. Not part of Muntin.

Builds and runs only in the `flare` pixi environment against the pinned
Flare release (see scripts/check_flare.sh). It imports Flare alone: no
Muntin module, no adapter, and it opens no socket when run.
"""

from std.sys import argv

from flare.http import HttpServer, Request, Response, ok
from flare.net import SocketAddr


def hello(req: Request) raises -> Response:
    return ok("hello")


def main() raises:
    var response = hello(Request("GET", "/hello"))
    if response.status != 200 or response.text() != "hello":
        raise Error("unexpected Flare response")
    print(response.status, response.text())

    # Never taken by scripts/check_flare.sh. It keeps Flare's server
    # bind/serve path in the type-checked build without running it.
    if len(argv()) > 1 and argv()[1] == "--serve":
        var server = HttpServer.bind(SocketAddr.localhost(0))
        server.serve(hello)
