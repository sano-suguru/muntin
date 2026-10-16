"""A Muntin route through the Flare adapter's `Server`, on the port given as
the first argument, for `scripts/bench_headers.sh`: `GET /` answers `hi`;
`GET /read` looks up 10 names, walks every field and answers how many bytes
it saw, an application's work on its request fields. One worker; a 60 s
idle timeout, so a request that waits behind another is measured as a wait
rather than dropped (docs/DX.md section 1)."""

from std.sys import argv

from muntin import App, Request, Response
from muntin_flare import Server


def hello() -> String:
    return "hi"


def read(req: Request) raises -> Response:
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
        var v = req.headers.get(name)
        if v:
            seen += v.value().byte_length()
    for i in range(len(req.headers)):
        seen += req.headers.name(i).byte_length()
        seen += req.headers.value(i).byte_length()
    return Response.text(String(seen))


def main() raises:
    var app = App()
    app.get["/"](hello)
    app.get["/read"](read)
    var server = Server.bind("127.0.0.1", Int(argv()[1]), idle_timeout_ms=60000)
    server.serve(app)
