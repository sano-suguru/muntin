"""Serves bench/overhead/muntin_app.mojo with Muntin's `Server`, plus
`GET /slow/{ms}`, for `scripts/bench_load.sh`. Not part of Muntin and not
run by CI.

    server_muntin PORT WORKERS MIDDLEWARE

`GET /slow/{ms}` sleeps `ms` milliseconds on the serving thread and answers
`slow`: a handler waiting on a blocking call. Every `Server` setting is its
default. One worker serves through `Server.serve(app)` on the calling
thread; more through `serve[make](workers=n)`. MIDDLEWARE is 0 or 1. Prints
`ready PORT` once bound.
"""

from std.sys import argv
from std.time import sleep

from muntin import App
from muntin_flare import Server

from muntin_app import build


def slow(ms: Int) -> String:
    sleep(Float64(ms) / 1000.0)
    return "slow"


def make() raises -> App:
    var app = build(Int(argv()[3]) != 0)
    app.get["/slow/{ms}"](slow)
    return app^


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
