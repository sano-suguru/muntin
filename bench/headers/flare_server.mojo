"""`GET /` answered by a plain handler on Flare's `HttpServer` alone, on the
port given as the first argument, for `scripts/bench_headers.sh`. One
worker and a 60 s idle timeout, as `muntin_server.mojo`."""

from std.sys import argv

from flare.http import HttpServer, Request, Response, ServerConfig, ok
from flare.net import SocketAddr


def hello(req: Request) raises -> Response:
    return ok("hi")


def main() raises:
    var config = ServerConfig()
    config.idle_timeout_ms = 60000
    var server = HttpServer.bind(
        SocketAddr.localhost(UInt16(Int(argv()[1]))), config^
    )
    server.serve(hello)
