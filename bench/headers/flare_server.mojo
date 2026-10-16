"""A plain handler on Flare's `HttpServer` alone, on the port given as the
first argument, for `scripts/bench_headers.sh`: `GET /` answers `hi`;
`GET /read` looks up `muntin_server.mojo`'s 10 names in Flare's `HeaderMap`
(which offers no walk of its fields) and answers how many bytes it saw.
One worker and a 60 s idle timeout, as `muntin_server.mojo`."""

from std.sys import argv

from flare.http import HttpServer, Request, Response, ServerConfig, ok
from flare.net import SocketAddr


def hello(req: Request) raises -> Response:
    if req.url != "/read":
        return ok("hi")
    var seen = 0
    for name in [
        "Host",
        "User-Agent",
        "Accept",
        "Accept-Language",
        "Accept-Encoding",
        "Cookie",
        "Authorization",
        "X-Request-Id",
        "X-Forwarded-For",
        "x-h0099",
    ]:
        seen += req.headers.get(name).byte_length()
    return ok(String(seen))


def main() raises:
    var config = ServerConfig()
    config.idle_timeout_ms = 60000
    var server = HttpServer.bind(
        SocketAddr.localhost(UInt16(Int(argv()[1]))), config^
    )
    server.serve(hello)
