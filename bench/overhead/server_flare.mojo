"""Serves `flare_app.mojo` with Flare's `HttpServer`, for
`scripts/bench_overhead.sh`. Not part of Muntin and not run by CI.

    server_flare PORT WORKERS MIDDLEWARE

One worker serves through `HttpServer.serve(handler)`; more through
`serve(handler, num_workers=n, pin_cores=False)`, each worker with its own
copy of the handler. Workers are not pinned, as Muntin's are not, so the
script's CPU split holds. Flare's listener strategy for several workers is
its environment's (`FLARE_REUSEPORT_WORKERS`). MIDDLEWARE is 0 or 1. Prints
`ready PORT` once bound.
"""

from std.sys import argv

from flare.http import Handler, HttpServer
from flare.net import SocketAddr

from flare_app import Tracing, router


def _serve[H: Handler & Copyable](mut srv: HttpServer, var h: H, workers: Int) raises:
    if workers == 1:
        srv.serve(h^)
    else:
        srv.serve(h^, num_workers=workers, pin_cores=False)


def main() raises:
    var args = argv()
    var workers = Int(args[2])
    var srv = HttpServer.bind(SocketAddr.localhost(UInt16(Int(args[1]))))
    print("ready", Int(srv.local_addr().port), flush=True)
    if Int(args[3]) != 0:
        _serve(srv, Tracing(router()), workers)
    else:
        _serve(srv, router(), workers)
