"""Serves `muntin_app.mojo` with Muntin's `Server`, for
`scripts/bench_overhead.sh`. Not part of Muntin and not run by CI.

    server_muntin PORT WORKERS MIDDLEWARE

One worker serves through `Server.serve(app)` on the calling thread; more
through `serve[make](workers=n)`, one `App` per worker. MIDDLEWARE is 0 or
1. Prints `ready PORT` once bound.
"""

from std.sys import argv

from muntin import App
from muntin_flare import Server

from muntin_app import build


def _middleware() raises -> Bool:
    return Int(argv()[3]) != 0


def make() raises -> App:
    return build(_middleware())


def main() raises:
    var args = argv()
    var workers = Int(args[2])
    var server = Server.bind("127.0.0.1", Int(args[1]))
    print("ready", server.port(), flush=True)
    if workers == 1:
        var app = make()
        server.serve(app)
    else:
        server.serve[make](workers=workers)
