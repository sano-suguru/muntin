# Must not compile (M3-032): Flare's multi-worker `serve` requires a
# `Copyable` handler, and `MuntinHandler` owns an `App`, which is `Movable`
# only. If this builds, revisit the guard (docs/history/architecture-decisions.md
# "Serving entrypoint decision (M3-032)"), not concurrency.
# Expected diagnostic (checked by scripts/check_flare.sh): does not conform to trait 'Handler & Copyable'
from flare.http import HttpServer
from flare.net import SocketAddr
from muntin import App
from muntin_flare import MuntinHandler


def main() raises:
    var server = HttpServer.bind(SocketAddr.localhost(0))
    server.serve(MuntinHandler(App()), num_workers=2)
