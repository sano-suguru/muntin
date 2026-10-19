"""Serves bench/overhead/muntin_app.mojo with Muntin's `Server`, plus
`GET /slow/{ms}`, for `scripts/bench_load.sh`. Not part of Muntin and not
run by CI.

    server_muntin PORT WORKERS MIDDLEWARE

`GET /slow/{ms}` sleeps `ms` milliseconds on the serving thread and answers
`slow`: a handler waiting on a blocking call. `GET /headers` answers the
request's fields as the handler sees them (`fields` below), so the client
can check the adapter's conversion, not only its cost. Every `Server` setting is its
default. One worker serves through `Server.serve(app)` on the calling
thread; more through `serve[make](workers=n)`. MIDDLEWARE is 0 or 1. Prints
`ready PORT` once bound.
"""

from std.sys import argv
from std.time import sleep

from muntin import App, Headers
from muntin_flare import Server

from muntin_app import build


def slow(ms: Int) -> String:
    sleep(Float64(ms) / 1000.0)
    return "slow"


def _lookup(headers: Headers, name: String, mut out: String):
    var values = headers.get_all(name)
    out += String(name, "=", len(values), "\n")
    for v in values:
        out += name + ": " + v + "\n"


def fields(headers: Headers) -> String:
    """Every field but Host and Cookie, in order, as `name: value` lines
    with the name as received (HTTP/2 moves both: `:authority`, and Cookie
    fields joined into one, RFC 9113 8.2.3); then, for each of four names looked up in another casing than
    any request sends, `NAME=count` and each value as `NAME: value`."""
    var out = String()
    for i in range(len(headers)):
        var name = headers.name(i)
        var lower = name.lower()
        if lower != "host" and lower != "cookie":
            out += name + ": " + headers.value(i) + "\n"
    for name in ["COOKIE", "Accept-Language", "HOST", "X-Absent"]:
        _lookup(headers, String(name), out)
    return out^


def make() raises -> App:
    var app = build(Int(argv()[3]) != 0)
    app.get["/slow/{ms}"](slow)
    app.get["/headers"](fields)
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
