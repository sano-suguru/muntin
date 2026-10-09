# Must not compile (M3-032): the private handler `Server.serve` uses over a
# borrowed `App` is not `Copyable`, which keeps Flare's multi-worker `serve`
# out of reach. If this builds, revisit the guard
# (docs/history/architecture-decisions.md "Serving entrypoint decision
# (M3-032)"), not concurrency.
# Expected diagnostic (checked by scripts/check_flare.sh): does not conform to trait 'Handler & Copyable'
from flare.http import HttpServer
from flare.net import SocketAddr
from muntin import App
from muntin_flare import _BorrowedHandler


def main() raises:
    var app = App()
    var server = HttpServer.bind(SocketAddr.localhost(0))
    server.serve(_BorrowedHandler(app), num_workers=2)
