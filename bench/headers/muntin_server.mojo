"""`GET /` answered by a Muntin route through the Flare adapter's `Server`,
on the port given as the first argument, for `scripts/bench_headers.sh`.
One worker; a 60 s idle timeout, so a request that waits behind another is
measured as a wait rather than dropped (docs/DX.md section 1)."""

from std.sys import argv

from muntin import App
from muntin_flare import Server


def hello() -> String:
    return "hi"


def main() raises:
    var app = App()
    app.get["/"](hello)
    var server = Server.bind("127.0.0.1", Int(argv()[1]), idle_timeout_ms=60000)
    server.serve(app)
